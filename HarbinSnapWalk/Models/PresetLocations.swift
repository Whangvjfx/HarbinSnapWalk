import Foundation
import CoreLocation

struct HEUPreset: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func == (lhs: HEUPreset, rhs: HEUPreset) -> Bool {
        lhs.name == rhs.name
    }

    /// 核心锚点：哈工程西一门（西侧主出入口 / 靠近文化公园与生活区）
    static let defaultCenter = HEUPreset(
        name: "哈工程西一门",
        subtitle: "西侧出入口 / 近文化公园与学生区",
        latitude: 45.77305,
        longitude: 126.67837
    )

    static let list: [HEUPreset] = [
        defaultCenter,
        HEUPreset(name: "哈工程中心区", subtitle: "11号楼 / 陈赓雕像", latitude: 45.7772, longitude: 126.6820),
        HEUPreset(name: "军工操场", subtitle: "大操场 / 启航活动中心旁", latitude: 45.7745, longitude: 126.6865),
        HEUPreset(name: "奥列霍夫广场", subtitle: "哈工程北门 / 东大直街", latitude: 45.7812, longitude: 126.6788),
        HEUPreset(name: "文庙街南门", subtitle: "哈工程南门 / 船舶电子大世界", latitude: 45.7718, longitude: 126.6805),
        HEUPreset(name: "文化公园", subtitle: "南通大街西侧步道", latitude: 45.7725, longitude: 126.6710),
        HEUPreset(name: "斯大林公园", subtitle: "防洪纪念塔沿江步道", latitude: 45.7794, longitude: 126.6177)
    ]
}
