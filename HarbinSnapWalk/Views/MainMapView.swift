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

    @State private var isDrawingMode = false
    @State private var rawScreenPoints: [CGPoint] = []
    @State private var seasonMode: WalkSeason = .springFall
    @State private var trackingState: MapTrackingState = .free

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: HEUPreset.defaultCenter.coordinate,
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

                        if let res = snapEngine.currentResult {
                            ForEach(Array(res.polylines.enumerated()), id: \.offset) { _, polyline in
                                MapPolyline(polyline)
                                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                            }

                            if let startCoord = res.anchorWaypoints.first {
                                Annotation("起点", coordinate: startCoord) {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                }
                            }
                        }
                    }
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                    }

                    // 顶层随手画手势交互层
                    if isDrawingMode {
                        SketchDrawingCanvas(points: $rawScreenPoints) {
                            let coords = rawScreenPoints.compactMap { pt in
                                mapProxy.convert(pt, from: .local)
                            }
                            isDrawingMode = false
                            rawScreenPoints.removeAll()

                            Task {
                                await snapEngine.snapUserSketchToRoads(
                                    rawCoordinates: coords,
                                    strideLength: seasonMode.strideLength
                                )
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)

            // 悬浮中控台与操作面板
            bottomControlPanel
        }
        .onAppear {
            locationManager.requestAuthorization()
            pedometer.refreshTodaySteps()
        }
    }

    private var bottomControlPanel: some View {
        VStack(spacing: 12) {
            HStack {
                if snapEngine.isSnapping {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // 随手画即时里程结算卡片
            if let res = snapEngine.currentResult {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(res.distanceKmFormatted)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                        Text("实际路网长度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider().frame(height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(res.estimatedSteps)")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("预估可达成步数")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider().frame(height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(res.durationFormatted)
                            .font(.system(size: 18, weight: .medium))
                        Text("预估耗时")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // 快捷预设横向滚动栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HEUPreset.list) { preset in
                        Button(action: { locatePreset(preset) }) {
                            Text(preset.name)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            // 核心交互按钮栏
            HStack(spacing: 10) {
                if snapEngine.currentResult != nil {
                    Button(action: { snapEngine.clear() }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .padding(12)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                    }
                }

                // 三态视角切换按钮
                Button(action: toggleTrackingMode) {
                    Image(systemName: trackingIconName)
                        .foregroundStyle(trackingState != .free ? .white : .blue)
                        .padding(12)
                        .background(
                            Circle().fill(trackingState != .free ? Color.blue : Color.blue.opacity(0.12))
                        )
                }

                // 核心随手画切换按钮
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
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(isDrawingMode ? Color.orange : Color.blue))
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: -2)
        )
    }

    private var statusText: String {
        if snapEngine.isSnapping { return "正在自动贴合路网..." }
        switch trackingState {
        case .followHeading:
            return "散步导航中 · 视角随朝向自动旋转"
        case .followLocation:
            return "位置居中跟随中"
        case .free:
            return snapEngine.statusMessage
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

    private func locatePreset(_ preset: HEUPreset) {
        trackingState = .free
        locationManager.setHeadingTracking(enabled: false)
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: preset.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.020, longitudeDelta: 0.020)
                )
            )
        }
    }
}
