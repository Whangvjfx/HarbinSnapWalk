import SwiftUI

struct HistoryRecordsView: View {
    @ObservedObject var store: ActivityRecordStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if store.records.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "figure.walk.arrival")
                            .font(.system(size: 56))
                            .foregroundStyle(.tertiary)
                        Text("暂无漫步归档记录")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("在地图上画出路线并启动行程，结束后将自动记录到这里。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        // 顶部统计总览卡片
                        Section {
                            VStack(spacing: 12) {
                                HStack(spacing: 16) {
                                    statCell(title: "累计里程", value: String(format: "%.1f km", store.totalDistanceKm), color: .blue)
                                    Divider()
                                    statCell(title: "累计热量", value: String(format: "%.0f kcal", store.totalCalories), color: .orange)
                                    Divider()
                                    statCell(title: "运动总时长", value: String(format: "%.1f 小时", store.totalDurationHours), color: .green)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                                )
                        )

                        // 历史条目明细
                        Section(header: Text("历史漫步明细（支持左滑删除）")) {
                            ForEach(store.records) { item in
                                HStack(spacing: 14) {
                                    Circle()
                                        .fill(item.isLoop ? Color.blue.opacity(0.15) : Color.green.opacity(0.15))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: item.isLoop ? "arrow.triangle.2.circlepath" : "arrow.right")
                                                .font(.headline)
                                                .foregroundStyle(item.isLoop ? .blue : .green)
                                        )

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.cityName)
                                                .font(.headline)
                                            Spacer()
                                            Text(item.distanceKmFormatted)
                                                .font(.system(.headline, design: .rounded).bold())
                                                .foregroundStyle(.blue)
                                        }

                                        HStack(spacing: 10) {
                                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("·")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(item.durationFormatted)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("·")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "%.0f kcal", item.caloriesKcal))
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .onDelete(perform: store.deleteRecord)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("漫步历史归档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}
