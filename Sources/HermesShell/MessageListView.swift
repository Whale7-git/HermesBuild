import SwiftUI
import UIKit

/// 消息行视图。折叠/展开状态由外层按稳定 id 持有。
struct ChatRowCell: View {
    let item: ChatRowItem
    var actionsEnabled: Bool = false
    /// 后端能力表：决定「分支」这类入口是可用、禁用还是根本不支持。
    var capabilities: BackendCapabilities = .webUI
    var baseURL: URL? = nil
    var sessionID: String = ""
    /// 附件预览该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var attachmentAuthorization: AttachmentAuthorization = .cookieOnly
    /// 纯图占位标记的账号作用域；空串时不做隐藏（保守）。
    var placeholderScope: String = ""
    /// 图片比例快照（会话内冻结）与其作用域。
    var imageRatios: ImageRatioSnapshot = .empty
    var imageRatioScope: String = ""
    var onAction: (ChatMessage, Bool) -> Void = { _, _ in }
    var onCopyReply: (String) -> Void = { _ in }
    var onCopyProcess: (String) -> Void = { _ in }
    var onShareReply: (String) -> Void = { _ in }
    var onQuote: (ChatMessage) -> Void = { _ in }
    var onOpenReader: (ChatMessage) -> Void = { _ in }
    let onCopy: (String, String) -> Void
    @Binding var state: ChatCellState
    /// 消息内查找：渲染后文本的检索词，以及本行内第 N 个命中为当前项。
    var findQuery: String = ""
    var activeFindOrdinal: Int? = nil
    /// 投递未确认时的动作行接线；默认空实现，现有调用点不需要改动。
    var canResendPending: Bool = false
    var pendingBusy: Bool = false
    var onReconcilePending: (String) -> Void = { _ in }
    var onResendPending: (String) -> Void = { _ in }
    var onDiscardPending: (String) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            switch item.row.kind {
            case .day(let day):
                DayDividerRow(label: ChatPresentation.dayLabel(day))
            case .time(let date):
                TimeDividerRow(label: ChatPresentation.timeLabel(date))
            case .message(let message):
                // 用户气泡的三态小字挂在气泡正下方；confirmed 时不产生任何额外节点。
                VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                    ChatMessageRow(
                        message: message,
                        showsSender: item.row.showsSender,
                        isContinuation: item.row.isContinuation,
                        isStreaming: item.isStreaming,
                        onCopy: { onCopy($0, "已复制回复") },
                        actionsEnabled: actionsEnabled && message.sourceIndex != nil,
                        capabilities: capabilities,
                        showsTime: ChatPresentation.showsTimeLabel(for: item.row),
                        showsCopy: ChatPresentation.showsCopy(for: item.row),
                        attachmentBaseURL: baseURL, attachmentSessionID: sessionID,
                        attachmentAuthorization: attachmentAuthorization,
                        placeholderScope: placeholderScope,
                        imageRatios: imageRatios, imageRatioScope: imageRatioScope,
                        onEdit: { onAction(message, false) },
                        onRegenerate: { onAction(message, true) },
                        onCopyProcess: { onCopyProcess(message.id) },
                        onShareReply: { onShareReply(message.id) },
                        onQuote: { onQuote(message) },
                        onOpenReader: { onOpenReader(message) },
                        collapsed: collapsedBinding,
                        onCopyReply: { onCopyReply(message.id) },
                        findQuery: findQuery,
                        activeFindOrdinal: activeFindOrdinal
                    )
                    if message.role == "user", item.row.delivery != .confirmed {
                        ChatDeliveryStatusLine(delivery: item.row.delivery,
                                               canResend: canResendPending)
                    }
                    if message.role == "user", item.row.delivery == .unconfirmed {
                        deliveryActions(for: message)
                    }
                }
                // Continuations stay visually attached to their answer. Group
                // starts use the same measured top spacing as before, while
                // the row's bottom inset supplies the rest of the rhythm.
                .padding(.top, item.row.isContinuation
                         ? AppTheme.groupGap / 2
                         : CGFloat(ChatPresentation.topSpacing(for: item.row)))
            case .tools(let tools):
                ChatToolGroup(tools: tools, allowsRunning: item.toolsAreLive, copied: { onCopy($0, "已复制工具结果") },
                    expanded: toolsExpandedBinding,
                    expandedToolIDs: expandedToolIDsBinding)
                    .padding(.top, 2)
            case .process(let group):
                ChatProcessRow(group: group, allowsRunning: item.toolsAreLive,
                    expanded: processExpandedBinding,
                    toolsExpanded: toolsExpandedBinding,
                    expandedToolIDs: expandedToolIDsBinding,
                    copied: { onCopy($0, "已复制工具结果") })
                    .padding(.top, 2)
            case .notice(let notice):
                ChatNoticeRow(notice: notice)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.bottom, item.row.isContinuation ? 7 : 10)
        .id(item.id)
    }

    /// 投递未确认时的动作行：核对 / 重发 / 放弃。仅 unconfirmed 出现。
    private func deliveryActions(for message: ChatMessage) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button("核对状态") { onReconcilePending(message.id) }
                .font(.caption.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.action)
                .accessibilityLabel("核对这条消息的投递状态")
                .disabled(pendingBusy)

            Button("重发") { onResendPending(message.id) }
                .font(.caption.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.action)
                .disabled(!canResendPending)
                .opacity(canResendPending ? 1 : 0.45)
                .accessibilityLabel("重发这条消息")
                .accessibilityHint(canResendPending
                    ? "重新提交这条未确认的消息"
                    : "先核对状态，确认后台没有这条消息后才可重发")

            // 放弃不是破坏性操作，用次要色而非红色。
            Button("放弃") { onDiscardPending(message.id) }
                .font(.caption.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("放弃这条未确认的消息")
                .disabled(pendingBusy)
        }
    }

    // 派生 Binding：@Binding 的 wrappedValue 是值类型拷贝，必须整体写回才能落库。
    private var collapsedBinding: Binding<Bool> {
        Binding(get: { state.collapsed }, set: { newValue in
            var s = state; s.collapsed = newValue; state = s
        })
    }
    private var toolsExpandedBinding: Binding<Bool> {
        Binding(get: { state.toolsExpanded }, set: { newValue in
            var s = state; s.toolsExpanded = newValue; state = s
        })
    }
    private var processExpandedBinding: Binding<Bool> {
        Binding(get: { state.processExpanded }, set: { newValue in
            var s = state; s.processExpanded = newValue; state = s
        })
    }
    private var expandedToolIDsBinding: Binding<Set<String>> {
        Binding(get: { state.expandedToolIDs }, set: { newValue in
            var s = state; s.expandedToolIDs = newValue; state = s
        })
    }
}

