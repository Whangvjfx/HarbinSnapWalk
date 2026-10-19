import SwiftUI

struct SaveRouteDialogView: View {
    @Binding var isPresented: Bool
    @State private var routeName: String
    let defaultName: String
    var onSave: (String) -> Void

    init(isPresented: Binding<Bool>, defaultName: String, onSave: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self.defaultName = defaultName
        self._routeName = State(initialValue: defaultName)
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 20) {
                // 顶部图标与标题
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 58, height: 58)
                            .shadow(color: .orange.opacity(0.35), radius: 8, y: 4)

                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    Text("收藏此路线")
                        .font(.title3.bold())

                    Text("保存后可随时在「我的收藏」中一键调出并开始漫步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }

                // 路线名称输入框
                VStack(alignment: .leading, spacing: 6) {
                    Text("路线名称")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("例如：哈工程晨跑环线、钟楼夜游线", text: $routeName)
                            .font(.subheadline)

                        if !routeName.isEmpty {
                            Button(action: { routeName = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }

                // 操作按钮
                HStack(spacing: 12) {
                    Button(action: { isPresented = false }) {
                        Text("取消")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                    }

                    Button(action: {
                        let finalName = routeName.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(finalName.isEmpty ? defaultName : finalName)
                        isPresented = false
                    }) {
                        Text("确认收藏")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing))
                                    .shadow(color: .orange.opacity(0.35), radius: 6, y: 3)
                            )
                    }
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
            .padding(.horizontal, 28)
        }
    }
}
