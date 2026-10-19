import SwiftUI
import MapKit

enum MapTrackingState {
    case free              // 自由浏览模式
    case followLocation    // 居中跟随模式（正北朝上）
    case followHeading     // 视角跟随朝向旋转模式（地图随人转，前方朝上）
}

/// 阶段目标点结构体：第 0 个为起点，后续为依次串联的阶段目标
struct PlannedWaypoint: Identifiable, Equatable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    var index: Int
    var isStart: Bool { index == 0 }
    var title: String {
        index == 0 ? "起点" : "目标 \(index)"
    }

    static func == (lhs: PlannedWaypoint, rhs: PlannedWaypoint) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.index == rhs.index
    }
}

/// 独立的地图视角与航向监听器：通过 @ObservedObject 彻底穿透 MapKit 注解缓存，保证 60fps 硬件级转动
@MainActor
final class MapOrientationManager: ObservableObject {
    @Published var currentHeading: Double = 0.0

    func updateHeading(_ newHeading: Double) {
        let normalized = (newHeading.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
        if abs(currentHeading - normalized) > 0.4 {
            currentHeading = normalized
        }
    }
}

/// 动态行进方向箭头视图：独立监听朝向并实时同步旋转，永不卡滞
struct DynamicRouteArrowView: View {
    let bearingDegrees: Double
    @ObservedObject var orientation: MapOrientationManager

    var body: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(Color.white.opacity(0.85))
            .rotationEffect(.degrees(bearingDegrees - orientation.currentHeading))
            .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
            .id("\(Int(orientation.currentHeading / 2.0))")
    }
}

struct MainMapView: View {
    @StateObject private var snapEngine = RouteSnapEngine()
    @StateObject private var pedometer = PedometerService()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var userProfile = UserProfileModel()
    @StateObject private var recordStore = ActivityRecordStore()
    @StateObject private var savedRouteStore = SavedRouteStore()
    @StateObject private var trackingManager = RouteTrackingManager()
    @StateObject private var orientationManager = MapOrientationManager()

    @State private var selectedCity: SupportedCity = .harbin
    @State private var isDrawingMode = false
    @State private var isWaypointMode = false
    @State private var isWaypointLoop = true
    @State private var plannedWaypoints: [PlannedWaypoint] = []
    @State private var lastDrawnCoordinates: [CLLocationCoordinate2D] = []
    @State private var customStartCoordinate: CLLocationCoordinate2D? = nil
    @State private var isRevisingRoute = false
    @State private var rawScreenPoints: [CGPoint] = []
    @State private var trackingState: MapTrackingState = .free
    @State private var mapCameraHeading: Double = 0.0

    private var effectiveMapHeading: Double {
        if trackingState == .followHeading, let heading = locationManager.userHeading {
            return heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        }
        return mapCameraHeading
    }

