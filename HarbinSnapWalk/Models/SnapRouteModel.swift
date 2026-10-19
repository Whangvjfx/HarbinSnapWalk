import Foundation
import MapKit
import CoreLocation

enum RouteShape: String, Codable {
    case loop = "环形闭环路线"
    case open = "单向通行路线"
    
    var iconName: String {
        switch self {
        case .loop: return "arrow.triangle.2.circlepath"
        case .open: return "arrow.right"
        }
    }
}

enum WalkSeason: String, CaseIterable, Identifiable {
    case springFall = "常规季节 (默认步长)"
    case winterIce = "哈尔滨冰雪防滑 (小步紧凑)"
    var id: String { rawValue }
    
    func factor(baseStride: Double) -> Double {
        switch self {
        case .springFall: return baseStride
        case .winterIce: return baseStride * 0.90
        }
    }
}

struct RouteDirectionArrow: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let bearingDegrees: Double
}

/// 无障碍风险提示点（如无法避开的人行天桥、地下通道或台阶路段）
struct RouteBarrierAlert: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
    let instruction: String
}

struct SnappedRouteResult {
    let polylines: [MKPolyline]
    let anchorWaypoints: [CLLocationCoordinate2D]
    let totalDistanceMeters: Double
    let estimatedTravelSeconds: TimeInterval
    let strideLength: Double
    let shape: RouteShape
    var barrierAlerts: [RouteBarrierAlert] = []
    var avoidedBarrierCount: Int = 0
    /// 方向箭头在创建路线时一次性计算并缓存（避免每次 GPS 刷新都重算、重建全部地图标注）
    let directionalArrows: [RouteDirectionArrow]

    init(
        polylines: [MKPolyline],
        anchorWaypoints: [CLLocationCoordinate2D],
        totalDistanceMeters: Double,
        estimatedTravelSeconds: TimeInterval,
        strideLength: Double,
        shape: RouteShape,
        barrierAlerts: [RouteBarrierAlert] = [],
        avoidedBarrierCount: Int = 0
    ) {
        self.polylines = polylines
        self.anchorWaypoints = anchorWaypoints
        self.totalDistanceMeters = totalDistanceMeters
        self.estimatedTravelSeconds = estimatedTravelSeconds
        self.strideLength = strideLength
        self.shape = shape
        self.barrierAlerts = barrierAlerts
        self.avoidedBarrierCount = avoidedBarrierCount
        self.directionalArrows = SnappedRouteResult.buildArrows(polylines: polylines)
    }

    var startCoordinate: CLLocationCoordinate2D? {
        anchorWaypoints.first
    }

    var endCoordinate: CLLocationCoordinate2D? {
        anchorWaypoints.last
    }

    var estimatedSteps: Int {
        Int(round(totalDistanceMeters / max(strideLength, 0.2)))
    }

    var distanceKmFormatted: String {
        String(format: "%.2f km", totalDistanceMeters / 1000.0)
    }

    var durationFormatted: String {
        let mins = Int(round(estimatedTravelSeconds / 60.0))
        let hrs = mins / 60
        let remainMins = mins % 60
        if hrs > 0 {
            return "\(hrs)小时\(remainMins)分"
        } else {
            return "\(mins)分钟"
        }
    }

    /// 预估运动消耗热量 (kcal)
    func estimatedCalories(weightKg: Double) -> Double {
        let hours = max(0, estimatedTravelSeconds) / 3600.0
        return 3.5 * weightKg * hours
    }

    /// 提取路线所有密集折线点坐标，用于沿线追踪检测
    var allRouteCoordinates: [CLLocationCoordinate2D] {
        SnappedRouteResult.coordinates(of: polylines)
    }

    private static func coordinates(of polylines: [MKPolyline]) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        for poly in polylines {
            let pointCount = poly.pointCount
            guard pointCount > 0 else { continue }
            var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            poly.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))
            coords.append(contentsOf: points)
        }
        return coords
    }

    /// 沿路线按真实里程均匀分布的透明行进方向小箭头（每 90 米一个，按插值精确定位）
    private static func buildArrows(polylines: [MKPolyline]) -> [RouteDirectionArrow] {
        let coords = coordinates(of: polylines)
        guard coords.count >= 2 else { return [] }

        var arrows: [RouteDirectionArrow] = []
        let stepIntervalMeters = 90.0
        var nextMark = stepIntervalMeters * 0.5
        var travelled = 0.0

        for i in 0..<(coords.count - 1) {
            let p1 = coords[i]
            let p2 = coords[i + 1]
            let segDist = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
            guard segDist > 0.01 else { continue }

            while travelled + segDist >= nextMark {
                let t = (nextMark - travelled) / segDist
                let coord = CLLocationCoordinate2D(
                    latitude: p1.latitude + (p2.latitude - p1.latitude) * t,
                    longitude: p1.longitude + (p2.longitude - p1.longitude) * t
                )
                arrows.append(
                    RouteDirectionArrow(
                        id: arrows.count,
                        coordinate: coord,
                        bearingDegrees: calculateBearing(from: p1, to: p2)
                    )
                )
                nextMark += stepIntervalMeters
            }
            travelled += segDist
        }

        return arrows
    }

    private static func calculateBearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180.0
        let lon1 = start.longitude * .pi / 180.0
        let lat2 = end.latitude * .pi / 180.0
        let lon2 = end.longitude * .pi / 180.0
        
        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180.0 / .pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}
