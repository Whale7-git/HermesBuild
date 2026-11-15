import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// 一次归档产生的撤销目标；批量归档时整批共用一个提示条，一次撤销全部恢复。
struct ArchiveUndoTarget: Identifiable, Equatable {
    let sessionID: String
    let title: String
    var id: String { sessionID }
}

/// 批量会话操作的结果；调用方据此决定是否提示部分失败。
struct BatchActionResult: Equatable {
    let succeeded: Int
    let failed: Int
    var isFullSuccess: Bool { failed == 0 }
}

/// 一次首页刷新从发出第一条请求到发布结果的总时限。
///
/// 单页请求各自设有超时仍不足以保证整轮刷新有界：网关可能连续翻很多页，
/// 每页都在自己的时限边缘返回。调用方需要一个覆盖整轮操作的上限，超时后
/// 取消仍在途的请求并继续显示上一次成功结果。
struct SessionRefreshPolicy: Equatable {
    let totalTimeout: TimeInterval

    static let standard = SessionRefreshPolicy(totalTimeout: 45)
}

struct SessionRefreshTimeout: Error {}

/// 认证探测与会话列表读取的唯一入口。
///
/// 独立成纯协调器，便于用替身锁住三件事：WebUI 先探测认证；网关不重复请求；
/// 不论认证端点还是分页列表，整轮刷新都受同一个总时限约束。
@MainActor
enum SessionRefreshLoader {
    static func load(api: HermesBackend, policy: SessionRefreshPolicy) async throws -> [SessionSummary] {
        let mode = api.capabilities.authProbeMode
        let timeoutNanoseconds = UInt64(max(0.001, policy.totalTimeout) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: [SessionSummary].self) { group in
            group.addTask { @MainActor in
                if mode == .dedicatedEndpoint {
                    let status = try await api.authStatus()
                    if status.loggedIn == false {
                        throw APIError.http(401, "登录已失效，请重新登录")
                    }
                }
                return try await api.sessions()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw SessionRefreshTimeout()
            }
            defer { group.cancelAll() }
            guard let rows = try await group.next() else { throw URLError(.badServerResponse) }
            return rows
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var instances: [HermesInstance]
    @Published var activeIndex: Int
    @Published var sessions: [SessionSummary] = [] {
        didSet { taskDerivedDirty = true }
    }
    @Published var loadingSessions = false
    /// Empty is authoritative only after a successful fetch for this scope.
    @Published private(set) var hasLoadedSessions = false
    /// Bounded, in-process session-list snapshots. Never shared across account scopes.
    private var sessionListCache: [String: [SessionSummary]] = [:]
    private var sessionListCacheOrder: [String] = []
    private let sessionListCacheLimit = 8

    private var sessionListScopeKey: String {
        historyInstanceID + "|" + historyAccountScope
    }

    private func rememberSessionList(_ rows: [SessionSummary], scope: String) {
        sessionListCache[scope] = rows
        sessionListCacheOrder.removeAll { $0 == scope }
        sessionListCacheOrder.append(scope)
        while sessionListCacheOrder.count > sessionListCacheLimit {
            let removed = sessionListCacheOrder.removeFirst()
            sessionListCache.removeValue(forKey: removed)
        }
    }

    private func forgetSessionList(scope: String) {
        sessionListCache.removeValue(forKey: scope)
        sessionListCacheOrder.removeAll { $0 == scope }
    }
    @Published var errorText: String?
    /// Sticky failure feedback: account-local files may still remain on disk.
    @Published private(set) var localCleanupWarning: String?
    /// Task observations remain correct in memory when this is set; only their
    /// cross-launch persistence is degraded.
    @Published private(set) var sessionTaskPersistenceWarning: String?

    private func recordCleanupResult(_ result: LocalStoreWriteResult) {
        guard !result.succeeded else { return }
        localCleanupWarning = "部分本地草稿或发送记录清理失败，数据可能仍留在设备上。"
        RuntimeLogRecorder.shared.recordApp(.error, "local-cleanup",
            "protected file cleanup failed")
    }

    private func recordHistoryCleanupResult(_ report: ChatHistoryStore.CleanupReport) {
        guard !report.succeeded else { return }
        localCleanupWarning = "本地历史缓存清理未完成（\(report.failed) 项失败或无法确认），部分文件可能仍在设备上。"
        RuntimeLogRecorder.shared.recordApp(.error, "history-cleanup",
            "history cache cleanup incomplete failures=\(report.failed)")
    }

    /// Persist the complete observation table and expose a distinct recovery
    /// warning if the verified read-back fails. In-memory state is never rolled
    /// back: losing the UI truth because disk is temporarily unavailable would
    /// hide approvals or verification locks that still exist.
    @discardableResult
    private func persistSessionTaskObservations(
        _ values: [String: SessionTaskObservation],
        instanceID: String,
        accountScope: String
    ) -> Bool {
        let saved = SessionTaskStore.save(
            values, instanceID: instanceID, accountScope: accountScope)
        if saved {
            sessionTaskPersistenceWarning = nil
            return true
        }
        sessionTaskPersistenceWarning =
            "任务状态暂时无法保存到设备；本次使用不受影响，重启后可能需要重新核对。"
        RuntimeLogRecorder.shared.recordApp(.error, "task-store",
            "task observation persistence failed")
        return false
    }

    /// Last successful list refresh in the current instance/account scope.
    @Published private(set) var lastSessionRefresh: Date?
    @Published private(set) var credentialWarning: String?
    /// 待登录标志。**只影响 UI 提示，绝不在置位时销毁本地数据**——
    /// 否则明文 HTTP 下 MITM 注入一个 401 就能远程清空全部未发草稿。
    /// 真正的账号退役只发生在：用户主动退出/切换账号、或新凭证校验成功后
    /// （见 `signIn` / `updateGatewayAPIKey`）。
    @Published var needsLogin = false
    @Published var creating = false
    /// 当前打开的会话 ID；nil 表示停在会话列表。
    @Published var currentSessionID: String?
    /// App is in the foreground and the chat page (not a drawer, browser or
    /// settings/login sheet) is actually on screen for `currentSessionID`.
    /// RootView keeps these facts synchronized with scene and overlay state.
    @Published private(set) var appIsActive = false
    @Published private(set) var conversationIsVisible = false
    @Published var showSettings = false
    /// 模型目录；nil 表示尚未读取成功，不伪造空列表。
    @Published var modelCatalog: ModelCatalog?
    @Published var catalogLoading = false
    /// 会话操作（改名/置顶/归档/删除/分支）的共享忙碌与错误。
    @Published var sessionActionBusy = false
    @Published var sessionActionError: String?
    /// 最近一次归档成功的会话（批量归档时为整批），供侧栏「撤销」使用；
    /// 其它会话操作或切实例会清空。
    @Published private(set) var lastArchiveUndo: [ArchiveUndoTarget] = []
    /// 本地完成标记：上一轮流式中、这一轮已停止且未被打开的会话。
    @Published private(set) var completedSessionIDs: Set<String> = []
    /// Locally observed task facts for the active instance/account scope.
    /// Server `is_streaming` is merged separately, so this dictionary only
    /// contains facts this device could actually observe inside a session.
    @Published private(set) var sessionTaskObservations: [String: SessionTaskObservation] = [:] {
        didSet { taskDerivedDirty = true }
    }
    private var taskDerivedDirty = true
    private var taskDerivedState = SessionTaskDerivedState()
    /// 通知投递。默认走系统实现，测试可注入替身。
    let notifier: any TaskNotificationDelivering
    /// Exact IDs delivered for unresolved requests, grouped by the immutable
    /// request identity. Resolution can arrive after an account switch, so the
    /// original scoped ID must survive rather than be recomputed from current state.
    private var pendingRequestNotificationIDs: [String: Set<String>] = [:]
    /// Blocking request identities observed by this chat page. The model owns
    /// the cards; this set keeps the task-center signal until the last sibling
    /// request of that kind is resolved.
    private var requestTaskSignals: Set<String> = []
    /// 用户对「需要处理」任务的本地确认。只影响展示，不改动持久化信号。
    @Published private(set) var taskAcknowledgements: [TaskAcknowledgement] = []
    private var taskAckDirty = true
    private var taskAckLoaded = false
    /// 仅一次领取：先落草稿，重生成才自动发送，切实例即作废。
    var pendingFork: (sessionID: String, plan: MessageForkPlan)?
    /// New-session first-turn intent lives in memory only. On process restart
    /// the persisted per-session draft is available, but the POST is never replayed.
    private var homeTurnClaim = HomeTurnClaim()
    @Published private(set) var homeSendError: String?

    func forkMessage(_ plan: MessageForkPlan, from sessionID: String) async {
        guard !sessionActionBusy else { return }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            // 分页后的 raw index 包含 tool rows。重新读边界，拒绝过时的截点。
            let boundary = try await requestAPI.history(sessionID: sessionID, before: plan.keepCount + 1)
            guard isCurrent(scope) else { return }
            guard boundary.messages.contains(where: { $0.id == plan.sourceMessageID && $0.content == plan.text && $0.sourceIndex == plan.keepCount && $0.attachmentPaths == plan.attachmentPaths }) else {
                throw ChatCoreError.server("原会话内容已变化，请刷新后重新操作。")
            }
            guard isCurrent(scope), currentSessionID == sessionID else { return }
            let newID = try await requestAPI.forkSession(sessionID: sessionID, keepCount: plan.keepCount)
            guard isCurrent(scope), currentSessionID == sessionID else { return }
            pendingFork = (newID, plan)
            currentSessionID = newID
        } catch {
            guard isCurrent(scope), currentSessionID == sessionID else { return }
            sessionActionError = error.localizedDescription
        }
    }

    func consumeFork(for sessionID: String) -> MessageForkPlan? {
        guard let pendingFork, pendingFork.sessionID == sessionID else { return nil }
        self.pendingFork = nil
        return pendingFork.plan
    }
    /// 切实例/退账号/清缓存都会改变这三个维度；异步回调必须对齐全部三者
    /// 才允许写回状态，只比较 sessionID 会把旧实例的结果写进新实例。
    private struct ActionScope: Equatable {
        let instanceID: UUID
        let accountScope: String
        let token: Int
    }

    private var actionScope: ActionScope {
        ActionScope(instanceID: active.id, accountScope: historyAccountScope, token: activeChangeToken)
    }

    private func isCurrent(_ scope: ActionScope) -> Bool {
        scope == actionScope
    }

    /// 切实例时递增，供聊天页据此断开旧实例的连接。
    @Published var activeChangeToken = 0
    private var refreshGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    private let sessionRefreshClock: SessionRefreshClock
    private var createGeneration = UUID()
    private let sessionRefreshPolicy: SessionRefreshPolicy

    /// 搜索结果或归档行打开的会话可能不在普通列表里；
    /// 记住点选时的摘要，否则标题会退化成占位「新会话」。
    @Published private var openedSession: SessionSummary?

    var currentSession: SessionSummary? {
        guard let currentSessionID else { return nil }
        return sessions.first { $0.sessionId == currentSessionID }
            ?? (openedSession?.sessionId == currentSessionID ? openedSession : nil)
            ?? SessionSummary.placeholder(id: currentSessionID)
    }

    private func prepareTaskDerivedState() {
        guard taskDerivedDirty else { return }
        taskDerivedState.update(sessions: sessions, observations: sessionTaskObservations)
        taskDerivedDirty = false
    }

    var sessionTaskSummaries: [SessionTaskSummary] {
        prepareTaskDerivedState()
        return taskDerivedState.summaries
    }

    func taskSummary(for sessionID: String) -> SessionTaskSummary? {
        prepareTaskDerivedState()
        return taskDerivedState.byID[sessionID]
    }

    /// Both filters are cached together; toggling the filter only selects a
    /// snapshot, never recomputes four sections inside individual row readers.
    func homeSections(pinnedOnly: Bool) -> SessionHomeSections {
        prepareTaskDerivedState()
        return pinnedOnly ? taskDerivedState.pinnedOnly : taskDerivedState.all
    }

    var taskSummaryRevision: UInt64 {
        prepareTaskDerivedState()
        return taskDerivedState.revision
    }
    var taskDerivationCount: UInt64 {
        prepareTaskDerivedState()
        return taskDerivedState.derivationCount
    }
    var homePartitionBuildCount: UInt64 {
        prepareTaskDerivedState()
        return taskDerivedState.homeBuildCount
    }

    /// Update the locally observed task facts for one conversation. An empty
    /// set removes the record. Only opaque IDs and enum values are persisted.
    func setSessionTaskSignals(_ signals: Set<SessionTaskSignal>, for sessionID: String) {
        let persisted = SessionTaskCenter.persistable(signals)
        let instance = historyInstanceID
        let account = historyAccountScope
        if persisted.isEmpty {
            requestTaskSignals = requestTaskSignals.filter { key in
                let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
                return parts.count != 3 || String(parts[1]) != sessionID
            }
        }
        let previousSignals = sessionTaskObservations[sessionID]?.signals ?? []
        guard persisted != previousSignals else { return }
        if persisted.isEmpty {
            sessionTaskObservations.removeValue(forKey: sessionID)
        } else {
            sessionTaskObservations[sessionID] = SessionTaskObservation(signals: persisted)
        }
        persistSessionTaskObservations(
            sessionTaskObservations, instanceID: instance, accountScope: account)
        // 恢复问题从无到有才提醒：一直存在的问题重复提醒只会淹没新问题。
        if persisted.contains(.recoveryIssue), !previousSignals.contains(.recoveryIssue) {
            let title = sessions.first { $0.sessionId == sessionID }?.displayTitle ?? ""
            notifyRecoveryIssue(sessionID: sessionID, title: title)
        }
    }

    /// Approval and clarify are separate blocking requests even when they
    /// belong to the same session. Track their request identities so resolving
    /// one does not remove the task-center fact for its siblings.
    private func setRequestTaskSignal(_ signal: SessionTaskSignal,
                                      sessionID: String, requestID: String?) {
        guard requestID != nil else {
            setSessionTaskSignals([signal], for: sessionID)
            return
        }
        let key = requestSignalKey(signal, sessionID: sessionID, requestID: requestID)
        requestTaskSignals.insert(key)
        var signals = sessionTaskObservations[sessionID]?.signals ?? []
        signals.insert(signal)
        setSessionTaskSignals(signals, for: sessionID)
    }

    private func clearRequestTaskSignal(_ signal: SessionTaskSignal,
                                        sessionID: String, requestID: String?) {
        guard requestID != nil else {
            setSessionTaskSignals([], for: sessionID)
            return
        }
        let key = requestSignalKey(signal, sessionID: sessionID, requestID: requestID)
        requestTaskSignals.remove(key)
        let sessionPrefix = [signal.rawValue, sessionID].joined(separator: "\u{0}") + "\u{0}"
        if !requestTaskSignals.contains(where: { $0.hasPrefix(sessionPrefix) }) {
            var signals = sessionTaskObservations[sessionID]?.signals ?? []
            signals.remove(signal)
            setSessionTaskSignals(signals, for: sessionID)
        }
    }

    private func requestSignalKey(_ signal: SessionTaskSignal, sessionID: String,
                                  requestID: String?) -> String {
        [signal.rawValue, sessionID, requestID ?? ""].joined(separator: "\u{0}")
    }

    func openSession(_ session: SessionSummary) {
        guard !clearingHistory, !needsLogin else { return }
        homeTurnClaim.cancel()
        openedSession = session
        currentSessionID = session.sessionId
        // 进入会话即视为已读，不再显示完成标记。
        clearCompletion(sessionID: session.sessionId)
    }

    func closeSession() {
        homeTurnClaim.cancel()
        currentSessionID = nil
        openedSession = nil
    }

    /// Called by RootView on scene and overlay changes. A notification is
    /// suppressed only when the app is active and the exact conversation is
    /// unobscured.
    func setPresentationVisibility(appActive: Bool, conversationVisible: Bool) {
        appIsActive = appActive
        conversationIsVisible = appActive && conversationVisible
    }

    /// The request identity index belongs to the current instance/account and
    /// chat page. Scope retirement and page teardown must not let an old request
    /// suppress a same-kind signal from a later session.
    func resetRequestTaskSignalIndex() {
        requestTaskSignals.removeAll()
    }

    private var visibleSessionID: String? {
        guard appIsActive, conversationIsVisible else { return nil }
        return currentSessionID
    }

    private var canSuppressNotificationForVisibleConversation: Bool {
        appIsActive && conversationIsVisible
    }

    /// The exact session currently on screen. `conversationVisible` describes
    /// page presentation, not notification scope; using it alone would suppress
    /// alerts from a different session while this page is active.
    private var visibleNotificationSessionID: String? {
        canSuppressNotificationForVisibleConversation ? currentSessionID : nil
    }

    // MARK: - 模型目录

    func loadModels(force: Bool = false) async {
        if catalogLoading { return }
        if modelCatalog != nil && !force { return }
        let scope = actionScope
        let requestAPI = api
        catalogLoading = true
        defer { if isCurrent(scope) { catalogLoading = false } }
        do {
            let catalog = try await requestAPI.availableModels()
            guard isCurrent(scope) else { return }
            modelCatalog = catalog
        } catch {
            guard isCurrent(scope) else { return }
            errorText = error.localizedDescription
        }
    }

    func setModel(_ option: ModelOption, for sessionID: String) async -> Bool {
        guard !sessionActionBusy else { return false }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            try await requestAPI.setSessionModel(sessionID: sessionID, model: option.model, provider: option.providerID)
            guard isCurrent(scope) else { return false }
            invalidateListRefresh()
            loadingSessions = false
            applyModel(option, to: sessionID)
            return true
        } catch {
            guard isCurrent(scope) else { return false }
            sessionActionError = error.localizedDescription
            return false
        }
    }

