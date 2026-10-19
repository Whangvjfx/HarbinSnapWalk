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
            self.weightKg = 68.0 // 默认按着衣与穿鞋测量估算
            self.age = 22
            self.isCustomStride = false
            self.customStrideMeters = 0.72
        }
    }

    /// 体质指数 BMI（基于日常穿衣服与鞋测量）
    var bmi: Double {
        let h = heightCm / 100.0
        guard h > 0 else { return 22.0 }
        return weightKg / (h * h)
    }

    var bmiCategory: String {
        let val = bmi
        if val < 18.5 {
            return "体型偏瘦"
        } else if val < 24.0 {
            return "标准匀称"
        } else if val < 28.0 {
            return "微重偏胖"
        } else {
            return "减重护膝期"
        }
    }

    /// 根据用户身高、体重(着衣量)、年龄给出的建议单次/每日漫步距离 (公里)
    var recommendedDailyDistanceKm: Double {
        let baseKm: Double
        if age > 60 {
            baseKm = 3.8
        } else if age > 45 {
            baseKm = 4.8
        } else {
            baseKm = 5.5
        }

        // 根据 BMI 护膝微调
        if bmi >= 28.0 {
            // 体重较重时，建议适度控制单次距离，保护半月板
            return max(3.0, min(5.0, baseKm * 0.85))
        } else if bmi >= 24.0 {
            // 微重区间：鼓励燃脂，建议 5~6 km
            return max(4.5, baseKm * 1.1)
        } else {
            return baseKm
        }
    }

    /// 建议每日步数
    var recommendedSteps: Int {
        let km = recommendedDailyDistanceKm
        let stride = effectiveStrideLength
        return Int(round((km * 1000.0) / stride))
    }

    /// 健康建议小贴士
    var healthAdviceText: String {
        if bmi >= 28.0 {
            return "体重偏重（日常穿衣鞋测得），建议采取平地匀速慢走，单次控制在 3.5~4.5 km，切忌过快，注重膝关节保护。"
        } else if bmi >= 24.0 {
            return "处于微重心血管耐力锻炼黄金期，建议每日保持 5.0~6.5 km 规律中速健走，有效促进脂肪代谢。"
        } else if bmi < 18.5 {
            return "体质偏瘦，建议每日 3.5~5.0 km 舒缓散步，配合营养补充，提升肌肉活力与睡眠质量。"
        } else {
            return "您的体脂比与体质处于健康标准区间。建议每次保持 5.0~6.0 km 舒展快走，保持旺盛精力。"
        }
    }

    /// 自动根据身高与性别推算自然步长（米）
    var effectiveStrideLength: Double {
        if isCustomStride {
            return max(0.4, min(1.2, customStrideMeters))
        }
        let ratio = (gender == .male) ? 0.415 : 0.413
        let calculated = (heightCm * ratio) / 100.0
        return max(0.45, min(1.0, calculated))
    }

    /// 根据运动耗时（秒）与速度（km/h）计算卡路里消耗 (kcal)
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
