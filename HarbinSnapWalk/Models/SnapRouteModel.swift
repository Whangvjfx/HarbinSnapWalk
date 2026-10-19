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
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let bearingDegrees: Double
}

struct SnappedRouteResult {
    let polylines: [MKPolyline]
    let anchorWaypoints: [CLLocationCoordinate2D]
    let totalDistanceMeters: Double
    let estimatedTravelSeconds: TimeInterval
    let strideLength: Double
    let shape: RouteShape

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

    /// 沿路线均匀分布的透明行进方向小箭头（每隔 80~100 米一个）
    var directionalArrows: [RouteDirectionArrow] {
        let coords = allRouteCoordinates
        guard coords.count > 4 else { return [] }

        var arrows: [RouteDirectionArrow] = []
        var accumulatedDistance = 0.0
        let stepIntervalMeters = 90.0 // 每隔 90 米放置一个微型行进箭头

        for i in 0..<(coords.count - 1) {
            let p1 = coords[i]
            let p2 = coords[i + 1]
            let segDist = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))
            
            accumulatedDistance += segDist

            if accumulatedDistance >= stepIntervalMeters {
                accumulatedDistance = 0.0
                let bearing = calculateBearing(from: p1, to: p2)
                arrows.append(RouteDirectionArrow(coordinate: p2, bearingDegrees: bearing))
            }
        }

        return arrows
    }

    private func calculateBearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
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
