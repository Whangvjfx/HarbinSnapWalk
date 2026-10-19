import Foundation
import CoreLocation

struct CitySpot: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func == (lhs: CitySpot, rhs: CitySpot) -> Bool {
        lhs.name == rhs.name && lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

enum SupportedCity: String, CaseIterable, Identifiable {
    case harbin = "哈尔滨市"
    case xian = "西安市"
    case luochuan = "洛川县"

    var id: String { rawValue }

    var defaultSpot: CitySpot {
        switch self {
        case .harbin:
            return CitySpot(
                name: "哈工程西一门",
                subtitle: "西侧主出入口 / 靠近文化公园与学生区",
                latitude: 45.77305,
                longitude: 126.67837
            )
        case .xian:
            return CitySpot(
                name: "西安钟楼",
                subtitle: "市中心明清地标 / 东大街与南大街交汇",
                latitude: 34.2612,
                longitude: 108.9423
            )
        case .luochuan:
            return CitySpot(
                name: "府北街邮政储蓄银行",
                subtitle: "府北街核心商业生活区",
                latitude: 35.7628,
                longitude: 109.4325
            )
        }
    }

    var spots: [CitySpot] {
        switch self {
        case .harbin:
            return [
                defaultSpot,
                CitySpot(name: "哈工程中心区", subtitle: "11号楼 / 陈赓雕像", latitude: 45.7772, longitude: 126.6820),
                CitySpot(name: "军工操场", subtitle: "大操场 / 启航活动中心旁", latitude: 45.7745, longitude: 126.6865),
                CitySpot(name: "奥列霍夫广场", subtitle: "哈工程北门 / 东大直街", latitude: 45.7812, longitude: 126.6788),
                CitySpot(name: "文庙街南门", subtitle: "哈工程南门 / 船舶电子大世界", latitude: 45.7718, longitude: 126.6805),
                CitySpot(name: "文化公园", subtitle: "南通大街西侧步道", latitude: 45.7725, longitude: 126.6710),
                CitySpot(name: "中央大街", subtitle: "百年俄式步行街", latitude: 45.7700, longitude: 126.6210),
                CitySpot(name: "斯大林公园", subtitle: "防洪纪念塔松花江畔步道", latitude: 45.7794, longitude: 126.6177)
            ]
        case .xian:
            return [
                defaultSpot,
                CitySpot(name: "大雁塔", subtitle: "大慈恩寺文化广场", latitude: 34.2189, longitude: 108.9642),
                CitySpot(name: "西安城墙南门", subtitle: "永宁门城楼广场", latitude: 34.2508, longitude: 108.9470),
                CitySpot(name: "大唐不夜城", subtitle: "盛唐文化步行街", latitude: 34.2115, longitude: 108.9640),
                CitySpot(name: "陕西历史博物馆", subtitle: "小寨东路步道", latitude: 34.2250, longitude: 108.9535),
                CitySpot(name: "西北工业大学友谊校区", subtitle: "友谊西路核心教学区", latitude: 34.2440, longitude: 108.9130),
                CitySpot(name: "西安交大兴庆校区", subtitle: "咸宁西路樱花道", latitude: 34.2480, longitude: 108.9830)
            ]
        case .luochuan:
            return [
                defaultSpot,
                CitySpot(name: "洛川县政府迎宾广场", subtitle: "中心行政休闲广场", latitude: 35.7595, longitude: 109.4310),
                CitySpot(name: "洛川会议纪念馆", subtitle: "冯家村革命旧址步道", latitude: 35.8080, longitude: 109.4380),
                CitySpot(name: "洛川人民公园", subtitle: "县城南侧环湖景观步道", latitude: 35.7560, longitude: 109.4350),
                CitySpot(name: "洛川苹果大市场", subtitle: "解放路北段产业地标", latitude: 35.7680, longitude: 109.4280)
            ]
        }
    }
}