    /// 服务端已确认后本地同步，避免列表与输入栏显示旧模型。
    private func applyModel(_ option: ModelOption, to sessionID: String) {
        if let index = sessions.firstIndex(where: { $0.sessionId == sessionID }) {
            sessions[index] = sessions[index].withModel(option.model)
        }
        // 搜索/归档打开的会话不在列表里；写 openedSession 触发 objectWillChange，
        // currentSession 计算属性才会重算，标签才不会停留在旧模型。
        if openedSession?.sessionId == sessionID {
            openedSession = openedSession?.withModel(option.model)
        }
    }

    // MARK: - 会话操作

    func rename(sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessionActionBusy else { return }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            try await requestAPI.renameSession(sessionID: sessionID, title: trimmed)
            guard isCurrent(scope) else { return }
            invalidateListRefresh()
            loadingSessions = false
            if let index = sessions.firstIndex(where: { $0.sessionId == sessionID }) {
                sessions[index] = sessions[index].withTitle(trimmed)
            }
            if openedSession?.sessionId == sessionID { openedSession = openedSession?.withTitle(trimmed) }
        } catch {
            guard isCurrent(scope) else { return }
            sessionActionError = error.localizedDescription
        }
    }

    func togglePin(sessionID: String) async {
        guard !sessionActionBusy else { return }
        lastArchiveUndo = []
        let current = sessions.first { $0.sessionId == sessionID }
        let next = !(current?.pinned ?? false)
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            try await requestAPI.setSessionPinned(sessionID: sessionID, pinned: next)
            guard isCurrent(scope) else { return }
            invalidateListRefresh()
            loadingSessions = false
            if let index = sessions.firstIndex(where: { $0.sessionId == sessionID }) {
                sessions[index] = sessions[index].withPinned(next)
            }
        } catch {
            guard isCurrent(scope) else { return }
            sessionActionError = error.localizedDescription
        }
    }

    /// 归档后本地立即移除该行；失败时回滚由 refresh 恢复真实状态。
    /// 成功后记录撤销信息，供侧栏提示条调用 undoArchive 恢复。
    func archive(sessionID: String) async {
        guard !sessionActionBusy else { return }
        // F-58：能力判断必须落在 AppState，而不只是 UI。
        // 网关后端没有归档列表路由（`GatewayBackend.setSessionArchived` 直接抛 501），
        // 归档后这条会话在 App 内既列不出也恢复不了。侧栏虽然用 `supportsArchive`
        // 隐藏了入口，但脚本/快捷指令/将来的新调用点绕过 UI 就会撞上一个没有
        // 上下文的 501。这里提前拒绝并给出可操作的原因。
        guard supportsArchive else {
            sessionActionError = Self.archiveUnsupportedMessage
            return
        }
        let title = sessions.first { $0.sessionId == sessionID }?.displayTitle
            ?? (openedSession?.sessionId == sessionID ? openedSession?.displayTitle : nil)
            ?? "该会话"
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            try await requestAPI.setSessionArchived(sessionID: sessionID, archived: true)
            guard isCurrent(scope) else { return }
            invalidateListRefresh()
            loadingSessions = false
            if currentSessionID == sessionID { currentSessionID = nil }
            sessions.removeAll { $0.sessionId == sessionID }
            dropTaskAcknowledgements(sessionID: sessionID)
            lastArchiveUndo = [ArchiveUndoTarget(sessionID: sessionID, title: title)]
        } catch {
            guard isCurrent(scope) else { return }
            sessionActionError = error.localizedDescription
        }
    }

    /// 恢复归档：与归档同一条路由，只把 archived 改成 false。
    /// 成功后才放行列表重读，归档分页与主列表都由服务端真实状态决定。
    func restore(sessionID: String) async {
        guard !sessionActionBusy else { return }
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            try await requestAPI.setSessionArchived(sessionID: sessionID, archived: false)
            guard isCurrent(scope) else { return }
            // 撤销的就是这一条时移出撤销条；批量归档的其它目标继续保留。
            lastArchiveUndo.removeAll { $0.sessionID == sessionID }
            invalidateListRefresh()
            await refresh()
        } catch {
            guard isCurrent(scope) else { return }
            sessionActionError = error.localizedDescription
        }
    }

    /// 撤销最近一次归档（可能是整批）：逐条走与 restore 相同的归档路由，
    /// 成功才从撤销条移除，失败保留并汇报，便于再次尝试。
    func undoArchive() async {
        let targets = lastArchiveUndo
        guard !targets.isEmpty, !sessionActionBusy else { return }
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        var firstError: String?
        var failed = 0
        for target in targets {
            guard isCurrent(scope), !Task.isCancelled else { return }
            do {
                try await requestAPI.setSessionArchived(sessionID: target.sessionID, archived: false)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                continue
            }
            guard isCurrent(scope) else { return }
            lastArchiveUndo.removeAll { $0.sessionID == target.sessionID }
        }
        guard isCurrent(scope) else { return }
        sessionActionError = batchError(firstError, failed: failed, total: targets.count)
        guard failed < targets.count else { return }
        invalidateListRefresh()
        await refresh()
    }

    func delete(sessionID: String) async {
        guard !sessionActionBusy else { return }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        let instanceID = historyInstanceID
        let accountScope = historyAccountScope
        let cache = ChatHistoryStore(instanceID: instanceID, sessionID: sessionID,
                                     accountScope: accountScope)
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            try await requestAPI.deleteSession(sessionID: sessionID)
            // 会话级本地状态必须跟着一起清：草稿/阅读位置/折叠状态都按会话 id 存，
            // 留着会让重建的同 ID 会话继承上一条的内容。
            discardLocalState(for: sessionID, instanceID: instanceID, accountScope: accountScope)
            // A list GET started before the deletion must not restore its row.
            guard isCurrent(scope) else {
                trackCleanup(Task { [weak self] in
                let result = await cache.remove()
                self?.recordHistoryCleanupResult(result)
            })
                return
            }
            invalidateListRefresh()
            loadingSessions = false
            if currentSessionID == sessionID { currentSessionID = nil }
            sessions.removeAll { $0.sessionId == sessionID }
            dropTaskAcknowledgements(sessionID: sessionID)
            // Disk cleanup runs independently of the immediate UI mutation.
            trackCleanup(Task { [weak self] in
                let result = await cache.remove()
                self?.recordHistoryCleanupResult(result)
            })
        } catch {
            guard isCurrent(scope) else { return }
            sessionActionError = error.localizedDescription
        }
    }

    // MARK: - 批量会话操作（列表多选）

    /// 全失败只报首条错误，部分失败带上失败条数；成功时保持 nil。
    private func batchError(_ firstError: String?, failed: Int, total: Int) -> String? {
        guard let firstError else { return nil }
        return failed >= total ? firstError : "\(failed) 个失败：\(firstError)"
    }

    /// 批量归档：一次 busy，逐条累计结果，成功项整批写入 lastArchiveUndo。
    func archiveSessions(ids: [String]) async -> BatchActionResult {
        guard !ids.isEmpty else { return BatchActionResult(succeeded: 0, failed: 0) }
        // F-58：与单条归档同一能力判断。整批直接拒绝，不逐条撞 501 再汇总。
        guard supportsArchive else {
            sessionActionError = Self.archiveUnsupportedMessage
            return BatchActionResult(succeeded: 0, failed: ids.count)
        }
        guard !sessionActionBusy else { return BatchActionResult(succeeded: 0, failed: ids.count) }
        let targets = ids.map { id in
            let title = sessions.first { $0.sessionId == id }?.displayTitle
                ?? (openedSession?.sessionId == id ? openedSession?.displayTitle : nil)
                ?? "该会话"
            return ArchiveUndoTarget(sessionID: id, title: title)
        }
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        var succeeded = 0
        var failed = 0
        var firstError: String?
        var archived: [ArchiveUndoTarget] = []
        for target in targets {
            guard isCurrent(scope), !Task.isCancelled else {
                return BatchActionResult(succeeded: succeeded, failed: failed)
            }
            do {
                try await requestAPI.setSessionArchived(sessionID: target.sessionID, archived: true)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                continue
            }
            guard isCurrent(scope) else {
                return BatchActionResult(succeeded: succeeded, failed: failed)
            }
            succeeded += 1
            archived.append(target)
        }
        guard isCurrent(scope) else {
            return BatchActionResult(succeeded: succeeded, failed: failed)
        }
        if !archived.isEmpty {
            let removed = Set(archived.map(\.sessionID))
            if let currentSessionID, removed.contains(currentSessionID) {
                self.currentSessionID = nil
            }
            sessions.removeAll { removed.contains($0.sessionId) }
            dropTaskAcknowledgements(sessionIDs: removed)
            lastArchiveUndo = archived
        }
        sessionActionError = batchError(firstError, failed: failed, total: targets.count)
        invalidateListRefresh()
        await refresh()
        return BatchActionResult(succeeded: succeeded, failed: failed)
    }

    /// 批量删除：删除不写撤销条；被删的当前会话关闭聊天。
    func deleteSessions(ids: [String]) async -> BatchActionResult {
        guard !ids.isEmpty else { return BatchActionResult(succeeded: 0, failed: 0) }
        guard !sessionActionBusy else { return BatchActionResult(succeeded: 0, failed: ids.count) }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        let instanceID = historyInstanceID
        let accountScope = historyAccountScope
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        var succeeded = 0
        var failed = 0
        var firstError: String?
        var removed: Set<String> = []
        for id in ids {
            guard isCurrent(scope), !Task.isCancelled else {
                return BatchActionResult(succeeded: succeeded, failed: failed)
            }
            let cache = ChatHistoryStore(instanceID: instanceID, sessionID: id, accountScope: accountScope)
            do {
                try await requestAPI.deleteSession(sessionID: id)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                continue
            }
            // Disk cleanup runs independently of the immediate UI mutation.
            discardLocalState(for: id, instanceID: instanceID, accountScope: accountScope)
            // A-09：批量删除同样登记引用，别让清理任务成为不可见的孤儿。
            trackCleanup(Task { [weak self] in
                let result = await cache.remove()
                self?.recordHistoryCleanupResult(result)
            })
            guard isCurrent(scope) else {
                return BatchActionResult(succeeded: succeeded, failed: failed)
            }
            succeeded += 1
            removed.insert(id)
        }
        guard isCurrent(scope) else {
            return BatchActionResult(succeeded: succeeded, failed: failed)
        }
        if !removed.isEmpty {
            if let currentSessionID, removed.contains(currentSessionID) {
                self.currentSessionID = nil
            }
            sessions.removeAll { removed.contains($0.sessionId) }
            dropTaskAcknowledgements(sessionIDs: removed)
        }
        sessionActionError = batchError(firstError, failed: failed, total: ids.count)
        invalidateListRefresh()
        await refresh()
        return BatchActionResult(succeeded: succeeded, failed: failed)
    }

    /// 批量置顶：成功项就地更新，不逐条触发列表重读。
    func setPinned(_ pinned: Bool, ids: [String]) async -> BatchActionResult {
        guard !ids.isEmpty else { return BatchActionResult(succeeded: 0, failed: 0) }
        guard !sessionActionBusy else { return BatchActionResult(succeeded: 0, failed: ids.count) }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        var succeeded = 0
        var failed = 0
        var firstError: String?
        var pinnedIDs: Set<String> = []
        for id in ids {
            guard isCurrent(scope), !Task.isCancelled else {
                return BatchActionResult(succeeded: succeeded, failed: failed)
            }
            do {
                try await requestAPI.setSessionPinned(sessionID: id, pinned: pinned)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                continue
            }
            guard isCurrent(scope) else {
                return BatchActionResult(succeeded: succeeded, failed: failed)
            }
            succeeded += 1
            pinnedIDs.insert(id)
        }
        guard isCurrent(scope) else {
            return BatchActionResult(succeeded: succeeded, failed: failed)
        }
        for index in sessions.indices where pinnedIDs.contains(sessions[index].sessionId) {
            sessions[index] = sessions[index].withPinned(pinned)
        }
        sessionActionError = batchError(firstError, failed: failed, total: ids.count)
        invalidateListRefresh()
        await refresh()
        return BatchActionResult(succeeded: succeeded, failed: failed)
    }

    /// 从会话分支；成功后打开新会话。keepCount 为 nil 表示保留全部历史。
    func branch(sessionID: String, keepCount: Int?) async {
        guard !sessionActionBusy else { return }
        lastArchiveUndo = []
        let scope = actionScope
        let requestAPI = api
        sessionActionBusy = true
        sessionActionError = nil
        defer { if isCurrent(scope) { sessionActionBusy = false } }
        do {
            let newID = try await requestAPI.forkSession(sessionID: sessionID, keepCount: keepCount)
            guard isCurrent(scope), currentSessionID == sessionID else { return }
            currentSessionID = newID
            await refresh()
        } catch {
            guard isCurrent(scope) else { return }
            sessionActionError = error.localizedDescription
        }
    }

    var active: HermesInstance { instances[activeIndex] }
    private(set) var api: HermesBackend
    private let credentialStorage: any InstanceCredentialStorage
    @Published private(set) var clearingHistory = false

    /// F-58：归档能力读后端能力表，不再比字面量。
    /// 原先这里与 `SessionDrawer.supportsArchive` 各写一份 `== .webui`，
    /// 注释却说是「同一判据以避免漂移」——用两份字面量避免漂移本身就是矛盾。
    /// 现在两份都读 `api.capabilities.canArchive`，能力只有一处定义。
    var supportsArchive: Bool { api.capabilities.canArchive }

    static let archiveUnsupportedMessage =
        "当前实例不支持归档：网关后端没有归档列表，归档后无法在 App 内查看或恢复。请改用支持归档的 WebUI 实例。"

    /// 尚未配置实例时的提示。与 `InstanceStore.loadResult` 的首次启动文案一致，
    /// 用在「配置提示丢失了但仍未配置」的兜底路径上。
    static let unconfiguredInstanceMessage =
        "尚未配置实例，请在设置中添加网关地址与密钥。"

    /// 网关实例已建好、但还没有 API 密钥。与「钥匙串暂时读不到」是两件事：
    /// 前者要用户去填，后者只需解锁重试。
    static let missingAPIKeyMessage =
        "尚未填写网关 API 密钥，请在设置中填写后下拉刷新。"

    /// A-09：`switchTo` 起的自动刷新必须持有引用。原先它是 fire-and-forget，
    /// 快速连续切实例会叠出多个仍带着旧 `actionScope` 的刷新任务，没有任何句柄
    /// 可以取消或观察。现在持有引用并在作用域变化时 cancel。
    ///
    /// 注意实际生效的取消链路有两条：`cancel()` 让这个包装任务立刻停在入口；
    /// 真正的列表 GET 由 `invalidateListRefresh()` 取消 `refreshTask` 来中止。
    /// 兜底保护仍然是 `fetchSessions` 里的 `isCurrent(scope)` —— 旧作用域的
    /// 结果永远不会写进新作用域。
    private var scopeRefreshTask: Task<Void, Never>?
    /// A-09：历史清理任务也必须持有引用，避免成为「看不见也管不着」的孤儿任务。
    ///
    /// 这里**刻意不取消**：`ChatHistoryStore.remove` 删的是刚被退役的旧账号
    /// 作用域下的缓存文件，取消它只会把旧账号的对话正文留在磁盘上（隐私问题）；
    /// 而它的 instanceID/accountScope 是按值捕获的，跑完也不会写脏新作用域。
    /// 只保留最近若干个引用（超出的丢弃引用，任务本身仍会跑完），
    /// 这样既能让作用域变化时有机会观察这些任务，也不会让数组无界增长。
    private var historyCleanupTasks: [Task<Void, Never>] = []

    /// F-45：把「实例 + 账号域 + 切换代数」写进路由身份。
    /// 三者任一变化都必须让 `ChatRoute` 不再相等，SwiftUI 才会重建目标视图。
    ///
    /// 用 `#if canImport(SwiftUI)` 守卫：`ChatRouteScope` 定义在只含 SwiftUI/UIKit
    /// 的 `ChatNavigation.swift` 里，离线测试目标（Linux，无 SwiftUI）单独编译
    /// `AppState.swift` 时不会带上那个文件，必须让这段引用在那边整体消失。
    private func publishRouteScope() {
        #if canImport(SwiftUI)
        ChatRouteScope.current =
            "\(historyInstanceID)|\(historyAccountScope)|\(activeChangeToken)"
        #endif
    }

    /// A-09：取消上一作用域残留的自动刷新。列表刷新本身由 `refreshTask` 与
    /// `refreshGeneration` 管理，`invalidateListRefresh()` 已经在处理。
    private func cancelScopeRefresh() {
        scopeRefreshTask?.cancel()
        scopeRefreshTask = nil
    }

    /// A-09：登记一个历史清理任务的引用。只登记不取消，理由见 `historyCleanupTasks`。
    private func trackCleanup(_ task: Task<Void, Never>) {
        historyCleanupTasks.append(task)
        if historyCleanupTasks.count > 8 {
            historyCleanupTasks.removeFirst(historyCleanupTasks.count - 8)
        }
    }

    var historyInstanceID: String {
        ChatHistoryIdentity.instanceID(id: active.id, baseURL: active.baseURL)
    }

    var historyAccountScope: String {
        ChatHistoryIdentity.accountScope(instanceID: historyInstanceID)
    }

    // MARK: - 会话完成标记（本地）

    /// 标记按实例 + 账号作用域分桶，切实例/退账号都必须换用对应集合。
    private var completedDefaultsKey: String {
        let parts = [historyInstanceID, historyAccountScope]
        let digest = (try? JSONEncoder().encode(parts))?.base64EncodedString() ?? ""
        return "HermesSessions.completed.v1." + digest
    }

    private func loadCompletions() {
        completedSessionIDs = Set(UserDefaults.standard.stringArray(forKey: completedDefaultsKey) ?? [])
    }

    private func loadSessionTasks() {
        sessionTaskObservations = SessionTaskStore.load(
            instanceID: historyInstanceID,
            accountScope: historyAccountScope
        )
        sessionTaskPersistenceWarning = nil
    }

    // MARK: - 任务确认（本地）

    /// 确认记录按实例 + 账号作用域分桶，与完成标记同一策略。
    ///
    /// 存在独立的新 key 下，不改 `SessionTaskStore` 的任何结构：旧版本 App
    /// 读不到这个 key，会当作「没有确认记录」，已处理的任务重新出现但不会崩。
    private var taskAckDefaultsKey: String {
        Self.taskAckDefaultsKey(instanceID: historyInstanceID, accountScope: historyAccountScope)
    }

    /// 某个作用域的确认记录存储键。删除实例时用这把键直接清掉该作用域的数据。
    private static func taskAckDefaultsKey(instanceID: String, accountScope: String) -> String {
        let parts = [instanceID, accountScope]
        let digest = (try? JSONEncoder().encode(parts))?.base64EncodedString() ?? ""
        return "HermesTaskAck.v1." + digest
    }

    /// 清除某作用域的确认记录：磁盘 + 内存（若当前正查看该作用域）。
    private func removeTaskAcknowledgements(instanceID: String, accountScope: String) {
        UserDefaults.standard.removeObject(
            forKey: Self.taskAckDefaultsKey(instanceID: instanceID, accountScope: accountScope))
        if instanceID == historyInstanceID && accountScope == historyAccountScope {
            taskAcknowledgements = []
        }
    }

    /// 惰性加载并顺手淘汰过期记录。切作用域后第一次读取才读盘。
    private func prepareTaskAcknowledgements() {
        guard taskAckDirty || !taskAckLoaded else { return }
        taskAckDirty = false
        taskAckLoaded = true
        guard let data = UserDefaults.standard.data(forKey: taskAckDefaultsKey),
              let decoded = try? JSONDecoder().decode([TaskAcknowledgement].self, from: data) else {
            taskAcknowledgements = []
            return
        }
        let pruned = TaskAcknowledgement.pruning(decoded, now: Date().timeIntervalSince1970)
        taskAcknowledgements = pruned
        if pruned.count != decoded.count { persistTaskAcknowledgements() }
    }

    private func persistTaskAcknowledgements() {
        let key = taskAckDefaultsKey
        if taskAcknowledgements.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(taskAcknowledgements) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 标记一条「需要处理」任务已处理。只有 `recoveryIssue` 允许。
    func acknowledgeTask(sessionID: String, signal: SessionTaskSignal) {
        guard TaskAcknowledgement.isAcknowledgeable(signal) else { return }
        guard let observation = sessionTaskObservations[sessionID],
              observation.signals.contains(signal) else { return }
        prepareTaskAcknowledgements()
        // 同一 (会话, 信号, 观察时间) 只留一条。
        let exists = taskAcknowledgements.contains {
            $0.sessionID == sessionID && $0.signal == signal
                && $0.observedAt == observation.observedAt
        }
        guard !exists else { return }
        let now = Date().timeIntervalSince1970
        taskAcknowledgements.append(
            TaskAcknowledgement(sessionID: sessionID, signal: signal,
                                observedAt: observation.observedAt, acknowledgedAt: now))
        taskAcknowledgements = TaskAcknowledgement.pruning(taskAcknowledgements, now: now)
        taskDerivedDirty = true
        persistTaskAcknowledgements()
    }

    /// 撤销一条确认，该任务立即回到原分区。
    func undoTaskAcknowledgement(_ acknowledgement: TaskAcknowledgement) {
        prepareTaskAcknowledgements()
        let next = TaskAcknowledgement.removing(acknowledgement, from: taskAcknowledgements)
        guard next.count != taskAcknowledgements.count else { return }
        taskAcknowledgements = next
        taskDerivedDirty = true
        persistTaskAcknowledgements()
    }

    /// 会话被删除时连带清理它的确认。
    private func dropTaskAcknowledgements(sessionID: String) {
        dropTaskAcknowledgements(sessionIDs: [sessionID])
    }

    /// 批量版本：归档或批量删除后一次清理。
    private func dropTaskAcknowledgements(sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }
        prepareTaskAcknowledgements()
        let next = taskAcknowledgements.filter { !sessionIDs.contains($0.sessionID) }
        guard next.count != taskAcknowledgements.count else { return }
        taskAcknowledgements = next
        taskDerivedDirty = true
        persistTaskAcknowledgements()
    }

    /// 切作用域：换 key，丢掉内存里的旧集合。
    private func resetTaskAcknowledgements() {
        taskAcknowledgements = []
        taskAckDirty = true
        taskAckLoaded = false
        taskDerivedDirty = true
    }

    /// 任务中心展示用的摘要：已确认的恢复问题被过滤掉。
    ///
    /// P1：过滤粒度是**信号**，不是整个会话（实现见
    /// `SessionTaskCenter.filteringAcknowledged`）。原实现按会话整条过滤，
    /// 于是同一会话里「已确认的恢复问题」和「仍需你确认的审批」一起消失。
    var visibleTaskSummaries: [SessionTaskSummary] {
        prepareTaskDerivedState()
        prepareTaskAcknowledgements()
        return SessionTaskCenter.filteringAcknowledged(
            taskDerivedState.summaries,
            observations: sessionTaskObservations,
            acknowledgements: taskAcknowledgements)
    }

    /// 「已处理」分区的内容：仍有效的确认，附带会话标题。
    var acknowledgedTaskEntries: [TaskAcknowledgement] {
        prepareTaskAcknowledgements()
        guard !taskAcknowledgements.isEmpty else { return [] }
        return taskAcknowledgements.sorted { $0.acknowledgedAt > $1.acknowledgedAt }
    }

    private func persistCompletions() {
        let key = completedDefaultsKey
        if completedSessionIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(completedSessionIDs), forKey: key)
        }
    }

    /// 上一轮还在流式、这一轮已停下，且不是当前打开的会话，才视为一次新完成。
    private func markCompletions(previous: [SessionSummary], next: [SessionSummary]) {
        guard !previous.isEmpty else { return }
        var streamingBefore: [String: Bool] = [:]
        for item in previous { streamingBefore[item.sessionId] = item.isStreaming == true }
        let open = visibleNotificationSessionID
        var changed = false
        for item in next where item.sessionId != open
            && streamingBefore[item.sessionId] == true
            && item.isStreaming != true {
            if completedSessionIDs.insert(item.sessionId).inserted {
                changed = true
                // 这一轮刚结束且用户不在该会话：发一条本地通知。
                // `SessionSummary` 没有 run 标识，`runID` 传 nil 让标识退化为
                // 按会话去重——同一会话连续跑完会替换前一条，结论都是「刚跑完」。
                notifyRunFinished(sessionID: item.sessionId, title: item.displayTitle)
            }
        }
        if changed { persistCompletions() }
    }

    /// 投递「后台处理完成」。开关与前台抑制都在 Planner 里判定。
    private func notifyRunFinished(sessionID: String, title: String) {
        let settings = TaskNotificationPlanner.Settings(
            approvalEnabled: NotificationPreference.approval,
            clarifyEnabled: NotificationPreference.clarify,
            finishedEnabled: NotificationPreference.finished,
            recoveryEnabled: NotificationPreference.recovery)
        guard let notification = TaskNotificationPlanner.finished(
            runID: nil, sessionID: sessionID, title: title,
            settings: settings, foregroundSessionID: visibleNotificationSessionID,
            appActive: canSuppressNotificationForVisibleConversation,
            instanceID: historyInstanceID, accountScope: historyAccountScope) else { return }
        let sound = NotificationPreference.sound
        let deliverer = notifier
        Task { await deliverer.deliver(notification, sound: sound) }
    }

    /// 投递「后台恢复需处理」。只在 `recoveryIssue` 从无到有时发。
    private func notifyRecoveryIssue(sessionID: String, title: String) {
        let settings = TaskNotificationPlanner.Settings(
            approvalEnabled: NotificationPreference.approval,
            clarifyEnabled: NotificationPreference.clarify,
            finishedEnabled: NotificationPreference.finished,
            recoveryEnabled: NotificationPreference.recovery)
        guard let notification = TaskNotificationPlanner.recovery(
            sessionID: sessionID, title: title,
            settings: settings, foregroundSessionID: visibleNotificationSessionID,
            appActive: canSuppressNotificationForVisibleConversation,
            instanceID: historyInstanceID, accountScope: historyAccountScope) else { return }
        let sound = NotificationPreference.sound
        let deliverer = notifier
        Task { await deliverer.deliver(notification, sound: sound) }
    }

    /// 会话页观察到审批到达。
    ///
    /// 只在「用户不在这个会话」时提醒：正看着的人已经看到卡片了。
    func approvalArrived(sessionID: String, requestID: String?) {
        // The task-center fact exists even when the current chat is visible
        // and the notification is deliberately suppressed. Record it before
        // the planner guard so exact resolution can still maintain siblings.
        setRequestTaskSignal(.waitingForApproval, sessionID: sessionID,
                             requestID: requestID)
        let settings = TaskNotificationPlanner.Settings(
            approvalEnabled: NotificationPreference.approval,
            clarifyEnabled: NotificationPreference.clarify,
            finishedEnabled: NotificationPreference.finished,
            recoveryEnabled: NotificationPreference.recovery)
        let title = sessions.first { $0.sessionId == sessionID }?.displayTitle ?? ""
        guard let notification = TaskNotificationPlanner.approval(
            requestID: requestID, sessionID: sessionID, title: title,
            settings: settings, foregroundSessionID: visibleNotificationSessionID,
            appActive: canSuppressNotificationForVisibleConversation,
            instanceID: historyInstanceID, accountScope: historyAccountScope) else { return }
        rememberPendingRequestNotification(notification, kind: "approval",
                                            sessionID: sessionID, requestID: requestID)
        let sound = NotificationPreference.sound
        let deliverer = notifier
        Task { await deliverer.deliver(notification, sound: sound) }
    }

    /// 补充信息请求使用独立类型和稳定 ID；即使同一 run 同时有审批和
    /// clarify，也不会互相替换或撤回。
    func clarifyArrived(sessionID: String, requestID: String?) {
        // Clarify is a separate blocking request. Register its identity even
        // when the visible conversation suppresses only the notification.
        setRequestTaskSignal(.waitingForClarify, sessionID: sessionID,
                             requestID: requestID)
        let settings = TaskNotificationPlanner.Settings(
            approvalEnabled: NotificationPreference.approval,
            clarifyEnabled: NotificationPreference.clarify,
            finishedEnabled: NotificationPreference.finished,
            recoveryEnabled: NotificationPreference.recovery)
        let title = sessions.first { $0.sessionId == sessionID }?.displayTitle ?? ""
        guard let notification = TaskNotificationPlanner.clarify(
            requestID: requestID, sessionID: sessionID, title: title,
            settings: settings, foregroundSessionID: visibleNotificationSessionID,
            appActive: canSuppressNotificationForVisibleConversation,
            instanceID: historyInstanceID, accountScope: historyAccountScope) else { return }
        rememberPendingRequestNotification(notification, kind: "clarify",
                                            sessionID: sessionID, requestID: requestID)
        let sound = NotificationPreference.sound
        let deliverer = notifier
        Task { await deliverer.deliver(notification, sound: sound) }
    }

    private func requestKey(kind: String, sessionID: String, requestID: String?) -> String {
        (requestID ?? "") + "\u{0}" + sessionID + "\u{0}" + kind
    }

    private func rememberPendingRequestNotification(_ notification: TaskNotification,
                                                     kind: String, sessionID: String,
                                                     requestID: String?) {
        let key = requestKey(kind: kind, sessionID: sessionID, requestID: requestID)
        pendingRequestNotificationIDs[key, default: []].insert(notification.stableID)
    }

    private func removeRequestNotification(kind: String, sessionID: String,
                                           requestID: String?) {
        let stableID = TaskNotificationPlanner.requestIdentifier(
            kind: kind, requestID: requestID, sessionID: sessionID,
            instanceID: historyInstanceID, accountScope: historyAccountScope)
        let key = requestKey(kind: kind, sessionID: sessionID, requestID: requestID)
        let identifiers = pendingRequestNotificationIDs.removeValue(forKey: key) ?? [stableID]
        let deliverer = notifier
        // The event can arrive before a delivery task records its ID. Remove
        // the deterministic ID anyway; system APIs are idempotent.
        Task {
            for identifier in identifiers {
                await deliverer.remove(identifier: identifier)
            }
        }
    }

    func approvalResolved(sessionID: String, requestID: String?) {
        clearRequestTaskSignal(.waitingForApproval, sessionID: sessionID,
                               requestID: requestID)
        removeRequestNotification(kind: "approval", sessionID: sessionID,
                                  requestID: requestID)
    }

    func clarifyResolved(sessionID: String, requestID: String?) {
        clearRequestTaskSignal(.waitingForClarify, sessionID: sessionID,
                               requestID: requestID)
        removeRequestNotification(kind: "clarify", sessionID: sessionID,
                                  requestID: requestID)
    }

    func clearCompletion(sessionID: String) {
        guard completedSessionIDs.remove(sessionID) != nil else { return }
        persistCompletions()
    }

    func clearAllCompletions() {
        completedSessionIDs = []
        persistCompletions()
    }

    /// 复位「当前作用域里的会话视图状态」。
    ///
    /// 原先四个入口（`retireHistoryAccount` / `clearCachedHistory` / `switchTo` /
    /// `disconnect`）各自手抄一份清理清单，字段数 9/7/10/7 且互不一致——
    /// `switchTo` 不清 `ChatMarkdownParser` 缓存，另两个清。同一语义三种行为。
    /// 现在共同部分集中到这里，各入口只保留自己的额外副作用（cookie、Keychain、
    /// 磁盘删除、路由发布）。
    ///
    /// `clearMarkdownCache` 默认 true：渲染缓存按正文内容寻址，留着不会串内容，
    /// 但会把上一个实例/账号的对话正文继续留在内存里——跨作用域必须清。
    private func resetScopeView(clearMarkdownCache: Bool = true) {
        // A-09：先取消上一代残留的自动刷新，别让它继续持有旧 api 跑网络。
        cancelScopeRefresh()
        invalidateListRefresh()
        createGeneration = UUID()
        creating = false
        loadingSessions = false
        currentSessionID = nil
        openedSession = nil
        pendingFork = nil
        lastArchiveUndo = []
        modelCatalog = nil
        catalogLoading = false
        sessionActionBusy = false
        sessionActionError = nil
        resetRequestTaskSignalIndex()
        lastSessionRefresh = sessionRefreshClock.lastSuccess(
            scope: historyInstanceID + "|" + historyAccountScope)
        activeChangeToken &+= 1
        if clearMarkdownCache {
            #if canImport(UIKit)
            ChatMarkdownParser.clearCache()
            #endif
        }
        publishRouteScope()
    }

    private func retireHistoryAccount() {
        // 先清当前实例的 cookie（URLSession + WebKit），避免换账号后旧登录态残留。
        if let webUI = api as? HermesAPI { webUI.clearCookies() }
        let instance = historyInstanceID
        let previous = ChatHistoryIdentity.rotate(instanceID: instance)
        GatewayRunStore.removeAll(instanceID: instance, accountScope: previous)
        // Backend-local run recovery must move to the new account namespace too.
        api = Self.makeBackend(for: active)
        loadCompletions()
        loadSessionTasks()
        resetTaskAcknowledgements()
        forgetSessionList(scope: instance + "|" + previous)
        sessions = []
        hasLoadedSessions = false
        resetScopeView()
        // 展示层缓存同样按实例 + 账号隔离：旧作用域必须一起丢弃，
        // 否则另一个账号的同一会话 ID 会命中上一条纯图标记与图片比例。
        ImageRatioStore.shared.remove(scope: instance + "|" + previous)
        ChatAttachmentPlaceholderStore.shared.removeScope(instance + "|" + previous)
        RecentModelStore.shared.remove(scope: instance + "|" + previous)
        sessionRefreshClock.remove(scope: instance + "|" + previous)
        recordCleanupResult(ChatDraftStore.removeAll(
            instanceID: instance, accountScope: previous))
        ChatReadingPositionStore.removeAll(instanceID: instance, accountScope: previous)
        ChatReaderPositionStore.removeAll(instanceID: instance, accountScope: previous)
        ChatCellStateStore.removeAll(instanceID: instance, accountScope: previous)
        SessionTaskStore.remove(instanceID: instance, accountScope: previous)
        // A-09：这个收尾任务原先没有引用。它的参数是按值捕获的，跑完只会删
        // 旧账号作用域的文件，所以**不能**取消（取消会把旧账号的对话正文留在
        // 磁盘上）。登记引用的作用只是让它有归属，而不是彻底不可见。
        trackCleanup(Task { [weak self] in
            let result = await ChatHistoryStore.remove(instanceID: instance, accountScope: previous)
            self?.recordHistoryCleanupResult(result)
        })
    }

    func clearCachedHistory() async {
        guard !clearingHistory else { return }
        let instance = historyInstanceID
        let account = historyAccountScope
        let scope = instance + "|" + account
        clearingHistory = true
        forgetSessionList(scope: scope)
        // Keep the currently confirmed remote list visible: clearing local
        // history does not mean the server's sessions have disappeared.
        resetScopeView()
        ImageRatioStore.shared.remove(scope: scope)
        ChatAttachmentPlaceholderStore.shared.removeScope(scope)
        RecentModelStore.shared.remove(scope: scope)
        sessionRefreshClock.remove(scope: scope)
        // 草稿/阅读位置/折叠状态不在 ChatHistoryStore 里，必须单独按账号清理，
        // 否则「清除本地历史缓存」之后草稿仍然留在设备上。
        recordCleanupResult(ChatDraftStore.removeAll(
            instanceID: instance, accountScope: account))
        ChatReadingPositionStore.removeAll(instanceID: instance, accountScope: account)
        ChatReaderPositionStore.removeAll(instanceID: instance, accountScope: account)
        ChatCellStateStore.removeAll(instanceID: instance, accountScope: account)
        SessionTaskStore.remove(instanceID: instance, accountScope: account)
        removeTaskAcknowledgements(instanceID: instance, accountScope: account)
        taskAckDirty = true
        taskAckLoaded = false
        sessionTaskPersistenceWarning = nil
        sessionTaskObservations = [:]
        let historyCleanup = await ChatHistoryStore.remove(
            instanceID: instance, accountScope: account)
        recordHistoryCleanupResult(historyCleanup)
        clearingHistory = false
        resetRequestTaskSignalIndex()
    }

    /// 删除一条会话在设备上留下的全部本地状态。
    /// 只清当前账号作用域下的那一份，别的账号不受影响。
    private func discardLocalState(for sessionID: String, instanceID: String, accountScope: String) {
        recordCleanupResult(ChatDraftStore.removeSession(
            instanceID: instanceID, accountScope: accountScope, sessionID: sessionID))
        ChatReadingPositionStore(instanceID: instanceID, accountScope: accountScope,
                                 sessionID: sessionID).remove()
        ChatReaderPositionStore(instanceID: instanceID, accountScope: accountScope,
                                sessionID: sessionID).remove()
        ChatCellStateStore(instanceID: instanceID, accountScope: accountScope,
                           sessionID: sessionID).remove()
        if instanceID == historyInstanceID && accountScope == historyAccountScope {
            sessionTaskObservations.removeValue(forKey: sessionID)
            persistSessionTaskObservations(
                sessionTaskObservations,
                instanceID: instanceID,
                accountScope: accountScope
            )
        }
    }

    /// 按实例配置造后端。WebUI 实例走老路径；网关实例走 GatewayBackend，
    /// 未配置 WebUI 回落地址时附件/模型目录会被明确拒绝而不是静默失败。
    static func makeBackend(for instance: HermesInstance) -> HermesBackend {
        // 地址非法时不回落到任何硬编码主机——那会把 Bearer key 静默发给第三方。
        // 返回一个必然连不上的占位后端，让调用方以「无可用后端」失败并提示用户。
        guard let primary = normalizedBaseURL(instance.baseURL) else {
            return HermesAPI(baseURL: HermesInstance.invalidPlaceholderBaseURL)
        }
        switch instance.backend {
        case .webui:
            return HermesAPI(baseURL: primary)
        case .gateway:
            #if canImport(WebKit)
            guard let gateway = URL(string: primary) else {
                return HermesAPI(baseURL: HermesInstance.invalidPlaceholderBaseURL)
            }
            // Gateway instances no longer use WebUI as an implicit fallback.
            // Keep the deprecated stored field for lossless migration only.
            return GatewayBackend(gatewayBaseURL: gateway,
                                  apiKey: instance.apiKey,
                                  webuiBaseURL: nil,
                                  gatewayDataPath: instance.gatewayDataPath,
                                  recoveryScope: {
                                      let identity = ChatHistoryIdentity.instanceID(id: instance.id, baseURL: instance.baseURL)
                                      return identity + "|" + ChatHistoryIdentity.accountScope(instanceID: identity)
                                  }())
            #else
            // 离线测试目标不构造真实网关后端（它依赖 WebKit 版 HermesAPI）；
            // 网关路径本身由 tests/gateway 覆盖纯逻辑部分。
            return HermesAPI(baseURL: primary)
            #endif
        }
    }

    /// AttachmentPreviewPolicy 以 try! 构造且拒绝 query/fragment/.. 的 baseURL；
    /// 传给 HermesAPI 的地址必须先过同一约束，否则附件预览会崩溃。
    static func normalizedBaseURL(_ raw: String) -> String? {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        guard var c = URLComponents(string: u),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil,
              !c.path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            return nil
        }
        // 明文只允许局域网/本机（与 Info.plist 的 NSAllowsLocalNetworking 对齐）；
        // 公网明文一律拒绝，避免 Bearer key 在公网裸奔。
        if scheme == "http" && !isLocalHost(host) { return nil }
        c.query = nil
        c.fragment = nil
        return c.string
    }

    /// 判断主机是否为局域网/本机：localhost、.local、127.0.0.1、10/8、
    /// 172.16/12、192.168/16。只有这些允许明文 http。
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || a == 127
    }

    init(credentials: any InstanceCredentialStorage = InstanceCredentialStore(),
         sessionRefreshPolicy: SessionRefreshPolicy = .standard,
         sessionRefreshClock: SessionRefreshClock = SessionRefreshClock(),
         notifier: (any TaskNotificationDelivering)? = nil) {
        credentialStorage = credentials
        self.sessionRefreshPolicy = sessionRefreshPolicy
        self.sessionRefreshClock = sessionRefreshClock
        self.notifier = notifier ?? SystemNotificationDeliverer.shared
        let loaded = InstanceStore.loadResult(credentials: credentials)
        let list = loaded.instances
        instances = list
        let storedID = InstanceStore.activeID
        let idx = list.firstIndex { $0.id == storedID } ?? 0
        activeIndex = idx
        api = Self.makeBackend(for: list[idx])
        errorText = loaded.warning
        credentialWarning = loaded.warning
        let initialInstance = ChatHistoryIdentity.instanceID(id: list[idx].id, baseURL: list[idx].baseURL)
        lastSessionRefresh = sessionRefreshClock.lastSuccess(
            scope: initialInstance + "|" + ChatHistoryIdentity.accountScope(instanceID: initialInstance))
        loadCompletions()
        loadSessionTasks()
        resetTaskAcknowledgements()
        // F-45：首次挂载也要写入路由作用域，否则默认空串会与「第一个作用域」比较相等。
        publishRouteScope()
        // F-77：`RuntimeLogRecorder.canRead` 已改为 fail-closed（未配置 appScope 时
        // 一律拒绝跨作用域读取）。所以必须在任何读取之前登记当前作用域，否则
        // 冷启动到 `refresh()` 之间的日志会读不到。
        RuntimeLogRecorder.shared.configureAppScope(
            instanceID: historyInstanceID, accountScope: historyAccountScope)
    }

    func switchTo(_ index: Int) {
        switchTo(index, snapshotDeparting: true)
    }

    private func switchTo(_ index: Int, snapshotDeparting: Bool) {
        guard instances.indices.contains(index) else { return }
        homeTurnClaim.cancel()
        homeSendError = nil
        // Snapshot the departing scope before replacing the API. Local list
        // mutations (delete/archive/rename) must not be undone on return.
        // Deleting an instance can shrink `instances` before calling switchTo.
        // In that path activeIndex may refer to the removed last element.
        if snapshotDeparting && hasLoadedSessions && instances.indices.contains(activeIndex) {
            rememberSessionList(sessions, scope: sessionListScopeKey)
        }
        activeIndex = index
        // 比例缓存要等进入会话才用得上，先在后台把本作用域读进内存，
        // 避免会话首帧拿到空快照；读取本身不在主线程。
        ImageRatioStore.shared.preload(scope: historyInstanceID + "|" + historyAccountScope)
        RuntimeLogRecorder.shared.configureAppScope(
            instanceID: historyInstanceID, accountScope: historyAccountScope)
        InstanceStore.activeID = instances[index].id
        api = Self.makeBackend(for: instances[index])
        loadCompletions()
        loadSessionTasks()
        resetTaskAcknowledgements()
        let remembered = sessionListCache[sessionListScopeKey]
        sessions = remembered ?? []
        hasLoadedSessions = remembered != nil
        needsLogin = false
        errorText = nil
        // 换实例同样换了作用域：渲染缓存必须清（原先这里漏了，另两个入口都清）。
        resetScopeView()
        // A-09：自动刷新保存引用，下一次切换可以取消它。
        // 用 weak self 避免「任务未结束就永不释放」的环；`Task.isCancelled` 前置判断
        // 才能真正拦住「快速连点切实例时排队的旧刷新」——`cancel()` 只是置标志，
        // 不检查的话任务体照样会跑起来。
        scopeRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    enum AddInstanceResult {
        case success
        case failure(String)
    }

    /// 校验并落盘一个新实例。校验规则与历史保持一致（HTTPS、无凭证/查询/锚点/穿越），
    /// 网关额外要求 API key 非空——没有密钥连列表都拉不到，加进去只会一直报错。
    @discardableResult
    func addInstance(name: String, url: String, backend: BackendKind = .webui,
                     apiKey: String = "", webuiBaseURL: String = "",
                     gatewayDataPath: String = "") -> AddInstanceResult {
        // 失败时同时写 errorText：设置页的表单读返回值，其它调用点沿用旧的横幅提示，
        // 两条路径都不至于静默什么都不发生。
        func fail(_ message: String) -> AddInstanceResult {
            errorText = message
            return .failure(message)
        }
        // 必须先校验**原始**地址：normalize 会把 query/fragment 抹掉，
        // 那样 `?view=chat` 这种明显不合法输入反而会被静默接受。
        guard let primary = Self.validatedInstanceURL(url) else {
            return fail("请输入有效的实例地址（HTTP/HTTPS，不含账号密码、查询参数、锚点或路径穿越）。")
        }
        var fallback = ""
        if !webuiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let validated = Self.validatedInstanceURL(webuiBaseURL) else {
                return fail("WebUI 回落地址无效（HTTP/HTTPS，不含账号密码、查询参数、锚点或路径穿越）。")
            }
            fallback = validated
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if backend == .gateway, key.isEmpty {
            return fail("网关实例必须填 API_SERVER_KEY。")
        }
        if apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return fail("API 密钥不能包含换行或控制字符。")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 网关侧数据目录留空时用官方镜像默认值：两个容器挂同一个宿主机目录，
        // WebUI 侧是 ~/.hermes，网关侧是 /opt/data。附件路径靠它换算。
        let dataPath: String = {
            let raw = gatewayDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if backend != .gateway { return "" }
            if raw.isEmpty { return "/opt/data" }
            return raw.hasPrefix("/") ? raw : "/" + raw
        }()
        let newInstance = HermesInstance(name: trimmedName.isEmpty ? primary : trimmedName,
                                        baseURL: primary, backend: backend,
                                        apiKey: key, webuiBaseURL: fallback,
                                        gatewayDataPath: dataPath)
        // Replace only the inert first-launch record after secure persistence.
        // A failed save must leave the setup state available for another attempt.
        let replacingSetup = instances.count == 1 && instances[0].baseURL.isEmpty
            && instances[0].apiKey.isEmpty
        let updated = replacingSetup ? [newInstance] : instances + [newInstance]
        do {
            let warning = try InstanceStore.save(updated, credentials: credentialStorage)
            instances = updated
            if replacingSetup { switchTo(0, snapshotDeparting: false) }
            errorText = warning
            credentialWarning = InstanceStore.loadResult(credentials: credentialStorage).warning ?? warning
        } catch { return fail("无法安全保存实例：\(error.localizedDescription)") }
        return .success
    }

    /// Editing retains the instance UUID. A changed endpoint must explicitly
    /// receive a new key: never forward an old Bearer secret to another host.
    @discardableResult
    func editInstance(id: UUID, name: String, url: String,
                      replacementAPIKey: String = "",
                      gatewayDataPath: String = "") async -> AddInstanceResult {
        func fail(_ message: String) -> AddInstanceResult {
            errorText = message
            return .failure(message)
        }
        guard let index = instances.firstIndex(where: { $0.id == id }) else {
            return fail("实例不存在，原配置未更改。")
        }
        let initial = instances
        let old = initial[index]
        let token = activeChangeToken
        guard let primary = Self.validatedInstanceURL(url) else {
            return fail("请输入有效的实例地址（HTTP/HTTPS，不含账号密码、查询、锚点或路径穿越）。")
        }
        guard !replacementAPIKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return fail("API 密钥不能包含换行或控制字符。")
        }
        let newKey = replacementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointChanged = primary != old.baseURL
        if old.backend == .gateway && endpointChanged && newKey.isEmpty {
            return fail("网关地址变化时必须重新输入 API_SERVER_KEY，以免将旧密钥发送到新服务器。")
        }
        var edited = old
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.name = trimmedName.isEmpty ? primary : trimmedName
        edited.baseURL = primary
        if old.backend == .gateway {
            if !newKey.isEmpty { edited.apiKey = newKey }
            guard !edited.apiKey.isEmpty || (!endpointChanged && newKey.isEmpty) else {
                return fail("网关实例必须配置 API_SERVER_KEY。")
            }
            let dataPath = gatewayDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty editor field means "leave the legacy path unchanged";
            // rename-only edits must never reset an existing chat.
            edited.gatewayDataPath = dataPath.isEmpty ? old.gatewayDataPath
                : (dataPath.hasPrefix("/") ? dataPath : "/" + dataPath)
        }
        if edited == old {
            errorText = nil
            return .success
        }
        let keyChanged = edited.apiKey != old.apiKey
        if endpointChanged || keyChanged {
            // Verify before persisting; a failed request must not retire data.
            do {
                _ = try await SessionRefreshLoader.load(
                    api: Self.makeBackend(for: edited), policy: sessionRefreshPolicy)
            } catch {
                guard !Task.isCancelled else { return .failure("编辑已取消。") }
                return fail("新连接验证失败，原配置及本地数据已保留：\(error.localizedDescription)")
            }
        }
        // A remote probe may suspend while user switches/removes instances.
        guard !Task.isCancelled, activeChangeToken == token,
              instances == initial, instances.indices.contains(index),
              instances[index].id == id else {
            return .failure("实例已发生变化，请重新打开编辑页。")
        }
        var updated = initial
        updated[index] = edited
        let warning: String?
        do { warning = try InstanceStore.save(updated, credentials: credentialStorage) }
        catch { return fail("无法安全保存实例，原配置未更改：\(error.localizedDescription)") }
        let wasActive = activeIndex == index
        instances = updated
        credentialWarning = InstanceStore.loadResult(credentials: credentialStorage).warning ?? warning
        if wasActive {
            if keyChanged && !endpointChanged {
                // A different key may belong to another account. Reuse the
                // authenticated retirement path, not a naive backend replace.
                retireHistoryAccount()
                scopeRefreshTask = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh()
                }
            } else if endpointChanged || edited.gatewayDataPath != old.gatewayDataPath {
                // URL is part of the history identity. Do not snapshot stale
                // sessions under a different endpoint's account scope.
                switchTo(index, snapshotDeparting: false)
            }
        } else if keyChanged && !endpointChanged {
            // Same safety policy for inactive instances: rotate their old
            // account namespace and clean its durable pending data.
            let instance = ChatHistoryIdentity.instanceID(id: id, baseURL: primary)
            let account = ChatHistoryIdentity.rotate(instanceID: instance)
            GatewayRunStore.removeAll(instanceID: instance, accountScope: account)
            let scope = instance + "|" + account
            ImageRatioStore.shared.remove(scope: scope)
            ChatAttachmentPlaceholderStore.shared.removeScope(scope)
            RecentModelStore.shared.remove(scope: scope)
            sessionRefreshClock.remove(scope: scope)
            forgetSessionList(scope: scope)
            recordCleanupResult(ChatDraftStore.removeAll(
                instanceID: instance, accountScope: account))
            ChatReadingPositionStore.removeAll(instanceID: instance, accountScope: account)
            ChatReaderPositionStore.removeAll(instanceID: instance, accountScope: account)
            ChatCellStateStore.removeAll(instanceID: instance, accountScope: account)
            SessionTaskStore.remove(instanceID: instance, accountScope: account)
            removeTaskAcknowledgements(instanceID: instance, accountScope: account)
            trackCleanup(Task { [weak self] in
                let report = await ChatHistoryStore.remove(instanceID: instance, accountScope: account)
                self?.recordHistoryCleanupResult(report)
            })
        }
        errorText = warning
        return .success
    }

    /// 严格校验用户输入的地址并去掉尾部斜杠。与 `normalizedBaseURL` 的区别：
    /// 后者用于读取**已存**实例（允许剥 query 做兼容），这里用于**新输入**，
    /// 带 query/fragment/凭证/`..` 一律拒绝，避免把一个有歧义的地址写进配置。
    static func validatedInstanceURL(_ raw: String) -> String? {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        guard let c = URLComponents(string: u),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              !c.path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            return nil
        }
        // Creation and runtime transport must agree on the HTTP trust boundary.
        // A public cleartext URL must not be persisted as a usable instance.
        return normalizedBaseURL(u)
    }

    /// 实例列表必须至少保留一项；菜单据此禁用「移除实例」。
    /// 计算属性而非 @Published，避免为派生值再造一份可写状态。
    var canDeleteInstance: Bool { instances.count > 1 }

    func deleteInstance(at offsets: IndexSet) {
        // 删空后再补回默认实例会让用户以为删除失败，改为直接拒绝并给出反馈。
        guard canDeleteInstance else {
            errorText = "至少保留一个实例"
            return
        }
        let validOffsets = IndexSet(offsets.filter { instances.indices.contains($0) })
        guard !validOffsets.isEmpty else { return }
        var updated = instances
        updated.remove(atOffsets: validOffsets)
        guard !updated.isEmpty else { errorText = "至少保留一个实例"; return }
        let warning: String?
        do { warning = try InstanceStore.save(updated, credentials: credentialStorage) }
        catch { errorText = "无法移除实例：\(error.localizedDescription)"; return }
        let oldID = active.id
        // The old active index cannot be trusted after removing entries: a
        // shifted index may refer to a different host. Snapshot under the
        // stable pre-delete scope while the old instance array is intact.
        let activeWasDeleted = validOffsets.contains(activeIndex)
        if !activeWasDeleted && hasLoadedSessions {
            rememberSessionList(sessions, scope: sessionListScopeKey)
        }
        for index in validOffsets {
            let item = instances[index]
            let instance = ChatHistoryIdentity.instanceID(id: item.id, baseURL: item.baseURL)
            let previous = ChatHistoryIdentity.rotate(instanceID: instance)
            GatewayRunStore.removeAll(instanceID: instance)
            ImageRatioStore.shared.remove(scope: instance + "|" + previous)
            ChatAttachmentPlaceholderStore.shared.removeScope(instance + "|" + previous)
            RecentModelStore.shared.remove(scope: instance + "|" + previous)
            sessionRefreshClock.remove(scope: instance + "|" + previous)
            forgetSessionList(scope: instance + "|" + previous)
            recordCleanupResult(ChatDraftStore.removeAll(
                instanceID: instance, accountScope: previous))
            ChatReadingPositionStore.removeAll(instanceID: instance, accountScope: previous)
            ChatReaderPositionStore.removeAll(instanceID: instance, accountScope: previous)
            ChatCellStateStore.removeAll(instanceID: instance, accountScope: previous)
            // P1：任务信号与确认记录按同一作用域持久化，删除实例必须一并清掉，
            // 否则旧实例的「恢复需处理」与「已处理」标记会残留在本机——
            // 其他清理点（如 clearAll）已经做这一步，删除实例漏掉了。
            SessionTaskStore.remove(instanceID: instance, accountScope: previous)
            removeTaskAcknowledgements(instanceID: instance, accountScope: previous)
            // A-09：删除实例同样会退役一个作用域，清理任务一并登记引用。
            trackCleanup(Task { [weak self] in
            let result = await ChatHistoryStore.remove(instanceID: instance, accountScope: previous)
            self?.recordHistoryCleanupResult(result)
        })
        }
        instances = updated
        let next = instances.firstIndex { $0.id == oldID } ?? 0
        // Do not snapshot departing state a second time after changing
        // instances: the previous activeIndex may now identify another host.
        switchTo(next, snapshotDeparting: false)
        errorText = warning
        credentialWarning = InstanceStore.loadResult(credentials: credentialStorage).warning ?? warning
    }

    /// Blank setup records and invalid legacy addresses never issue requests.
    /// Credentials are checked separately once a user has configured an endpoint.
    var needsInstanceSetup: Bool {
        Self.normalizedBaseURL(active.baseURL) == nil
            || active.baseURL == HermesInstance.invalidPlaceholderBaseURL
    }

    func refresh() async {
        // 地址不可用：不发请求、不覆盖已有提示。
        // 直接返回，让 `init`/`loadResult` 写入的 warning 留在 `errorText` 上，
        // 首页显示的是「请在设置中添加网关地址与密钥」而不是一条 DNS 错误。
        if needsInstanceSetup {
            loadingSessions = false
            if errorText == nil { errorText = credentialWarning ?? Self.unconfiguredInstanceMessage }
            return
        }
        // A temporarily locked/unavailable Keychain is not a rejected API key.
        // Retry the local read without sending an empty Bearer credential or
        // retiring the still-valid account's drafts and recovery records.
        //
        // 顺序很重要：**先**尝试从钥匙串恢复，再判「确实没有密钥」。
        // 反过来的话，设备重启后未解锁时（内存里 apiKey 为空、但钥匙串里其实有）
        // 会被误判成「用户还没填」，于是提示去设置里重新输入——而用户什么都没做错。
        if active.backend == .gateway, active.apiKey.isEmpty, credentialWarning != nil {
            let loaded = InstanceStore.loadResult(credentials: credentialStorage)
            credentialWarning = loaded.warning
            guard let restored = loaded.instances.first(where: { $0.id == active.id }),
                  !restored.apiKey.isEmpty else {
                credentialWarning = loaded.warning ?? "暂时无法读取网关密钥，请解锁设备后下拉刷新重试。"
                errorText = credentialWarning
                return
            }
            instances[activeIndex].apiKey = restored.apiKey
            api = Self.makeBackend(for: active)
        }
        // 网关模式但确实还没有 API 密钥（从没填过）：不发请求。
        //
        // 空 Bearer 打到网关只会得到 401，然后 `fetchSessions` 会把 `needsLogin`
        // 置位、弹出登录页——而用户其实只是还没填密钥，不是登录态失效。
        // 这里给一条可直接操作的提示，一次网络都不发。
        if active.backend == .gateway, active.apiKey.isEmpty {
            loadingSessions = false
            let message = Self.missingAPIKeyMessage
            if errorText != message { errorText = message }
            return
        }
        ImageRatioStore.shared.preload(scope: historyInstanceID + "|" + historyAccountScope)
        // 应用级日志分区：登录/网络/缓存这类不归属任何会话的事件都写这里，
        // 因此在会话列表页打开设置也有内容可导出。
        RuntimeLogRecorder.shared.configureAppScope(
            instanceID: historyInstanceID, accountScope: historyAccountScope)
        // A pull gesture, footer button and initial page load can overlap. All
        // callers wait for the same real request instead of ending a spinner
        // early or repeatedly replacing the request's ownership generation.
        if let refreshTask { await refreshTask.value; return }
        let scope = actionScope
        let requestAPI = api
        let generation = UUID()
        refreshGeneration = generation
        loadingSessions = true
        errorText = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchSessions(api: requestAPI, scope: scope, generation: generation)
        }
        refreshTask = task
        await task.value
        if refreshGeneration == generation { refreshTask = nil }
    }

    private func invalidateListRefresh() {
        refreshGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func fetchSessions(api requestAPI: HermesBackend, scope: ActionScope, generation: UUID) async {
        defer { if refreshGeneration == generation, isCurrent(scope) { loadingSessions = false } }
        do {
            await requestAPI.syncCookiesFromWebKit()
            guard isCurrent(scope), refreshGeneration == generation, !Task.isCancelled else { return }
            let rows = try await SessionRefreshLoader.load(
                api: requestAPI, policy: sessionRefreshPolicy)
            guard isCurrent(scope), refreshGeneration == generation, !Task.isCancelled else { return }
            RuntimeLogRecorder.shared.recordApp(.info, "sessions", "ok count=\(rows.count)")
            needsLogin = false
            let next = rows.filter { $0.archived != true }
                .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
            markCompletions(previous: sessions, next: next)
            // Deleted/archived sessions must not accumulate for the account's lifetime.
            let live = Set(next.map(\.sessionId))
            if !completedSessionIDs.isSubset(of: live) {
                completedSessionIDs.formIntersection(live)
                persistCompletions()
            }
            let prunedTasks = SessionTaskCenter.prune(
                observations: sessionTaskObservations,
                liveSessionIDs: live
            )
            if prunedTasks != sessionTaskObservations {
                sessionTaskObservations = prunedTasks
                persistSessionTaskObservations(
                    prunedTasks,
                    instanceID: historyInstanceID,
                    accountScope: historyAccountScope
                )
            }
            sessions = next
            hasLoadedSessions = true
            rememberSessionList(next, scope: sessionListScopeKey)
            let refreshedAt = Date()
            sessionRefreshClock.recordSuccess(
                scope: historyInstanceID + "|" + historyAccountScope,
                at: refreshedAt)
            lastSessionRefresh = refreshedAt
        } catch is SessionRefreshTimeout {
            guard isCurrent(scope), refreshGeneration == generation, !Task.isCancelled else { return }
            errorText = sessions.isEmpty
                ? "请求超过时限，当前没有可保留的会话；下拉重试。"
                : "请求超过时限；列表仍显示上次成功刷新的内容。"
            RuntimeLogRecorder.shared.recordApp(.error, "sessions", "timeout")
        } catch {
            guard isCurrent(scope), refreshGeneration == generation,
                  !Task.isCancelled, !Self.isCancellation(error) else { return }
            errorText = error.localizedDescription
            if case APIError.http(let code, _) = error, code == 401 || code == 403 {
                needsLogin = true
            }
            RuntimeLogRecorder.shared.recordApp(.error, "sessions", "fail err=\(error.localizedDescription)")
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    func signIn(password: String) async {
        // 登录前**不**退役：密码错了就退役，等于一次输错清空本地草稿/历史。
        // 只有凭证被服务端接受之后才轮换账号域（见下方 login ok 分支）。
        let scope = actionScope
        let requestAPI = api
        do {
            try await requestAPI.login(password: password)
            guard isCurrent(scope), !Task.isCancelled else { return }
            RuntimeLogRecorder.shared.recordApp(.info, "auth", "login ok")
            retireHistoryAccount()
            needsLogin = false
            errorText = nil
            await refresh()
        } catch {
            guard isCurrent(scope), !Task.isCancelled else { return }
            errorText = error.localizedDescription
            RuntimeLogRecorder.shared.recordApp(.error, "auth", "login fail err=\(error.localizedDescription)")
        }
    }

    /// Correct the current gateway credential without requiring removal of an
    /// instance. **先用新密钥做只读探测，验证通过才保存并轮换账号域**——
    /// 密钥打错一个字符不能再清空草稿/历史。
    func updateGatewayAPIKey(_ value: String) async {
        guard active.backend == .gateway, !Task.isCancelled else { return }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { errorText = "请输入 API 密钥。"; return }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            errorText = "API 密钥不能包含换行或控制字符。"
            return
        }
        guard Self.normalizedBaseURL(active.baseURL) != nil else {
            errorText = "实例地址无效，请先修正网关地址。"
            return
        }
        // Bind a credential probe to the original instance and account generation.
        // Never use a mutable activeIndex after await: the user can switch or
        // remove instances while the probe is waiting on the network.
        let scope = actionScope
        let originalIndex = activeIndex
        let originalID = active.id
        var probeInstance = active
        probeInstance.apiKey = key
        let probe = Self.makeBackend(for: probeInstance)
        do {
            _ = try await probe.sessions()
            guard isCurrent(scope), !Task.isCancelled,
                  instances.indices.contains(originalIndex),
                  instances[originalIndex].id == originalID else { return }
        } catch {
            guard isCurrent(scope), !Task.isCancelled else { return }
            errorText = "API 密钥验证失败，本地数据已保留。请检查密钥或网关地址后重试。"
            RuntimeLogRecorder.shared.recordApp(.error, "credential", "probe fail err=\(error.localizedDescription)")
            return
        }
        var updated = instances
        updated[originalIndex].apiKey = key
        let warning: String?
        do { warning = try InstanceStore.save(updated, credentials: credentialStorage) }
        catch { errorText = "无法安全保存 API 密钥：\(error.localizedDescription)"; return }
        instances = updated
        credentialWarning = InstanceStore.loadResult(credentials: credentialStorage).warning ?? warning
        // 只有验证通过才轮换账号域、清理旧数据。
        retireHistoryAccount()
        needsLogin = false
        errorText = nil
        let newScope = actionScope
        await refresh()
        if isCurrent(newScope), !Task.isCancelled, errorText == nil { errorText = warning }
    }

    /// The paired WebUI cookie can select a different attachment account even
    /// when the gateway API key stays the same. Retire all old local references
    /// before rebuilding the backend that will perform future uploads.
    func didAuthenticateAttachmentWebUI() async {
        guard active.backend == .gateway, !Task.isCancelled else { return }
        retireHistoryAccount()
        await refresh()
    }

    /// First home message: create a server Session once, write its exact
    /// per-instance/account draft before changing the route, and then let
    /// NativeChatModel perform the ONLY chat POST after it has loaded.
    ///
    /// A crashed client can recover that saved draft manually. It must not
    /// infer that the first POST was absent and silently retry it.
    func createSessionForHomeTurn(_ text: String, model option: ModelOption?,
                                  sendImmediately: Bool = true) async -> Bool {
        let eligible = sendImmediately
            ? HomeTurnPolicy.canSubmit(text: text, creating: creating,
                                       needsSetup: needsInstanceSetup)
            : HomeTurnPolicy.canStartAttachment(creating: creating,
                                                needsSetup: needsInstanceSetup)
        guard eligible, !clearingHistory, !needsLogin else { return false }
        if let option {
            let count = modelCatalog?.options.filter { $0.model == option.model }.count ?? 0
            guard HomeTurnPolicy.modelIsUnambiguous(option.model, matchingCount: count) else {
                homeSendError = "同名模型无法区分 provider；请先新建会话，再选择模型。"
                return false
            }
        }
        let scope = actionScope
        let requestAPI = api
        let instanceID = historyInstanceID
        let accountScope = historyAccountScope
        let generation = UUID()
        createGeneration = generation
        creating = true
        homeSendError = nil
        defer { if createGeneration == generation { creating = false } }
        do {
            let sid = try await requestAPI.createSession(title: nil, model: option?.model)
            guard isCurrent(scope), createGeneration == generation,
                  !Task.isCancelled else { return false }
            let store = ChatDraftStore(instanceID: instanceID, accountScope: accountScope,
                sessionID: sid, legacyBaseURL: requestAPI.webConsoleBaseURL.absoluteString,
                fileStore: LocalDataFileStore(instanceID: instanceID,
                    accountScope: accountScope, sessionID: sid))
            let saved = store.save(text)
            guard saved.succeeded else {
                homeSendError = "会话已创建，但本地草稿保存失败；消息没有发送。请保留输入内容并检查设备存储。"
                return false
            }
            if sendImmediately {
                homeTurnClaim.arm(.init(instanceID: instanceID, accountScope: accountScope,
                                        sessionID: sid, text: text))
            } else {
                // Attachment intent stages a draft in the new Session; it must
                // NOT send it until the user has added attachments and taps Send.
                homeTurnClaim.cancel()
            }
            currentSessionID = sid
            return true
        } catch {
            guard isCurrent(scope), createGeneration == generation else { return false }
            // An uncertain session-creation HTTP response must not be retried
            // automatically. Unlike a chat POST, an empty orphan session is
            // harmless; retaining the user's text is the critical invariant.
            homeSendError = "新建会话未确认，消息未发送：\(error.localizedDescription)"
            return false
        }
    }

    func consumeHomeTurn(for sessionID: String) -> String? {
        guard currentSessionID == sessionID else { return nil }
        return homeTurnClaim.claim(instanceID: historyInstanceID,
                                  accountScope: historyAccountScope, sessionID: sessionID)
    }

    /// 新建失败明确报错，绝不退回网页或静默换会话。
    func createSession() async {
        guard !creating, !clearingHistory, !needsLogin else { return }
        homeTurnClaim.cancel()
        let scope = actionScope
        let requestAPI = api
        let generation = UUID()
        createGeneration = generation
        creating = true
        defer { if createGeneration == generation { creating = false } }
        do {
            let sid = try await requestAPI.createSession(title: nil, model: nil)
            guard isCurrent(scope), createGeneration == generation else { return }
            currentSessionID = sid
        } catch {
            guard isCurrent(scope), createGeneration == generation else { return }
            errorText = error.localizedDescription
        }
    }
}
