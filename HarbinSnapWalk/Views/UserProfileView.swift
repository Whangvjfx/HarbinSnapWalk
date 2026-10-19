import SwiftUI

struct UserProfileView: View {
    @ObservedObject var profile: UserProfileModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        // 1. 顶部核心健康与建议漫步距离卡片 (Apple Health 质感)
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: "heart.text.square.fill")
                                    .font(.title2)
                                    .foregroundStyle(.pink)
                                Text("健康评估与建议漫步指标")
                                    .font(.headline)
                                Spacer()
                                Text(profile.bmiCategory)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.pink.opacity(0.12)))
                                    .foregroundStyle(.pink)
                            }

                            Divider()

                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("每日建议距离")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "%.1f km", profile.recommendedDailyDistanceKm))
                                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                                        .foregroundStyle(.blue)
                                }

                                Divider().frame(height: 36)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("推荐目标步数")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(profile.recommendedSteps) 步")
                                        .font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                }

                                Divider().frame(height: 36)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("体质 BMI")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "%.1f", profile.bmi))
                                        .font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                }
                            }

                            // 医生级健康小贴士
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                                Text(profile.healthAdviceText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                                )
                                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                        )

                        // 2. 身体生理特征卡片
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: "figure.walk.motion")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                Text("生理测量参数")
                                    .font(.headline)
                                Spacer()
                                Text("体重默认为着衣和鞋测量")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Divider()

                            // 生理性别
                            HStack {
                                Text("生理性别")
                                    .font(.subheadline)
                                Spacer()
                                Picker("性别", selection: $profile.gender) {
                                    ForEach(UserGender.allCases) { g in
                                        Text(g.rawValue).tag(g)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 140)
                            }

                            // 身高
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("身高")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(profile.heightCm)) cm")
                                        .font(.system(.body, design: .rounded).bold())
                                        .foregroundStyle(.blue)
                                }
                                Slider(value: $profile.heightCm, in: 130...210, step: 1)
                            }

                            // 体重 (默认着衣鞋测量)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("体重 (日常着衣鞋测量)")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.1f kg", profile.weightKg))
                                        .font(.system(.body, design: .rounded).bold())
                                        .foregroundStyle(.blue)
                                }
                                Slider(value: $profile.weightKg, in: 35...130, step: 0.5)
                            }

                            // 年龄
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("年龄")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(profile.age) 岁")
                                        .font(.system(.body, design: .rounded).bold())
                                        .foregroundStyle(.blue)
                                }
                                Stepper("", value: $profile.age, in: 12...95)
                                    .labelsHidden()
                            }
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                                )
                                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                        )

                        // 3. 自然步长测算卡片
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: "shoeprints.fill")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                                Text("步频与步长推算")
                                    .font(.headline)
                                Spacer()
                            }

                            Divider()

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("当前测算步长")
                                        .font(.subheadline)
                                    Text(profile.isCustomStride ? "手动固定设定" : "根据身高骨骼自动推算")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.2f 米/步", profile.effectiveStrideLength))
                                    .font(.system(.headline, design: .rounded).bold())
                                    .foregroundStyle(.green)
                            }

                            Toggle("自定义步长", isOn: $profile.isCustomStride)
                                .font(.subheadline)

                            if profile.isCustomStride {
                                VStack(alignment: .leading, spacing: 6) {
                                    Slider(value: $profile.customStrideMeters, in: 0.45...1.10, step: 0.02)
                                    Text(String(format: "当前值: %.2f m", profile.customStrideMeters))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                                )
                                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                        )
                    }
                    .padding(16)
                }
            }
            .navigationTitle("健康与身体档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
