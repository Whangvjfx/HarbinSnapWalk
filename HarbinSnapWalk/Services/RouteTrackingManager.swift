import Foundation
import MapKit
import CoreLocation
import Combine
import UIKit
import UserNotifications

/// 运动暂停状态持久化容器（供后台挂起、杀死或关闭 App 后恢复使用）
struct PausedWorkoutSession: Codable {
    let cityName: String
    let elapsedSeconds: TimeInterval
    let completedDistanceMeters: Double
    let currentCalories: Double
    let progressRate: Double
    let nextCheckpointIndex: Int
    let skippedCheckpointCount: Int
    let hasAcquiredRoute: Bool
    let pausedLatitude: Double?
    let pausedLongitude: Double?
    let pausedAt: Date
    let startDate: Date?

    // 路线几何数据
    let routeCoordinatesData: [[Double]] // [[lat, lon], ...]
    let routeDistanceMeters: Double
    let routeEstimatedTravelSeconds: TimeInterval
    let routeStrideLength: Double
    let routeIsLoop: Bool
    let routeAnchorWaypointsData: [[Double]]

    // 障碍提示点
    let barrierAlertsData: [PausedBarrierAlert]

    func restoreSnappedRoute() -> SnappedRouteResult {
        let coords = routeCoordinatesData.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        let anchors = routeAnchorWaypointsData.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        let alerts = barrierAlertsData.map {
            RouteBarrierAlert(
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                title: $0.title,
                instruction: $0.instruction
            )
        }
        return SnappedRouteResult(
            polylines: [polyline],
            anchorWaypoints: anchors.isEmpty ? (coords.isEmpty ? [] : [coords.first!, coords.last!]) : anchors,
            totalDistanceMeters: routeDistanceMeters,
            estimatedTravelSeconds: routeEstimatedTravelSeconds,
            strideLength: routeStrideLength,
            shape: routeIsLoop ? .loop : .open,
            barrierAlerts: alerts
        )
    }

    var pausedCoordinate: CLLocationCoordinate2D? {
        guard let lat = pausedLatitude, let lon = pausedLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct PausedBarrierAlert: Codable {
    let latitude: Double
    let longitude: Double
    let title: String
    let instruction: String
}

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

    // 走过即消失 & 完赛重新显示全图路线状态
    @Published var remainingPolylines: [MKPolyline] = []
    @Published var remainingDirectionalArrows: [RouteDirectionArrow] = []
    @Published var showFullCompletedRoute: Bool = false
    @Published var fullRouteResult: SnappedRouteResult? = nil
    private var checkpointCoordIndices: [Int] = []

    // 断点续走与检查点容错增强状态
    @Published var lastPausedCoordinate: CLLocationCoordinate2D? = nil
    @Published var hasRestoredFromPause: Bool = false
    @Published var activeCheckpointCoordinate: CLLocationCoordinate2D? = nil
    @Published var currentCheckpointIndex: Int = 0
    @Published var totalCheckpointCount: Int = 0

    // MARK: - 判定参数（宽容且鲁棒的检查点容错机制）
    /// 检查点到达判定半径：放宽至 60 米，覆盖多车道马路对侧、树荫遮挡及偶发 GPS 漂移
    private let reachRadius: Double = 60.0
    /// 允许向前跳过的检查点数量（4 × 60 米 ≈ 240 米），用于绕开施工围挡、天桥
    private let maxSkipAhead: Int = 4
    /// 全程累计跳过的检查点上限比例
    private let maxSkipRatio: Double = 0.35
    /// 有效步行里程判定比例
    private let minDistanceRatio: Double = 0.50
    /// 定位精度过滤上限（超 60 米视为严重漂移）
    private let maxAcceptableAccuracy: Double = 60.0
    /// 步行速度上限（18 km/h）
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

    // 后台任务保活与断点持久化
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private let persistenceFileName = "paused_workout_session.json"
    private var sessionPersistenceURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(persistenceFileName)
    }

    init() {
        setupLifecycleObservers()
    }

