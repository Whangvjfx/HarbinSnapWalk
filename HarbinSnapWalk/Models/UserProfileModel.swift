import Foundation

enum UserGender: String, CaseIterable, Identifiable, Codable {
    case male = "男"
    case female = "女"
    
    var id: String { rawValue }
}

final class UserProfileModel: ObservableObject {
    private let key = "HarbinSnapWalk_UserProfile"
    
    @Published var gender: UserGender {
        didSet { save() }
    }
    @Published var heightCm: Double {
        didSet { save() }
    }
    @Published var weightKg: Double {
        didSet { save() }
    }
    @Published var age: Int {
        didSet { save() }
    }
    @Published var isCustomStride: Bool {
        didSet { save() }
    }
    @Published var customStrideMeters: Double {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(ProfileStorage.self, from: data) {
            self.gender = saved.gender
            self.heightCm = saved.heightCm
            self.weightKg = saved.weightKg
            self.age = saved.age
            self.isCustomStride = saved.isCustomStride
            self.customStrideMeters = saved.customStrideMeters
        } else {
            self.gender = .male
            self.heightCm = 175.0
            self.weightKg = 68.0
            self.age = 22
            self.isCustomStride = false
            self.customStrideMeters = 0.72
        }
    }

    /// 自动根据身高与性别推算合理自然步长（米）
    var effectiveStrideLength: Double {
        if isCustomStride {
            return max(0.4, min(1.2, customStrideMeters))
        }
        let ratio = (gender == .male) ? 0.415 : 0.413
        let calculated = (heightCm * ratio) / 100.0
        return max(0.45, min(1.0, calculated))
    }

    /// 根据运动耗时（秒）与平均速度（km/h）计算卡路里消耗 (kcal)
    func calculateCalories(durationSeconds: TimeInterval, speedKmH: Double) -> Double {
        let hours = max(0, durationSeconds) / 3600.0
        guard hours > 0 else { return 0 }
        
        let met: Double
        if speedKmH < 3.5 {
            met = 2.8
        } else if speedKmH < 4.8 {
            met = 3.5
        } else if speedKmH < 6.0 {
            met = 4.3
        } else if speedKmH < 7.5 {
            met = 5.5
        } else {
            met = 6.8
        }
        
        return met * weightKg * hours
    }

    private func save() {
        let storage = ProfileStorage(
            gender: gender,
            heightCm: heightCm,
            weightKg: weightKg,
            age: age,
            isCustomStride: isCustomStride,
            customStrideMeters: customStrideMeters
        )
        if let encoded = try? JSONEncoder().encode(storage) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

private struct ProfileStorage: Codable {
    let gender: UserGender
    let heightCm: Double
    let weightKg: Double
    let age: Int
    let isCustomStride: Bool
    let customStrideMeters: Double
}
