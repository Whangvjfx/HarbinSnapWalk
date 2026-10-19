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
                    VStack(spacing: 20) {
                        // 顶部玻璃感卡片：基础生理特征
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: "figure.walk.motion")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                Text("身体健康参数")
                                    .font(.headline)
                                Spacer()
                            }

                            Divider()

                            // 性别选择
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

                            // 身高滑动条
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

                            // 体重滑动条
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("体重 (用于热量计算)")
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
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                                )
                                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                        )

                        // 步长与热量换算模型卡片
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: "flame.fill")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                Text("自然步频与能耗模型")
                                    .font(.headline)
                                Spacer()
                            }

                            Divider()

                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("当前测算步长")
                                        .font(.subheadline)
                                    Text(profile.isCustomStride ? "手动自定义设定" : "根据身高骨骼自动推算")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.2f 米/步", profile.effectiveStrideLength))
                                    .font(.system(.headline, design: .rounded).bold())
                                    .foregroundStyle(.green)
                            }

                            Toggle("自定义步长 (非自动推算)", isOn: $profile.isCustomStride)
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
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                                )
                                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                        )
                    }
                    .padding(16)
                }
            }
            .navigationTitle("健康与生理特征")
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
