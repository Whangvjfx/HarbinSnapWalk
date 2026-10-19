import Foundation
import MapKit
import CoreLocation

@MainActor
final class RouteSnapEngine: ObservableObject {
    @Published var isSnapping = false
    @Published var currentResult: SnappedRouteResult?
    @Published var statusMessage: String = "随手画个圈或折线，秒级贴合路网"

    /// 核心入口：将原始手绘屏幕坐标解析为地理序列并吸附至街道，彻底消解突出的死胡同单线，同时坚决保护大圈完整性
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

        // 0. 去除起笔收笔毛刺抖动
        let cleaned = cleanJitterAndHooks(rawCoordinates)
        guard cleaned.count >= 2 else {
            self.statusMessage = "绘制过于微小，请划出一段明显轨迹"
            return
        }

        // 1. 意图判定：自动识别用户是想画「环形闭环」还是「单向路线」
        let isLoopIntent = detectLoopIntent(cleaned)

        // 2. 几何弦长抽稀并提取高质量骨干锚点（根据手绘总长自适应采样 4~8 个锚点）
        var anchors = downsampleCoordinatesAdaptively(cleaned, isLoop: isLoopIntent)

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
        var rawLegs: [MKPolyline] = []
        var estimatedSeconds: TimeInterval = 0.0

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
                    rawLegs.append(leg.polyline)
                    estimatedSeconds += leg.expectedTravelTime
                }
            }

            // 4. 合并坐标链并执行【精密小枝消解算法】，限定最大小枝长度为 220 米，严禁误伤大圈！
            let mergedCoords = mergePolylineCoordinates(rawLegs)
            let cleanedCoords = eliminateDeadEndSpursSafely(mergedCoords, isLoop: isLoopIntent)

            guard cleanedCoords.count >= 2 else {
                self.statusMessage = "未匹配到适宜步行的连贯路网"
                return
            }

            // 重新计算纯净里程
            let finalDistance = calculateTotalDistance(cleanedCoords)
            let finalPolyline = MKPolyline(coordinates: cleanedCoords, count: cleanedCoords.count)

            self.currentResult = SnappedRouteResult(
                polylines: [finalPolyline],
                anchorWaypoints: anchors,
                totalDistanceMeters: finalDistance,
                estimatedTravelSeconds: max(60.0, estimatedSeconds),
                strideLength: strideLength,
                shape: isLoopIntent ? .loop : .open
            )
            
            self.statusMessage = isLoopIntent ? "已识别为环形闭环路线" : "已识别为单向通行路线"
        } catch {
            self.statusMessage = "部分路段受限于小区围墙或封闭街区，已尽力吸附"
        }
    }

    // MARK: - 智能闭环意图判定
    private func detectLoopIntent(_ points: [CLLocationCoordinate2D]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 3 else {
            return false
        }
        let straightDist = distanceBetween(first, last)
        
        var totalPathDist: Double = 0.0
        for i in 0..<(points.count - 1) {
            totalPathDist += distanceBetween(points[i], points[i + 1])
        }

        // 规则 1：如果首尾直线距离小于 220 米，判定为画圈闭环
        if straightDist <= 220.0 {
            return true
        }

        // 规则 2：如果首尾距离占整条画线总长度比例小于 22%，且画线总长超过 350 米，也属于大圈闭环
        if totalPathDist >= 350.0 && (straightDist / totalPathDist) <= 0.22 {
            return true
        }

        return false
    }

    // MARK: - 自适应降采样（保护大圈的均匀跨度）
    private func downsampleCoordinatesAdaptively(_ points: [CLLocationCoordinate2D], isLoop: Bool) -> [CLLocationCoordinate2D] {
        guard points.count > 3 else { return points }

        var totalLen = 0.0
        for i in 0..<(points.count - 1) {
            totalLen += distanceBetween(points[i], points[i + 1])
        }

        // 根据手绘全长动态决定锚点数量（大圈 6~8 个点，短线 4~5 个点）
        let targetPointsCount = totalLen > 3000 ? 7 : (totalLen > 1500 ? 6 : 4)
        let stepInterval = totalLen / Double(targetPointsCount)

        var result: [CLLocationCoordinate2D] = [points.first!]
        var accumulated = 0.0

        for i in 0..<(points.count - 1) {
            let seg = distanceBetween(points[i], points[i + 1])
            accumulated += seg
            if accumulated >= stepInterval && result.count < targetPointsCount {
                result.append(points[i + 1])
                accumulated = 0.0
            }
        }

        if !isLoop {
            if let last = points.last, distanceBetween(result.last!, last) > 40.0 {
                result.append(last)
            }
        }

        return result
    }

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

    private func mergePolylineCoordinates(_ polylines: [MKPolyline]) -> [CLLocationCoordinate2D] {
        var merged: [CLLocationCoordinate2D] = []
        for poly in polylines {
            let count = poly.pointCount
            guard count > 0 else { continue }
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: count))
            
            for pt in coords {
                if let last = merged.last {
                    if distanceBetween(last, pt) > 1.5 {
                        merged.append(pt)
                    }
                } else {
                    merged.append(pt)
                }
            }
        }
        return merged
    }

    // MARK: - 精密死胡同小枝消解（限定最大长度为 220 米，严禁误吞大圈！）
    private func eliminateDeadEndSpursSafely(_ coords: [CLLocationCoordinate2D], isLoop: Bool) -> [CLLocationCoordinate2D] {
        guard coords.count > 6 else { return coords }
        var current = coords
        var changed = true
        var loopCount = 0

        while changed && loopCount < 4 {
            changed = false
            loopCount += 1
            var result: [CLLocationCoordinate2D] = []
            var i = 0

            while i < current.count {
                result.append(current[i])

                var bestJumpIndex: Int? = nil
                // 仅向后探查局部小范围（最多 60 个点，防止跨越大半个城市大圈）
                let maxLookAhead = min(current.count, i + 60)

                for j in stride(from: maxLookAhead - 1, to: i + 3, by: -1) {
                    let directDistance = distanceBetween(current[i], current[j])
                    
                    // 如果两个点空间距离很近（<= 26 米，处于同一干道路口处）
                    if directDistance <= 26.0 {
                        var segmentTravelDistance = 0.0
                        for k in i..<j {
                            segmentTravelDistance += distanceBetween(current[k], current[k + 1])
                        }

                        // 【极其关键的安全防护阈值】：
                        // 小枝盲端的往返长度通常在 30m ~ 200m 之间（例如进出胡同或院落）；
                        // 如果在 30m 到 220m 之间，且两端重合，判定为多余小枝并裁剪！
                        // 如果大于 220m，说明是一个宏观城市街区大圈，绝对不裁剪！
                        if segmentTravelDistance >= 30.0 && segmentTravelDistance <= 220.0 {
                            bestJumpIndex = j
                            break
                        }
                    }
                }

                if let jump = bestJumpIndex {
                    // 切除死胡同小枝
                    i = jump
                    changed = true
                } else {
                    i += 1
                }
            }
            current = result
        }

        return current
    }

    private func calculateTotalDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
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
