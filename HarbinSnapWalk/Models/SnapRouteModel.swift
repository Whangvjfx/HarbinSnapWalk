import Foundation
import MapKit
import CoreLocation

enum WalkSeason: String, CaseIterable, Identifiable {
    case springFall = "常规季节 (0.74m/步)"
    case winterIce = "哈尔滨冰雪防滑 (0.68m/步)"
    var id: String { rawValue }
    var strideLength: Double {
        switch self {
        case .springFall: return 0.74
        case .winterIce: return 0.68
        }
    }
}

struct SnappedRouteResult {
    let polylines: [MKPolyline]
    let anchorWaypoints: [CLLocationCoordinate2D]
    let totalDistanceMeters: Double
    let estimatedTravelSeconds: TimeInterval
    let strideLength: Double

    var estimatedSteps: Int {
        Int(round(totalDistanceMeters / max(strideLength, 0.1)))
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
}
