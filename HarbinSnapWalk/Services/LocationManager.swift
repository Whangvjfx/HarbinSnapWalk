import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var userHeading: CLHeading?
    @Published var isHeadingActive: Bool = false

    override init() {
        super.init()
        manager.delegate = self
        
        // 核心省电配置 1：降低精度到 10 米级，大幅降低基带与卫星侦测占空比
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        
        // 核心省电配置 2：步行 10 米才触发一次坐标推送，静止时不唤醒渲染
        manager.distanceFilter = 10.0
        
        // 核心省电配置 3：启用步行健身低功耗曲线
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
        
        // 磁力计罗盘过滤阈值（偏转超过 5 度再触发更新）
        manager.headingFilter = 5.0
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// 罗盘生命周期调控：仅在「视角朝向跟随」模式下启动，避免常驻消耗磁力计功耗
    func setHeadingTracking(enabled: Bool) {
        isHeadingActive = enabled
        if enabled {
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        self.userLocation = latest.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        self.userHeading = newHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("定位获取异常: \(error.localizedDescription)")
    }
}
