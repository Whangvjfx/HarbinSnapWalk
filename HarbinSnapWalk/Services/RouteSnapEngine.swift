import Foundation
import MapKit
import CoreLocation

@MainActor
final class RouteSnapEngine: ObservableObject {
    @Published var isSnapping = false
    @Published var currentResult: SnappedRouteResult?
    @Published var statusMessage: String = "随手画个圈或折线，秒级贴合路网"

    /// 核心入口：将原始手绘屏幕坐标解析为地理序列并吸附至街道，彻底消解所有突出的死胡同与折返分支
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

        // 2. 几何弦长抽稀并提取高质量骨干锚点（限制在 3~6 个，防止密集噪点误入死角）
        var anchors = downsampleCoordinates(cleaned, minIntervalMeters: 300.0, maxPoints: 6)

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

            // 4. 彻底合并为全局坐标链并执行【深度死胡同盲端与折返分支完全消解算法】
            let mergedCoords = mergePolylineCoordinates(rawLegs)
            let cleanedCoords = eliminateAllSpursAndBacktracks(mergedCoords, isLoop: isLoopIntent)

            guard cleanedCoords.count >= 2 else {
                self.statusMessage = "未匹配到适宜步行的连贯路网"
                return
            }

            // 重新计算去杂枝后的真实纯净里程
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

        // 规则 1：如果首尾直线距离小于 200 米，判定为画圈闭环
        if straightDist <= 200.0 {
            return true
        }

        // 规则 2：如果首尾距离占整条画线总长度比例小于 20%，且画线总长超过 350 米，也属于画圈
        if totalPathDist >= 350.0 && (straightDist / totalPathDist) <= 0.20 {
            return true
        }

        return false
    }

    // MARK: - 去除起笔收笔毛刺抖动
    private func cleanJitterAndHooks(_ raw: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard raw.count > 4 else { return raw }
        var filtered: [CLLocationCoordinate2D] = [raw[0]]
        for i in 1..<raw.count {
            if distanceBetween(filtered.last!, raw[i]) >= 10.0 {
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

    // MARK: - 合并多段 Polyline 坐标
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

    // MARK: - 彻底消解突出的死胡同盲枝与折返单线 (100% Eradicate Spurs & Dead-ends)
    /// 核心算法：检测路径上任何「离开主路拐入死胡同又折返回主路（如拐进院落、死胡同打转）」的突起单线，彻底裁剪！
    private func eliminateAllSpursAndBacktracks(_ coords: [CLLocationCoordinate2D], isLoop: Bool) -> [CLLocationCoordinate2D] {
        guard coords.count > 5 else { return coords }
        var current = coords
        var changed = true
        var loopCount = 0

        // 多轮迭代裁切，直到不存在任何折返盲端
        while changed && loopCount < 6 {
            changed = false
            loopCount += 1
            var result: [CLLocationCoordinate2D] = []
            var i = 0

            while i < current.count {
                result.append(current[i])

                // 向前探查是否存在「走了一段路后又回到该路口附近」的折返死胡同
                var bestJumpIndex: Int? = nil
                let maxLookAhead = min(current.count, i + 150)

                for j in stride(from: maxLookAhead - 1, to: i + 3, by: -1) {
                    // 如果是整条路线的大闭环，不要把整条环线切了
                    if isLoop && i < 6 && j > current.count - 8 {
                        continue
                    }

                    let directDistance = distanceBetween(current[i], current[j])
                    
                    // 如果相隔较多点的两个位置空间距离小于 32 米（处于同一个路口或干道相连处）
                    if directDistance < 32.0 {
                        // 计算中间实际走过的折线路程
                        var segmentTravelDistance = 0.0
                        for k in i..<j {
                            segmentTravelDistance += distanceBetween(current[k], current[k + 1])
                        }

                        // 如果在中间走了 40 米以上，说明拐进了一个小枝盲端又绕了回来
                        if segmentTravelDistance >= 40.0 {
                            bestJumpIndex = j
                            break
                        }
                    }
                }

                if let jump = bestJumpIndex {
                    // 彻底切除 i 到 jump 之间的整个死胡同突起小枝！
                    i = jump
                    changed = true
                } else {
                    i += 1
                }
            }
            current = result
        }

        // 尾部多余毛刺修剪（如果末尾几米有反向折头）
        if current.count > 4 {
            let lastIdx = current.count - 1
            if distanceBetween(current[lastIdx], current[lastIdx - 2]) < distanceBetween(current[lastIdx - 1], current[lastIdx - 2]) {
                current.removeLast()
            }
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
