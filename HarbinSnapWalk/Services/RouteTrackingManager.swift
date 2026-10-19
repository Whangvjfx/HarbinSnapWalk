import Foundation
import MapKit
import CoreLocation
import Combine
import UIKit
import UserNotifications

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

    // MARK: - 判定参数（兼顾宽容与防作弊）
    /// 检查点到达半径（米）：覆盖城市 GPS 常见 10~30 米漂移，以及马路对侧人行道
    private let reachRadius: Double = 40.0
    /// 允许一次性向前跳过的检查点数量（4 × 60 米 ≈ 240 米），用于绕开天桥、施工围挡
    private let maxSkipAhead: Int = 4
    /// 全程累计跳过的检查点不得超过 25%，否则不判定为自动完赛（防止抄近道）
    private let maxSkipRatio: Double = 0.25
    /// 实际有效步行里程至少达到路线长度的 60% 才判定完赛（防止 GPS 跳点/瞬移作弊）
    private let minDistanceRatio: Double = 0.60
    /// 定位精度差于 50 米的点直接丢弃，避免室内/高楼间漂移干扰
    private let maxAcceptableAccuracy: Double = 50.0
    /// 步行速度上限 18 km/h，连续 2 次超过判定为乘车
    private let vehicleSpeedMps: Double = 5.0

    // 活跃路线与检查点
    private(set) var activeRoute: SnappedRouteResult?
    private var routeCoords: [CLLocationCoordinate2D] = []
    private var routeLengthMeters: Double = 0
    private var checkpoints: [CLLocationCoordinate2D] = []
    private var nextCheckpointIndex: Int = 0
    private var skippedCheckpointCount: Int = 0
    private var hasAcquiredRoute: Bool = false

    private var timer: AnyCancellable?
    private var startDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseBeganAt: Date?
    private var movingSeconds: TimeInterval = 0
    private var movingDistance: Double = 0

    private var lastAcceptedLocation: CLLocation?
    private var consecutiveFastFixes: Int = 0
    private var isCurrentlyOffRoute: Bool = false
    private var lastOffRouteAlertDate: Date?
    private var initialStartCoordinate: CLLocationCoordinate2D?
    private var cityName: String = "哈尔滨市"
    private var weightProvider: UserProfileModel?

    func startWorkout(
        route: SnappedRouteResult,
        userProfile: UserProfileModel,
        cityName: String,
        currentLocation: CLLocationCoordinate2D?
    ) {
        self.cityName = cityName
        self.initialStartCoordinate = route.startCoordinate ?? currentLocation
        self.elapsedSeconds = 0
        self.completedDistanceMeters = 0
        self.currentSpeedKmH = 0
        self.currentCalories = 0
        self.offRouteNotice = nil
        self.isTracking = true
        self.isPaused = false
        self.lastAcceptedLocation = nil
        self.consecutiveFastFixes = 0
        self.isCurrentlyOffRoute = false
        self.lastOffRouteAlertDate = nil
        self.startDate = Date()
        self.pausedAccumulated = 0
        self.pauseBeganAt = nil
        self.movingSeconds = 0
        self.movingDistance = 0
        self.weightProvider = userProfile

        loadRoute(route)
        requestNotificationPermissionIfNeeded()
        startTimer(userProfile: userProfile)
    }

    func pauseWorkout() {
        guard !isPaused else { return }
        self.isPaused = true
        self.pauseBeganAt = Date()
    }

    func resumeWorkout() {
        guard isPaused else { return }
        if let began = pauseBeganAt {
            pausedAccumulated += Date().timeIntervalSince(began)
        }
        pauseBeganAt = nil
        // 恢复后重新取点，暂停期间移动的距离不计入
        lastAcceptedLocation = nil
        self.isPaused = false
    }

    func stopWorkout(userProfile: UserProfileModel, completedNaturally: Bool, recordStore: ActivityRecordStore) {
        guard isTracking else { return }
        timer?.cancel()
        timer = nil
        refreshElapsed()

        let avgSpeed = movingSeconds > 0 ? (movingDistance / 1000.0) / (movingSeconds / 3600.0) : 0
        let overallSpeed = elapsedSeconds > 0 ? (completedDistanceMeters / 1000.0) / (elapsedSeconds / 3600.0) : 0
        let finalCalories = userProfile.calculateCalories(durationSeconds: movingSeconds, speedKmH: avgSpeed)
        let steps = Int(round(completedDistanceMeters / userProfile.effectiveStrideLength))

        let record = ActivityRecord(
            id: UUID(),
            date: Date(),
            cityName: cityName,
            distanceMeters: completedDistanceMeters,
            durationSeconds: elapsedSeconds,
            steps: max(steps, 0),
            caloriesKcal: finalCalories,
            averageSpeedKmH: overallSpeed,
            completionRate: progressRate,
            isLoop: activeRoute?.shape == .loop
        )

        recordStore.addRecord(record)
        self.lastCompletedRecord = record
        self.showWorkoutSummary = true

        self.isTracking = false
        self.isPaused = false
        self.offRouteNotice = nil

        if completedNaturally {
            postLocalNotification(
                id: "workout-finished",
                title: "🎉 行程已完成",
                body: String(format: "共走 %.2f 公里，用时 %@，消耗约 %.0f 千卡", completedDistanceMeters / 1000.0, formatDuration(elapsedSeconds), finalCalories)
            )
        }
    }

    /// GPS 定位更新：精度过滤、乘车识别、顺序检查点推进（允许小范围绕障）、自动完赛
    func processLocation(
        _ location: CLLocation,
        userProfile: UserProfileModel,
        recordStore: ActivityRecordStore
    ) {
        guard isTracking, !isPaused, activeRoute != nil else { return }

        // 1. 精度过滤
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxAcceptableAccuracy else {
            self.offRouteNotice = "GPS 信号较弱，正在等待更精确的定位…"
            return
        }
        let coord = location.coordinate

        // 2. 速度计算（优先使用系统测速，缺失时按两点间距离/时间估算）
        var segDist: Double = 0
        var dt: TimeInterval = 0
        if let last = lastAcceptedLocation {
            segDist = location.distance(from: last)
            dt = location.timestamp.timeIntervalSince(last.timestamp)
        }
        let derivedSpeed = dt > 0.5 ? segDist / dt : 0
        let speedMps = location.speed >= 0 ? location.speed : derivedSpeed
        self.currentSpeedKmH = max(0, speedMps * 3.6)

        // 3. 乘车识别：连续 2 次超过 18 km/h
        if speedMps > vehicleSpeedMps && derivedSpeed > vehicleSpeedMps * 0.8 {
            consecutiveFastFixes += 1
        } else {
            consecutiveFastFixes = 0
        }
        if consecutiveFastFixes >= 2 {
            self.offRouteNotice = "⚠️ 检测到移动速度过快（疑似乘车），该段不计入里程与进度"
            lastAcceptedLocation = location
            return
        }

        // 4. 里程累计（按偏离程度给予全额/折算/不计）
        let distanceToRoute = distanceFromPointToPolyline(coord, routeCoords)
        if lastAcceptedLocation != nil, segDist < 80.0 {
            if distanceToRoute <= 90.0 {
                completedDistanceMeters += segDist
            } else if distanceToRoute <= 220.0 {
                completedDistanceMeters += segDist * 0.85
            }
            if speedMps >= 0.4 && dt > 0 && dt < 30 {
                movingSeconds += dt
                movingDistance += segDist
            }
        }
        lastAcceptedLocation = location

        // 5. 偏航状态与提醒（进入偏航时提醒一次，2 分钟内不重复）
        if distanceToRoute <= 90.0 {
            offRouteNotice = nil
            isCurrentlyOffRoute = false
        } else if distanceToRoute <= 220.0 {
            offRouteNotice = "正在绕行缓冲带内（遇天桥/障碍可安心绕行，回到路线自动衔接）"
            isCurrentlyOffRoute = false
        } else {
            offRouteNotice = "已偏离路线超 220 米，可回到路线或点击「中途改线」"
            if !isCurrentlyOffRoute {
                isCurrentlyOffRoute = true
                let now = Date()
                if lastOffRouteAlertDate == nil || now.timeIntervalSince(lastOffRouteAlertDate!) > 120 {
                    lastOffRouteAlertDate = now
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    postLocalNotification(
                        id: "off-route",
                        title: "已偏离规划路线",
                        body: "您已偏离路线超过 220 米，请回到路线上，或打开 App 中途改线。"
                    )
                }
            }
        }

        // 6. 顺序检查点推进
        advanceCheckpoints(with: coord)

        // 7. 自动完赛判定
        if nextCheckpointIndex >= checkpoints.count, !checkpoints.isEmpty {
            let skipOK = Double(skippedCheckpointCount) <= Double(checkpoints.count) * maxSkipRatio
            let distanceOK = completedDistanceMeters >= routeLengthMeters * minDistanceRatio
            if skipOK && distanceOK {
                stopWorkout(userProfile: userProfile, completedNaturally: true, recordStore: recordStore)
            } else if !skipOK {
                offRouteNotice = "已到达终点，但有较多路段未经过，可手动结束或补走"
            } else {
                offRouteNotice = "已到达终点，但有效步行里程不足，可手动结束或继续走"
            }
        }
    }

    /// 中途动态修改路线
    func replanRouteMidway(newRoute: SnappedRouteResult) {
        loadRoute(newRoute)
        self.offRouteNotice = "路线已中途更新，继续散步吧！"
    }

    /// 获取最初出发点坐标（用于中途改线时判断是否要回到起点）
    var workoutInitialCoordinate: CLLocationCoordinate2D? {
        initialStartCoordinate
    }

    // MARK: - 路线装载与检查点推进

    private func loadRoute(_ route: SnappedRouteResult) {
        self.activeRoute = route
        self.routeCoords = route.allRouteCoordinates
        self.routeLengthMeters = route.totalDistanceMeters
        self.checkpoints = extractCheckpoints(from: routeCoords, stepMeters: 60.0)
        self.nextCheckpointIndex = 0
        self.skippedCheckpointCount = 0
        self.hasAcquiredRoute = false
        self.progressRate = 0
        self.isCurrentlyOffRoute = false
    }

    private func advanceCheckpoints(with coord: CLLocationCoordinate2D) {
        guard !checkpoints.isEmpty else { return }

        // 首次接入路线：
        // - 环形路线可从任意检查点起步（自动把该点旋转为起点，终点同步变为该点）
        // - 单向路线必须从前 5 个检查点之一起步
        if !hasAcquiredRoute {
            let isLoop = activeRoute?.shape == .loop
            let searchRange = isLoop ? (0..<checkpoints.count) : (0..<min(checkpoints.count, maxSkipAhead + 1))
            var bestIdx: Int? = nil
            var bestDist = Double.greatestFiniteMagnitude
            for k in searchRange {
                let d = distance(coord, checkpoints[k])
                if d <= reachRadius && d < bestDist {
                    bestDist = d
                    bestIdx = k
                }
            }
            guard let start = bestIdx else {
                if offRouteNotice == nil {
                    offRouteNotice = isLoop ? "请先走到路线上的任意位置开始" : "请先前往路线起点（绿色标记）开始"
                }
                return
            }
            if isLoop && start != 0 {
                var ring = checkpoints
                if ring.count > 2, distance(ring.first!, ring.last!) <= 20.0 {
                    ring.removeLast()
                }
                let s = min(start, ring.count - 1)
                checkpoints = Array(ring[s...]) + Array(ring[..<s]) + [ring[s]]
                nextCheckpointIndex = 1
            } else {
                nextCheckpointIndex = start + 1
            }
            hasAcquiredRoute = true
            updateProgress()
            return
        }

        // 顺序推进：只在 [next, next + maxSkipAhead] 窗口内寻找可到达的检查点，取最远的一个
        var advanced = true
        while advanced && nextCheckpointIndex < checkpoints.count {
            advanced = false
            let upper = min(checkpoints.count - 1, nextCheckpointIndex + maxSkipAhead)
            var reached: Int? = nil
            for k in stride(from: upper, through: nextCheckpointIndex, by: -1) {
                if distance(coord, checkpoints[k]) <= reachRadius {
                    reached = k
                    break
                }
            }
            if let k = reached {
                skippedCheckpointCount += (k - nextCheckpointIndex)
                nextCheckpointIndex = k + 1
                advanced = true
            }
        }
        updateProgress()
    }

    private var effectiveEndCoordinate: CLLocationCoordinate2D? {
        checkpoints.last
    }

    private func updateProgress() {
        guard !checkpoints.isEmpty else { return }
        progressRate = min(1.0, Double(nextCheckpointIndex) / Double(checkpoints.count))
    }

    // MARK: - 计时（基于真实时钟，后台/锁屏期间也准确）
    private func startTimer(userProfile: UserProfileModel) {
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isTracking else { return }
                self.refreshElapsed()
                let avgMovingSpeed = self.movingSeconds > 0 ? (self.movingDistance / 1000.0) / (self.movingSeconds / 3600.0) : 0
                self.currentCalories = userProfile.calculateCalories(durationSeconds: self.movingSeconds, speedKmH: avgMovingSpeed)
            }
    }

    private func refreshElapsed() {
        guard let start = startDate else { return }
        var paused = pausedAccumulated
        if let began = pauseBeganAt {
            paused += Date().timeIntervalSince(began)
        }
        elapsedSeconds = max(0, Date().timeIntervalSince(start) - paused).rounded(.down)
    }

    // MARK: - 本地通知（锁屏/后台时提醒完赛与偏航）
    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postLocalNotification(id: String, title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)小时\(m)分" : "\(m)分钟"
    }

    // MARK: - 几何辅助
    private func extractCheckpoints(from coords: [CLLocationCoordinate2D], stepMeters: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 1 else { return coords }
        var list: [CLLocationCoordinate2D] = [coords[0]]
        var travelled = 0.0
        for i in 1..<coords.count {
            travelled += distance(coords[i - 1], coords[i])
            if travelled >= stepMeters {
                list.append(coords[i])
                travelled = 0
            }
        }
        if let lastPt = coords.last, distance(list.last!, lastPt) > 15.0 {
            list.append(lastPt)
        }
        return list
    }

    /// 点到折线的最短距离（逐段计算点到线段的垂直距离，比点到点更准确）
    private func distanceFromPointToPolyline(_ p: CLLocationCoordinate2D, _ line: [CLLocationCoordinate2D]) -> Double {
        guard line.count >= 2 else {
            return line.first.map { distance(p, $0) } ?? 0
        }
        let mPerLat = 111132.0
        let mPerLon = 111319.5 * cos(p.latitude * .pi / 180.0)
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(line.count - 1) {
            let ax = (line[i].longitude - p.longitude) * mPerLon
            let ay = (line[i].latitude - p.latitude) * mPerLat
            let bx = (line[i + 1].longitude - p.longitude) * mPerLon
            let by = (line[i + 1].latitude - p.latitude) * mPerLat
            let dx = bx - ax
            let dy = by - ay
            let lenSq = dx * dx + dy * dy
            var t = 0.0
            if lenSq > 1e-6 {
                t = max(0, min(1, -(ax * dx + ay * dy) / lenSq))
            }
            let cx = ax + t * dx
            let cy = ay + t * dy
            let d = sqrt(cx * cx + cy * cy)
            if d < best { best = d }
        }
        return best
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
