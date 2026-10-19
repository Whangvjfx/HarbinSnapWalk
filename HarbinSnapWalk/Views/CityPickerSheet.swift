import SwiftUI

struct CityPickerSheet: View {
    @Binding var selectedCity: SupportedCity
    var onSelectSpot: (CitySpot) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    // 城市分段选择器
                    Picker("城市", selection: $selectedCity) {
                        ForEach(SupportedCity.allCases) { city in
                            Text(city.rawValue).tag(city)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // 预设核心地标列表
                    List {
                        Section(header: Text("\(selectedCity.rawValue) · 经典漫步锚点")) {
                            ForEach(selectedCity.spots) { spot in
                                Button(action: {
                                    onSelectSpot(spot)
                                    dismiss()
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .foregroundStyle(spot.name.contains("府北街") || spot.name.contains("西一门") ? .orange : .blue)
                                            .font(.title3)

                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(spot.name)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                                if spot.name.contains("西一门") || spot.name.contains("府北街") {
                                                    Text("推荐")
                                                        .font(.caption2.bold())
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill(.orange.opacity(0.18)))
                                                        .foregroundStyle(.orange)
                                                }
                                            }
                                            Text(spot.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("切换城市与地标")
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
}
