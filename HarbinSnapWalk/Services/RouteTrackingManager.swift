import Foundation
import MapKit
import CoreLocation
import Combine

@MainActor
final class RouteTrackingManager: ObservableObject {
    @Published var isTracking: Bool = false
    @Published var isPaused: Bool = false
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var completedDistanceMeters: Double = 0
    @Published var currentSpeedKmH: Double = 0
    @Published var currentCalories: Double = 0
    @Published var progressRate: Double = 0.0 // 0.0 ~ 1.0
    @Published var offRouteNotice: String? = nil
    @Published var showWorkoutSummary: Bool = false
    @Published var lastCompletedRecord: ActivityRecord? = nil

    // 活跃路线与检查点
    private(set) var activeRoute: SnappedRouteResult?
    private var checkpoints: [CLLocationCoordinate2D] = []
    private var visitedCheckpointIndices = Set<Int>()
    private var timer: AnyCancellable?
    private var lastRecordedLocation: CLLocationCoordinate2D?
    private var initialStartCoordinate: CLLocationCoordinate2D?
    private var cityName: String = "哈尔滨市"

    func startWorkout(
        route: SnappedRouteResult,
        userProfile: UserProfileModel,
        cityName: String,
        currentLocation: CLLocationCoordinate2D?
    ) {
        self.activeRoute = route
        self.cityName = cityName
        self.initialStartCoordinate = route.startCoordinate ?? currentLocation
        self.elapsedSeconds = 0
        self.completedDistanceMeters = 0
        self.currentSpeedKmH = 0
        self.currentCalories = 0
        self.progressRate = 0.0
        self.offRouteNotice = nil
        self.isTracking = true
        self.isPaused = false
        self.lastRecordedLocation = currentLocation

        // 提取路线中每隔约 60 米的判定检查点
        self.checkpoints = extractCheckpoints(from: route.allRouteCoordinates, stepMeters: 60.0)
        self.visitedCheckpointIndices.removeAll()

        startTimer(userProfile: userProfile)
    }

    func pauseWorkout() {
        self.isPaused = true
    }

    func resumeWorkout() {
        self.isPaused = false
    }

    func stopWorkout(userProfile: UserProfileModel, completedNaturally: Bool, recordStore: ActivityRecordStore) {
        timer?.cancel()
        timer = nil

        let finalSpeed = elapsedSeconds > 0 ? (completedDistanceMeters / 1000.0) / (elapsedSeconds / 3600.0) : 0
        let finalCalories = userProfile.calculateCalories(durationSeconds: elapsedSeconds, speedKmH: max(finalSpeed, 3.8))
        let steps = Int(round(completedDistanceMeters / userProfile.effectiveStrideLength))

        let record = ActivityRecord(
            id: UUID(),
            date: Date(),
            cityName: cityName,
            distanceMeters: completedDistanceMeters,
            durationSeconds: elapsedSeconds,
            steps: max(steps, 0),
            caloriesKcal: finalCalories,
            averageSpeedKmH: finalSpeed,
            completionRate: progressRate,
            isLoop: activeRoute?.shape == .loop
        )

        recordStore.addRecord(record)
        self.lastCompletedRecord = record
        self.showWorkoutSummary = true

        self.isTracking = false
        self.isPaused = false
        self.offRouteNotice = nil
    }