    // 模态弹窗控制
    @State private var showCityPicker = false
    @State private var showSearchSheet = false
    @State private var showProfileSheet = false
    @State private var showHistorySheet = false
    @State private var showSavedRoutesSheet = false
    @State private var showSaveRouteDialog = false

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: SupportedCity.harbin.defaultSpot.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.022, longitudeDelta: 0.022)
        )
    )

    var body: some View {
        GeometryReader { geo in
            MapReader { mapProxy in
                ZStack(alignment: .bottom) {
                    ZStack {
                        // 底层原生 Map 容器
                        Map(position: $cameraPosition) {
                            UserAnnotation()

                            // 1. 行程进行中：走完的路段自动消失，仅呈现剩余待走路线与前方箭头
                            if trackingManager.isTracking {
                                ForEach(Array(trackingManager.remainingPolylines.enumerated()), id: \.offset) { _, polyline in
                                    MapPolyline(polyline)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.blue, Color.cyan],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ),
                                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                                        )
                                }

                                // 沿剩余路线均匀呈现方向小箭头 (随地图/朝向旋转硬件级实时精准转动)
                                ForEach(trackingManager.remainingDirectionalArrows) { arrow in
                                    Annotation("", coordinate: arrow.coordinate) {
                                        DynamicRouteArrowView(bearingDegrees: arrow.bearingDegrees, orientation: orientationManager)
                                    }
                                }

                                // 当前活跃目标检查点：发光标示，支持直接点击手动确认通过（容错机制）
                                if let chkCoord = trackingManager.activeCheckpointCoordinate {
                                    Annotation("", coordinate: chkCoord) {
                                        Button(action: {
                                            trackingManager.manuallyConfirmCurrentCheckpoint(userProfile: userProfile, recordStore: recordStore)
                                        }) {
                                            VStack(spacing: 3) {
                                                ZStack {
                                                    Circle()
                                                        .fill(Color.orange.opacity(0.25))
                                                        .frame(width: 38, height: 38)
                                                    Circle()
                                                        .fill(LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                        .frame(width: 26, height: 26)
                                                        .shadow(color: Color.orange.opacity(0.6), radius: 6, y: 2)
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 11, weight: .black))
                                                        .foregroundStyle(.white)
                                                }
                                                HStack(spacing: 2) {
                                                    Image(systemName: "hand.tap.fill")
                                                        .font(.system(size: 8, weight: .bold))
                                                    Text("点此通过")
                                                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2.5)
                                                .background(
                                                    Capsule()
                                                        .fill(LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                                        .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 0.6))
                                                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
                                                )
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                // 记录的上次暂停位置标记（重新打开软件后醒目提示）
                                if trackingManager.isPaused, let pausedCoord = trackingManager.lastPausedCoordinate {
                                    Annotation("", coordinate: pausedCoord) {
                                        VStack(spacing: 2) {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.orange.opacity(0.25))
                                                    .frame(width: 38, height: 38)
                                                Circle()
                                                    .fill(Color.orange)
                                                    .frame(width: 26, height: 26)
                                                    .shadow(color: Color.orange.opacity(0.55), radius: 4)
                                                Image(systemName: "pause.fill")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.white)
                                            }
                                            Text("上次暂停处")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule()
                                                        .fill(Color.orange.opacity(0.95))
                                                        .shadow(color: .black.opacity(0.25), radius: 2)
                                                )
                                        }
                                    }
                                }

                                // 行程中无障碍避障提醒标记
                                if let route = trackingManager.activeRoute {
                                    ForEach(route.barrierAlerts) { alert in
                                        Annotation(alert.title, coordinate: alert.coordinate) {
                                            HStack(spacing: 3) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 10, weight: .bold))
                                                Text(alert.title)
                                                    .font(.system(size: 10, weight: .bold))
                                            }
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(Color.orange)
                                                    .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                                                    .shadow(color: .orange.opacity(0.45), radius: 4, y: 2)
                                            )
                                        }
                                    }
                                }
                            } else if let route = trackingManager.showFullCompletedRoute ? trackingManager.fullRouteResult : snapEngine.currentResult {
                                // 2. 未在行程中或刚刚走完行程：重新呈现全图完整路线
                                ForEach(Array(route.polylines.enumerated()), id: \.offset) { _, polyline in
                                    MapPolyline(polyline)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.blue, Color.cyan],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ),
                                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                                        )
                                }

                                // 起点标记
                                if let startCoord = route.startCoordinate {
                                    Annotation("起点", coordinate: startCoord) {
                                        ZStack {
                                            Circle().fill(.white).frame(width: 24, height: 24)
                                            Circle().fill(Color.green).frame(width: 18, height: 18)
                                            Image(systemName: "figure.walk")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                        .shadow(color: .green.opacity(0.5), radius: 6)
                                    }
                                }

                                // 单向路线的终点标记
                                if route.shape == .open, let endCoord = route.endCoordinate {
                                    Annotation("终点", coordinate: endCoord) {
                                        ZStack {
                                            Circle().fill(.white).frame(width: 24, height: 24)
                                            Circle().fill(Color.red).frame(width: 18, height: 18)
                                            Image(systemName: "flag.fill")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                        .shadow(color: .red.opacity(0.5), radius: 6)
                                    }
                                }

                                // 无障碍提醒标记
                                ForEach(route.barrierAlerts) { alert in
                                    Annotation(alert.title, coordinate: alert.coordinate) {
                                        HStack(spacing: 3) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 10, weight: .bold))
                                            Text(alert.title)
                                                .font(.system(size: 10, weight: .bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.orange)
                                                .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                                                .shadow(color: .orange.opacity(0.45), radius: 4, y: 2)
                                        )
                                    }
                                }
                            }

                            // 阶段选点模式：阶段连贯虚线预览
                            if isWaypointMode && plannedWaypoints.count >= 2 {
                                let pts = plannedWaypoints.map { $0.coordinate } + (isWaypointLoop ? [plannedWaypoints[0].coordinate] : [])
                                let previewPolyline = MKPolyline(coordinates: pts, count: pts.count)
                                MapPolyline(previewPolyline)
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.green, Color.cyan, Color.blue],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: [8, 6])
                                    )
                            }

                            // 阶段选点模式：数字阶段目标标记（起点为绿，后续目标为蓝）
                            if isWaypointMode || (!plannedWaypoints.isEmpty && snapEngine.currentResult == nil) {
                                ForEach(plannedWaypoints) { wp in
                                    Annotation("", coordinate: wp.coordinate) {
                                        VStack(spacing: 2) {
                                            ZStack {
                                                Circle()
                                                    .fill(wp.isStart ? Color.green : Color.blue)
                                                    .frame(width: 32, height: 32)
                                                    .shadow(color: (wp.isStart ? Color.green : Color.blue).opacity(0.5), radius: 6, y: 2)
                                                Circle()
                                                    .stroke(Color.white, lineWidth: 2)
                                                    .frame(width: 32, height: 32)
                                                if wp.isStart {
                                                    Image(systemName: "figure.walk")
                                                        .font(.system(size: 13, weight: .bold))
                                                        .foregroundStyle(.white)
                                                } else {
                                                    Text("\(wp.index)")
                                                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                            Text(wp.title)
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule()
                                                        .fill(wp.isStart ? Color.green.opacity(0.9) : Color.blue.opacity(0.9))
                                                        .overlay(Capsule().stroke(Color.white.opacity(0.6), lineWidth: 0.8))
                                                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                                                )
                                        }
                                    }
                                }
                            }
                        }
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { tapVal in
                                guard isWaypointMode else { return }
                                if let coord = mapProxy.convert(tapVal.location, from: .local) {
                                    addWaypoint(coord)
                                }
                            }
                        )
                        .mapControls {
                            MapCompass()
                            MapScaleView()
                        }
                        .onMapCameraChange(frequency: .continuous) { context in
                            mapCameraHeading = context.camera.heading
                            if trackingState != .followHeading {
                                orientationManager.updateHeading(context.camera.heading)
                            } else if let userH = locationManager.userHeading {
                                let deg = userH.trueHeading >= 0 ? userH.trueHeading : userH.magneticHeading
                                orientationManager.updateHeading(deg)
                            } else {
                                orientationManager.updateHeading(context.camera.heading)
                            }
                        }

                        // 阶段选点模式下的屏幕中心瞄准准星
                        if isWaypointMode {
                            VStack(spacing: 0) {
                                Image(systemName: plannedWaypoints.isEmpty ? "mappin.circle.fill" : "plus.circle.fill")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(plannedWaypoints.isEmpty ? Color.green : Color.blue)
                                    .background(Circle().fill(.white).padding(2))
                                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(plannedWaypoints.isEmpty ? Color.green : Color.blue)
                                    .offset(y: -4)
                            }
                            .allowsHitTesting(false)
                        }

                        // 顶层手绘画布
                        if isDrawingMode {
                            SketchDrawingCanvas(points: $rawScreenPoints) {
                                handleFinishDrawing(mapProxy: mapProxy)
                            }
                        }
                    }
                    .ignoresSafeArea()

                    // 顶部导航栏 / 微胶囊 HUD
                    VStack(spacing: 8) {
                        if trackingManager.isTracking {
                            activeWorkoutTopCapsule
                        } else {
                            topFloatingNavBar
                        }
                        Spacer()
                    }
                    .padding(.top, max(geo.safeAreaInsets.top, 44) + 6)
                    .padding(.horizontal, 16)

                    // 下方中控：运动中极简浮动岛，选点规划模式中控，闲置时 Apple 液态磨砂卡片
                    VStack {
                        if trackingManager.isTracking {
                            minimalActiveWorkoutDock
                        } else if isWaypointMode {
                            waypointPlanningBottomDock(
                                mapProxy: mapProxy,
                                centerPoint: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                            )
                        } else {
                            redesignedBottomCard
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerSheet(selectedCity: $selectedCity) { spot in
                selectedCity = SupportedCity.allCases.first(where: { $0.spots.contains(spot) }) ?? selectedCity
                locateCoordinate(spot.coordinate, delta: 0.020)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            LocationSearchView { coord, _ in
                locateCoordinate(coord, delta: 0.016)
            }
        }
        .sheet(isPresented: $showSavedRoutesSheet) {
            SavedRoutesView(store: savedRouteStore) { saved in
                loadSavedRoute(saved)
            }
        }
        .sheet(isPresented: $showProfileSheet) {
            UserProfileView(profile: userProfile)
        }
        .sheet(isPresented: $showHistorySheet) {
            HistoryRecordsView(store: recordStore)
        }
        .fullScreenCover(isPresented: $showSaveRouteDialog) {
            if let res = snapEngine.currentResult ?? trackingManager.fullRouteResult {
                let defaultName = "\(selectedCity.rawValue) \(res.distanceKmFormatted) 路线"
                SaveRouteDialogView(isPresented: $showSaveRouteDialog, defaultName: defaultName) { name in
                    savedRouteStore.saveRoute(
                        name: name,
                        result: res,
                        cityName: selectedCity.rawValue,
                        weightKg: userProfile.weightKg
                    )
                    snapEngine.statusMessage = "🌟 路线「\(name)」已成功收藏！"
                }
                .background(ClearBackgroundView())
            }
        }
        .fullScreenCover(isPresented: $trackingManager.showWorkoutSummary) {
            if let record = trackingManager.lastCompletedRecord {
                WorkoutSummaryView(record: record) {
                    trackingManager.showWorkoutSummary = false
                }
                .background(ClearBackgroundView())
            }
        }
        .onAppear {
            locationManager.onLocationUpdate = { [weak trackingManager, weak userProfile, weak recordStore] loc in
                guard let tm = trackingManager, let up = userProfile, let rs = recordStore else { return }
                tm.processLocation(loc, userProfile: up, recordStore: rs)
            }
            locationManager.onHeadingUpdate = { [weak orientationManager] heading in
                if trackingState == .followHeading {
                    orientationManager?.updateHeading(heading)
                }
            }
            locationManager.requestAuthorization()
            pedometer.refreshTodaySteps()

            // 检查并恢复之前暂停的行程（支持关闭软件后重新打开继续）
            trackingManager.checkAndRestorePausedWorkout(userProfile: userProfile)
            if trackingManager.isTracking {
                locationManager.setWorkoutMode(active: true)
                if trackingManager.hasRestoredFromPause, let pausedLoc = trackingManager.lastPausedCoordinate {
                    locateCoordinate(pausedLoc, delta: 0.016)
                }
            }
        }
        .onChange(of: selectedCity) { _, newCity in
            locateCoordinate(newCity.defaultSpot.coordinate, delta: 0.020)
        }
        .onChange(of: trackingManager.isTracking) { _, isTracking in
            locationManager.setWorkoutMode(active: isTracking)
        }
    }

    // MARK: - 顶部精致磨砂悬浮导航栏 (带收藏路线入口)
    private var topFloatingNavBar: some View {
        HStack(spacing: 8) {
            // 城市快速切换 Menu：点击即切换并立即飞往该城市默认位置
            Menu {
                ForEach(SupportedCity.allCases) { city in
                    Button(action: {
                        selectedCity = city
                        locateCoordinate(city.defaultSpot.coordinate, delta: 0.020)
                    }) {
                        HStack {
                            Text(city.rawValue)
                            if selectedCity == city {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(action: { showCityPicker = true }) {
                    Label("浏览城市更多精选地标...", systemImage: "list.bullet.circle")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Text(selectedCity.rawValue)
                        .font(.system(.subheadline, design: .rounded).bold())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule().stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.45), Color.white.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                        )
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                )
            }
            .foregroundStyle(.primary)

            Spacer()

            // 搜索按钮
            frostedNavIconButton(icon: "magnifyingglass") {
                showSearchSheet = true
            }

            // 收藏路线按钮 (专属管理已收藏路线)
            frostedNavIconButton(icon: "bookmark.fill") {
                showSavedRoutesSheet = true
            }

            // 历史归档按钮
            frostedNavIconButton(icon: "clock.arrow.circlepath") {
                showHistorySheet = true
            }

            // 身体健康特征按钮
            frostedNavIconButton(icon: "person.crop.circle") {
                showProfileSheet = true
            }
        }
    }

    private var activePlanningResult: SnappedRouteResult? {
        snapEngine.currentResult ?? (trackingManager.showFullCompletedRoute ? trackingManager.fullRouteResult : nil)
    }

    // MARK: - 全新极简 Apple 风格磨砂玻璃底部卡片 (带收藏与命名触发)
    private var redesignedBottomCard: some View {
        VStack(spacing: 14) {
            // 1. 顶部状态与健康建议微标签
            HStack {
                if let res = activePlanningResult {
                    HStack(spacing: 6) {
                        Image(systemName: res.shape == .loop ? "arrow.triangle.2.circlepath" : "arrow.right")
                            .font(.caption2.bold())
                        Text(res.shape == .loop ? "环形闭环路线" : "单向漫步路线")
                            .font(.system(.caption, design: .rounded).bold())
                    }
                    .foregroundStyle(res.shape == .loop ? Color.blue : Color.indigo)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill((res.shape == .loop ? Color.blue : Color.indigo).opacity(0.12))
                    )

                    Spacer()

                    // 健康建议距离达成度比对
                    let km = res.totalDistanceMeters / 1000.0
                    let targetKm = userProfile.recommendedDailyDistanceKm
                    if km >= targetKm * 0.95 {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("已达健康建议距离").font(.caption2.bold()).foregroundStyle(.green)
                        }
                    } else {
                        Text(String(format: "健康建议 %.1f km (已达%.0f%%)", targetKm, (km / targetKm) * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 5) {
                        if snapEngine.isSnapping {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        Text(snapEngine.statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            // 2. 核心大字数据展示区 (Apple Health 质感)
            if let res = activePlanningResult {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(res.distanceKmFormatted.replacingOccurrences(of: " km", with: ""))
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("公里")
                        .font(.headline.bold())
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 右侧紧凑数据堆叠
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                Image(systemName: "flame.fill").font(.caption2).foregroundStyle(.orange)
                                Text(String(format: "%.0f kcal", res.estimatedCalories(weightKg: userProfile.weightKg)))
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            Text("预估热量").font(.caption2).foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                Image(systemName: "shoeprints.fill").font(.caption2).foregroundStyle(.blue)
                                Text("\(res.estimatedSteps)")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            Text("预估步数").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)

                // 2.5 起点归属指示与定位切换（起点自主选定，定位仅作参考）
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    if customStartCoordinate != nil {
                        Text("当前起点：已自定义")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(action: {
                            customStartCoordinate = nil
                            reSnapLastRoute()
                        }) {
                            Text("恢复手绘起点")
                                .font(.caption2.bold())
                                .foregroundStyle(.blue)
                        }
                    } else {
                        Text("当前起点：手绘起笔点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let userLoc = locationManager.userLocation {
                            Button(action: {
                                customStartCoordinate = userLoc
                                reSnapLastRoute()
                            }) {
                                Text("改定位为起点 (参考)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // 3. 城市快捷地标微型横滑栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selectedCity.spots) { spot in
                        Button(action: {
                            locateCoordinate(spot.coordinate, delta: 0.018)
                        }) {
                            Text(spot.name)
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.primary.opacity(0.06))
                                )
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            // 4. 精炼按钮栏（包含一键收藏与命名按钮）
            HStack(spacing: 8) {
                if let activeRes = activePlanningResult {
                    // 清空小圆纽
                    Button(action: {
                        snapEngine.clear()
                        customStartCoordinate = nil
                        plannedWaypoints.removeAll()
                        trackingManager.showFullCompletedRoute = false
                        trackingManager.fullRouteResult = nil
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.red.opacity(0.1))
                            )
                    }

                    // 收藏此路线按钮（弹出自定义命名对话框）
                    Button(action: { showSaveRouteDialog = true }) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }

                    // 主操作 1：启动行程 (优雅翠绿渐变)
                    Button(action: {
                        trackingManager.startWorkout(
                            route: activeRes,
                            userProfile: userProfile,
                            cityName: selectedCity.rawValue,
                            currentLocation: locationManager.userLocation
                        )
                        trackingState = .followLocation
                        cameraPosition = .userLocation(fallback: .automatic)
                        orientationManager.updateHeading(mapCameraHeading)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.headline)
                            Text("启动行程")
                                .font(.headline.bold())
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [Color.green, Color.teal], startPoint: .leading, endPoint: .trailing))
                                .shadow(color: Color.green.opacity(0.35), radius: 8, y: 3)
                        )
                    }

                    // 主操作 2：重新随手画
                    Button(action: {
                        isWaypointMode = false
                        isDrawingMode = true
                        rawScreenPoints.removeAll()
                    }) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.blue)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.blue.opacity(0.12))
                            )
                    }

                    // 主操作 3：进入阶段目标选点规划
                    Button(action: {
                        isDrawingMode = false
                        isWaypointMode = true
                        plannedWaypoints.removeAll()
                    }) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.purple)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.purple.opacity(0.12))
                            )
                    }
                } else {
                    // 未画线时的双重核心入口：随手画线 & 选点规划
                    Button(action: {
                        isWaypointMode = false
                        isDrawingMode.toggle()
                        if isDrawingMode {
                            trackingState = .free
                            locationManager.setHeadingTracking(enabled: false)
                            rawScreenPoints.removeAll()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isDrawingMode ? "hand.draw.fill" : "pencil.tip.crop.circle")
                                .font(.subheadline)
                            Text(isDrawingMode ? "松手即贴合" : "✏️ 随手画线")
                                .font(.system(.subheadline, design: .rounded).bold())
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isDrawingMode ? Color.orange : Color.blue)
                                .shadow(color: (isDrawingMode ? Color.orange : Color.blue).opacity(0.3), radius: 8, y: 3)
                        )
                    }

                    Button(action: {
                        isDrawingMode = false
                        isWaypointMode = true
                        trackingState = .free
                        locationManager.setHeadingTracking(enabled: false)
                        plannedWaypoints.removeAll()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                .font(.subheadline)
                            Text("📍 选点规划")
                                .font(.system(.subheadline, design: .rounded).bold())
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .leading, endPoint: .trailing))
                                .shadow(color: Color.indigo.opacity(0.3), radius: 8, y: 3)
                        )
                    }
                }

                // 定位视角切换小圆纽
                Button(action: toggleTrackingMode) {
                    Image(systemName: trackingIconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(trackingState != .free ? Color.white : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(trackingState != .free ? Color.blue : Color.primary.opacity(0.08))
                        )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.5), Color.white.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.14), radius: 24, y: 6)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - 阶段目标选点规划专用 Apple 磨砂底部中控
    private func waypointPlanningBottomDock(mapProxy: MapProxy, centerPoint: CGPoint) -> some View {
        VStack(spacing: 12) {
            // 1. 顶部模式标题与闭环切换胶囊
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.purple)
                    Text("阶段选点路线规划")
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundStyle(.primary)
                }

                Spacer()

                // 闭环 / 单向 切换胶囊
                Button(action: {
                    isWaypointLoop.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isWaypointLoop ? "arrow.triangle.2.circlepath" : "arrow.right")
                            .font(.caption2.bold())
                        Text(isWaypointLoop ? "环形回起点" : "单向漫步")
                            .font(.system(.caption, design: .rounded).bold())
                    }
                    .foregroundStyle(isWaypointLoop ? Color.blue : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill((isWaypointLoop ? Color.blue : Color.orange).opacity(0.14))
                    )
                }

                // 退出选点模式按钮
                Button(action: {
                    isWaypointMode = false
                    plannedWaypoints.removeAll()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }

            // 2. 当前阶段点进度状态指示
            HStack(spacing: 6) {
                if plannedWaypoints.isEmpty {
                    Image(systemName: "1.circle.fill").foregroundStyle(.green)
                    Text("请点击地图放置【起点】（定位仅作参考）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if plannedWaypoints.count == 1 {
                    Image(systemName: "2.circle.fill").foregroundStyle(.blue)
                    Text("起点已设定！请点击地图放置【阶段目标 1】")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                    Text("已设定起点 + \(plannedWaypoints.count - 1) 个阶段目标点")
                        .font(.footnote.bold())
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            // 3. 选点辅助工具栏 (定位设为起点、中心准星添加、撤销、清空)
            HStack(spacing: 8) {
                // 定位作为参考：一键将起点设为当前定位
                Button(action: {
                    setGpsAsStartWaypoint()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption.bold())
                        Text(plannedWaypoints.isEmpty ? "定位设起点" : "改定位起点")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    )
                }

                // 在屏幕中心准星处添加点
                Button(action: {
                    if let coord = mapProxy.convert(centerPoint, from: .local) {
                        addWaypoint(coord)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption.bold())
                        Text(plannedWaypoints.isEmpty ? "准星设起点" : "准星加目标")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.12))
                    )
                }

                Spacer()

                // 撤销上一个点
                Button(action: undoLastWaypoint) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(plannedWaypoints.isEmpty ? Color.secondary : Color.primary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .disabled(plannedWaypoints.isEmpty)

                // 清空所有点
                Button(action: clearAllWaypoints) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(plannedWaypoints.isEmpty ? Color.secondary : Color.red)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.red.opacity(plannedWaypoints.isEmpty ? 0.04 : 0.12))
                        )
                }
                .disabled(plannedWaypoints.isEmpty)
            }

            // 4. 大操作主按钮：串联生成总路线
            Button(action: generateSequentialWaypointRoute) {
                HStack(spacing: 8) {
                    if snapEngine.isSnapping {
                        ProgressView().tint(.white).controlSize(.small)
                        Text("正在优选双侧人行道平路...")
                            .font(.headline.bold())
                    } else {
                        Image(systemName: "sparkles")
                            .font(.headline)
                        Text(plannedWaypoints.count >= 2 ? "✨ 串联生成总路线 (\(plannedWaypoints.count) 个阶段)" : "请至少放置起点和 1 个阶段目标")
                            .font(.headline.bold())
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            plannedWaypoints.count >= 2
                                ? LinearGradient(colors: [Color.green, Color.teal], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.4)], startPoint: .leading, endPoint: .trailing)
                        )
                        .shadow(color: plannedWaypoints.count >= 2 ? Color.green.opacity(0.35) : Color.clear, radius: 8, y: 3)
                )
            }
            .disabled(plannedWaypoints.count < 2 || snapEngine.isSnapping)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.5), Color.white.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.16), radius: 24, y: 6)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - 运动进行中：顶部极简磨砂微胶囊 HUD (最大化留白地图，零换行严密对齐)
    private var activeWorkoutTopCapsule: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // 1. 时间
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text(formatSeconds(trackingManager.elapsedSeconds))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                hudDivider

                // 2. 距离（严格按实际检测到的距离显示）
                HStack(spacing: 2) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(String(format: "%.2f", trackingManager.completedDistanceMeters / 1000.0))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("km")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                hudDivider

                // 3. 热量
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(String(format: "%.0f", trackingManager.currentCalories))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("kcal")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if trackingManager.totalCheckpointCount > 0 {
                    hudDivider

                    // 4. 检查点进度（支持轻触直接手动确认通过）
                    Button(action: {
                        trackingManager.manuallyConfirmCurrentCheckpoint(userProfile: userProfile, recordStore: recordStore)
                    }) {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.teal)
                            Text("\(trackingManager.currentCheckpointIndex)/\(trackingManager.totalCheckpointCount)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.teal)
                        }
                    }
                    .buttonStyle(.plain)

                    hudDivider

                    // 5. 进度百分比
                    Text(String(format: "%.0f%%", trackingManager.progressRate * 100))
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            )

            if let notice = trackingManager.offRouteNotice {
                Text(notice)
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.06), radius: 4)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 0.8, height: 13)
    }

    // MARK: - 运动进行中：底部极简透明悬浮岛 (完全不遮挡地图)
    private var minimalActiveWorkoutDock: some View {
        VStack(spacing: 10) {
            // 若为关闭软件后重新打开恢复的暂停状态，呈现恢复提示与放弃选项
            if trackingManager.hasRestoredFromPause && trackingManager.isPaused {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("已恢复上次暂停状态，可在此继续运动")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    Button(action: {
                        trackingManager.discardRestoredWorkout()
                    }) {
                        Text("放弃")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                )
                .padding(.horizontal, 20)
            }

            HStack(spacing: 8) {
                // 1. 暂停 / 继续按钮 (暂停时自动记录当前定位并持久化到本地文件)
                Button(action: {
                    if trackingManager.isPaused {
                        trackingManager.resumeWorkout()
                    } else {
                        trackingManager.pauseWorkout(currentLocation: locationManager.userLocation)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: trackingManager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .bold))
                        if trackingManager.isPaused {
                            Text("继续")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(trackingManager.isPaused ? .white : .orange)
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, trackingManager.isPaused ? 10 : 0)
                    .background(
                        Group {
                            if trackingManager.isPaused {
                                Capsule(style: .continuous)
                                    .fill(LinearGradient(colors: [Color.green, Color.teal], startPoint: .leading, endPoint: .trailing))
                                    .shadow(color: Color.green.opacity(0.35), radius: 6, y: 2)
                            } else {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                            }
                        }
                    )
                }

                // 2. 手动强行确认通过当前检查点/路段 (用户容错机制)
                Button(action: {
                    trackingManager.manuallyConfirmCurrentCheckpoint(userProfile: userProfile, recordStore: recordStore)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("手动通过")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Color.teal, Color.cyan], startPoint: .leading, endPoint: .trailing))
                            .shadow(color: Color.teal.opacity(0.3), radius: 6, y: 2)
                    )
                }

                // 3. 中途修改路线按钮
                Button(action: startMidwayRouteRevision) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing))
                                .shadow(color: .indigo.opacity(0.3), radius: 6, y: 2)
                        )
                }

                // 4. 结束行程按钮
                Button(action: {
                    trackingManager.stopWorkout(
                        userProfile: userProfile,
                        completedNaturally: false,
                        recordStore: recordStore
                    )
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        )
                }

                // 5. 视角跟随切换按钮
                Button(action: toggleTrackingMode) {
                    Image(systemName: trackingIconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(trackingState != .free ? Color.blue : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            )
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 28)
    }

    // MARK: - 加载收藏路线并在地图取景
    private func loadSavedRoute(_ saved: SavedRoute) {
        let result = saved.toSnappedRouteResult(strideLength: userProfile.effectiveStrideLength)
        snapEngine.currentResult = result
        snapEngine.statusMessage = "已调出收藏路线「\(saved.name)」"

        lastDrawnCoordinates = saved.coordinates
        customStartCoordinate = nil

        // 自动适配城市标签
        if let matchCity = SupportedCity.allCases.first(where: { $0.rawValue == saved.cityName }) {
            selectedCity = matchCity
        }

        // 镜头自动框选整条路线
        let coords = saved.coordinates
        guard !coords.isEmpty else { return }
        var minLat = coords[0].latitude
        var maxLat = coords[0].latitude
        var minLon = coords[0].longitude
        var maxLon = coords[0].longitude

        for c in coords {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2.0, longitude: (minLon + maxLon) / 2.0)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.012, (maxLat - minLat) * 1.45),
            longitudeDelta: max(0.012, (maxLon - minLon) * 1.45)
        )
        trackingState = .free
        locationManager.setHeadingTracking(enabled: false)
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - 阶段选点规划与起点控制辅助函数
    private func addWaypoint(_ coord: CLLocationCoordinate2D) {
        let index = plannedWaypoints.count
        let newWp = PlannedWaypoint(coordinate: coord, index: index)
        plannedWaypoints.append(newWp)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if index == 0 {
            snapEngine.statusMessage = "已设定【起点】，请在地图上依次点击放置后续阶段目标点"
        } else {
            snapEngine.statusMessage = "已设定第 \(index) 个阶段目标，可继续点击地图添加或生成总路线"
        }
    }

    private func setGpsAsStartWaypoint() {
        guard let loc = locationManager.userLocation else {
            snapEngine.statusMessage = "尚未获取到 GPS 定位信号，请稍等或直接点击地图选点"
            return
        }
        if plannedWaypoints.isEmpty {
            addWaypoint(loc)
        } else {
            plannedWaypoints[0].coordinate = loc
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            snapEngine.statusMessage = "已将起点设定为当前定位"
        }
    }

    private func undoLastWaypoint() {
        guard !plannedWaypoints.isEmpty else { return }
        plannedWaypoints.removeLast()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if plannedWaypoints.isEmpty {
            snapEngine.statusMessage = "已清空点位，请点击地图放置起点"
        } else {
            snapEngine.statusMessage = "已撤销上一个点，当前共有 \(plannedWaypoints.count) 个点"
        }
    }

    private func clearAllWaypoints() {
        plannedWaypoints.removeAll()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        snapEngine.statusMessage = "已清空所有阶段目标点"
    }

    private func generateSequentialWaypointRoute() {
        guard plannedWaypoints.count >= 2 else { return }
        let coords = plannedWaypoints.map { $0.coordinate }
        let isLoop = isWaypointLoop
        isWaypointMode = false
        lastDrawnCoordinates = coords
        customStartCoordinate = coords.first

        Task {
            await snapEngine.snapSequentialWaypointsToRoads(
                waypoints: coords,
                isLoop: isLoop,
                strideLength: userProfile.effectiveStrideLength
            )
        }
    }

    private func reSnapLastRoute() {
        guard !lastDrawnCoordinates.isEmpty else { return }
        Task {
            await snapEngine.snapUserSketchToRoads(
                rawCoordinates: lastDrawnCoordinates,
                startCoordinate: customStartCoordinate,
                strideLength: userProfile.effectiveStrideLength
            )
        }
    }

    // MARK: - 手势绘图结束处理
    private func handleFinishDrawing(mapProxy: MapProxy) {
        let coords = rawScreenPoints.compactMap { pt in
            mapProxy.convert(pt, from: .local)
        }
        isDrawingMode = false
        rawScreenPoints.removeAll()

        guard coords.count >= 2 else { return }

        // 保存本次手绘原始轨迹坐标，便于后续切换起点
        lastDrawnCoordinates = coords

        // 起点完全由用户决定：若用户未指定起点，则以手绘第一笔位置为起点！定位仅作参考
        let chosenStart = customStartCoordinate

        Task {
            if isRevisingRoute {
                var finalPoints = coords
                let anchor = chosenStart ?? locationManager.userLocation ?? coords.first!
                finalPoints.insert(anchor, at: 0)

                if let initialStart = trackingManager.workoutInitialCoordinate,
                   let lastPt = finalPoints.last {
                    let distToOriginalStart = CLLocation(latitude: lastPt.latitude, longitude: lastPt.longitude)
                        .distance(from: CLLocation(latitude: initialStart.latitude, longitude: initialStart.longitude))
                    if distToOriginalStart <= 220.0 {
                        finalPoints.append(initialStart)
                    }
                }

                let newRoute = await snapEngine.snapUserSketchToRoads(
                    rawCoordinates: finalPoints,
                    startCoordinate: anchor,
                    strideLength: userProfile.effectiveStrideLength
                )

                if let route = newRoute {
                    trackingManager.replanRouteMidway(newRoute: route)
                }
                isRevisingRoute = false
            } else {
                await snapEngine.snapUserSketchToRoads(
                    rawCoordinates: coords,
                    startCoordinate: chosenStart, // nil 即代表完全以手绘第一笔为起点！
                    strideLength: userProfile.effectiveStrideLength
                )
            }
        }
    }

    private func startMidwayRouteRevision() {
        isRevisingRoute = true
        isDrawingMode = true
        trackingState = .free
        locationManager.setHeadingTracking(enabled: false)
        rawScreenPoints.removeAll()
    }

    private func frostedNavIconButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle().stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.45), Color.white.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                        )
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                )
        }
    }

    private var trackingIconName: String {
        switch trackingState {
        case .free: return "location"
        case .followLocation: return "location.fill"
        case .followHeading: return "location.north.line.fill"
        }
    }

    private func toggleTrackingMode() {
        switch trackingState {
        case .free:
            trackingState = .followLocation
            locationManager.setHeadingTracking(enabled: true)
            withAnimation {
                cameraPosition = .userLocation(fallback: .automatic)
            }
            orientationManager.updateHeading(mapCameraHeading)
        case .followLocation:
            trackingState = .followHeading
            locationManager.setHeadingTracking(enabled: true)
            withAnimation {
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            }
            if let userH = locationManager.userHeading {
                let deg = userH.trueHeading >= 0 ? userH.trueHeading : userH.magneticHeading
                orientationManager.updateHeading(deg)
            }
        case .followHeading:
            trackingState = .free
            locationManager.setHeadingTracking(enabled: trackingManager.isTracking)
            orientationManager.updateHeading(mapCameraHeading)
        }
    }

    private func locateCoordinate(_ coord: CLLocationCoordinate2D, delta: Double) {
        trackingState = .free
        locationManager.setHeadingTracking(enabled: false)
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
                )
            )
        }
    }

    private func formatSeconds(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

// 辅助透明背景容器
struct ClearBackgroundView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
