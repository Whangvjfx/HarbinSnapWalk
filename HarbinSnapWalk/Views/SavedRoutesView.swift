import SwiftUI
import CoreLocation

struct SavedRoutesView: View {
    @ObservedObject var store: SavedRouteStore
    var onSelectRoute: (SavedRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var editingRouteId: UUID? = nil
    @State private var editingName: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if store.savedRoutes.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 56))
                            .foregroundStyle(.tertiary)
                        Text("暂无收藏的路线")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("在地图上随手画出心仪路线后，点击下方「收藏」按钮即可在此保存并随时调出。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        Section(header: Text("已收藏的专属路线（点击即可调出并在地图开始运动）")) {
                            ForEach(store.savedRoutes) { route in
                                Button(action: {
                                    onSelectRoute(route)
                                    dismiss()
                                }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            // 路线形态图标
                                            Image(systemName: route.isLoop ? "arrow.triangle.2.circlepath" : "arrow.right")
                                                .font(.caption.bold())
                                                .foregroundStyle(route.isLoop ? .blue : .indigo)
                                                .padding(6)
                                                .background(Circle().fill((route.isLoop ? Color.blue : Color.indigo).opacity(0.12)))

                                            // 路线名称
                                            if editingRouteId == route.id {
                                                TextField("路线名称", text: $editingName, onCommit: {
                                                    store.renameRoute(id: route.id, newName: editingName)
                                                    editingRouteId = nil
                                                })
                                                .textFieldStyle(.roundedBorder)
                                            } else {
                                                Text(route.name)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                            }

                                            Spacer()

                                            // 重命名小按钮
                                            Button(action: {
                                                if editingRouteId == route.id {
                                                    store.renameRoute(id: route.id, newName: editingName)
                                                    editingRouteId = nil
                                                } else {
                                                    editingName = route.name
                                                    editingRouteId = route.id
                                                }
                                            }) {
                                                Image(systemName: editingRouteId == route.id ? "checkmark.circle.fill" : "pencil")
                                                    .font(.caption)
                                                    .foregroundStyle(editingRouteId == route.id ? .green : .secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        // 指标标签栏
                                        HStack(spacing: 12) {
                                            Label(route.distanceKmFormatted, systemImage: "figure.walk")
                                                .font(.system(.caption, design: .rounded).bold())
                                                .foregroundStyle(.blue)

                                            Label("\(route.estimatedSteps) 步", systemImage: "shoeprints.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            Label(String(format: "%.0f kcal", route.estimatedCalories), systemImage: "flame.fill")
                                                .font(.caption)
                                                .foregroundStyle(.orange)

                                            Spacer()

                                            Text(route.cityName)
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                            .onDelete(perform: store.deleteRoute)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("我的路线收藏")
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
