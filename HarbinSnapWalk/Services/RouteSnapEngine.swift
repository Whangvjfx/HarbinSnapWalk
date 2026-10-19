import Foundation
import MapKit
import CoreLocation

@MainActor
final class RouteSnapEngine: ObservableObject {
    @Published var isSnapping = false
    @Published var currentResult: SnappedRouteResult?
    @Published var statusMessage: String = "点击下方画笔，在地图上随手涂鸦即可贴合道路"

    /// 核心入口：将原始手绘屏幕坐标解析为地理序列并吸附至街道
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

        // 1. 几何弦长距离抽稀提取锚点（3~7 个，避免高频请求被封禁）
        let anchors = downsampleCoordinates(rawCoordinates, minIntervalMeters: 250.0, maxPoints: 7)

        guard anchors.count >= 2 else {
            self.statusMessage = "绘制点过密，请扩大画圈跨度"
            return
        }

        // 2. 串联发起步行路径吸附
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

            self.currentResult = SnappedRouteResult(
                polylines: polylines,
                anchorWaypoints: anchors,
                totalDistanceMeters: totalDist,
                estimatedTravelSeconds: totalDuration,
                strideLength: strideLength
            )
            self.statusMessage = "路网吸附完成！"
        } catch {
            self.statusMessage = "部分路段可能受限于围墙或校门，已尽力吸附"
        }
    }

    /// 几何弦长抽稀与闭环吸合算法
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

        // 闭环判断：如果起点和终点直线距离小于 140 米，自动闭合成环
        let lastRaw = points.last!
        let loopDist = distanceBetween(lastRaw, points.first!)
        if loopDist < 140.0 {
            result.append(points.first!)
        } else {
            result.append(lastRaw)
        }

        // 如果锚点仍过多，实施等步长夹紧
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
