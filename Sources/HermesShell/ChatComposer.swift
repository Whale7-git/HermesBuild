import SwiftUI

/// 输入框文本的外部同步指令。父视图只在「确实要改写输入框」时递增 token：
/// 发送成功后清空、分支预填。按键本身完全不经过父视图与模型。
///
/// 性能原因：`draft` 原先挂在 `NativeChatModel`（ObservableObject）上，每敲一个字都会
/// 让整个会话页失效——重建 `ChatListSnapshot` 并对 2000 行做 `==` 比较。现在文本由
/// 输入框自己持有（本视图的 `@State`），一次按键只让输入框子树失效。
struct ChatComposerDraftSync: Equatable {
    var token = 0
    var text = ""
    /// 仅当输入框当前内容等于该值时才覆盖。
    /// 用于「发送成功后清空」：期间用户新敲的字不能被清空逻辑吞掉
    /// （与原 `if draft == composerText { draft = "" }` 语义一致）。
    var onlyIfCurrent: String? = nil
    /// 仅当输入框当前为空时才覆盖。
    /// 用于「发送失败回填」：用户已经开始重新输入时不要再盖掉他的字
    /// （与原 `if draft.isEmpty { draft = originalDraft }` 语义一致）。
    var onlyIfEmpty = false
}

struct ChatComposer: View {
    var draftSync = ChatComposerDraftSync()
    var insertion = ChatComposerInsertion()
    /// 草稿落盘（与模型同一作用域键）。按键期间由本视图防抖写入，
    /// 保证进程被杀后仍能恢复，同时不再逐字触发模型发布。
    var draftStore: ChatDraftStore? = nil
    /// Reports only a failure category to the chat page; draft text stays local.
    var onPersistenceResult: (LocalStoreWriteResult) -> Void = { _ in }
    var onLocalWriteSuccess: () -> Void = {}
    @Binding var focused: Bool
    let modelLabel: String
    let onChooseModel: () -> Void
    let readOnly: Bool
    let loading: Bool
    let running: Bool
    let stopping: Bool
    let canStop: Bool
    let canSend: Bool
    var hasReadyAttachments = false
    var hasAttachmentItems = false
    /// 提交回调带上当前文本：文本不再存在模型里逐字同步。
    let onSend: (String) -> Void
    let onStop: () -> Void
    let onAttach: () -> Void
    var attachments: AnyView? = nil
    var attachmentMenu: AnyView? = nil
    var readOnlyMessage: String? = nil
    /// Hide the routine cache-verification banner, not the read-only gate.
    /// Auth failures, uncertain sends and local persistence failures remain visible.
    var quietReadOnlyNotice = false
    /// 运行中发送语义；由模型持有，输入栏只负责切换。
    @Binding var sendMode: ChatSendMode
    /// 排队中的那条：显示在输入框上方，让用户知道它还等着发。
    var queuedText: String? = nil
    var canSendQueued = false
    var onSendQueued: () -> Void = {}
    var queuedTurns: [ChatQueuedTurn] = []
    var onSendQueuedTurn: (String) -> Void = { _ in }
    var onEditQueuedTurn: (String) -> Void = { _ in }
    var onManageQueue: () -> Void = {}
    var onRemoveQueuedTurn: (String) -> Void = { _ in }
    var contextPressure: ChatContextPressure? = nil
    var showsQueueSummary = true
    var onShowContextUsage: () -> Void = {}
    var onInsertCompressCommand: () -> Void = {}
    @State private var text: String
    @State private var quoteReference: ChatQuote.Reference?
    @State private var quoteExpanded = false
    private var persistedText: String {
        ChatQuote.assemble(quoteReference, reply: text)
    }
    @State private var sendTick = 0
    @State private var stopTick = 0
    @State private var composing = false
    @State private var caretOffset = 0
    @State private var commandInsertion: ChatDraftCommandInsertion?
    @State private var pendingCommand: String?
    @State private var draftMetrics = ChatDraftMetrics(visibleLines: 1, isScrollable: false)
    @AppStorage("chatReturnSends") private var returnSends = true
    /// A-04：动画必须响应「减弱动态效果」。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(initialDraft: String, draftSync: ChatComposerDraftSync = ChatComposerDraftSync(),
         insertion: ChatComposerInsertion = ChatComposerInsertion(),
         draftStore: ChatDraftStore? = nil,
         onPersistenceResult: @escaping (LocalStoreWriteResult) -> Void = { _ in },
         onLocalWriteSuccess: @escaping () -> Void = {},
         focused: Binding<Bool>, modelLabel: String = "默认模型",
         onChooseModel: @escaping () -> Void = {},
         readOnly: Bool, loading: Bool,
         running: Bool, stopping: Bool, canStop: Bool, canSend: Bool,
         hasReadyAttachments: Bool = false, hasAttachmentItems: Bool = false,
         onSend: @escaping (String) -> Void, onStop: @escaping () -> Void,
         onAttach: @escaping () -> Void, attachments: AnyView? = nil, attachmentMenu: AnyView? = nil,
         readOnlyMessage: String? = nil,
         quietReadOnlyNotice: Bool = false,
         sendMode: Binding<ChatSendMode>, queuedText: String? = nil, canSendQueued: Bool = false,
         onSendQueued: @escaping () -> Void = {},
         queuedTurns: [ChatQueuedTurn] = [], onSendQueuedTurn: @escaping (String) -> Void = { _ in },
         onEditQueuedTurn: @escaping (String) -> Void = { _ in },
         onManageQueue: @escaping () -> Void = {},
         onRemoveQueuedTurn: @escaping (String) -> Void = { _ in },
         contextPressure: ChatContextPressure? = nil,
         onShowContextUsage: @escaping () -> Void = {},
         onInsertCompressCommand: @escaping () -> Void = {},
         showsQueueSummary: Bool = true) {
        self.showsQueueSummary = showsQueueSummary
        self.draftSync = draftSync
        self.insertion = insertion
        self.draftStore = draftStore
        self.onPersistenceResult = onPersistenceResult
        self.onLocalWriteSuccess = onLocalWriteSuccess
        _focused = focused
        self.modelLabel = modelLabel
        self.onChooseModel = onChooseModel
        self.readOnly = readOnly
        self.loading = loading
        self.running = running
        self.stopping = stopping
        self.canStop = canStop
        self.canSend = canSend
        self.hasReadyAttachments = hasReadyAttachments
        self.hasAttachmentItems = hasAttachmentItems
        self.onSend = onSend
        self.onStop = onStop
        self.onAttach = onAttach
        self.attachments = attachments
        self.attachmentMenu = attachmentMenu
        self.readOnlyMessage = readOnlyMessage
        self.quietReadOnlyNotice = quietReadOnlyNotice
        _sendMode = sendMode
        self.queuedText = queuedText
        self.canSendQueued = canSendQueued
        self.onSendQueued = onSendQueued
        self.queuedTurns = queuedTurns
        self.onSendQueuedTurn = onSendQueuedTurn
        self.onEditQueuedTurn = onEditQueuedTurn
        self.onManageQueue = onManageQueue
        self.onRemoveQueuedTurn = onRemoveQueuedTurn
        self.contextPressure = contextPressure
        self.onShowContextUsage = onShowContextUsage
        self.onInsertCompressCommand = onInsertCompressCommand
        let decoded = ChatQuote.splitDraft(initialDraft)
        _text = State(initialValue: decoded.reply)
        _quoteReference = State(initialValue: decoded.reference)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sendEnabled: Bool { canSend && !composing && (!trimmed.isEmpty || hasReadyAttachments) }
    /// Queue actions do not depend on the current attachment editor state.
    private var canDispatchQueued: Bool {
        canSendQueued && !running && !loading && !readOnly && !stopping
    }
    private var showsAttachments: Bool { hasAttachmentItems }
    private var editingEnabled: Bool { !loading && !readOnly }

    /// 只在超过 4 行（接近 6 行封顶）时出现，避免一行输入就被提示打扰。
    private var draftHint: String? {
        guard !readOnly, draftMetrics.visibleLines > 4 else { return nil }
        return draftMetrics.isScrollable
            ? "已显示 \(draftMetrics.visibleLines) 行 · 可滚动"
            : "已显示 \(draftMetrics.visibleLines) 行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsQueueSummary {
                if !queuedTurns.isEmpty { queuedList }
                else if let queuedText { queuedNotice(queuedText) }
            }
            if let contextPressure { contextPressureNotice(contextPressure) }
            if readOnly && !quietReadOnlyNotice { readOnlyNotice }
            inputCard
        }
        .background(AppTheme.canvas)
        // 只冻结草稿驱动的尺寸变化；spinner、聚焦描边等系统动画保持存活。
        .animation(nil, value: text)
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .sensoryFeedback(.impact(weight: .light), trigger: stopTick)
        // 防抖落盘：继续输入会取消上一轮写入，停止输入 500ms 后才写一次。
        // 相比原先「逐字写 UserDefaults」，磁盘写入次数下降一个数量级。
        .task(id: persistedText) {
            guard let draftStore else { return }
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            let result = draftStore.save(persistedText)
            if result.succeeded {
                onLocalWriteSuccess()
            } else {
                onPersistenceResult(result)
            }
        }
        .onChange(of: draftSync.token) { _, _ in applyDraftSync() }
        .onChange(of: insertion.token) { _, _ in applyInsertion() }
        .onChange(of: commandInsertion?.token) { _, _ in
            guard let next = pendingCommand else { return }
            pendingCommand = nil
            text = next
            caretOffset = (next as NSString).length
            if let draftStore { report(draftStore.save(next)) }
        }
        .onDisappear {
            if let draftStore { report(draftStore.save(persistedText)) }
        }
        .onChange(of: readOnly) { _, value in
            if value { composing = false }
        }
        .onChange(of: focused) { _, value in
            if !value {
                composing = false
                // 失焦立刻落盘：防抖窗口只有 500ms，但用户「打完就切走」很常见，
                // 这里补一次同步写入，保证进程被杀也不会丢草稿。
                if let draftStore { report(draftStore.save(persistedText)) }
            }
        }
    }

    /// 外部改写输入框（清空 / 分支预填 / 失败回填）。token 是唯一的触发条件，
    /// 因此父视图不必把输入内容纳入自己的状态。
    private func applyDraftSync() {
        if let expected = draftSync.onlyIfCurrent, persistedText != expected { return }
        if draftSync.onlyIfEmpty, !text.isEmpty || quoteReference != nil { return }
        let parsed = ChatQuote.splitDraft(draftSync.text)
        guard text != parsed.reply || quoteReference != parsed.reference else { return }
        text = parsed.reply
        quoteReference = parsed.reference
        quoteExpanded = false
        // 立即落盘：避免「已清空」与「防抖写盘」之间的窗口把旧草稿写回磁盘。
        if let draftStore { report(draftStore.save(persistedText)) }
    }

    private func report(_ result: LocalStoreWriteResult) {
        if result.succeeded { onLocalWriteSuccess() }
        else { onPersistenceResult(result) }
    }

    /// Quoting updates a compact, removable preview. The transmitted quote
    /// remains in persistedText for recovery, but never enters UITextView.
    private func applyInsertion() {
        if let reference = insertion.quote {
            quoteReference = reference
            quoteExpanded = false
            if let draftStore { report(draftStore.save(persistedText)) }
            focused = true
            return
        }
        guard !insertion.text.isEmpty else { return }
        let next = ChatComposerInsertionPlan.append(insertion.text, to: text)
        // Reuse the editor's document insertion path so the selection moves to
        // the end of the quote instead of staying at the old caret.
        pendingCommand = next
        commandInsertion = ChatDraftCommandInsertion(
            token: (commandInsertion?.token ?? 0) &+ 1, text: next)
        focused = true
    }

    /// 只读态不再整体消失，说明行固定 32pt，输入框保留为禁用态。
    private var readOnlyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: loading ? "clock" : "lock")
            Text(readOnlyMessage ?? (loading ? "正在读取会话…" : "此会话只读"))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// 排队中的那条：明确告诉用户「还没发出去」，而不是让它消失。
    private func queuedNotice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.append")
            VStack(alignment: .leading, spacing: 2) {
                Text(running ? "排队中 · 本轮正常结束后自动发送" : "排队消息尚未发送").font(.caption.weight(.medium))
                Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !running {
                Button("发送", action: onSendQueued)
                    .font(.caption.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!canSendQueued)
                    .accessibilityLabel("发送排队消息")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }

    private var commandSuggestions: [ChatSlashCommand.Suggestion] {
        guard !readOnly, focused, !composing else { return [] }
        return ChatSlashCommand.menuSuggestions(for: text, caretUTF16Offset: caretOffset)
    }

    private var queuedList: some View {
        Button(action: onManageQueue) {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("待发送 · \(queuedTurns.count) 条")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(queueSummary)
                        .font(.caption2)
                        .foregroundStyle(queueNeedsAttention ? AppTheme.warning : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("管理")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AppTheme.softFill.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("待发送 \(queuedTurns.count) 条，\(queueSummary)")
        .accessibilityHint("打开消息队列管理")
    }

    private var queueSummary: String {
        let status = ChatQueueStatus(turns: queuedTurns)
        guard status.total > 0 else { return "" }
        if status.needsAttention || status.submitting > 0 {
            return status.compactSummary
        }
        guard let first = queuedTurns.first else { return status.compactSummary }
        let text = first.text.isEmpty || first.text == NativeChatModel.attachmentOnlyText
            ? "仅附件" : first.text.replacingOccurrences(of: "\n", with: " ")
        if queuedTurns.count == 1 { return text }
        return "\(text) 等 \(queuedTurns.count) 条"
    }

    private var queueNeedsAttention: Bool {
        ChatQueueStatus(turns: queuedTurns).needsAttention
    }

    private func contextPressureNotice(_ pressure: ChatContextPressure) -> some View {
        Button {
            if pressure.severity == .critical {
                insertCommand(ChatSlashCommand.Suggestion(
                    command: "/compress", summary: "请求服务端压缩当前上下文",
                    insertion: "/compress "))
                focused = true
                onInsertCompressCommand()
            } else {
                onShowContextUsage()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pressure.severity == .critical
                      ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
                Text(pressure.severity == .critical ? pressure.message : "上下文已使用 \(pressure.percent)%")
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(pressure.severity == .critical ? "压缩" : "查看")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pressure.severity == .critical ? AppTheme.warning : Color.secondary)
        .padding(.horizontal, 16)
        .accessibilityLabel(pressure.message)
        .accessibilityHint(pressure.severity == .critical ? "在输入框插入压缩命令" : "查看上下文用量")
    }

    /// Compact, single-line-first conversation composer. The SAME UIKit
    /// editor remains mounted as it grows, preserving marked Chinese IME text
    /// and selection while the keyboard follows the system safe area.
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsAttachments, let attachments {
                attachments
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
                    .padding(.bottom, 4)
                Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
                    .padding(.horizontal, 12)
            }
            if let quoteReference {
                HStack(alignment: .top, spacing: 9) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppTheme.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("引用 \(quoteReference.author)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Button {
                            quoteExpanded.toggle()
                        } label: {
                            Text(quoteReference.preview)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(quoteExpanded ? nil : 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(quoteExpanded ? "收起引用内容" : "展开引用内容")
                        .accessibilityValue(quoteExpanded ? "已展开" : "已折叠")
                        .accessibilityHint("仅展开预览，不会修改要发送的引用")
                    }
                    Button {
                        self.quoteReference = nil
                        quoteExpanded = false
                        if let draftStore { report(draftStore.save(persistedText)) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            // Keep the glyph compact but make the whole
                            // control safely tappable in the composer.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("移除引用")
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 11)
                .padding(.top, 7)
            }
            if !commandSuggestions.isEmpty {
                slashCommandMenu
            }
            HStack(alignment: .bottom, spacing: 5) {
                ChatDraftEditor(text: $text, focused: $focused, editable: editingEnabled,
                                returnSends: returnSends, canSubmit: sendEnabled,
                                onSubmit: submit,
                                onComposition: { composing = $0 },
                                onMetricsChange: receiveMetrics,
                                onSelectionChange: { offset in
                                    if caretOffset != offset {
                                        DispatchQueue.main.async { caretOffset = offset }
                                    }
                                },
                                commandInsertion: commandInsertion)
                    .opacity(readOnly ? 0.6 : 1)
                    // Never ask a UIViewRepresentable for its unconstrained
                    // intrinsic height: it can inherit a previously expanded
                    // UITextView frame and leave a huge empty editor at rest.
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                    .padding(.vertical, 1)

            }
            .padding(.horizontal, 13)
            .padding(.top, 5)
            .padding(.bottom, 0)

            if !readOnly {
                HStack(alignment: .center,
                       spacing: dynamicTypeSize.isAccessibilitySize ? 5 : 12) {
                    Group {
                        if let attachmentMenu { attachmentMenu }
                        else {
                            Button(action: onAttach) {
                                Image(systemName: "plus")
                                    .font(.body.weight(.medium))
                                    .frame(width: 42, height: 42)
                            }
                            .accessibilityLabel("添加附件")
                        }
                    }
                    .frame(width: 44, height: 44)
                    Spacer(minLength: 0)
                    Button(action: onChooseModel) {
                        HStack(spacing: 4) {
                            Text(modelLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .minimumScaleFactor(0.85)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        // Allow the model title to yield horizontal space to
                        // the fixed 44pt send/stop targets on narrow phones.
                        .frame(maxWidth: 114, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .layoutPriority(-1)
                    .buttonStyle(.plain)
                    .accessibilityLabel("切换模型，当前\(modelLabel)")
                    .accessibilityHint("打开模型选择；长名称在按钮中可能显示省略号")
                    if ChatComposerActionPolicy.showsSend(
                        running: running, sendEnabled: sendEnabled,
                        hasReadyAttachments: hasReadyAttachments) {
                        actionButton(symbol: "arrow.up", enabled: sendEnabled,
                                     label: running ? "发送（\(sendMode.label)）" : "发送消息",
                                     hint: ChatComposerFeedbackPolicy.sendHint(
                                        readOnly: readOnly, loading: loading,
                                        stopping: stopping, composing: composing,
                                        canSend: canSend,
                                        hasContent: !trimmed.isEmpty || hasReadyAttachments),
                                     action: submit)
                    }
                    if ChatComposerActionPolicy.showsStop(running: running) {
                        actionButton(symbol: "stop.fill", enabled: canStop && !stopping,
                                     label: stopping ? "正在停止" : (canStop ? "停止生成" : "等待连接后可停止"),
                                     hint: ChatComposerFeedbackPolicy.stopHint(
                                        stopping: stopping, canStop: canStop),
                                     busy: stopping) {
                            stopTick += 1
                            onStop()
                        }
                    }
                }
                .padding(.leading, 5)
                .padding(.trailing, 7)
                .padding(.bottom, 2)
            }
            if !readOnly && running && (!trimmed.isEmpty || hasReadyAttachments) {
                HStack {
                    sendModePicker
                    Spacer(minLength: 0)
                }
                .padding(.leading, 9)
                .padding(.bottom, 5)
            }
        }
        .background(AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(focused && !readOnly ? AppTheme.accent.opacity(0.26)
                              : AppTheme.hairline.opacity(0.6), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 5)
    }

    private var slashCommandMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("命令")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("仅插入，不会自动执行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            ForEach(commandSuggestions) { suggestion in
                Button {
                    insertCommand(suggestion)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(suggestion.command)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(minWidth: 82, alignment: .leading)
                        Text(suggestion.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .accessibilityLabel("\(suggestion.command)，\(suggestion.summary)")
                .accessibilityHint("插入到输入框，不自动发送")
            }
        }
        .background(AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 0.5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func insertCommand(_ suggestion: ChatSlashCommand.Suggestion) {
        let next = suggestion.insertion
        pendingCommand = next
        commandInsertion = ChatDraftCommandInsertion(
            token: (commandInsertion?.token ?? 0) &+ 1, text: next)
    }

    /// 运行中发送语义切换。默认 steer，与服务端 `default_message_mode` 一致。
    private var sendModePicker: some View {
        Menu {
            ForEach(ChatSendMode.allCases) { mode in
                Button {
                    sendMode = mode
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(mode.label)
                            Text(mode.hint).font(.caption2)
                        }
                    } icon: {
                        Image(systemName: mode == sendMode ? "checkmark" : mode.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sendMode.icon).font(.caption2.weight(.semibold))
                Text(sendMode.label).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("运行中发送方式，当前\(sendMode.label)")
        .accessibilityHint(sendMode.hint)
    }

    private func actionButton(symbol: String, enabled: Bool, label: String,
                              hint: String = "", busy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: symbol)
                        // 发送 ↔ 停止是高频切换，硬切显得突兀。
                        .contentTransition(.symbolEffect(.replace))
                }
            }
                .font(symbol == "stop.fill" ? .footnote.weight(.semibold) : .headline)
                .foregroundStyle(enabled ? AppTheme.onAction : Color.secondary)
                .frame(width: 34, height: 34)
                .background(enabled ? AppTheme.action : AppTheme.softFill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func receiveMetrics(_ metrics: ChatDraftMetrics) {
        guard metrics != draftMetrics else { return }
        // 回调来自 UIKit 布局过程，跳出本轮 SwiftUI 更新再落状态。
        DispatchQueue.main.async {
            if draftMetrics != metrics { draftMetrics = metrics }
        }
    }

    private func submit() {
        guard sendEnabled else { return }
        sendTick += 1
        onSend(persistedText)
    }
}
