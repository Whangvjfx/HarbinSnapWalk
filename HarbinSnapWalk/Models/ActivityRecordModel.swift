import Foundation

struct ActivityRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let cityName: String
    let distanceMeters: Double
    let durationSeconds: TimeInterval
    let steps: Int
    let caloriesKcal: Double
    let averageSpeedKmH: Double
    let completionRate: Double
    let isLoop: Bool

    var distanceKmFormatted: String {
        String(format: "%.2f km", distanceMeters / 1000.0)
    }

    var durationFormatted: String {
        let mins = Int(round(durationSeconds / 60.0))
        let hrs = mins / 60
        let remainMins = mins % 60
        if hrs > 0 {
            return "\(hrs)小时\(remainMins)分"
        } else {
            return "\(mins)分钟"
        }
    }

    var paceFormatted: String {
        guard distanceMeters > 50, durationSeconds > 10 else { return "--'--\"" }
        let km = distanceMeters / 1000.0
        let secPerKm = durationSeconds / km
        let mins = Int(secPerKm / 60.0)
        let secs = Int(secPerKm.truncatingRemainder(dividingBy: 60))
        return String(format: "%d'%02d\"", mins, secs)
    }
}

@MainActor
final class ActivityRecordStore: ObservableObject {
    @Published var records: [ActivityRecord] = []
    
    private let fileName = "activity_records.json"

    private var fileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(fileName)
    }

    init() {
        load()
    }

    func addRecord(_ record: ActivityRecord) {
        records.insert(record, at: 0)
        save()
    }

    func deleteRecord(by id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func deleteRecord(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    var totalDistanceKm: Double {
        records.reduce(0) { $0 + $1.distanceMeters } / 1000.0
    }

    var totalCalories: Double {
        records.reduce(0) { $0 + $1.caloriesKcal }
    }

    var totalDurationHours: Double {
        records.reduce(0) { $0 + $1.durationSeconds } / 3600.0
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            print("保存行程记录失败: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            self.records = try JSONDecoder().decode([ActivityRecord].self, from: data)
        } catch {
            print("加载行程记录失败: \(error.localizedDescription)")
        }
    }
}
