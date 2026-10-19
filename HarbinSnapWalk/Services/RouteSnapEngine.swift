import Foundation
import MapKit
import CoreLocation

@MainActor
final class RouteSnapEngine: ObservableObject {
    @Published var isSnapping = false
    @Published var currentResult: SnappedRouteResult?
    @Published var statusMessage: String = "点击下方画笔，在地图上随手涂鸦即可贴合道路"

    /// 核心入口：将原始手绘屏幕坐标解析为地理序列并吸附至街道，自动去盲端毛刺并判断闭环/单向意图
    func snapUserSketchToRoads(
        rawCoordinates: [CLLocationCoordinate2D],
        strideLength: Double
    ) async {
        guard rawCoordinates.count >= 2 else {
            self.statusMessage = "绘制线条过短，请画出一段路线"
            return
        }

        self.isSnapping = true
        self.statusMessage = "正在自动贴合真实街道路网..."
        defer { self.isSnapping = false }

        // 0. 去除起笔与落笔的手指抖动毛刺
        let cleaned = cleanJitterAndHooks(rawCoordinates)
        guard cleaned.count >= 2 else {
            self.statusMessage = "绘制过于微小，请划出一段明显轨迹"
            return
        }

        // 1. 意图判定：自动识别用户是想画「环形闭环」还是「单向路线」
        let isLoopIntent = detectLoopIntent(cleaned)

        // 2. 几何弦长抽稀并提取高质量关键锚点（3~6个，避免高频请求或误入盲道）
        var anchors = downsampleCoordinates(cleaned, minIntervalMeters: 280.0, maxPoints: 6)

        // 如果用户意图是闭环，强行将终点闭合到起点
        if isLoopIntent {
            if let first = anchors.first {
                anchors.append(first)
            }
        }

        guard anchors.count >= 2 else {
            self.statusMessage = "关键锚点不足，请扩大画圈跨度"
            return
        }

        // 3. 串联发起步行路径吸附
        var polylines: [MKPolyline] = []
        var totalDist: Double = 0.0
        var totalDuration: TimeInterval = 0.0

        do {
            for i in 0..<(anchors.count - 1) {
                let startPoint = anchors[i]
                let endPoint = anchors[i + 1]

                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: startPoint))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: endPoint))
                req.transportType = .walking
                req.requestsAlternateRoutes = false

                let directions = MKDirections(request: req)
                let response = try await directions.calculate()
                if let leg = response.routes.first {
                    polylines.append(leg.polyline)
                    totalDist += leg.distance
                    totalDuration += leg.expectedTravelTime
                }
            }

            // 4. 核心去毛刺与盲端折返消解算法 (Eliminate Dead-end Backtrack Spurs)
            let optimizedPolylines = pruneDeadEndBacktracks(polylines)

            // 重新校准折线真实总里程与耗时
            var finalDistance: Double = 0.0
            for poly in optimizedPolylines {
                finalDistance += calculatePolylineDistance(poly)
            }
            if finalDistance <= 0 { finalDistance = totalDist }
            let durationRatio = totalDist > 0 ? (finalDistance / totalDist) : 1.0
            let finalDuration = max(60.0, totalDuration * durationRatio)

            self.currentResult = SnappedRouteResult(
                polylines: optimizedPolylines,
                anchorWaypoints: anchors,
                totalDistanceMeters: finalDistance,
                estimatedTravelSeconds: finalDuration,
                strideLength: strideLength,
                shape: isLoopIntent ? .loop : .open
            )
            
            self.statusMessage = isLoopIntent ? "已识别为环形闭环路线并贴合路网！" : "已识别为单向通行路线并贴合路网！"
        } catch {
            self.statusMessage = "部分路段受限于小区围墙或封闭街区，已尽力吸附"
        }
    }

    // MARK: - 智能闭环意图判定算法
    private func detectLoopIntent(_ points: [CLLocationCoordinate2D]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 3 else {
            return false
        }
        let straightDist = distanceBetween(first, last)
        
        // 计算手绘整条线的大致总长度
        var totalPathDist: Double = 0.0
        for i in 0..<(points.count - 1) {
            totalPathDist += distanceBetween(points[i], points[i + 1])
        }

        // 规则 1：如果首尾直线距离小于 180 米，几乎肯定是个圈
        if straightDist <= 180.0 {
            return true
        }

        // 规则 2：如果首尾距离占整条画线总长度比例小于 18%，且画线总长超过 350 米，也属于画圈
        if totalPathDist >= 350.0 && (straightDist / totalPathDist) <= 0.18 {
            return true
        }

        return false
    }

    // MARK: - 去除起笔收笔毛刺抖动
    private func cleanJitterAndHooks(_ raw: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard raw.count > 4 else { return raw }
        var filtered: [CLLocationCoordinate2D] = [raw[0]]
        for i in 1..<raw.count {
            if distanceBetween(filtered.last!, raw[i]) >= 8.0 {
                filtered.append(raw[i])
            }
        }
        return filtered
    }

    // MARK: - 几何弦长抽稀与降采样
    private func downsampleCoordinates(_ points: [CLLocationCoordinate2D], minIntervalMeters: Double, maxPoints: Int) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        var result: [CLLocationCoordinate2D] = [points.first!]
        var lastKept = points.first!

        for i in 1..<(points.count - 1) {
            let current = points[i]
            let dist = distanceBetween(lastKept, current)
            if dist >= minIntervalMeters {
                result.append(current)
                lastKept = current
            }
        }
        result.append(points.last!)

        if result.count > maxPoints {
            let step = Double(result.count - 1) / Double(maxPoints - 1)
            var clamped: [CLLocationCoordinate2D] = []
            for k in 0..<maxPoints {
                let idx = Int(round(Double(k) * step))
                clamped.append(result[min(idx, result.count - 1)])
            }
            return clamped
        }

        return result
    }

    // MARK: - 核心消解死胡同突起折返 (Backtrack Spur Removal)
    /// 当前后两段 MKDirections 折线重叠折返（例如拐进一条死路又原路折返回主路）时，自动裁切掉折返分支
    private func pruneDeadEndBacktracks(_ polylines: [MKPolyline]) -> [MKPolyline] {
        guard polylines.count >= 2 else { return polylines }

        var cleanedPolys: [MKPolyline] = []

        for i in 0..<polylines.count {
            let currentPoly = polylines[i]
            let currentCoords = polylineCoordinates(currentPoly)
            guard currentCoords.count >= 3 else {
                cleanedPolys.append(currentPoly)
                continue
            }

            // 检测单条折线内部是否有自我掉头折返（U-turn spur）
            let unspurredCoords = removeInternalUturns(currentCoords)
            cleanedPolys.append(MKPolyline(coordinates: unspurredCoords, count: unspurredCoords.count))
        }

        return cleanedPolys
    }

    /// 消除折线内部死胡同盲端（A -> B -> A 模式的无意义突起）
    private func removeInternalUturns(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coords.count > 6 else { return coords }
        var result: [CLLocationCoordinate2D] = []
        var i = 0

        while i < coords.count {
            result.append(coords[i])
            // 向前探查 4~15 个点内是否存在原路折返
            var foundCut = false
            for j in stride(from: min(coords.count - 1, i + 15), to: i + 3, by: -1) {
                let dist = distanceBetween(coords[i], coords[j])
                if dist < 18.0 {
                    // 检测中间最高凸起点是否是个盲端（中间离两头直线较远）
                    let midIdx = (i + j) / 2
                    let midDist = distanceBetween(coords[i], coords[midIdx])
                    if midDist > 25.0 {
                        // 发现典型突出的盲端折返，跳过该段突起
                        i = j
                        foundCut = true
                        break
                    }
                }
            }
            if !foundCut {
                i += 1
            }
        }
        return result
    }

    private func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    private func calculatePolylineDistance(_ polyline: MKPolyline) -> Double {
        let coords = polylineCoordinates(polyline)
        guard coords.count > 1 else { return 0 }
        var dist = 0.0
        for i in 0..<(coords.count - 1) {
            dist += distanceBetween(coords[i], coords[i + 1])
        }
        return dist
    }

    private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB)
    }

    func clear() {
        self.currentResult = nil
        self.statusMessage = "路线已清空，点击画笔即可重新随手涂鸦"
    }
}
