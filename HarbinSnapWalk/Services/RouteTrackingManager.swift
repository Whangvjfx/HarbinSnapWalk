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

    /// GPS 定位更新回调：智能判定是否在轨、防作弊、更新进度并检测是否完赛
    func processGPSUpdate(
        newLocation: CLLocationCoordinate2D,
        gpsSpeedMps: Double,
        userProfile: UserProfileModel,
        recordStore: ActivityRecordStore
    ) {
        guard isTracking, !isPaused, let route = activeRoute else { return }

        // 1. 防作弊检测：如果瞬时 GPS 速度超过 18 km/h (5.0 m/s)，判定为乘坐车辆/单车，不计入有效步行
        let speedKmH = max(0, gpsSpeedMps * 3.6)
        if speedKmH > 18.0 {
            self.offRouteNotice = "⚠️ 检测到车速过快，已暂停步数与里程统计"
            return
        }

        // 2. 距离累计与垂线距离计算
        if let last = lastRecordedLocation {
            let segDist = distanceBetween(last, newLocation)
            // 滤除漂移（单次点跳变 > 80m 不计）
            if segDist < 80.0 {
                // 计算当前点到规划路线的最短垂直距离
                let minDistanceToRoute = minDistance(from: newLocation, to: checkpoints)
                
                if minDistanceToRoute <= 45.0 {
                    // 正轨内（允许两侧人行道与路边 45 米内）
                    self.completedDistanceMeters += segDist
                    self.offRouteNotice = nil
                } else if minDistanceToRoute <= 120.0 {
                    // 轻微偏航，给予 60% 折扣累计并提醒
                    self.completedDistanceMeters += segDist * 0.6
                    self.offRouteNotice = "您稍偏离了规划路线，请注意街巷走向"
                } else {
                    // 彻底偏航 (>120米)，不累计进度
                    self.offRouteNotice = "已偏离路线超过 120 米，请回到路线上"
                }
            }
        }
        self.lastRecordedLocation = newLocation

        // 3. 推进检查点进度
        for (idx, cp) in checkpoints.enumerated() {
            if !visitedCheckpointIndices.contains(idx) {
                if distanceBetween(newLocation, cp) <= 45.0 {
                    visitedCheckpointIndices.insert(idx)
                }
            }
        }

        if !checkpoints.isEmpty {
            self.progressRate = min(1.0, Double(visitedCheckpointIndices.count) / Double(checkpoints.count))
        }

        // 4. 自动完赛判定：覆盖度 >= 80% 且到达终点判定圈（<=50米）
        if let endCoord = route.endCoordinate {
            let distToEnd = distanceBetween(newLocation, endCoord)
            if (progressRate >= 0.80 && distToEnd <= 50.0) || (progressRate >= 0.95) {
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
