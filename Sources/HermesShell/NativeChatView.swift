import SwiftUI
import UIKit
import Combine

/// 会话级对象容器：把「一次创建、整个会话生命周期内不变」的东西收拢到一份，
/// 并只在视图身份首次出现时构造。
///
/// 为什么改：原来 init 里先 `let model = NativeChatModel(...)`，再塞进
/// `StateObject(wrappedValue:)`。`StateObject` 的入参虽然是 autoclosure，
/// 但对象在进入闭包之前就已经被构造出来了——RootView 每发布一次（AppState 是
/// EnvironmentObject，发布很频繁），就会完整重建一次模型：ChatDraftStore 的 JSON
/// 编码、Combine 订阅、时间线投影、比例快照的锁+字典构建全都白做然后丢弃。
/// 现在整个构造表达式留在 autoclosure 里，只在首次渲染时求值一次。
///
/// 时间线投影的 `objectWillChange` 在这里转发出去：视图只持有一个 StateObject，
/// 仍会在模型或时间线任一变化时失效，行为与原实现一致。
@MainActor
final class ChatSessionObjects: ObservableObject {
    let model: NativeChatModel
    let runtimeKey: ConversationRuntimeRegistry.Key
    let presentation: UUID
    let registry: ConversationRuntimeRegistry
    let timeline: ChatTimelineProjection
    /// 与模型同一作用域键的草稿存储：输入框用它做防抖落盘。
    let draftStore: ChatDraftStore
    /// 进入会话时取一次的比例快照，整个会话（含宿主重建）都用这一份。
    let imageRatios: ImageRatioSnapshot
    /// 进入会话时读一次的「上次读到」位置。
    let initialReadingPosition: ChatReadingPosition?
    /// 进入会话时的本地草稿。放在这里而不是每次 body 去读 `model.draft`：
    /// 那样会让整个页面重新依赖草稿字段，等于把「按键不失效」的好处还回去一半。
    let initialDraft: String
    /// 模型侧草稿改写通知（发送成功清空、失败回填、排队清空）。
    ///
    /// 为什么单独做一条流：`model.$draft` 若直接参与视图求值，每敲一个字都会让
    /// 整个会话页失效，回到「全量重建快照 + 2000 行比较」的老问题。
    /// 这条流只在 `draft` 被模型**主动改写**时给出新值，由视图写进
    /// `ChatComposerDraftSync`，驱动输入框子树而不是整页。
    let draftChanges: AnyPublisher<String, Never>
    private var subscriptions: Set<AnyCancellable> = []

