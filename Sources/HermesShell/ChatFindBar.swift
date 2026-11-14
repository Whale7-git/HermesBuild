import SwiftUI
import UIKit

struct ChatFindBar: View {
    @Binding var query: String
    let count: Int
    let index: Int
    let searching: Bool
    let snippet: String?
    let onStep: (Int) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var lastAnnouncement = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 12)
                TextField("查找已加载的正文", text: $query)
                    .font(.subheadline).focused($focused)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.search).onSubmit { focused = false; onStep(0) }
                    .accessibilityLabel("在当前会话已加载的消息正文中查找")
                if searching { ProgressView().controlSize(.small) }
                else { Text(count == 0 ? "0" : "\(index + 1)/\(count)\(count == 300 ? "+" : "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                stepButton("chevron.up", label: "上一处匹配", direction: -1)
                stepButton("chevron.down", label: "下一处匹配", direction: 1)
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭会话内查找")
            }
            Text(snippet ?? (query.isEmpty ? "仅查找已加载的正文；加载更早消息可扩大范围。" : "没有匹配的正文"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .padding(.horizontal, 12).padding(.bottom, 10)
                .accessibilityLabel(snippet.map { "匹配摘要：\($0)。跳转定位到所在消息。" } ?? "仅查找已加载正文")
        }
        .buttonStyle(.plain).tint(AppTheme.accent)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14).padding(.vertical, 6)
        .onAppear {
            // 自动聚焦会抢走 VoiceOver 焦点，使栏内其它控件被跳过。
            guard !UIAccessibility.isVoiceOverRunning else { return }
            focused = true
        }
        .onChange(of: index) { _, _ in announceMatch() }
        .onChange(of: count) { _, _ in announceMatch() }
    }

    /// 计数与位置只有视觉反馈；VoiceOver 需要显式播报当前命中位置。
    private func announceMatch() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let text: String
        if count > 0 {
            text = "第 \(min(max(index, 0), count - 1) + 1) 处，共 \(count) 处"
        } else {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            text = "没有匹配的正文"
        }
        // index 与 count 同一次更新里都可能变化，去重避免重复播报。
        guard text != lastAnnouncement else { return }
        lastAnnouncement = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    private func stepButton(_ symbol: String, label: String, direction: Int) -> some View {
        Button { focused = false; onStep(direction) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }.disabled(count == 0 || searching).accessibilityLabel(label)
    }
}
