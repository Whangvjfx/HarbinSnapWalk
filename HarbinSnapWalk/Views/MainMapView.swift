import SwiftUI
import MapKit

enum MapTrackingState {
    case free              // 自由浏览模式
    case followLocation    // 居中跟随模式（正北朝上）
    case followHeading     // 视角跟随朝向旋转模式（地图随人转，前方朝上）
}

struct MainMapView: View {
    @StateObject private var snapEngine = RouteSnapEngine()
    @StateObject private var pedometer = PedometerService()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var userProfile = UserProfileModel()
    @StateObject private var recordStore = ActivityRecordStore()
    @StateObject private var trackingManager = RouteTrackingManager()

    @State private var selectedCity: SupportedCity = .harbin
    @State private var isDrawingMode = false
    @State private var isRevisingRoute = false // 中途改线标志
    @State private var rawScreenPoints: [CGPoint] = []
    @State private var trackingState: MapTrackingState = .free

    // 模态弹窗控制
    @State private var showCityPicker = false
    @State private var showSearchSheet = false
    @State private var showProfileSheet = false
    @State private var showHistorySheet = false

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: SupportedCity.harbin.defaultSpot.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.022, longitudeDelta: 0.022)
        )
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { mapProxy in
                ZStack {
                    // 底层原生 Map 容器
                    Map(position: $cameraPosition) {
                        UserAnnotation()

                        // 绘制当前吸附路线（优先显示行程中正在使用的活跃路线）
                        if let route = trackingManager.isTracking ? trackingManager.activeRoute : snapEngine.currentResult {
                            ForEach(Array(route.polylines.enumerated()), id: \.offset) { _, polyline in
                                MapPolyline(polyline)
                                    .stroke(
                                        LinearGradient(
                                            colors: [.blue, .cyan],
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
                                        Circle().fill(.white).frame(width: 22, height: 22)
                                        Circle().fill(.green).frame(width: 16, height: 16)
                                        Image(systemName: "figure.walk")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .shadow(color: .green.opacity(0.4), radius: 6)
                                }
                            }

                            // 单向路线的终点标记
                            if route.shape == .open, let endCoord = route.endCoordinate {
                                Annotation("终点", coordinate: endCoord) {
                                    ZStack {
                                        Circle().fill(.white).frame(width: 22, height: 22)
                                        Circle().fill(.red).frame(width: 16, height: 16)
                                        Image(systemName: "flag.fill")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .shadow(color: .red.opacity(0.4), radius: 6)
                                }
                            }
                        }
                    }
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                    }

                    // 顶层手绘交互层
                    if isDrawingMode {
                        SketchDrawingCanvas(points: $rawScreenPoints) {
                            handleFinishDrawing(mapProxy: mapProxy)
                        }
                    }
                }
            }
            .ignoresSafeArea()

            // 顶部导航与微型 HUD 胶囊
            VStack(spacing: 8) {
                if trackingManager.isTracking {
                    activeWorkoutTopCapsule
                } else {
                    topFloatingNavBar
                }
                Spacer()
            }
            .padding(.top, 50)
            .padding(.horizontal, 16)

            // 下方中控：运动中显示极简透明悬浮岛，闲置时显示丰富磨砂面板
            VStack {
                if trackingManager.isTracking {
                    minimalActiveWorkoutDock
                } else {
                    bottomStandardControlPanel
                }
            }
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerSheet(selectedCity: $selectedCity) { spot in
                locateCoordinate(spot.coordinate, delta: 0.020)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            LocationSearchView { coord, _ in
                locateCoordinate(coord, delta: 0.016)
            }
        }
        .sheet(isPresented: $showProfileSheet) {
            UserProfileView(profile: userProfile)
        }
        .sheet(isPresented: $showHistorySheet) {
            HistoryRecordsView(store: recordStore)
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
            locationManager.requestAuthorization()
            pedometer.refreshTodaySteps()
        }
        .onChange(of: locationManager.userLocation) { _, newLoc in
            guard let loc = newLoc else { return }
            trackingManager.processGPSUpdate(
                newLocation: loc,
                gpsSpeedMps: 0.0,
                userProfile: userProfile,
                recordStore: recordStore
            )
        }
    }

    // MARK: - 顶部闲置磨砂导航栏
    private var topFloatingNavBar: some View {
        HStack(spacing: 10) {
            // 城市切换按钮
            Button(action: { showCityPicker = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "building.2.crop.circle.fill")
                        .foregroundStyle(.blue)
                    Text(selectedCity.rawValue)
                        .font(.system(.subheadline, design: .rounded).bold())
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                )
            }
            .foregroundStyle(.primary)

            Spacer()

            // 搜索按钮
            navCircleButton(icon: "magnifyingglass") {
                showSearchSheet = true
            }

            // 历史归档按钮
            navCircleButton(icon: "clock.arrow.circlepath") {
                showHistorySheet = true
            }

            // 健康身体档案按钮
            navCircleButton(icon: "person.crop.circle") {
                showProfileSheet = true
            }
        }
    }

    // MARK: - 运动进行中：顶部极简磨砂微胶囊 HUD (最大化留白地图)
    private var activeWorkoutTopCapsule: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                // 时间
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(formatSeconds(trackingManager.elapsedSeconds))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }

                Divider().frame(height: 14)

                // 距离
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(String(format: "%.2f km", trackingManager.completedDistanceMeters / 1000.0))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }

                Divider().frame(height: 14)

                // 热量
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(String(format: "%.0f kcal", trackingManager.currentCalories))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }

                Divider().frame(height: 14)

                // 进度率
                Text(String(format: "%.0f%%", trackingManager.progressRate * 100))
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            )

            // 偏离提示条（仅在偏航时出现，不占用地图）
            if let notice = trackingManager.offRouteNotice {
                Text(notice)
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
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

    // MARK: - 运动进行中：底部极简透明悬浮岛 (完全不遮挡地图)
    private var minimalActiveWorkoutDock: some View {
        HStack(spacing: 14) {
            // 暂停 / 继续按钮
            Button(action: {
                if trackingManager.isPaused {
                    trackingManager.resumeWorkout()
                } else {
                    trackingManager.pauseWorkout()
                }
            }) {
                Image(systemName: trackingManager.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3.bold())
                    .foregroundStyle(trackingManager.isPaused ? .green : .orange)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                    )
            }

            // 核心特性：中途修改路线按钮
            Button(action: startMidwayRouteRevision) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.outline")
                        .font(.subheadline.bold())
                    Text("中途改线")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing))
                        .shadow(color: .indigo.opacity(0.3), radius: 8, y: 3)
                )
            }

            // 结束行程按钮
            Button(action: {
                trackingManager.stopWorkout(
                    userProfile: userProfile,
                    completedNaturally: false,
                    recordStore: recordStore
                )
            }) {
                Image(systemName: "stop.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.red)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                    )
            }

            // 视角跟随切换按钮
            Button(action: toggleTrackingMode) {
                Image(systemName: trackingIconName)
                    .font(.title3)
                    .foregroundStyle(trackingState != .free ? .blue : .primary)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    // MARK: - 闲置状态：标准磨砂面板
    private var bottomStandardControlPanel: some View {
        VStack(spacing: 12) {
            // 状态提示行
            HStack {
                if snapEngine.isSnapping {
                    ProgressView().controlSize(.small)
                }
                Text(snapEngine.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            // 吸附结算卡片（若已有生成的路线）
            if let res = snapEngine.currentResult {
                VStack(spacing: 10) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(res.distanceKmFormatted)
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(.blue)
                            Text("路网规划里程")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Divider().frame(height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(res.estimatedSteps)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                            Text("预估达成步数")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Divider().frame(height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f kcal", res.estimatedCalories(weightKg: userProfile.weightKg)))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                            Text("预估热量消耗")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // 闭环/单向形态徽章
                        VStack(alignment: .trailing, spacing: 2) {
                            Image(systemName: res.shape.iconName)
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                            Text(res.shape == .loop ? "环形闭环" : "单向路线")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            // 快捷地标横向滚动栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selectedCity.spots) { spot in
                        Button(action: {
                            locateCoordinate(spot.coordinate, delta: 0.018)
                        }) {
                            Text(spot.name)
                                .font(.caption.bold())
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.secondary.opacity(0.12))
                                )
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            // 核心按钮操作栏
            HStack(spacing: 10) {
                if snapEngine.currentResult != nil {
                    // 清空路线
                    Button(action: { snapEngine.clear() }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .frame(width: 46, height: 46)
                            .background(
                                Circle().fill(Color.red.opacity(0.12))
                            )
                    }

                    // 启动行程按钮
                    Button(action: {
                        if let route = snapEngine.currentResult {
                            trackingManager.startWorkout(
                                route: route,
                                userProfile: userProfile,
                                cityName: selectedCity.rawValue,
                                currentLocation: locationManager.userLocation
                            )
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                                .font(.headline)
                            Text("启动行程")
                                .font(.headline.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing))
                                .shadow(color: .green.opacity(0.3), radius: 8, y: 3)
                        )
                    }
                }

                // 视角切换按钮
                Button(action: toggleTrackingMode) {
                    Image(systemName: trackingIconName)
                        .foregroundStyle(trackingState != .free ? .white : .blue)
                        .frame(width: 46, height: 46)
                        .background(
                            Circle().fill(trackingState != .free ? Color.blue : Color.blue.opacity(0.12))
                        )
                }

                // 核心随手画触发按钮
                Button(action: {
                    isDrawingMode.toggle()
                    if isDrawingMode {
                        trackingState = .free
                        locationManager.setHeadingTracking(enabled: false)
                        rawScreenPoints.removeAll()
                    }
                }) {
                    HStack {
                        Image(systemName: isDrawingMode ? "hand.draw.fill" : "pencil.tip.crop.circle")
                        Text(isDrawingMode ? "正在画线 (松手即贴合)" : "✏️ 随手画路线")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isDrawingMode ? Color.orange : Color.blue)
                            .shadow(color: (isDrawingMode ? Color.orange : Color.blue).opacity(0.3), radius: 8, y: 3)
                    )
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 28)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 14, y: -2)
        )
    }

    // MARK: - 手势绘图结束处理
    private func handleFinishDrawing(mapProxy: MapProxy) {
        let coords = rawScreenPoints.compactMap { pt in
            mapProxy.convert(pt, from: .local)
        }
        isDrawingMode = false
        rawScreenPoints.removeAll()

        guard !coords.isEmpty else { return }

        Task {
            if isRevisingRoute {
                // 中途修改路线：以当前 GPS 坐标或首绘点为起点
                var finalPoints = coords
                if let userLoc = locationManager.userLocation {
                    finalPoints.insert(userLoc, at: 0)
                }

                // 智能意图：判断用户是否意图回到行程最初出发点
                if let initialStart = trackingManager.workoutInitialCoordinate,
                   let lastPt = finalPoints.last {
                    let distToOriginalStart = CLLocation(latitude: lastPt.latitude, longitude: lastPt.longitude)
                        .distance(from: CLLocation(latitude: initialStart.latitude, longitude: initialStart.longitude))
                    // 如果改线终点靠近最初起点（<= 220 米），将最初起点拼接为最终终点
                    if distToOriginalStart <= 220.0 {
                        finalPoints.append(initialStart)
                    }
                }

                await snapEngine.snapUserSketchToRoads(
                    rawCoordinates: finalPoints,
                    strideLength: userProfile.effectiveStrideLength
                )

                if let newRoute = snapEngine.currentResult {
                    trackingManager.replanRouteMidway(newRoute: newRoute)
                }
                isRevisingRoute = false
            } else {
                await snapEngine.snapUserSketchToRoads(
                    rawCoordinates: coords,
                    strideLength: userProfile.effectiveStrideLength
                )
            }
        }
    }

    // MARK: - 触发中途修改路线
    private func startMidwayRouteRevision() {
        isRevisingRoute = true
        isDrawingMode = true
        trackingState = .free
        locationManager.setHeadingTracking(enabled: false)
        rawScreenPoints.removeAll()
    }

    // MARK: - 视角与导航辅助函数
    private func navCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
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
            locationManager.setHeadingTracking(enabled: false)
            withAnimation {
                cameraPosition = .userLocation(fallback: .automatic)
            }
        case .followLocation:
            trackingState = .followHeading
            locationManager.setHeadingTracking(enabled: true)
            withAnimation {
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            }
        case .followHeading:
            trackingState = .free
            locationManager.setHeadingTracking(enabled: false)
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
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
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