    init(sessionID: String, api: HermesBackend, instanceID: String, accountScope: String,
         readingStore: ChatReadingPositionStore, historyStore: ChatHistoryStore,
         registry: ConversationRuntimeRegistry) {
        self.registry = registry
        let lease = UUID()
        self.presentation = lease
        let key = ConversationRuntimeRegistry.Key(instanceID: instanceID,
            accountScope: accountScope, sessionID: sessionID)
        self.runtimeKey = key
        let scope = instanceID + "|" + accountScope
        // A06：草稿键编码 [instanceID, accountScope, sessionID]，账号间不串；
        // legacyBaseURL 用于保存时清理无账号维度的 v1 旧键。
        let fileStore = LocalDataFileStore(instanceID: instanceID, accountScope: accountScope,
                                           sessionID: sessionID)
        let store = ChatDraftStore(instanceID: instanceID, accountScope: accountScope,
            sessionID: sessionID, legacyBaseURL: api.webConsoleBaseURL.absoluteString,
            fileStore: fileStore)
        let model = registry.claim(key, presentation: lease) {
            NativeChatModel(sessionID: sessionID, api: api, draftStore: store,
                            historyStore: historyStore, displayScope: scope)
        }
        self.model = model
        self.draftStore = store
        self.timeline = ChatTimelineProjection(model: model)
        self.imageRatios = ImageRatioStore.shared.snapshot(scope: scope, sessionID: sessionID)
        self.initialReadingPosition = readingStore.load()
        self.initialDraft = store.load()
        // 去掉首值：初值已经通过 initialDraft 播种，重复推送会白跑一次同步。
        self.draftChanges = model.$draft.dropFirst().eraseToAnyPublisher()
        model.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        timeline.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}

/// SwiftUI owns conversation state; UIKit owns transcript geometry and scrolling.
struct NativeChatView: View {
    let sessionID: String
    let title: String
    let onOpenSidebar: () -> Void
    let readingStore: ChatReadingPositionStore
    /// 进入会话时取一次的比例快照，整个会话（含宿主重建）都用这一份。
    var imageRatios: ImageRatioSnapshot { objects.imageRatios }
    var initialReadingPosition: ChatReadingPosition? { objects.initialReadingPosition }
    @State var restoringReading = false
    @State var restoreCancelled = false
    @State private var foregroundResumeTask: Task<Void, Never>?
    @State private var foregroundResumeTicket = UUID()
    @State var showFind = false
    @State var findQuery = ""
    @State var findHits: [ChatConversationSearch.Hit] = []
    @State var findHasMoreMatches = false
    @State var findQueryTooLong = false
    @State var findOrigin: ChatReadingPosition?
    @State var findIndex = 0
    @State var finding = false
    @State var findTask: Task<Void, Never>?
    @State var findWork = FindWorkState()
    @State var findWorker = ChatFindWorker()
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// 模型 + 时间线投影的单一持有者（见 ChatSessionObjects）。
    @StateObject var objects: ChatSessionObjects
    /// 与模型同一作用域键的草稿存储：输入框用它做防抖落盘。
    var draftStore: ChatDraftStore { objects.draftStore }
    /// 外部改写输入框的指令（发送成功清空、分支预填、模型回填）。
    @State var draftSync = ChatComposerDraftSync()
    /// 补充信息卡片的输入态：「其他」把选项按钮翻成输入框时置起，换提问时复位。
    @State var clarifyTextModes: Set<String> = []
    @State var clarifyDrafts: [String: String] = [:]
    @State var clarifySelections: [String: Set<Int>] = [:]
    @State var expandedRequestID: String?
    /// Quote insertion is separate from model-owned draft rewrites so it cannot
    /// overwrite text the user typed while the action sheet was open.
    @State var composerInsertion = ChatComposerInsertion()
    /// 最近一次交给模型的文本。用于区分「模型按自己的规则改写了草稿」与
    /// 「用户正在输入」：只有前者才需要把内容推回输入框。
    @State var syncedDraft = ""
    @StateObject var attachments: AttachmentComposerModel
    /// Explicit send tap owns the entire lazy-upload preflight. Navigation and
    /// background transitions cancel it before any chat submission.
    @State var preparingAttachmentSend = false
    @State var attachmentSendTicket = UUID()
    @State var attachmentSendTask: Task<Void, Never>?
    @State var scroll = ChatScrollState()
    @State var cellStates: [String: ChatCellState] = [:]
    @State var scrollCommand = ChatScrollCommand()
    @State var pendingUserTurnFocus = false
    @State var userIDBeforeSend: String?
    @State var focusedUserTurnID: String?
    @State var focusedUserTurnText: String?
    @State var isLoadingOlder = false
    @State var paginationOwnership = ChatPaginationOwnership()
    @State var paginationTask: Task<Void, Never>?
    @State var toast: String?
    @State var toastTask: Task<Void, Never>?
    /// 顶部错误/只读钉住条：本次会话里点过关闭就不再出现。
    @State var noticeBarDismissed = false
    @State var noticeChecking = false
    @State var visible = false
    @State var showAttachInfo = false
    @State var attachmentPickerTrigger = 0
    @State var attachmentTarget: String?
    @State var attachmentHighlight: String?
    @State var attachmentHighlightTask: Task<Void, Never>?
    @State var activePanel: ChatPanel?
    @State var pendingPanel: ChatPanel?
    @State var panelDismissing = false
    @State var afterPanelAction: ChatPanelAction?
    @State private var readerPositionStore: ChatReaderPositionStore
    /// 会话内管理：改名弹窗与草稿。标题以 `app.sessions` 为准，改名后立即回显。
    @State var showRename = false
    @State var renameDraft = ""
    /// 导出 Markdown：写到临时文件后交给系统分享，分享结束即删除。
    /// 导出子状态机。原先这里是 5 个独立 `@State`，现已收进一个对象。
    @StateObject var export = ChatExportController()
    // UIKit owns first-responder state. FocusState without a SwiftUI focused
    // field resets on document publications and dismisses the native keyboard.
    @State var composerFocused = false
    /// 首屏「上次读到」提示；位置同时留一份，供点击时直接定位。
    @State var resumeHint: ReadingResumeSummary?
    @State var resumePosition: ChatReadingPosition?
    /// 弱持有滚动控制器，只为分页耗时埋点，不参与视图生命周期。
    @State var controllerBox = WeakScrollController()
    /// 实例 + 账号作用域：纯图占位标记与图片比例缓存都按它隔离。
    let displayScope: String
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) var scenePhase
    /// 系统栈返回：与左缘右滑的交互式返回走同一条 pop 路径。
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.colorScheme) var colorScheme

    init(sessionID: String, title: String, api: HermesBackend, instanceID: String, accountScope: String,
         readingStore: ChatReadingPositionStore, historyStore: ChatHistoryStore,
         registry: ConversationRuntimeRegistry,
         onOpenSidebar: @escaping () -> Void = {}) {
        self.sessionID = sessionID
        self.title = title
        self.onOpenSidebar = onOpenSidebar
        self.displayScope = instanceID + "|" + accountScope
        self.readingStore = readingStore
        _readerPositionStore = State(initialValue: ChatReaderPositionStore(
            instanceID: instanceID, accountScope: accountScope, sessionID: sessionID))
        let attachmentDraftStore = ChatDraftStore(
            instanceID: instanceID, accountScope: accountScope, sessionID: sessionID,
            legacyBaseURL: api.webConsoleBaseURL.absoluteString,
            fileStore: LocalDataFileStore(instanceID: instanceID, accountScope: accountScope,
                                          sessionID: sessionID))
        _attachments = StateObject(wrappedValue: AttachmentComposerModel(
            api: api, sessionID: sessionID, draftStore: attachmentDraftStore))
        // 关键：只把「如何构造」放进 autoclosure，不在这里真的构造。
        // StateObject 只在视图身份首次出现时求值一次，宿主重建不再白造模型；
        // 草稿键编码、比例快照（ImageRatioStore 的锁 + 字典构建）与阅读位置
        // 读取也一并挪进去，避免每次宿主重建都白做一遍。
        _objects = StateObject(wrappedValue: ChatSessionObjects(
            sessionID: sessionID, api: api, instanceID: instanceID, accountScope: accountScope,
            readingStore: readingStore, historyStore: historyStore, registry: registry))
    }

    var model: NativeChatModel { objects.model }
    var timeline: ChatTimelineProjection { objects.timeline }

    var items: [ChatRowItem] {
        timeline.items
    }

    /// 输入栏显示真实模型标签；目录未读到或会话无模型时退回“默认模型”。
    var modelLabel: String {
        let current = model.sessionModel ?? app.currentSession?.model
        if let option = app.modelCatalog?.option(matching: current,
                                                  provider: model.sessionProvider) {
            return option.label
        }
        return current?.isEmpty == false ? current! : "默认模型"
    }

    var statusSnapshot: ChatStatusSnapshot {
        let presentation = model.presentationState
        return ChatStatusSnapshot(reasoning: model.reasoning, running: presentation.showsProgress,
            notice: presentation.notice, activityTitle: presentation.title, activityInChrome: true)
    }

    /// Persist facts this page has actually observed. The caller supplies a
    /// fresh set so the computation never becomes part of SwiftUI's body type.
    private func recordTaskSignals() {
        guard objects.registry.owns(objects.runtimeKey, presentation: objects.presentation) else { return }
        app.recordRuntimeSignals(model, key: objects.runtimeKey)
    }

    // Split the very long ViewBuilder chain into type-checkable segments.
    // The modifier order and view identity remain unchanged.
    private var layoutContent: some View {
        VStack(spacing: 0) {
            header
            findBar
            readingPositionBar
            // 错误/本地历史钉在正文上方：上滚读历史时也不会丢失状态。
            if showsNoticeBar { noticeBar }
            thread
            pendingRequestsSection
            taskSummaryBar
            composerSection
        }
        .background(AppTheme.canvas)
        .overlay(alignment: .top) { toastView }
        .sheet(item: panelBinding, onDismiss: panelDidDismiss) { panel in
            panelContent(panel)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(AppTheme.radiusSheet)
        }
        .alert("附件", isPresented: $showAttachInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("相册选图和文件上传通过输入栏左侧的「＋」按钮；聊天里的附件点开可预览、保存或分享。")
        }
        .alert("重命名会话", isPresented: $showRename) {
            TextField("会话标题", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let value = renameDraft
                Task {
                    await app.rename(sessionID: sessionID, title: value)
                    if let failure = app.sessionActionError { showToast("改名失败：\(failure)") }
                }
            }
        } message: {
            Text("只改显示标题，不影响会话内容。")
        }
        .overlay(alignment: .top) { exportOverlay }
        .onChange(of: export.sharingFile?.id) { _, _ in
            if let file = export.sharingFile { showPanel(.share(file)) }
        }
    }

    private var lifecycleContent: some View {
        layoutContent
        .task { [app] in
            guard objects.registry.reattach(objects.runtimeKey, presentation: objects.presentation,
                                            model: model) else { return }
            app.bindRuntime(model, key: objects.runtimeKey)
            guard displayScope == app.historyInstanceID + "|" + app.historyAccountScope,
                  app.currentSessionID == sessionID else { return }
            visible = true
            // 输入框的初值是模型读到的本地草稿，这里同步一次基线，
            // 之后才用「与上次交给模型的值是否相同」判断模型侧改写。
            syncedDraft = objects.initialDraft
            let instance = app.active.id
            let account = app.historyAccountScope
            let changeToken = app.activeChangeToken
            model.onAuthenticationRequired = { [weak app] in
                guard let app, app.active.id == instance, app.historyAccountScope == account,
                      app.activeChangeToken == changeToken else { return }
                app.needsLogin = true
            }
            // 审批到达：交给 AppState 决定要不要提醒（开关、前台抑制、
            // 会话标题都在那里）。作用域校验与上面一致，防止旧页面的
            // 回调在切换账号后仍然生效。
            model.onApprovalArrived = { [weak app] sessionID, requestID in
                guard let app, app.active.id == instance, app.historyAccountScope == account,
                      app.activeChangeToken == changeToken else { return }
                app.approvalArrived(sessionID: sessionID, requestID: requestID)
            }
            model.onApprovalResolved = { [weak app] sessionID, requestID in
                guard let app, app.active.id == instance, app.historyAccountScope == account,
                      app.activeChangeToken == changeToken else { return }
                app.approvalResolved(sessionID: sessionID, requestID: requestID)
            }
            // clarify 走同一套作用域校验与投递链路。
            model.onClarifyArrived = { [weak app] sessionID, requestID in
                guard let app, app.active.id == instance, app.historyAccountScope == account,
                      app.activeChangeToken == changeToken else { return }
                app.clarifyArrived(sessionID: sessionID, requestID: requestID)
            }
            model.onClarifyResolved = { [weak app] sessionID, requestID in
                guard let app, app.active.id == instance, app.historyAccountScope == account,
                      app.activeChangeToken == changeToken else { return }
                app.clarifyResolved(sessionID: sessionID, requestID: requestID)
            }
            // Paint the bounded confirmed local window before the network
            // wait. Never infer an unloaded reading anchor or page offline.
            let warmupSample = ChatPerformanceRecorder.shared.begin()
            await model.warmupCachedHistory()
            ChatPerformanceRecorder.shared.finish(.historyWarmup, warmupSample)
            guard !Task.isCancelled, visible, app.active.id == instance,
                  app.historyAccountScope == account, app.activeChangeToken == changeToken,
                  app.currentSessionID == sessionID else { return }
            restoreCollapsedCells()
            if model.cachedHistoryDate != nil {
                prepareResumeHint()
                if let position = initialReadingPosition, !position.following,
                   items.contains(where: { $0.id == position.rowID }) {
                    await restoreReadingPosition(position)
                }
            }
            guard !Task.isCancelled, visible, app.active.id == instance,
                  app.historyAccountScope == account, app.activeChangeToken == changeToken,
                  app.currentSessionID == sessionID else { return }
            if model.suspended { await model.resumeForeground() }
            else { await model.load(silent: !model.transcript.messages.isEmpty, preserveLoadedOlder: true) }
            // The initial disk restore may already contain an unresolved
            // accepted POST; onChange cannot see that pre-existing value.
            model.scheduleAutomaticReconciliation()
            guard !Task.isCancelled, visible, app.active.id == instance,
                  app.historyAccountScope == account, app.activeChangeToken == changeToken,
                  app.currentSessionID == sessionID else { return }
            if app.consumeHomeAttachmentRequest(for: sessionID) {
                // An explicit Plus tap opens the real native Files/Photos
                // source chooser in the destination Session; it NEVER posts.
                attachmentPickerTrigger &+= 1
            }
            if let firstText = app.consumeHomeTurn(for: sessionID) {
                // Claim BEFORE send. A failed/unknown POST cannot be replayed.
                if model.canSend && !model.uncertain && model.draft == firstText {
                    syncedDraft = firstText
                    userIDBeforeSend = model.transcript.messages.last(where: { $0.role == "user" })?.id
                    pendingUserTurnFocus = true
                    let submitted = await model.send()
                    if !submitted { pendingUserTurnFocus = false }
                } else {
                    pendingUserTurnFocus = false
                    model.notice = "新会话已创建，但首条消息尚未提交。草稿已保存，请核对状态后手动发送。"
                }
            }
            guard !Task.isCancelled, visible, app.active.id == instance,
                  app.historyAccountScope == account, app.activeChangeToken == changeToken,
                  app.currentSessionID == sessionID else { return }
            restoreCollapsedCells()
            prepareResumeHint()
            await restoreReadingPosition()
            guard !Task.isCancelled, visible, app.active.id == instance,
                  app.historyAccountScope == account, app.activeChangeToken == changeToken,
                  app.currentSessionID == sessionID else { return }
            // 锚点行已载入说明自动恢复已到位，提示条就没必要再占一行。
            // 读已算好的 `items`，不再全量重建时间线（同一份数据）。
            if let position = resumePosition,
               items.contains(where: { $0.id == position.rowID }) {
                resumeHint = nil
            }
            if let plan = app.consumeFork(for: sessionID) {
                // 分支预填是「用户明确要求替换输入框」，因此这里无条件推送，
                // 同时先把基线对齐，避免 onChange 再推一次。
                let token = draftSync.token &+ 1
                model.draft = plan.text
                syncedDraft = plan.text
                draftSync = ChatComposerDraftSync(token: token, text: plan.text)
                if plan.sendImmediately && model.canSend {
                    // A03：历史附件是服务端已上传引用，分支重发原样带回，不重新上传。
                    await model.send(attachments: plan.attachmentPaths.map { ChatAttachmentPayload(historyPath: $0) })
                }
                else if plan.sendImmediately { model.notice = "分支已建立；状态尚未确认，请核对后点击发送。" }
                else { composerFocused = true }
            }
        }
        .onDisappear {
            attachmentSendTask?.cancel(); attachmentSendTask = nil
            attachments.cancelUploads()
            preparingAttachmentSend = false
            retirePagination()
            pendingUserTurnFocus = false
            focusedUserTurnID = nil
            focusedUserTurnText = nil
            controllerBox.value?.turnReading.reset()
            recordTaskSignals()
            // Presentation detachment is not transport suspension. A live
            // runtime retains its SSE cursor and exact POST owner.
            objects.registry.detach(objects.runtimeKey, presentation: objects.presentation)
            visible = false
            // Let the child composer finish its final synchronous draft save
            // before the registry may evict an offscreen settled runtime.
            Task { @MainActor [weak app] in
                app?.wakeUnopenedSessionRecovery()
            }
            pendingPanel = nil; afterPanelAction = nil; activePanel = nil
            attachmentHighlightTask?.cancel()
            attachmentHighlight = nil
            cancelExport()
            toastTask?.cancel()
            scheduleFind(.cancelled, jump: false)
            foregroundResumeTask?.cancel(); foregroundResumeTask = nil
        }
        // AppState observes runtime state even after the presentation detaches.
    }

    private var observationContent: some View {
        lifecycleContent
        .onChange(of: model.error) { _, _ in noticeBarDismissed = false }
        // 模型侧改写草稿时把内容推回输入框。判定条件沿用模型原来的写法，
        // 避免把用户发送期间新敲的字吞掉：
        //   清空 → 仅当输入框仍是刚发出的那段（`if draft == composerText`）
        //   回填 → 仅当输入框已经空了（`if draft.isEmpty`）
        // 用 onReceive 而不是 onChange(of: model.draft)：后者让 body 依赖草稿字段，
        // 等于把「按键不失效」还回去；这里只消费模型主动改写的推送。
        .onReceive(objects.draftChanges) { value in
            guard objects.registry.owns(objects.runtimeKey, presentation: objects.presentation),
                  value != syncedDraft else { return }
            let previous = syncedDraft
            syncedDraft = value
            draftSync = ChatComposerDraftSync(
                token: draftSync.token &+ 1, text: value,
                onlyIfCurrent: value.isEmpty ? previous : nil,
                onlyIfEmpty: !value.isEmpty)
        }
        .onChange(of: model.uncertain) { _, value in
            if value {
                noticeBarDismissed = false
                model.scheduleAutomaticReconciliation()
            }
        }
        .onChange(of: model.running) { _, running in
            if !running { model.scheduleAutomaticReconciliation() }
        }
        .onChange(of: model.localPersistenceIssue) { _, value in if value != nil { noticeBarDismissed = false } }
        .onChange(of: model.queuePersistenceFailed) { _, value in if value { noticeBarDismissed = false } }
        .onChange(of: attachments.errorMessage) { _, value in
            if let value { showToast(value) }
        }
        .onChange(of: findQuery) { _, _ in scheduleFind(.queryChanged, jump: false) }
        .onChange(of: items) { _, _ in if showFind { scheduleFind(.contentChanged, jump: false) } }
        .onChange(of: model.settledAttachmentPaths) { _, paths in
            guard objects.registry.owns(objects.runtimeKey, presentation: objects.presentation) else { return }
            let settled = Set(paths)
            let ids = attachments.batch.items.compactMap { item -> UUID? in
                if case .ready(let uploaded) = item.state, settled.contains(uploaded.path) { return item.id }
                return nil
            }
            for id in ids { attachments.remove(id) }
        }
        // 折叠状态跨会话/进程保留：只存「已折叠」的 id 集合。
        .onChange(of: cellStates) { _, states in
            cellStateStore.saveCollapsed(Set(states.filter { $0.value.collapsed }.map { $0.key }))
        }
        // 异步回答完成时给一次播报，避免 VoiceOver 用户错过。
        .onChange(of: model.completedReplies) { _, _ in
            // Do not let a failed/delayed submission focus an unrelated later
            // user row after this reply cycle has already completed.
            pendingUserTurnFocus = false
            if visible && scenePhase == .active && UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: "回复已完成")
            }
        }
    }

    var body: some View {
        observationContent
        .onChange(of: app.activeChangeToken) { _, _ in
            retirePagination()
            scheduleFind(.cancelled, jump: false)
            showFind = false
            findOrigin = nil
            findHits = []
            findHasMoreMatches = false
            findQueryTooLong = false
            controllerBox.value?.turnReading.reset()
            pendingUserTurnFocus = false
            focusedUserTurnID = nil
            focusedUserTurnText = nil
            attachmentSendTask?.cancel(); attachmentSendTask = nil
            attachments.cancelUploads()
            preparingAttachmentSend = false
            // The old account's attachment state is no longer writable.
            cancelExport()
            foregroundResumeTask?.cancel(); foregroundResumeTask = nil
            // 认证图片缓存按「实例 + 账号」隔离；切换账号必须整片清掉，
            // 否则上一个账号能读到的附件图会残留在内存里。
            RemoteImageLoader.shared.purgeAuthenticated()
            // AppState retires the old registry synchronously on scope change.
        }
        .onChange(of: app.sessionActionError) { _, error in
            if let error { showToast(error) }
        }
        // Only real newly appended user messages establish top reading focus.
        .onChange(of: model.transcript.messages.last(where: { $0.role == "user" })?.id) { oldID, newID in
            guard let newID, let last = model.transcript.messages.last(where: { $0.role == "user" })
                else { return }
            let newTurn = pendingUserTurnFocus && newID != userIDBeforeSend
            // Native optimistic entries are replaced with server history IDs
            // after POST confirmation. Preserve that turn's visual focus only
            // when the replacement text agrees with the original submission.
            let confirmedReplacement = focusedUserTurnID == oldID
                && focusedUserTurnText == last.content && newID != oldID
            guard newTurn || confirmedReplacement else { return }
            pendingUserTurnFocus = false
            focusedUserTurnID = newID
            focusedUserTurnText = last.content
            scrollCommand = ChatScrollCommand(sequence: scrollCommand.sequence &+ 1,
                animated: false, targetID: "m-\(newID)", offsetInRow: 0,
                findOrdinal: nil, focusTurn: true)
        }
        // Streaming updates never issue scroll requests. UIKit keeps the reading
        // anchor or bottom edge when it commits the changed row geometry.
        .onChange(of: model.transcript.messages.last?.content) { _, _ in
            guard model.running else { return }
            var next = scroll
            if next.receivedAssistantUpdate() { scroll = next }
        }
        // 服务端确认换模型后，同步输入栏标签；不靠重新进会话才刷新。
        .onChange(of: app.currentSession?.model) { _, newValue in
            guard displayScope == app.historyInstanceID + "|" + app.historyAccountScope,
                  app.currentSessionID == sessionID else { return }
            if let newValue, !newValue.isEmpty { model.sessionModel = newValue }
        }
        .onReceive(NotificationCenter.default.publisher(for: RecoveryNetworkWakeup.restored)) { _ in
            guard visible, scenePhase == .active else { return }
            model.scheduleAutomaticReconciliation(immediate: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && visible {
                guard foregroundResumeTask == nil else { return }
                restoreCancelled = false
                let ticket = UUID()
                foregroundResumeTicket = ticket
                foregroundResumeTask = Task {
                    defer { if foregroundResumeTicket == ticket { foregroundResumeTask = nil } }
                    await model.resumeForeground()
                    model.scheduleAutomaticReconciliation(immediate: true)
                    guard !Task.isCancelled, foregroundResumeTicket == ticket, scenePhase == .active, visible,
                          !model.syncing, !model.loading else { return }
                    let position = readingStore.load()
                    guard ReadingRestorePolicy.shouldRestoreAnchor(active: scenePhase == .active,
                        visible: visible, following: scroll.following, cancelled: restoreCancelled) else { return }
                    await restoreReadingPosition(position)
                }
            } else if phase == .background {
                // Background URLSession without a verified resumable gateway
                // contract is unsafe: keep original bytes and require a new
                // explicit send after foreground return.
                attachmentSendTask?.cancel(); attachmentSendTask = nil
                attachments.cancelUploads()
                preparingAttachmentSend = false
                cancelExport()
                foregroundResumeTask?.cancel(); foregroundResumeTask = nil
                restoreCancelled = true
                // AppState owns network suspension for all runtimes.
            }
        }
    }

    func messageReaderSheet(_ message: ChatMessage) -> some View {
        ChatMessageReader(
            message: message,
            replyText: ChatTimeline.replyText(
                endingAt: message.id, messages: model.transcript.messages),
            initialPosition: readerPositionStore.position(
                messageID: message.id,
                content: ChatTimeline.replyText(
                    endingAt: message.id, messages: model.transcript.messages)),
            onPositionChange: { _ in },
            onPositionPersist: { snapshot in
                readerPositionStore.save(
                    offset: snapshot.offset,
                    maximumOffset: snapshot.maximumOffset,
                    viewportWidth: snapshot.viewportWidth,
                    messageID: message.id,
                    content: ChatTimeline.replyText(
                        endingAt: message.id, messages: model.transcript.messages))
            },
            makeShareFile: { makeReplyShareFile(endingAt: message.id) }
        )
    }
}

/// 只用于埋点的弱引用容器：不延长滚动控制器的生命周期。
final class WeakScrollController {
    weak var value: ChatScrollController?
}
