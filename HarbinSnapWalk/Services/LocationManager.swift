import Foundation
import CoreLocation

// 全局支持 CLLocationCoordinate2D 比较
extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var userHeading: CLHeading?
    @Published var isHeadingActive: Bool = false
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        
        // 核心省电配置 1：降低精度到 10 米级，大幅降低基带与卫星侦测占空比
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        
        // 核心省电配置 2：步行 8 米才触发一次坐标推送，静止时不唤醒渲染
        manager.distanceFilter = 8.0
        
        // 核心省电配置 3：启用步行健身低功耗曲线
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
        
        // 磁力计罗盘过滤阈值（偏转超过 5 度再触发更新）
        manager.headingFilter = 5.0

        // 允许后台持续定位（开启行程后持续记录）
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let coord = latest.coordinate
        Task { @MainActor in
            self.userLocation = coord
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        Task { @MainActor in
            self.userHeading = newHeading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("定位获取异常: \(error.localizedDescription)")
    }
}
