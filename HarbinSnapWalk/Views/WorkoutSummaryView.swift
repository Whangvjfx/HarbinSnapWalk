import SwiftUI

struct WorkoutSummaryView: View {
    let record: ActivityRecord
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 20) {
                // 顶部勋章与成就标题
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 68, height: 68)
                            .shadow(color: .orange.opacity(0.4), radius: 10, y: 5)

                        Image(systemName: "figure.walk")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    Text("漫步达成！")
                        .font(.title2.bold())

                    Text("\(record.cityName) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 核心数据网格
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        metricBox(title: "总活动时间", value: record.durationFormatted, icon: "timer", color: .blue)
                        metricBox(title: "实际里程", value: record.distanceKmFormatted, icon: "map.fill", color: .green)
                    }

                    HStack(spacing: 12) {
                        metricBox(title: "消耗热量", value: String(format: "%.0f kcal", record.caloriesKcal), icon: "flame.fill", color: .orange)
                        metricBox(title: "总计步数", value: "\(record.steps) 步", icon: "shoeprints.fill", color: .purple)
                    }

                    HStack(spacing: 12) {
                        metricBox(title: "平均速度", value: String(format: "%.1f km/h", record.averageSpeedKmH), icon: "speedometer", color: .teal)
                        metricBox(title: "路线达成率", value: String(format: "%.0f%%", record.completionRate * 100), icon: "checkmark.seal.fill", color: .indigo)
                    }
                }

                // 确定并归档按钮
                Button(action: onDismiss) {
                    Text("完成并归档")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                        )
                }
                .padding(.top, 6)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .padding(.horizontal, 24)
        }
    }

    private func metricBox(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
