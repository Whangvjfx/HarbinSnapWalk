import Foundation
import CoreLocation

// 向前兼容与桥接
typealias HEUPreset = CitySpot

extension CitySpot {
    static var defaultCenter: CitySpot {
        SupportedCity.harbin.defaultSpot
    }
    
    static var list: [CitySpot] {
        SupportedCity.harbin.spots
    }
}