    /// GPS 定位更新回调：支持无障碍平地绕行宽容度、防作弊、自动豁免被绕开的障碍点并检测完赛
    func processGPSUpdate(
        newLocation: CLLocationCoordinate2D,
        gpsSpeedMps: Double,
        userProfile: UserProfileModel,
        recordStore: ActivityRecordStore
    ) {
        guard isTracking, !isPaused, let route = activeRoute else { return }

        // 1. 防作弊检测：如果瞬时 GPS 速度超过 18 km/h (5.0 m/s)，判定为乘坐机动车，不计入有效步行
        let speedKmH = max(0, gpsSpeedMps * 3.6)
        if speedKmH > 18.0 {
            self.offRouteNotice = "⚠️ 检测到车速过快，已暂停步数与里程统计"
            return
        }

        // 2. 距离累计与无障碍绕行走廊计算
        if let last = lastRecordedLocation {
            let segDist = distanceBetween(last, newLocation)
            // 滤除定位漂移（单次点跳变 > 80m 不计）
            if segDist < 80.0 {
                let minDistanceToRoute = minDistance(from: newLocation, to: checkpoints)

                if minDistanceToRoute <= 90.0 {
                    // 无障碍全额走廊（90 米内：允许走对侧人行道、绕开施工围挡或前往邻近地面斑马线平交过街）
                    self.completedDistanceMeters += segDist
                    self.offRouteNotice = nil
                } else if minDistanceToRoute <= 220.0 {
                    // 宽容绕障缓冲带（90~220 米：允许大范围绕开天桥/封闭门禁，按 85% 折算里程）
                    self.completedDistanceMeters += segDist * 0.85
                    self.offRouteNotice = "正在绕行缓冲带内（若遇障碍/天桥可安心绕行，重回主路自动衔接）"
                } else {
                    // 偏离超过 220 米，提示回到路线或点击「中途改线」
                    self.offRouteNotice = "已偏离路线超 220 米，可回到主路或点击下方「中途改线」"
                }
            }
        }
        self.lastRecordedLocation = newLocation

        // 3. 推进检查点进度 + 无障碍前向跳点自动豁免（若因避开天桥/路障绕过了中间 1~4 个检查点，回到前方路线时自动补齐）
        var newlyReachedIndices: [Int] = []
        for (idx, cp) in checkpoints.enumerated() {
            if !visitedCheckpointIndices.contains(idx) {
                if distanceBetween(newLocation, cp) <= 75.0 {
                    visitedCheckpointIndices.insert(idx)
                    newlyReachedIndices.append(idx)
                }
            }
        }

        // 前向跳点自动豁免：当用户绕过某个障碍重新踏上前方检查点 idx 时，若 idx 前方最多 4 个检查点内已有已打卡点，则自动豁免中间被绕开的障碍点
        for idx in newlyReachedIndices {
            let lookbackStart = max(0, idx - 5)
            if lookbackStart < idx {
                let hasPriorVisited = (lookbackStart..<idx).contains { visitedCheckpointIndices.contains($0) } || idx <= 2
                if hasPriorVisited {
                    for bypassed in lookbackStart..<idx {
                        visitedCheckpointIndices.insert(bypassed)
                    }
                }
            }
        }

        if !checkpoints.isEmpty {
            self.progressRate = min(1.0, Double(visitedCheckpointIndices.count) / Double(checkpoints.count))
        }

        // 4. 自动完赛判定：覆盖度 >= 78% 且到达终点判定圈（<= 65米）或覆盖度 >= 94%
        if let endCoord = route.endCoordinate {
            let distToEnd = distanceBetween(newLocation, endCoord)
            if (progressRate >= 0.78 && distToEnd <= 65.0) || (progressRate >= 0.94) {
                stopWorkout(userProfile: userProfile, completedNaturally: true, recordStore: recordStore)
            }
        }
    }

    /// 中途动态修改路线
    func replanRouteMidway(newRoute: SnappedRouteResult) {
        self.activeRoute = newRoute
        self.checkpoints = extractCheckpoints(from: newRoute.allRouteCoordinates, stepMeters: 60.0)
        self.visitedCheckpointIndices.removeAll()
        self.offRouteNotice = "路线已中途更新，继续散步吧！"
    }

    /// 获取最初出发点坐标（用于中途改线时判断是否要回到起点）
    var workoutInitialCoordinate: CLLocationCoordinate2D? {
        initialStartCoordinate
    }

    // MARK: - 辅助计算
    private func startTimer(userProfile: UserProfileModel) {
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isTracking, !self.isPaused else { return }
                self.elapsedSeconds += 1
                
                let km = self.completedDistanceMeters / 1000.0
                let hours = self.elapsedSeconds / 3600.0
                self.currentSpeedKmH = hours > 0 ? (km / hours) : 0
                self.currentCalories = userProfile.calculateCalories(durationSeconds: self.elapsedSeconds, speedKmH: max(self.currentSpeedKmH, 3.8))
            }
    }

    private func extractCheckpoints(from coords: [CLLocationCoordinate2D], stepMeters: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 1 else { return coords }
        var list: [CLLocationCoordinate2D] = [coords[0]]
        var last = coords[0]
        for pt in coords {
            if distanceBetween(last, pt) >= stepMeters {
                list.append(pt)
                last = pt
            }
        }
        if let lastPt = coords.last, distanceBetween(list.last!, lastPt) > 15.0 {
            list.append(lastPt)
        }
        return list
    }

    private func minDistance(from target: CLLocationCoordinate2D, to points: [CLLocationCoordinate2D]) -> Double {
        guard !points.isEmpty else { return 0 }
        var minD = Double.infinity
        for pt in points {
            let d = distanceBetween(target, pt)
            if d < minD { minD = d }
        }
        return minD
    }

    private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
    }
}
