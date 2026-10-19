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
    @StateObject private var savedRouteStore = SavedRouteStore()
    @StateObject private var trackingManager = RouteTrackingManager()

    @State private var selectedCity: SupportedCity = .harbin
    @State private var isDrawingMode = false
    @State private var isRevisingRoute = false
    @State private var rawScreenPoints: [CGPoint] = []
    @State private var trackingState: MapTrackingState = .free

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
        ZStack(alignment: .bottom) {
            MapReader { mapProxy in
                ZStack {
                    // 底层原生 Map 容器
                    Map(position: $cameraPosition) {
                        UserAnnotation()

                        // 绘制当前纯净无杂枝吸附路线
                        if let route = trackingManager.isTracking ? trackingManager.activeRoute : snapEngine.currentResult {
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

                            // 启动行程后：沿路线均匀呈现根据手绘行进方向的半透明微型箭头
                            if trackingManager.isTracking {
                                ForEach(route.directionalArrows) { arrow in
                                    Annotation("", coordinate: arrow.coordinate) {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 13, weight: .heavy))
                                            .foregroundStyle(Color.white.opacity(0.85))
                                            .rotationEffect(.degrees(arrow.bearingDegrees))
                                            .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                                    }
                                }
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
                        }
                    }
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                    }

                    // 顶层手绘画布
                    if isDrawingMode {
                        SketchDrawingCanvas(points: $rawScreenPoints) {
                            handleFinishDrawing(mapProxy: mapProxy)
                        }
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
            .padding(.top, 52)
            .padding(.horizontal, 16)

            // 下方中控：运动中极简浮动岛，闲置时 Apple 液态磨砂卡片
            VStack {
                if trackingManager.isTracking {
                    minimalActiveWorkoutDock
                } else {
                    redesignedBottomCard
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
            if let res = snapEngine.currentResult {
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
            locationManager.requestAuthorization()
            pedometer.refreshTodaySteps()
        }
        .onChange(of: selectedCity) { _, newCity in
            locateCoordinate(newCity.defaultSpot.coordinate, delta: 0.020)
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

    // MARK: - 全新极简 Apple 风格磨砂玻璃底部卡片 (带收藏与命名触发)
    private var redesignedBottomCard: some View {
        VStack(spacing: 14) {
            // 1. 顶部状态与健康建议微标签
            HStack {
                if let res = snapEngine.currentResult {
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
            if let res = snapEngine.currentResult {
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
            HStack(spacing: 10) {
                if snapEngine.currentResult != nil {
                    // 清空小圆纽
                    Button(action: { snapEngine.clear() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 46, height: 46)
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
                            .frame(width: 46, height: 46)
                            .background(
                                Circle()
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }

                    // 主操作 1：启动行程 (优雅翠绿渐变)
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
                        isDrawingMode = true
                        rawScreenPoints.removeAll()
                    }) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.blue)
                            .frame(width: 46, height: 46)
                            .background(
                                Circle()
                                    .fill(Color.blue.opacity(0.12))
                            )
                    }
                } else {
                    // 未画线时的核心入口按钮
                    Button(action: {
                        isDrawingMode.toggle()
                        if isDrawingMode {
                            trackingState = .free
                            locationManager.setHeadingTracking(enabled: false)
                            rawScreenPoints.removeAll()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: isDrawingMode ? "hand.draw.fill" : "pencil.tip.crop.circle")
                                .font(.headline)
                            Text(isDrawingMode ? "正在画线 (松手即贴合)" : "✏️ 随手画路线")
                                .font(.headline.bold())
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
                }

                // 定位视角切换小圆纽
                Button(action: toggleTrackingMode) {
                    Image(systemName: trackingIconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(trackingState != .free ? .white : .primary)
                        .frame(width: 46, height: 46)
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

    // MARK: - 运动进行中：顶部极简磨砂微胶囊 HUD (最大化留白地图)
    private var activeWorkoutTopCapsule: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
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
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
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

            // 中途修改路线按钮
            Button(action: startMidwayRouteRevision) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.outline")
                        .font(.subheadline.bold())
                    Text("中途改线")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background(
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing))
                        .shadow(color: .indigo.opacity(0.35), radius: 8, y: 3)
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

    // MARK: - 加载收藏路线并在地图取景
    private func loadSavedRoute(_ saved: SavedRoute) {
        let result = saved.toSnappedRouteResult(strideLength: userProfile.effectiveStrideLength)
        snapEngine.currentResult = result
        snapEngine.statusMessage = "已调出收藏路线「\(saved.name)」"

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
                var finalPoints = coords
                if let userLoc = locationManager.userLocation {
                    finalPoints.insert(userLoc, at: 0)
                }

                if let initialStart = trackingManager.workoutInitialCoordinate,
                   let lastPt = finalPoints.last {
                    let distToOriginalStart = CLLocation(latitude: lastPt.latitude, longitude: lastPt.longitude)
                        .distance(from: CLLocation(latitude: initialStart.latitude, longitude: initialStart.longitude))
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
