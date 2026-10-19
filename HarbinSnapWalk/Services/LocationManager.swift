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

    /// 原始定位回调（不依赖 SwiftUI 视图刷新，App 处于后台时依然可靠触发，用于行程追踪）
    var onLocationUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        
        // 闲置模式：10 米级精度 + 8 米触发，省电
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 8.0
        manager.activityType = .fitness
        // 闲置时允许系统自动暂停以省电；行程中会强制关闭（见 setWorkoutMode）
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

    /// 行程模式切换：行程中使用最高精度、禁止系统自动暂停定位（否则锁屏后 iOS 可能停止定位且不再恢复）
    func setWorkoutMode(active: Bool) {
        if active {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5.0
            manager.pausesLocationUpdatesAutomatically = false
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 8.0
            manager.pausesLocationUpdatesAutomatically = true
        }
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
        Task { @MainActor in
            self.userLocation = latest.coordinate
            self.onLocationUpdate?(latest)
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
