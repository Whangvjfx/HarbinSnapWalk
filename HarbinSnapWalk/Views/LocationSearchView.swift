import SwiftUI
import CoreLocation

struct LocationSearchView: View {
    @StateObject private var searchService = SearchService()
    var onSelectCoordinate: (CLLocationCoordinate2D, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 磨砂质感搜索输入框
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("输入全国地名、路口、小区或景区...", text: $searchService.queryText)
                            .focused($isFieldFocused)
                            .submitLabel(.search)

                        if !searchService.queryText.isEmpty {
                            Button(action: { searchService.queryText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                            )
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    // 联想结果列表
                    List {
                        if searchService.searchResults.isEmpty && !searchService.queryText.isEmpty {
                            Text("未找到相关地点，请尝试输入更广泛的地名")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(searchService.searchResults) { item in
                                Button(action: {
                                    Task {
                                        if let coord = await searchService.resolveCoordinate(for: item) {
                                            onSelectCoordinate(coord, item.title)
                                            dismiss()
                                        }
                                    }
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.blue)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            if !item.subtitle.isEmpty {
                                                Text(item.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.left")
                                            .font(.caption)
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
            .navigationTitle("全国地址搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                isFieldFocused = true
            }
        }
    }
}
