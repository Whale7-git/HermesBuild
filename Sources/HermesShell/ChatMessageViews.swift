import SwiftUI
import UIKit
import Textual

struct DayDividerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.top, 18)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle().fill(AppTheme.hairline).frame(height: 1)
    }
}

/// 居中的时间行：只在组与组之间出现一次，不再每条消息挂小字。
struct TimeDividerRow: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .accessibilityLabel(label)
    }
}

/// 终态通知行（对齐 Conduit 的 notice item）：一轮怎么结束的，在对话流里留一条
/// 可见记录，用图标区分取消/失败/打断/预算上限。
struct ChatNoticeRow: View {
    let notice: ChatNotice

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(AppTheme.hairline.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch notice.kind {
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .interrupted: return "hand.raised"
        case .workLimit: return "hourglass"
        case .stopped: return "stop.circle"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .cancelled, .stopped: return .secondary
        case .failed: return AppTheme.danger
        case .interrupted: return AppTheme.action
        case .workLimit: return .orange
        }
    }
}

struct ChatMessageRow: View {
    let message: ChatMessage
    let showsSender: Bool
    /// 同一组的续条：不重复头像/名字/时间行，只留正文。
    var isContinuation: Bool = false
    let isStreaming: Bool
    let onCopy: (String) -> Void
    var actionsEnabled: Bool = false
    /// 后端能力表。分支/重生成要「显示但禁用」而不是静默消失——
    /// 静默消失让用户无法区分「这个后端不支持」与「坏了」。
    var capabilities: BackendCapabilities = .webUI
    /// 只在组首显示时间；组内续条不重复。
    var showsTime = true
    /// 该段是否给出「复制」：同一轮里只有最后一段有。
    var showsCopy = true
    var attachmentBaseURL: URL? = nil
    var attachmentSessionID: String = ""
    /// 附件预览该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var attachmentAuthorization: AttachmentAuthorization = .cookieOnly
    /// 纯图占位标记的账号作用域；只在展示层使用，不影响发送与导出。
    var placeholderScope: String = ""
    /// 图片比例快照（会话内冻结）与其作用域。
    var imageRatios: ImageRatioSnapshot = .empty
    var imageRatioScope: String = ""
    var onEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onCopyProcess: () -> Void = {}
    var onShareReply: () -> Void = {}
    var onQuote: () -> Void = {}
    var onOpenReader: () -> Void = {}
    @Binding var collapsed: Bool
    var onCopyReply: () -> Void = {}
    /// 消息内查找：渲染后文本的检索词，以及本行内第 N 个命中为当前项。
    var findQuery: String = ""
    var activeFindOrdinal: Int? = nil
    @State private var selectedMessageText: MessageSelectionText?
    @State private var internalNoticeExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    private var isUser: Bool { message.role == "user" }
    private var backgroundBody: String? { ChatBackgroundEnvelope.userBody(message) }
    private var isInternalNotification: Bool { backgroundBody != nil }
    /// 只显示本实例能安全预览的路径；外部 URL 不当图片拉取。
    private var previewable: [String] { message.attachmentPaths }
    private var collapsible: Bool { !isStreaming && ChatPresentation.isCollapsible(message.content) }
    /// 只有「本机记录 + 附件 + 占位原文」同时成立才隐藏文字；其余一律照常显示。
    private var hidesAttachmentPlaceholder: Bool {
        // 先做零成本判定，避免每一行都去读本机记录。
        guard isUser, !previewable.isEmpty, !placeholderScope.isEmpty,
              message.content == ChatAttachmentPlaceholder.systemText else { return false }
        // 只看这条消息自己的身份：正文相同但没被标记的消息照常显示。
        return ChatAttachmentPlaceholder.hidesBody(
            messageID: message.id, content: message.content, role: message.role,
            attachmentCount: previewable.count,
            markedIDs: ChatAttachmentPlaceholderStore.shared.markedIDs(
                scope: placeholderScope, sessionID: attachmentSessionID))
    }
    private var visibleText: String {
        collapsed && !isStreaming ? ChatPresentation.collapsedPreview(message.content) : message.content
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            if showsHeader { header }
            if isUser {
                if isInternalNotification {
                    internalNoticeBubble
                } else if !hidesAttachmentPlaceholder {
                    // 纯图消息不画文字气泡；附件条本身承载上下文菜单。
                    userBubble
                }
            } else { assistantBody }
            if !previewable.isEmpty, let attachmentBaseURL {
                attachmentStrip(baseURL: attachmentBaseURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        // 让一条回复成为**一个可聚焦容器**，而不是一堆平铺的元素。
        //
        // 正文是 UITextView，VoiceOver 本来就能读——缺的是消息级语义：没有它，
        // 一条多段回复会被拆成十几个可聚焦元素逐个朗读，听感是碎的。
        // 用 `.contain` 而不是 `.combine`：combine 会把整条长回复压成一段
        // 不可导航的文本，反而更糟（用户无法只重听某一段）。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isInternalNotification ? "后台通知" : (isUser ? "你的消息" : "Hermes 的回复"))
        .sheet(item: $selectedMessageText) { item in
            MessageTextSelectionSheet(text: item.text)
        }
    }

    /// Conversational reading is content-first: sender metadata is available
    /// from the session context and timeline, not repeated above every bubble.
    /// Hiding this static chrome also reduces row height churn during updates.
    private var showsHeader: Bool { false }

    private var header: some View {
        HStack(spacing: 7) {
            if !isUser, showsSender {
                HermesAvatar(size: 20)
                Text("Hermes")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if showsTime, let stamp = message.timestamp {
                Text(ChatPresentation.timeLabel(Date(timeIntervalSince1970: stamp)))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 后端是否支持从指定消息处分支。网关只支持整会话复制，
    /// 此时入口仍然显示，但禁用并说明原因。
    private var canForkAtMessage: Bool { capabilities.canForkAtMessage }

    /// 禁用原因。能力可用时返回空串（无障碍提示留白，不制造噪音）。
    private var forkAtMessageHint: String {
        capabilities.unavailableHint(for: .forkAtMessage) ?? ""
    }

    /// 纯图消息没有文字气泡，长按附件条仍要能编辑/复制。
    @ViewBuilder
    private func attachmentStrip(baseURL: URL) -> some View {
        let strip = AttachmentStrip(paths: previewable, name: message.id,
                                    baseURL: baseURL, sessionID: attachmentSessionID,
                                    authorization: attachmentAuthorization,
                                    imageRatios: imageRatios, imageRatioScope: imageRatioScope)
        if hidesAttachmentPlaceholder {
            strip.contextMenu {
                Button("编辑并在分支发送", systemImage: "pencil", action: onEdit)
                    .disabled(!actionsEnabled || !canForkAtMessage)
                    .accessibilityHint(forkAtMessageHint)
                Button("复制", systemImage: "doc.on.doc") { copy() }
            }
        } else {
            strip
        }
    }

    /// Only server-labelled internal notifications are collapsed.
    /// Never classify arbitrary user text by matching OOB-looking strings.
    private var internalNoticeBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { internalNoticeExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                    Text(internalNoticeExpanded ? "收起后台消息" : "查看后台消息")
                    Image(systemName: internalNoticeExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(internalNoticeExpanded ? "收起后台消息" : "展开后台消息")
            if internalNoticeExpanded {
                Text(backgroundBody ?? message.content)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                Button("复制后台原文", systemImage: "doc.on.doc") {
                    onCopy(message.content)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 320, alignment: .trailing)
    }

    private var userBubble: some View {
        Group {
            if findQuery.isEmpty {
                Text(message.content).textSelection(.enabled)
            } else {
                ChatFindPlainText(text: message.content, query: findQuery, activeOrdinal: activeFindOrdinal)
            }
        }
            .font(.body)
            .lineSpacing(3)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background {
                // 光模式下 userFill 与画布对比仍偏弱，加一圈轻描边保证气泡有轮廓；
                // 描边画在内侧，不改变布局高度。
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.userFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(contrast == .increased ? AppTheme.hairline : Color.clear, lineWidth: 1)
                    }
            }
            .frame(maxWidth: 320, alignment: .trailing)
            // 气泡内只有这一个文本叶子节点，label 直接覆盖默认朗读，不会重复。
            .accessibilityLabel("你：\(message.content)")
            .contextMenu {
                Button("编辑并在分支发送", systemImage: "pencil", action: onEdit)
                    .disabled(!actionsEnabled || !canForkAtMessage)
                    .accessibilityHint(forkAtMessageHint)
                Button("复制", systemImage: "doc.on.doc") { copy() }
                Button("引用回复", systemImage: "quote.bubble") { onQuote() }
            }
    }

    @ViewBuilder
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeMarkdownView(text: visibleText, cacheable: !isStreaming,
                               findQuery: findQuery, activeFindOrdinal: activeFindOrdinal)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)

            if ChatPresentation.replyActionsVisible(
                isStreaming: isStreaming, showsCopy: showsCopy,
                isCollapsible: collapsible) {
                replyActions
            }
        }
    }

    private var replyActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout { replyActionButtons }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var replyActionButtons: some View {
        if showsCopy {
            Button(action: onCopyReply) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label("复制", systemImage: "square.on.square")
                            .frame(minHeight: 44)
                    } else {
                        Image(systemName: "square.on.square")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("复制本轮已加载的回复")
            Button(action: onQuote) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label("引用", systemImage: "quote.bubble")
                            .frame(minHeight: 44)
                    } else {
                        Image(systemName: "quote.bubble")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("引用回复")
        }
        Menu {
            Button("专注阅读", systemImage: "text.page", action: onOpenReader)
            Divider()
            if collapsible {
                Button(collapsed ? "展开摘要" : "收起全文",
                       systemImage: collapsed ? "chevron.down" : "chevron.up") {
                    collapsed.toggle()
                }
                Divider()
            }
            Button("选择本条原文", systemImage: "selection.pin.in.out") {
                selectedMessageText = MessageSelectionText(text: message.content)
            }
            Button("复制本条全文", systemImage: "doc.on.doc") { copy() }
            Button("复制为 Markdown", systemImage: "text.badge.checkmark") {
                copyMarkdown()
            }
            if showsCopy {
                Button("复制整轮过程", systemImage: "text.page.badge.magnifyingglass") {
                    onCopyProcess()
                }
                Button("分享整轮回答", systemImage: "square.and.arrow.up") {
                    onShareReply()
                }
                Button("在分支重新生成", systemImage: "arrow.clockwise", action: onRegenerate)
                    .disabled(!actionsEnabled || !canForkAtMessage)
                    .accessibilityHint(forkAtMessageHint)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("本条回复的更多操作")
    }

    private func copy() {
        onCopy(message.content)

    }

    /// 「复制这条为 Markdown」：本轮工具一起带出；不含标题与用量。
    /// `onCopy` 在本行只收文本，Toast 文案由上游 `MessageListView` 统一给。
    private func copyMarkdown() {
        onCopy(TranscriptExporter.markdown(for: message))
    }

    /// 用户气泡是纯文本，String 的 grapheme 偏移可直接落在 AttributedString 上。
    private func highlightedAttributed(_ text: String) -> AttributedString {
        chatFindHighlighted(AttributedString(text), query: findQuery,
                            activeOrdinal: activeFindOrdinal)
    }
}

/// 在渲染结果上按字符偏移着色，只加背景色，不改字体与语义。
/// 偏移越界或区间无效时跳过，绝不因为查找词而丢内容。
private func chatFindHighlighted(_ content: AttributedString, query: String,
                                 activeOrdinal: Int?) -> AttributedString {
    guard !query.isEmpty else { return content }
    let plain = String(content.characters)
    guard !plain.isEmpty else { return content }
    let ranges = ChatFindHighlight.characterRanges(of: query, in: plain)
    guard !ranges.isEmpty else { return content }
    var result = content
    // 写入背景色不改变字符数，长度只算一次；否则每个命中都要 O(n) 数一遍。
    let total = result.characters.count
    for (ordinal, range) in ranges.enumerated() {
        let characters = result.characters
        guard range.lowerBound >= 0, range.upperBound <= total,
              range.lowerBound < range.upperBound,
              let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound,
                                          limitedBy: characters.endIndex),
              let upper = characters.index(characters.startIndex, offsetBy: range.upperBound,
                                          limitedBy: characters.endIndex),
              lower < upper else { continue }
        result[lower..<upper].backgroundColor = ordinal == activeOrdinal
            ? AppTheme.accent.opacity(0.45)
            : AppTheme.accent.opacity(0.20)
        result[lower..<upper][TextualFindOccurrenceAttribute.self] = ordinal
    }
    return result
}

struct NativeMarkdownView: View, Equatable {
    let text: String
    let cacheable: Bool
    /// 查找高亮：query 为空时完全走原渲染路径。
    var findQuery: String = ""
    var activeFindOrdinal: Int? = nil
    @Environment(\.chatRenderState) private var rendering
    /// 相邻段落合并成一个原生文本视图后，块间距改由段落间距承担：
    /// 0.65 × 17pt ≈ 11pt，随 Dynamic Type 缩放，与 ChatReadingParagraphStyle 一致。
    @ScaledMetric(relativeTo: .body) private var nativeParagraphSpacing: CGFloat = 11
    /// 本条消息里是否有选区；合并段落会重建文本视图，所以结构切换要等选区结束。
    @StateObject private var selectionActivity = TextualSelectionActivity()
    @State private var mergeState: ParagraphMergeState
    @StateObject private var document: ChatMarkdownDocument
    @ObservedObject private var performance = ChatPerformanceRecorder.shared

    init(text: String, cacheable: Bool = true, findQuery: String = "", activeFindOrdinal: Int? = nil) {
        self.text = text
        self.cacheable = cacheable
        _mergeState = State(initialValue: ParagraphMergeState(finished: cacheable))
        self.findQuery = findQuery
        self.activeFindOrdinal = activeFindOrdinal
        _document = StateObject(wrappedValue: ChatMarkdownDocument(source: text, finished: cacheable))
    }

    static func == (left: Self, right: Self) -> Bool {
        left.text == right.text && left.cacheable == right.cacheable
            && left.findQuery == right.findQuery
            && left.activeFindOrdinal == right.activeFindOrdinal
    }

    var body: some View {
        // 只生成着色副本，document 本身不因查找词变化而重解析。
        let content = chatFindHighlighted(document.content, query: findQuery,
                                          activeOrdinal: activeFindOrdinal)
        StructuredText(attributedString: content, deferCodeHighlightingAfter: document.highlightAfter)
            // This override must be closest to StructuredText: the bundle
            // below also supplies listItemStyle through the environment.
            .textual.listItemStyle(ChatNativeListItemStyle())
            .textual.paragraphStyle(ChatReadingParagraphStyle())
            .textual.headingStyle(ChatReadingHeadingStyle())
            .textual.codeBlockStyle(ChatCodeBlockStyle())
            .textual.structuredTextStyle(.gitHub)
            // UIKit now draws and selects the same visible glyphs. Textual
            // retains block layout; its reflected selection overlay stays off.
            .textual.textSelection(.disabled)
            .environment(\.textualUsesNativeTextViews, true)
            // 合并后的段落间距：只在段落边界生效，块自身的底部间距保持不变。
            .environment(\.textualNativeParagraphSpacing, nativeParagraphSpacing)
            // 只对已完成消息合并相邻段落；正在选字时推迟到选区结束再切换结构。
            .environment(\.textualBlockCoalescing, mergeState.enabled)
            .environment(\.textualSelectionActivity, Optional(selectionActivity))
            .environment(\.textualCodeTokenizationDuration, performance.durationSink(for: .highlight))
            .font(.body)
            .lineSpacing(4)
            // 消息正文里的 Markdown 链接必须走白名单：默认 openURL 会把
            // 自定义 scheme / file: / javascript: 交给系统处理，等于让
            // 不可信的模型输出决定跳转目标。
            .environment(\.openURL, OpenURLAction { url in
                guard ExternalLinkPolicy.canOpen(url.absoluteString) else { return .discarded }
                return .systemAction
            })
            .onAppear { document.appear(rendering: rendering) }
            .onChange(of: cacheable) { _, finished in
                mergeState.update(finished: finished, selecting: selectionActivity.isSelecting)
            }
            .onChange(of: selectionActivity.isSelecting) { _, selecting in
                mergeState.update(finished: cacheable, selecting: selecting)
            }
            .onDisappear {
                document.disappear()
            }
            .onChange(of: ChatMarkdownDocument.Request(source: text, finished: cacheable), initial: true) { _, request in
                document.update(source: request.source, finished: request.finished)
            }
    }

}

/// Native fragments do not expose SwiftUI Text's first/last baselines.
/// Textual's inferred firstTextCenter can depend on the whole item height.
/// Use real top edges instead, independent of the paragraph's line count.
private struct ChatNativeListItemStyle: StructuredText.ListItemStyle {
    @ScaledMetric(relativeTo: .body) private var markerSpacing: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: markerSpacing) {
            configuration.marker
            configuration.block
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChatReadingParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.22))
            .textual.blockSpacing(.fontScaled(top: 0, bottom: 0.65))
    }
}

private struct ChatReadingHeadingStyle: StructuredText.HeadingStyle {
    func makeBody(configuration: Configuration) -> some View {
        let scales: [CGFloat] = [1.55, 1.3, 1.15, 1.05, 1, 1]
        configuration.label
            .textual.fontScale(scales[min(6, max(1, configuration.headingLevel)) - 1])
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: 0.9, bottom: 0.5))
    }
}

private struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel(configuration.languageHint))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                CodeCopyButton { configuration.codeBlock.copyToPasteboard() }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(AppTheme.softFill)

            Rectangle().fill(AppTheme.hairline).frame(height: 0.5)

            // Textual's Overflow preserves selection and excludes horizontal
            // code gestures from the surrounding document selection surface.
            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.225))
                    .textual.fontScale(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .padding(14)
            }
        }
        .background(AppTheme.codeFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .textual.blockSpacing(.init(top: 8, bottom: 12))
    }

    private func languageLabel(_ hint: String?) -> String {
        let label = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "代码" : label
    }
}

/// One round of tool calls collapsed to a single quiet line. Expanding shows
/// each call flat, separated by a hairline — no card inside a card.
struct ChatToolGroup: View {
    let tools: [ChatTool]
    var allowsRunning = false
    let copied: (String) -> Void
    @Binding var expanded: Bool
    @Binding var expandedToolIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var running: Bool { allowsRunning && tools.contains { !$0.done && !$0.isError } }
    private var failed: Bool { tools.contains(where: \.isError) }
    private var unresolved: Bool { tools.contains { !$0.done && !$0.isError } }
    private var summaryItems: [ChatToolSummary.Item] {
        tools.map { ChatToolSummary.Item(name: $0.name, done: $0.done, isError: $0.isError) }
    }
    var body: some View {
        // The header is updated for every live tool event. Map the complete
        // tool array once, not independently for title and subtitle.
        let items = summaryItems
        let title = ChatToolSummary.title(items, allowsRunning: allowsRunning)
        let summary = ChatToolSummary.summary(items, allowsRunning: allowsRunning)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: failed ? "exclamationmark.circle" : (running ? "gearshape.2" : (unresolved ? "questionmark.circle" : "checkmark.circle")))
                        .font(.footnote)
                        .foregroundStyle(failed ? Color.orange : (running ? AppTheme.accent : (unresolved ? Color.secondary : AppTheme.success)))
                    VStack(alignment: .leading, spacing: 2) {
                        // 折叠行只占一行：标题 + 摘要合在一起。
                        //
                        // 原先是 title 一行、summary 再一行（footnote + caption2），
                        // 一轮工具调用在时间线里就占两行高度，回复越长这类行越多，
                        // 视觉上像「每段工具后面都拖一条尾巴」。摘要本身是补充信息，
                        // 同一行放得下就够；放不下用 `lineLimit(1)` 截断，展开仍可看全。
                        Text(summary.isEmpty ? title : "\(title) · \(summary)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)。\(expanded ? "收起" : "展开")详情")
            .accessibilityHint(summary)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 {
                            Rectangle().fill(AppTheme.hairline).frame(height: 1).padding(.vertical, 6)
                        }
                        ChatToolDetail(tool: tool, allowsRunning: allowsRunning, copied: copied, expanded: Binding(
                            get: { expandedToolIDs.contains(tool.id) },
                            // @Binding<Set> 的 getter 给的是拷贝，原地 insert/remove 会被丢弃，
                            // 必须整体写回（与 MessageListView 的 state 绑定同理）。
                            set: { toggled in
                                var next = expandedToolIDs
                                if toggled { next.insert(tool.id) } else { next.remove(tool.id) }
                                expandedToolIDs = next
                            }
                        ))
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AppTheme.hairline)
                        .frame(width: 1)
                        .padding(.leading, 4)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Collapsed execution detail for earlier assistant segments. The final answer
/// remains a normal selectable Markdown row below this disclosure.
struct ChatProcessRow: View {
    let group: ChatProcessGroup
    var allowsRunning = false
    @Binding var expanded: Bool
    @Binding var toolsExpanded: Bool
    @Binding var expandedToolIDs: Set<String>
    let copied: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var running: Bool {
        allowsRunning && group.tools.contains { !$0.done && !$0.isError }
    }
    private var failed: Bool { group.tools.contains(where: \.isError) }
    private var executionItems: [ChatToolSummary.Item] {
        group.tools.map { .init(name: $0.name, done: $0.done, isError: $0.isError) }
    }
    var body: some View {
        let items = executionItems
        let title = ChatExecutionPresentation.title(
            messageCount: group.messages.count, toolItems: items, allowsRunning: allowsRunning)
        let subtitle = ChatExecutionPresentation.detail(
            messageCount: group.messages.count, toolItems: items, allowsRunning: allowsRunning)
        return VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: failed ? "exclamationmark.circle.fill"
                          : (running ? "ellipsis.bubble.fill" : "checkmark.circle"))
                        .font(.footnote)
                        .foregroundStyle(failed ? AppTheme.warning
                                         : (running ? AppTheme.accent : AppTheme.success))
                        // 工具执行可能几十秒没有文字输出，静态图标让人怀疑卡死。
                        // 呼吸只在实际运行时生效，完成/失败自动停。
                        .symbolEffect(.pulse, options: .repeating, isActive: running && !reduceMotion)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(failed ? AppTheme.warning : Color.secondary)
                            .lineLimit(1)
                        if !subtitle.isEmpty && (expanded || dynamicTypeSize.isAccessibilitySize) {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)。\(expanded ? "收起" : "展开")详情")
            .accessibilityHint("\(subtitle)。最终回答在下方")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.messages) { message in
                        NativeMarkdownView(text: message.content, cacheable: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !group.tools.isEmpty {
                        ChatToolGroup(tools: group.tools, allowsRunning: allowsRunning,
                            copied: copied, expanded: $toolsExpanded,
                            expandedToolIDs: $expandedToolIDs)
                    }
                }
                .padding(.leading, 17)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .overlay(alignment: .bottom) {
            if expanded {
                Rectangle()
                    .fill(AppTheme.hairline)
                    .frame(height: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ChatToolDetail: View {
    let tool: ChatTool
    var allowsRunning = false
    let copied: (String) -> Void
    @Binding var expanded: Bool
    @State private var showFullResult = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: tool.isError ? "xmark.circle" : (tool.done ? "checkmark.circle" : "clock"))
                        .font(.caption2)
                        .foregroundStyle(tool.isError ? Color.orange : Color.secondary)
                    Text(tool.name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if allowsRunning && !tool.done && !tool.isError {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: expanded)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tool.name)，\(tool.isError ? "执行失败" : (tool.done ? "已完成" : (allowsRunning ? "执行中" : "状态待核对")))。\(expanded ? "收起" : "展开")详情")

            if expanded {
                if !tool.args.isEmpty {
                    sectionLabel("参数")
                    Text(String(tool.args.prefix(4000)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
                if !tool.result.isEmpty {
                    HStack {
                        sectionLabel("结果")
                        Spacer()
                        Button { copied(tool.result) } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.caption2)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("复制工具结果")
                    }
                    Text(String(tool.result.prefix(16000)))
                        .font(.system(.caption, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .lineLimit(20)
                    Button("查看完整结果") { showFullResult = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.accent)
                        .frame(minHeight: 44, alignment: .leading)
                } else if tool.done {
                    Text("执行结束；此接口未返回结果正文。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showFullResult) {
            NavigationStack {
                ReadOnlyResultView(text: tool.result)
                    .navigationTitle(tool.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("复制") { copied(tool.result) }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showFullResult = false }
                        }
                    }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }
}