/// 用户气泡下方的投递三态小字。动作行由 `ChatRowCell` 在 unconfirmed 时补在下方。
private struct ChatDeliveryStatusLine: View {
    let delivery: ChatDeliveryState
    /// 后台已核对没有这条消息，允许重发时换一个更积极的文案。
    var canResend: Bool = false

    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(spokenLabel)
    }

    private var title: String {
        switch delivery {
        case .confirmed: return ""
        case .submitting: return "提交中…"
        case .accepted: return "已受理"
        case .unconfirmed: return canResend ? "历史未发现 · 可重发" : "结果待核对 · 草稿已保留"
        }
    }

    /// VoiceOver 需要先听到「结果待核对」这一前缀，再补充它意味着什么。
    private var spokenLabel: String {
        guard delivery == .unconfirmed else { return title }
        let base = "结果待核对，发送结果尚未确认，请刷新历史后核对"
        return canResend ? "\(base)。后台已核对没有这条消息，可以重发" : base
    }
}

/// Immutable footer input: model publications must not resize a hosted footer
/// behind UIKit's back while a user gesture owns the viewport.
/// 错误与只读提示改由聊天页顶部的钉住条承担，这里只留思考过程与活动行。
struct ChatStatusSnapshot: Equatable {
    var reasoning: String
    var running: Bool
    var notice: String?
    var activityTitle: String
    var activityInChrome = false
    /// A concrete tool already appears in its own process row; do not repeat its
    /// name in the footer. Generic reply progress stays visible while streaming.
    var duplicatesToolRow: Bool {
        running && activityTitle.hasPrefix("正在执行 ")
    }
    /// When a live tool row already shows progress, reasoning can remain in its
    /// own disclosure but the spinner line is redundant.
    var showsActivityLine: Bool { running && !duplicatesToolRow && !activityInChrome }
    var showsReasoning: Bool {
        !reasoning.isEmpty && !(running && duplicatesToolRow)
    }
    var isVisible: Bool { showsActivityLine || notice != nil || showsReasoning }
}

/// 底部状态区：思考过程、正在执行、提示。随消息一起滚动，不压住正文。
struct ChatStatusFooter: View {
    let state: ChatStatusSnapshot
    let webURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.showsReasoning {
                ReasoningPanel(text: state.reasoning, running: state.running)
            }
            if state.showsActivityLine {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.activityTitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = state.notice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                    if notice.contains("审批") || notice.contains("补充信息") {
                        Link("在浏览器处理", destination: webURL).font(.footnote)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 10)
    }

}
