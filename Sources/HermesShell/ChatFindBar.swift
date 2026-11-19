import SwiftUI
import UIKit

/// A stable-height search surface: changes to loading/count never resize the
/// scroll viewport. Navigation only occurs for an explicit user action.
struct ChatFindBar: View {
    @Binding var query: String
    let count: Int
    let index: Int
    let searching: Bool
    let snippet: String?
    let hasMoreMatches: Bool
    let queryTooLong: Bool
    let canLoadOlder: Bool
    let loadingOlder: Bool
    let olderLimitReached: Bool
    let canReturnToOrigin: Bool
    let onStep: (Int) -> Void
    let onLoadOlder: () -> Void
    let onReturnToOrigin: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var lastAnnouncement = ""

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var countLabel: String {
        if queryTooLong { return "过长" }
        if !hasQuery { return "0" }
        if count == 0 { return "0" }
        return "\(index + 1)/\(count)" + (hasMoreMatches ? "+" : "")
    }

    private var detail: String {
        if queryTooLong { return "关键词过长（最多 512 个 UTF-16 单元），请缩短后重试。" }
        if !hasQuery { return "仅搜索已加载消息；可以主动读取更早历史。" }
        if searching { return "正在搜索已加载的消息…" }
        if let snippet { return snippet }
        return "已加载消息没有匹配；可能还有未加载历史。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).padding(.leading, 12)
                TextField("查找已加载的正文", text: $query)
                    .font(.subheadline).focused($focused)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.search).onSubmit { focused = false; onStep(0) }
                    .accessibilityLabel("在当前会话已加载的消息正文中查找")
                if searching {
                    ProgressView().controlSize(.small).frame(width: 36)
                } else {
                    Text(countLabel).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(minWidth: 36)
                        .accessibilityLabel(count > 0 ? "第 \(index + 1) 个命中，显示 \(count) 个" : "无命中")
                }
                stepButton("chevron.up", label: "上一处匹配", direction: -1)
                stepButton("chevron.down", label: "下一处匹配", direction: 1)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("关闭会话内查找")
            }
            Text(detail)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(height: 18, alignment: .leading)
                .padding(.horizontal, 12)
                .accessibilityLabel(queryTooLong ? detail : "搜索范围为已加载消息。" + detail)
            HStack(spacing: 8) {
                if loadingOlder { ProgressView().controlSize(.small) }
                Button(action: { focused = false; onLoadOlder() }) {
                    Label(olderLimitReached ? "已达历史上限" : "查找更早历史", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                }
                .disabled(!hasQuery || queryTooLong || !canLoadOlder || loadingOlder)
                .accessibilityHint(olderLimitReached ? "已达本地历史窗口上限" : "读取一页更早历史并继续查找")
                Spacer(minLength: 0)
                Button(action: { focused = false; onReturnToOrigin() }) {
                    Label("返回原位置", systemImage: "bookmark")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                }
                .disabled(!canReturnToOrigin)
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain).tint(AppTheme.accent)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14).padding(.vertical, 6)
        .onAppear {
            guard !UIAccessibility.isVoiceOverRunning else { return }
            focused = true
        }
        .onChange(of: index) { _, _ in announceMatch() }
        .onChange(of: count) { _, _ in announceMatch() }
        .onChange(of: queryTooLong) { _, _ in announceMatch() }
        .onChange(of: hasMoreMatches) { _, _ in announceMatch() }
    }

    private func announceMatch() {
        guard UIAccessibility.isVoiceOverRunning, hasQuery else { return }
        let text: String
        if queryTooLong {
            text = "关键词太长，请缩短后重试"
        } else if count > 0 {
            text = "第 \(min(max(index, 0), count - 1) + 1) 处，已显示 \(count) 处"
                + (hasMoreMatches ? "，还有更多匹配" : "")
        } else if searching {
            return
        } else {
            text = "已加载消息中没有匹配"
        }
        guard text != lastAnnouncement else { return }
        lastAnnouncement = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func stepButton(_ symbol: String, label: String, direction: Int) -> some View {
        Button { focused = false; onStep(direction) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .disabled(count == 0 || searching || queryTooLong)
        .accessibilityLabel(label)
    }
}