    // MARK: - 生命周期与后台运行保活处理
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidEnterBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillEnterForeground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillTerminate()
            }
        }
    }

    private func handleAppDidEnterBackground() {
        guard isTracking else { return }
        // 用户切出到微信、相机、音乐等其他应用时：自动把当前最新状态持久化到磁盘
        saveCurrentStateToDisk(currentLocation: lastAcceptedLocation?.coordinate ?? initialStartCoordinate)

        // 申请后台任务，保证切出瞬间未完成的运算与数据落地不受阻断
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "HarbinSnapWalkBackgroundTracker") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func handleAppWillEnterForeground() {
        endBackgroundTask()
        if isTracking {
            refreshElapsed()
        }
    }

    private func handleAppWillTerminate() {
        guard isTracking else { return }
        saveCurrentStateToDisk(currentLocation: lastAcceptedLocation?.coordinate ?? initialStartCoordinate)
    }

    private func endBackgroundTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    // MARK: - 行程生命周期控制

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
        self.hasRestoredFromPause = false
        self.lastPausedCoordinate = nil
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
        saveCurrentStateToDisk(currentLocation: initialStartCoordinate)
    }

    func pauseWorkout(currentLocation: CLLocationCoordinate2D? = nil) {
        guard !isPaused else { return }
        self.isPaused = true
        self.pauseBeganAt = Date()
        let loc = currentLocation ?? lastAcceptedLocation?.coordinate ?? initialStartCoordinate
        self.lastPausedCoordinate = loc
        saveCurrentStateToDisk(currentLocation: loc)
        postLocalNotification(
            id: "workout-paused",
            title: "⏸️ 行程已暂停",
            body: "已记录当前暂停位置。即使关闭软件，重新打开也可继续进行。"
        )
    }

    func resumeWorkout() {
        guard isPaused else { return }
        if let began = pauseBeganAt {
            pausedAccumulated += Date().timeIntervalSince(began)
        }
        pauseBeganAt = nil
        lastAcceptedLocation = nil
        self.isPaused = false
        self.hasRestoredFromPause = false
        self.lastPausedCoordinate = nil
        saveCurrentStateToDisk(currentLocation: lastAcceptedLocation?.coordinate)
        self.offRouteNotice = "行程已继续！"
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

        // 最终统计里程严格按实际检测到的距离记录
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
        self.hasRestoredFromPause = false
        self.lastPausedCoordinate = nil
        self.showFullCompletedRoute = true // 走完全程，重新在地图上完整呈现全图路线！
        self.remainingPolylines = []
        self.remainingDirectionalArrows = []
        self.offRouteNotice = "🎉 行程已圆满完成！已重新呈现全城轨迹全貌"
        clearPausedState()

        if completedNaturally {
            postLocalNotification(
                id: "workout-finished",
                title: "🎉 行程已完成",
                body: String(format: "共走 %.2f 公里，用时 %@，消耗约 %.0f 千卡", completedDistanceMeters / 1000.0, formatDuration(elapsedSeconds), finalCalories)
            )
        }
    }

    // MARK: - 容错机制：用户手动强制确认已完成当前段/检查点
    func manuallyConfirmCurrentCheckpoint(userProfile: UserProfileModel, recordStore: ActivityRecordStore) {
        guard isTracking, !checkpoints.isEmpty else { return }

        if !hasAcquiredRoute {
            hasAcquiredRoute = true
            nextCheckpointIndex = min(1, checkpoints.count)
            self.offRouteNotice = "✔️ 已手动确认开始并接入路线"
        } else if nextCheckpointIndex < checkpoints.count {
            nextCheckpointIndex += 1
            let remaining = max(0, checkpoints.count - nextCheckpointIndex)
            if remaining == 0 {
                self.offRouteNotice = "🎉 已到达终点！"
                stopWorkout(userProfile: userProfile, completedNaturally: true, recordStore: recordStore)
                return
            } else {
                self.offRouteNotice = "✔️ 已确认通过当前段 (剩余 \(remaining) 个检查点)"
            }
        } else {
            stopWorkout(userProfile: userProfile, completedNaturally: true, recordStore: recordStore)
            return
        }

        updateCheckpointState()
        updateRemainingRoute(currentLocation: lastAcceptedLocation?.coordinate)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        saveCurrentStateToDisk(currentLocation: lastAcceptedLocation?.coordinate)
    }

    // MARK: - 暂停状态持久化与断点续走恢复
    func saveCurrentStateToDisk(currentLocation: CLLocationCoordinate2D? = nil) {
        guard let route = activeRoute else { return }
        let coords = route.allRouteCoordinates
        let anchors = route.anchorWaypoints
        let loc = currentLocation ?? lastAcceptedLocation?.coordinate ?? initialStartCoordinate

        let alertsData = route.barrierAlerts.map {
            PausedBarrierAlert(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                title: $0.title,
                instruction: $0.instruction
            )
        }

        let session = PausedWorkoutSession(
            cityName: cityName,
            elapsedSeconds: elapsedSeconds,
            completedDistanceMeters: completedDistanceMeters,
            currentCalories: currentCalories,
            progressRate: progressRate,
            nextCheckpointIndex: nextCheckpointIndex,
            skippedCheckpointCount: skippedCheckpointCount,
            hasAcquiredRoute: hasAcquiredRoute,
            pausedLatitude: loc?.latitude,
            pausedLongitude: loc?.longitude,
            pausedAt: Date(),
            startDate: startDate,
            routeCoordinatesData: coords.map { [$0.latitude, $0.longitude] },
            routeDistanceMeters: route.totalDistanceMeters,
            routeEstimatedTravelSeconds: route.estimatedTravelSeconds,
            routeStrideLength: route.strideLength,
            routeIsLoop: route.shape == .loop,
            routeAnchorWaypointsData: anchors.map { [$0.latitude, $0.longitude] },
            barrierAlertsData: alertsData
        )

        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: sessionPersistenceURL, options: .atomic)
        } catch {
            print("保存暂停行程失败: \(error)")
        }
    }

    func checkAndRestorePausedWorkout(userProfile: UserProfileModel) -> Bool {
        guard FileManager.default.fileExists(atPath: sessionPersistenceURL.path) else { return false }
        do {
            let data = try Data(contentsOf: sessionPersistenceURL)
            let session = try JSONDecoder().decode(PausedWorkoutSession.self, from: data)
            let restoredRoute = session.restoreSnappedRoute()

            self.cityName = session.cityName
            self.activeRoute = restoredRoute
            self.fullRouteResult = restoredRoute
            self.showFullCompletedRoute = false
            self.routeCoords = restoredRoute.allRouteCoordinates
            self.routeLengthMeters = restoredRoute.totalDistanceMeters
            let extracted = extractCheckpoints(from: routeCoords, stepMeters: 60.0)
            self.checkpoints = extracted.checkpoints
            self.checkpointCoordIndices = extracted.indices
            self.nextCheckpointIndex = session.nextCheckpointIndex
            self.skippedCheckpointCount = session.skippedCheckpointCount
            self.hasAcquiredRoute = session.hasAcquiredRoute
            self.progressRate = session.progressRate

            self.elapsedSeconds = session.elapsedSeconds
            self.completedDistanceMeters = session.completedDistanceMeters
            self.currentCalories = session.currentCalories
            self.startDate = session.startDate ?? session.pausedAt
            self.pausedAccumulated = 0
            self.pauseBeganAt = Date()
            self.weightProvider = userProfile
            self.initialStartCoordinate = session.pausedCoordinate ?? restoredRoute.startCoordinate
            self.lastPausedCoordinate = session.pausedCoordinate

            self.isTracking = true
            self.isPaused = true
            self.hasRestoredFromPause = true
            self.offRouteNotice = "已恢复上次暂停的行程，点击「继续运动」即可继续！"
            updateCheckpointState()
            updateRemainingRoute(currentLocation: session.pausedCoordinate)
            return true
        } catch {
            print("恢复暂停行程异常: \(error)")
            clearPausedState()
            return false
        }
    }

    func discardRestoredWorkout() {
        clearPausedState()
        timer?.cancel()
        timer = nil
        self.isTracking = false
        self.isPaused = false
        self.hasRestoredFromPause = false
        self.lastPausedCoordinate = nil
        self.activeRoute = nil
        self.remainingPolylines = []
        self.remainingDirectionalArrows = []
        self.showFullCompletedRoute = false
        self.fullRouteResult = nil
        self.offRouteNotice = nil
        updateCheckpointState()
    }

    func clearPausedState() {
        self.lastPausedCoordinate = nil
        self.hasRestoredFromPause = false
        try? FileManager.default.removeItem(at: sessionPersistenceURL)
    }

    // MARK: - GPS 定位更新（真实距离累加与检查点自动推进）
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

        // 2. 速度计算
        var segDist: Double = 0
        var dt: TimeInterval = 0
        if let last = lastAcceptedLocation {
            segDist = location.distance(from: last)
            dt = location.timestamp.timeIntervalSince(last.timestamp)
        }
        let derivedSpeed = dt > 0.5 ? segDist / dt : 0
        let speedMps = location.speed >= 0 ? location.speed : derivedSpeed
        self.currentSpeedKmH = max(0, speedMps * 3.6)

        // 3. 乘车识别
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

        // 4. 里程累计：严格按真实检测到的物理距离计算
        let distanceToRoute = distanceFromPointToPolyline(coord, routeCoords)
        if lastAcceptedLocation != nil, segDist < 80.0 {
            // 放宽缓冲区（110米以内全额计入，260米以内折算计入）
            if distanceToRoute <= 110.0 {
                completedDistanceMeters += segDist
            } else if distanceToRoute <= 260.0 {
                completedDistanceMeters += segDist * 0.90
            }
            if speedMps >= 0.3 && dt > 0 && dt < 30 {
                movingSeconds += dt
                movingDistance += segDist
            }
        }
        lastAcceptedLocation = location

        // 5. 偏航状态与提醒
        if distanceToRoute <= 110.0 {
            offRouteNotice = nil
            isCurrentlyOffRoute = false
        } else if distanceToRoute <= 260.0 {
            offRouteNotice = "正在绕行缓冲带内（遇障碍可安心绕行，回到路线自动衔接）"
            isCurrentlyOffRoute = false
        } else {
            offRouteNotice = "已偏离路线超 260 米，可回到路线或点击「中途改线」"
            if !isCurrentlyOffRoute {
                isCurrentlyOffRoute = true
                let now = Date()
                if lastOffRouteAlertDate == nil || now.timeIntervalSince(lastOffRouteAlertDate!) > 120 {
                    lastOffRouteAlertDate = now
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    postLocalNotification(
                        id: "off-route",
                        title: "已偏离规划路线",
                        body: "您已偏离路线超过 260 米，请回到路线上，或打开 App 中途改线。"
                    )
                }
            }
        }

        // 6. 顺序检查点自动推进
        advanceCheckpoints(with: coord)

        // 7. 自动完赛判定
        if nextCheckpointIndex >= checkpoints.count, !checkpoints.isEmpty {
            let skipOK = Double(skippedCheckpointCount) <= Double(checkpoints.count) * maxSkipRatio
            let distanceOK = completedDistanceMeters >= routeLengthMeters * minDistanceRatio
            if skipOK && distanceOK {
                stopWorkout(userProfile: userProfile, completedNaturally: true, recordStore: recordStore)
            } else if !skipOK {
                offRouteNotice = "已到达终点，可点击「手动确认」或结束行程"
            } else {
                offRouteNotice = "已到达终点，可手动结束或继续多走一段"
            }
        }
    }

    /// 中途动态修改路线
    func replanRouteMidway(newRoute: SnappedRouteResult) {
        loadRoute(newRoute)
        self.offRouteNotice = "路线已中途更新，继续散步吧！"
    }

    var workoutInitialCoordinate: CLLocationCoordinate2D? {
        initialStartCoordinate
    }

    // MARK: - 路线装载与检查点推进

    private func loadRoute(_ route: SnappedRouteResult) {
        self.activeRoute = route
        self.fullRouteResult = route
        self.showFullCompletedRoute = false
        self.routeCoords = route.allRouteCoordinates
        self.routeLengthMeters = route.totalDistanceMeters
        let extracted = extractCheckpoints(from: routeCoords, stepMeters: 60.0)
        self.checkpoints = extracted.checkpoints
        self.checkpointCoordIndices = extracted.indices
        self.nextCheckpointIndex = 0
        self.skippedCheckpointCount = 0
        self.hasAcquiredRoute = false
        self.progressRate = 0
        self.isCurrentlyOffRoute = false
        updateCheckpointState()
        updateRemainingRoute(currentLocation: initialStartCoordinate)
    }

    private func advanceCheckpoints(with coord: CLLocationCoordinate2D) {
        guard !checkpoints.isEmpty else { return }

        // 首次接入路线
        if !hasAcquiredRoute {
            let isLoop = activeRoute?.shape == .loop
            let searchRange = isLoop ? (0..<checkpoints.count) : (0..<min(checkpoints.count, maxSkipAhead + 1))
            var bestIdx: Int? = nil
            var bestDist = Double.greatestFiniteMagnitude
            for k in searchRange {
                let d = distance(coord, checkpoints[k])
                if d <= max(reachRadius, 90.0) && d < bestDist {
                    bestDist = d
                    bestIdx = k
                }
            }
            guard let start = bestIdx else {
                if offRouteNotice == nil {
                    offRouteNotice = isLoop ? "请先走到路线上的任意位置开始" : "请先前往路线起点附近开始"
                }
                return
            }
            if isLoop && start != 0 {
                var ring = checkpoints
                var ringIndices = checkpointCoordIndices
                if ring.count > 2, distance(ring.first!, ring.last!) <= 20.0 {
                    ring.removeLast()
                    ringIndices.removeLast()
                }
                let s = min(start, ring.count - 1)
                checkpoints = Array(ring[s...]) + Array(ring[..<s]) + [ring[s]]
                checkpointCoordIndices = Array(ringIndices[s...]) + Array(ringIndices[..<s]) + [ringIndices[s]]
                nextCheckpointIndex = 1
            } else {
                nextCheckpointIndex = start
            }
            hasAcquiredRoute = true
            updateCheckpointState()
            updateRemainingRoute(currentLocation: coord)
            return
        }

        // 顺序推进：系统自动检测当前及前方允许窗口内的检查点是否已到达
        var advanced = false
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let remaining = max(0, checkpoints.count - nextCheckpointIndex)
            if remaining > 0 {
                self.offRouteNotice = "✔️ 自动通过检查点 (\(nextCheckpointIndex)/\(checkpoints.count))"
            } else {
                self.offRouteNotice = "🎉 已到达终点！"
            }
        }

        if advanced {
            updateCheckpointState()
            updateRemainingRoute(currentLocation: coord)
            saveCurrentStateToDisk(currentLocation: coord)
        }
    }

    // MARK: - 动态计算剩余待走路线（已走过的路段消失，只显示前方路线与对应箭头）
    func updateRemainingRoute(currentLocation: CLLocationCoordinate2D? = nil) {
        guard let route = activeRoute, !routeCoords.isEmpty else {
            self.remainingPolylines = []
            self.remainingDirectionalArrows = []
            return
        }

        // 1. 若尚未走过任何检查点，整条路线均为剩余路线
        guard nextCheckpointIndex > 0 else {
            self.remainingPolylines = route.polylines
            self.remainingDirectionalArrows = route.directionalArrows
            return
        }

        // 2. 若所有检查点都已走过，剩余待走路线为空
        guard nextCheckpointIndex < checkpoints.count,
              nextCheckpointIndex < checkpointCoordIndices.count else {
            self.remainingPolylines = []
            self.remainingDirectionalArrows = []
            return
        }

        // 3. 取出当前活跃检查点在全部折线中的切分点，之前的路段全部切除消失
        let startIdx = checkpointCoordIndices[nextCheckpointIndex]
        guard startIdx < routeCoords.count else {
            self.remainingPolylines = []
            self.remainingDirectionalArrows = []
            return
        }

        var remainingCoords = Array(routeCoords[startIdx...])
        // 若用户当前位置离路线前方较近（80米内），把用户当前点作为剩余路线的起点，视觉平滑连贯
        if let loc = currentLocation ?? lastAcceptedLocation?.coordinate {
            let d = distance(loc, remainingCoords[0])
            if d <= 80.0 && d > 2.0 {
                remainingCoords.insert(loc, at: 0)
            }
        }

        guard remainingCoords.count >= 2 else {
            self.remainingPolylines = []
            self.remainingDirectionalArrows = []
            return
        }

        let poly = MKPolyline(coordinates: remainingCoords, count: remainingCoords.count)
        self.remainingPolylines = [poly]
        self.remainingDirectionalArrows = SnappedRouteResult.buildArrows(polylines: [poly])
    }

    private func updateCheckpointState() {
        guard !checkpoints.isEmpty else {
            progressRate = 0
            activeCheckpointCoordinate = nil
            currentCheckpointIndex = 0
            totalCheckpointCount = 0
            return
        }
        progressRate = min(1.0, Double(nextCheckpointIndex) / Double(checkpoints.count))
        currentCheckpointIndex = min(nextCheckpointIndex, checkpoints.count)
        totalCheckpointCount = checkpoints.count
        activeCheckpointCoordinate = nextCheckpointIndex < checkpoints.count ? checkpoints[nextCheckpointIndex] : checkpoints.last
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
    private func extractCheckpoints(from coords: [CLLocationCoordinate2D], stepMeters: Double) -> (checkpoints: [CLLocationCoordinate2D], indices: [Int]) {
        guard coords.count > 1 else {
            return (coords, coords.isEmpty ? [] : [0])
        }
        var list: [CLLocationCoordinate2D] = [coords[0]]
        var indices: [Int] = [0]
        var travelled = 0.0
        for i in 1..<coords.count {
            travelled += distance(coords[i - 1], coords[i])
            if travelled >= stepMeters {
                list.append(coords[i])
                indices.append(i)
                travelled = 0
            }
        }
        if let lastPt = coords.last, distance(list.last!, lastPt) > 15.0 {
            list.append(lastPt)
            indices.append(coords.count - 1)
        }
        return (list, indices)
    }

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
