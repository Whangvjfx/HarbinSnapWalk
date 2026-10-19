import Foundation
import CoreMotion

@MainActor
final class PedometerService: ObservableObject {
    private let pedometer = CMPedometer()
    @Published var todaySteps: Int = 0

    func refreshTodaySteps() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: startOfDay, to: Date()) { [weak self] data, _ in
            Task { @MainActor in
                self?.todaySteps = data?.numberOfSteps.intValue ?? 0
            }
        }
    }
}
