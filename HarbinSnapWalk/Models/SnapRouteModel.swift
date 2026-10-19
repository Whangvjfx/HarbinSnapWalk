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
            var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            poly.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))
            coords.append(contentsOf: points)
        }
        return coords
    }
}
