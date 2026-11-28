import Foundation

// MARK: - 本文件的边界（写在最前面，因为它比任何实现细节都重要）
//
// `HistorySyncCoordinator` 只做一件事：把服务端权威历史搬到本地 transcript，
// 并记住「搬到哪了」「还差多少」「上次为什么没搬成」。
//
// 它**不是**状态机的所有者，所以：
//
// 1. 不修改 `Turn`（`TurnState.swift`），不产生 `TurnEvent`，不解释 Run 状态。
// 2. 不设置任何「能不能发送」的标志。本文件里没有 `canSend` / `blocksSend` /
//    `uncertain` / `locked`，一个都没有——历史同步失败**永远不阻塞发送**（G6）。
// 3. 不写 notice / error 文案。失败只落在一个**只读的** `status` 上，由 UI 自己
//    决定要不要显示「同步中」「稍后重试」。本类型的任何返回值都不含用户可见文案。
// 4. 不引用 `NativeChatModel`。依赖靠下面的协议 + 闭包反转：本文件只认识
//    「一页历史长什么样」和「怎么取下一车页」，不认识谁在用它。
//
// 唯一被允许的「状态」是新鲜度：`status` / `historyFresh` / `isSyncing` / `paging`。
// 它们只影响显示，不参与发送判定。
//
// 官方依据（`audit/refactor-official-guidance.md`）：
//
// - **G4** 终态与 `output` 是本地真相，status 在终态后只短暂保留。所以「终态已到、
//   正文还没落史」是正常窗口：`.backfill` 触发比普通刷新多给几次重试（正文必然存在，
//   只是历史写得慢），但仍不阻塞任何操作。
// - **G6** SSE 天生 attach/detach，断线重连是正常路径。同理，历史同步失败也只是
//   「这次没追上」，不是错误状态：不上锁、不提示、不进入任何「需要用户核对」的路径。
// - **G1/G2/G3** 属于 POST / Run 生命周期，不在本文件范围内。这里没有幂等重放，
//   也没有 `unknown`——历史是只读 GET，重试天然安全。

// MARK: - 依赖反转：三页纸的抽象

/// 一条历史消息在**合并算法**里需要的最小投影。
///
/// 刻意不含 `attachmentPaths` / `displayKind` / `delivery` 等渲染字段：合并只关心
/// 「这条是谁」「正文有没有变空」「它在原始 transcript 里的位置」。字段越少，
/// 越不容易在合并时把渲染态写回权威数据。
protocol HistorySyncMessage: Sendable {
    var id: String { get }
    var role: String { get }
    var content: String { get }
    /// 服务端原始 transcript 里的绝对下标（含不可见的工具行）。
    /// `nil` 表示本地乐观行，不能用来定位，也不该被服务端页面覆盖。
    var sourceIndex: Int? { get }
}

/// 一张工具卡片在合并算法里的最小投影。
protocol HistorySyncTool: Sendable {
    var id: String { get }
    var args: String { get }
    var result: String { get }
    var done: Bool { get }
    /// 这张卡挂在哪条消息之后。合并后锚点不存在时必须丢弃。
    var afterMessageID: String? { get }
}

/// 一页历史。`ChatSnapshot` 在文末直接适配，本类型不认识它。
protocol HistorySyncPage: Sendable {
    associatedtype Message: HistorySyncMessage
    associatedtype Tool: HistorySyncTool

    /// 这一页属于哪个会话。**合并前必须逐次核对**，这是防跨会话污染的第一道闸。
    var sessionID: String { get }
    var messages: [Message] { get }
    var tools: [Tool] { get }
    /// 本页第一条可见消息的绝对下标。翻页时把它当 `before` 往前要。
    var olderOffset: Int { get }
    /// 本页窗口的**开区间**结束下标（含不可见工具行）。
    var rawMessageEndIndex: Int { get }
    /// 服务端是否截断了这段历史（只上报，不解释）。
    var messagesTruncated: Bool { get }
}

/// 能报告「服务端建议等多久」的错误（G7 的 `Retry-After`）。
///
/// 只定义协议、不定义实现：`APIError` 在自己的文件里，本文件不去改它。
/// 谁拿到了响应头，谁就遵循这个协议；没遵循的错误退回指数退避。
protocol HistoryRetryAfterHinting {
    var retryAfterSeconds: TimeInterval? { get }
}

// MARK: - 小值类型

/// 为什么发起这次同步。只影响重试次数与日志，不影响任何判定。
enum HistorySyncTrigger: String, Equatable, Sendable {
    /// 首次进入会话。
    case initial
    /// 回前台。
    case foreground
    /// 一轮已到终态，正文还没落史，需要补齐（G4）。
    case backfill
    /// 用户手动刷新。
    case manual
}

/// 历史窗口在合并时的插入方向。
enum HistorySyncPlacement: String, Equatable, Sendable {
    /// 尾部刷新：新页与已有窗口重叠在末端。
    case tail
    /// 向前翻页：新页整体更早。
    case older

    /// 这次合并是否把内容插到了顶部（UI 需要保持滚动锚点）。
    var insertedOlder: Bool { self == .older }
}

/// 一次同步失败的性质。**只用于显示与诊断**，不参与发送判定。
struct HistorySyncFailure: Error, Equatable, Sendable {
    enum Cause: String, Equatable, Sendable {
        /// 网络/5xx/408/429：已按退避重试过，仍然失败。
        case transient
        /// 4xx（401/403/404/422…）：重试无益。
        case rejected
        /// 服务端返回了**别的会话**的历史。丢弃，绝不合并。
        case sessionMismatch
        /// 页面自相矛盾（负 offset、结束下标早于起始下标）。
        case invalidPage
    }

    let cause: Cause
    /// 仅在 `cause == .rejected` 时有值。
    let status: Int?
    /// 这次判定用掉了几次尝试（含第一次）。
    let attempts: Int

    var isRetryable: Bool { cause == .transient }
}

/// 尾部历史的新鲜度。**唯一**会变成 `historyFresh` 的东西。
enum HistorySyncStatus: Equatable, Sendable {
    /// 还没同步过，或刚被 `reset()`。
    case idle
    /// 同步在途。UI 可以显示「同步中」，但不该禁用任何按钮。
    case syncing
    /// 已经追上服务端当前窗口。
    case fresh
    /// 上次同步没成功；旧内容继续显示，可以重试。
    case stale(HistorySyncFailure)

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

/// 长历史分页的状态。与尾部新鲜度**正交**：翻页成功不证明尾部是新的。
enum HistorySyncPaging: Equatable, Sendable {
    case idle
    case loading
    /// 已经到第 0 条，或服务端不再给出新内容。
    case exhausted
    /// 这一页没取到。**游标不动**，重试还是同一页。
    case failed(HistorySyncFailure)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// 分页游标。`nil` 表示「还没观察到任何一页」，而不是「从 0 开始」。
///
/// 这个区别是分页进度保留的关键：首次刷新前不能假装已经加载到第 0 条，
/// 否则一次失败的冷启动会让「加载更早」永远要不到东西。
struct HistorySyncCursor: Equatable, Sendable {
    var olderOffset: Int? = nil
    var rawEndIndex: Int? = nil
    var exhausted: Bool = false

    static let empty = HistorySyncCursor()
}

/// 一次合并做了什么。全部是计数与坐标，**不含正文**，可以安全写进日志。
struct HistorySyncChange: Equatable, Sendable {
    let placement: HistorySyncPlacement
    let addedMessages: Int
    let updatedMessages: Int
    let addedTools: Int
    let updatedTools: Int
    /// 因为锚点消息不在窗口内而被丢弃的工具数。
    let droppedTools: Int
    let olderOffset: Int?
    let rawEndIndex: Int?
    /// 服务端这一页比已知窗口更短（压缩 / 迟到的旧响应）。内容没丢，只是要记一笔。
    let windowRegressed: Bool
    /// 累计观察到服务端截断（粘性，`reset()` 清除）。
    let messagesTruncated: Bool
    /// 已经到最早一条。
    let reachedStart: Bool
}

enum HistorySyncRefreshOutcome: Equatable, Sendable {
    case merged(HistorySyncChange)
    /// 被自己取消，或调用方 `cancel()` / `reset()`。
    case cancelled
    /// 被更新的一次刷新取代；结果已丢弃，状态由新的那次负责。
    case superseded
    case failed(HistorySyncFailure)
}

enum HistorySyncPagingOutcome: Equatable, Sendable {
    case merged(HistorySyncChange)
    /// 没有更早的了。
    case exhausted
    /// 还没拿到过任何一页，不知道从哪往前翻。
    case notReady
    /// 已经有一页在取。
    case alreadyLoading
    case cancelled
    case superseded
    case failed(HistorySyncFailure)
}

/// 重试策略。默认值与仓库既有约定一致（`HistoryLoadFailure` 注释里的 2s/5s/12s）。
struct HistorySyncPolicy: Sendable {
    /// 普通刷新最多尝试几次（含首次）。
    var maxAttempts = 3
    /// `.backfill` 的尝试次数：终态已到，正文必然存在，只是历史写得慢（G4）。
    var backfillAttempts = 5
    var initialBackoff: TimeInterval = 2
    var maxBackoff: TimeInterval = 12
    /// 读 `Retry-After`（G7）。关掉只在测试里需要。
    var honorsRetryAfter = true

    static let standard = HistorySyncPolicy()

    func attempts(for trigger: HistorySyncTrigger) -> Int {
        max(1, trigger == .backfill ? backfillAttempts : maxAttempts)
    }

    /// 第 `attempt` 次失败后等多久。`attempt` 从 1 开始。
    func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if honorsRetryAfter, let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return min(maxBackoff, retryAfter)
        }
        let exponent = min(max(attempt - 1, 0), 4)
        let scaled = initialBackoff * Double(1 << exponent)   // 2, 4, 8, 16, 32 …
        return min(maxBackoff, max(0, scaled))
    }
}

// MARK: - 同步器

/// 只读的历史同步器：后台刷新、长历史分页、失败重试、分页进度保留、合并去重。
///
/// 它持有**服务端已确认的历史**（`messages` / `tools`），不持有本地乐观行——
/// 后者按仓库既有约定永不进入确认历史（见 `ChatHistoryStore.Message.init`）。
/// 因此 UI 渲染的是 `coordinator.messages + 本地乐观行`，没有第二个真相源。
///
/// 用法（依赖注入就这一处）：
///
/// ```swift
/// let coordinator = HistorySyncCoordinator(sessionID: id) { sessionID, before in
///     try await service.history(sessionID: sessionID, before: before)
/// }
/// let outcome = await coordinator.refresh(trigger: .initial)
/// // 只把 outcome 里的计数用于日志；正文直接读 coordinator.messages
/// ```
///
/// 线程模型：整个类型在 `@MainActor` 上，合并与游标推进不会与其他 actor 交错。
/// 网络在 `await` 处让出，回来时用 `epoch` + `token` 双重核对，迟到的响应一律丢弃。
@MainActor
final class HistorySyncCoordinator<Page: HistorySyncPage> {

    typealias Message = Page.Message
    typealias Tool = Page.Tool
    /// `(sessionID, before)` → 一页历史。`before == nil` 表示要尾部窗口。
    typealias Loader = @MainActor (String, Int?) async throws -> Page
    /// 仅用于测试注入；生产走 `Task.sleep`。
    typealias Sleeper = @MainActor (TimeInterval) async throws -> Void
    typealias Diagnostics = @MainActor (String) -> Void

    let sessionID: String
    private let policy: HistorySyncPolicy
    private let loadPage: Loader
    private let sleeper: Sleeper?
    private let diagnostics: Diagnostics?

    /// 服务端已确认的消息，按 `sourceIndex` 升序，`sourceIndex == nil` 的排最后。
    private(set) var messages: [Message] = []
    /// 服务端已确认的工具卡片，锚点保证存在于 `messages` 里。
    private(set) var tools: [Tool] = []
    private(set) var cursor = HistorySyncCursor()
    /// 尾部新鲜度。**只影响显示**。
    private(set) var status: HistorySyncStatus = .idle
    /// 分页状态。与 `status` 正交。
    private(set) var paging: HistorySyncPaging = .idle
    /// 累计观察到服务端截断。粘性，`reset()` 清除。
    private(set) var messagesTruncated = false

    /// 最近一次**有结论**的尾部状态。取消同步时用它恢复，避免把「已追上」
    /// 误降级成「从没同步过」。
    private var settledStatus: HistorySyncStatus = .idle

    private struct RefreshFlight {
        let token: UUID
        let task: Task<HistorySyncRefreshOutcome, Never>
    }

    private struct PagingFlight {
        let token: UUID
        let task: Task<HistorySyncPagingOutcome, Never>
    }

    private var refreshFlight: RefreshFlight?
    private var pagingFlight: PagingFlight?
    /// 会话代次。`reset()` 推进；所有在途请求回来时都要核对。
    private var epoch: UInt64 = 0

    /// 内部失败通道：区分「失败」「被取消」「被取代」，避免让 `CancellationError`
    /// 混进「同步失败」——取消不是失败，不该把 `historyFresh` 打掉。
    private enum FlightError: Error {
        case cancelled
        case superseded
        case failed(HistorySyncFailure)
    }

    /// 页面自检失败。与网络错误分开，因为它**不可重试**。
    private enum PageRejection: Error {
        case sessionMismatch
        case invalidPage
    }

    init(sessionID: String,
         policy: HistorySyncPolicy = .standard,
         loadPage: @escaping Loader,
         sleeper: Sleeper? = nil,
         diagnostics: Diagnostics? = nil) {
        self.sessionID = sessionID
        self.policy = policy
        self.loadPage = loadPage
        self.sleeper = sleeper
        self.diagnostics = diagnostics
    }

    // MARK: - 只读派生（全部只影响显示）

    /// 历史是否已经追上服务端当前窗口。**不参与发送判定。**
    var historyFresh: Bool { status.isFresh }

    /// UI 是否该显示「同步中」。翻页也算，但两者都**不该禁用输入**。
    var isSyncing: Bool { status.isSyncing || paging.isLoading }

    var hasMoreOlder: Bool {
        guard !cursor.exhausted, let older = cursor.olderOffset else { return false }
        return older > 0
    }

    var messageCount: Int { messages.count }
    var isEmpty: Bool { messages.isEmpty }

    // MARK: - 生命周期

    /// 会话切换、登出、显式清空。推进代次，让所有在途响应失效。
    func reset() {
        epoch &+= 1
        refreshFlight?.task.cancel()
        pagingFlight?.task.cancel()
        refreshFlight = nil
        pagingFlight = nil
        messages = []
        tools = []
        cursor = .empty
        messagesTruncated = false
        settledStatus = .idle
        status = .idle
        paging = .idle
    }

    /// 取消在途同步，但保留已合并的内容与游标。
    ///
    /// 失败路径都靠 `epoch`/`token` 兜底，所以这里只是尽早停掉请求、顺手把
    /// 「同步中」收回成上一次的结论。
    func cancel() {
        epoch &+= 1
        refreshFlight?.task.cancel()
        pagingFlight?.task.cancel()
        refreshFlight = nil
        pagingFlight = nil
        status = settledStatus
        if paging.isLoading { paging = .idle }
    }

    /// 用调用方**已经确认过**的窗口坐标初始化游标（例如冷启动读到的缓存记录），
    /// 让「加载更早」在首次联网刷新之前就能工作。
    ///
    /// 只在还没有任何合并结果时生效。有内容之后坐标由本类型自己维护，
    /// 外部再写就会破坏「进度只前进」的保证。
    @discardableResult
    func seed(cursor value: HistorySyncCursor) -> Bool {
        guard messages.isEmpty, tools.isEmpty, cursor == .empty else { return false }
        cursor = value
        return true
    }

    // MARK: - 尾部刷新

    /// 拉取尾部窗口并合并。多次调用时**后一次取代前一次**（旧请求会被真正取消）。
    @discardableResult
    func refresh(trigger: HistorySyncTrigger = .manual) async -> HistorySyncRefreshOutcome {
        refreshFlight?.task.cancel()
        let token = UUID()
        let epoch = self.epoch
        status = .syncing
        let task = Task { @MainActor in
            await self.performRefresh(token: token, epoch: epoch, trigger: trigger)
        }
        refreshFlight = RefreshFlight(token: token, task: task)
        let outcome = await task.value
        if refreshFlight?.token == token { refreshFlight = nil }
        return outcome
    }

    private func performRefresh(token: UUID, epoch: UInt64,
                                trigger: HistorySyncTrigger) async -> HistorySyncRefreshOutcome {
        guard isCurrent(token: token, epoch: epoch) else { return .superseded }
        diagnostics?("history refresh start trigger=\(trigger.rawValue)")
        do {
            let page = try await fetch(before: nil, attempts: policy.attempts(for: trigger),
                                       token: token, epoch: epoch)
            guard isCurrent(token: token, epoch: epoch) else { return .superseded }
            let change = apply(page: page, placement: .tail)
            settle(.fresh)
            diagnostics?("history refresh ok added=\(change.addedMessages)"
                + " updated=\(change.updatedMessages) regressed=\(change.windowRegressed)")
            return .merged(change)
        } catch let error as FlightError {
            switch error {
            case .cancelled:
                if isCurrent(token: token, epoch: epoch) { status = settledStatus }
                return .cancelled
            case .superseded:
                return .superseded
            case .failed(let failure):
                guard isCurrent(token: token, epoch: epoch) else { return .superseded }
                settle(.stale(failure))
                diagnostics?("history refresh fail cause=\(failure.cause.rawValue)"
                    + " status=\(failure.status.map { String($0) } ?? "none")"
                    + " attempts=\(failure.attempts)")
                return .failed(failure)
            }
        } catch {
            // `fetch` 只抛 `FlightError`；这里保留一条兜底，不吞掉任何东西。
            guard isCurrent(token: token, epoch: epoch) else { return .superseded }
            let failure = HistorySyncFailure(cause: .invalidPage, status: nil, attempts: 1)
            settle(.stale(failure))
            return .failed(failure)
        }
    }

    // MARK: - 长历史分页

    /// 往前翻一页。同一时刻只允许一页在途（`alreadyLoading`）。
    ///
    /// 失败时**游标不动**：下一次调用还是同一页，这就是分页进度保留。
    @discardableResult
    func loadOlder() async -> HistorySyncPagingOutcome {
        guard let before = cursor.olderOffset else { return .notReady }
        guard before > 0, !cursor.exhausted else {
            paging = .exhausted
            return .exhausted
        }
        if let flight = pagingFlight, !flight.task.isCancelled { return .alreadyLoading }
        let token = UUID()
        let epoch = self.epoch
        paging = .loading
        let task = Task { @MainActor in
            await self.performPaging(token: token, epoch: epoch, before: before)
        }
        pagingFlight = PagingFlight(token: token, task: task)
        let outcome = await task.value
        if pagingFlight?.token == token { pagingFlight = nil }
        return outcome
    }

    private func performPaging(token: UUID, epoch: UInt64,
                               before: Int) async -> HistorySyncPagingOutcome {
        guard isCurrent(token: token, epoch: epoch) else { return .superseded }
        do {
            let page = try await fetch(before: before, attempts: policy.maxAttempts,
                                       token: token, epoch: epoch)
            guard isCurrent(token: token, epoch: epoch) else { return .superseded }
            let change = apply(page: page, placement: .older)
            // 一页既没带来新消息、也没把游标推前，说明服务端在原地打转。
            // 停在这里，不要变成请求放大器（F-78 的同类陷阱）。
            let progressed = change.addedMessages > 0 || (change.olderOffset ?? before) < before
            paging = (change.reachedStart || !progressed) ? .exhausted : .idle
            diagnostics?("history paging ok added=\(change.addedMessages)"
                + " older=\(change.olderOffset.map { String($0) } ?? "none")"
                + " reached=\(change.reachedStart)")
            return .merged(change)
        } catch let error as FlightError {
            switch error {
            case .cancelled:
                if isCurrent(token: token, epoch: epoch) { paging = .idle }
                return .cancelled
            case .superseded:
                return .superseded
            case .failed(let failure):
                guard isCurrent(token: token, epoch: epoch) else { return .superseded }
                // 注意：只动 `paging`，不动 `status`。翻页失败不抹掉尾部新鲜度。
                paging = .failed(failure)
                diagnostics?("history paging fail cause=\(failure.cause.rawValue)"
                    + " attempts=\(failure.attempts)")
                return .failed(failure)
            }
        } catch {
            guard isCurrent(token: token, epoch: epoch) else { return .superseded }
            let failure = HistorySyncFailure(cause: .invalidPage, status: nil, attempts: 1)
            paging = .failed(failure)
            return .failed(failure)
        }
    }

    // MARK: - 取页 + 重试

    private func fetch(before: Int?, attempts: Int,
                       token: UUID, epoch: UInt64) async throws -> Page {
        var attempt = 0
        while true {
            if Task.isCancelled { throw FlightError.cancelled }
            guard isCurrent(token: token, epoch: epoch) else { throw FlightError.superseded }
            attempt += 1
            do {
                let page = try await loadPage(sessionID, before)
                if Task.isCancelled { throw FlightError.cancelled }
                guard isCurrent(token: token, epoch: epoch) else { throw FlightError.superseded }
                try Self.validate(page, expecting: sessionID)
                return page
            } catch let error as FlightError {
                throw error
            } catch is CancellationError {
                // 取消不是失败：不重试、不改新鲜度。
                throw FlightError.cancelled
            } catch let rejection as PageRejection {
                // 页面自检失败是确定性失败，重试只会拿到同样的东西。
                throw FlightError.failed(Self.failure(from: rejection, attempts: attempt))
            } catch {
                let failure = Self.failure(from: error, attempts: attempt)
                guard failure.isRetryable, attempt < attempts else {
                    throw FlightError.failed(failure)
                }
                let hint = (error as? HistoryRetryAfterHinting)?.retryAfterSeconds
                let delay = policy.delay(afterAttempt: attempt, retryAfter: hint)
                diagnostics?("history retry attempt=\(attempt) delay=\(Int(delay))")
                do {
                    try await pause(delay)
                } catch {
                    throw FlightError.cancelled
                }
            }
        }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        if let sleeper {
            try await sleeper(seconds)
            return
        }
        let clamped = min(max(0, seconds), 300)
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }

    private func isCurrent(token: UUID, epoch: UInt64) -> Bool {
        guard self.epoch == epoch else { return false }
        return refreshFlight?.token == token || pagingFlight?.token == token
    }

    // MARK: - 页面自检

    /// 三道闸，任何一道不过都**不合并**：
    ///
    /// 1. 会话必须对得上（防跨会话污染）。
    /// 2. `olderOffset` 不能为负（负坐标会污染游标）。
    /// 3. 窗口结束下标不能早于起始下标（自相矛盾的一页）。
    private static func validate(_ page: Page, expecting sessionID: String) throws {
        guard page.sessionID == sessionID else { throw PageRejection.sessionMismatch }
        guard page.olderOffset >= 0,
              page.rawMessageEndIndex >= page.olderOffset else { throw PageRejection.invalidPage }
    }

    private static func failure(from rejection: PageRejection, attempts: Int) -> HistorySyncFailure {
        switch rejection {
        case .sessionMismatch:
            return HistorySyncFailure(cause: .sessionMismatch, status: nil, attempts: attempts)
        case .invalidPage:
            return HistorySyncFailure(cause: .invalidPage, status: nil, attempts: attempts)
        }
    }

    /// 复用 `HistoryLoadFailure` 的分类：5xx / 408 / 429 / 网络错误是暂时性，
    /// 其余 4xx 与契约错误是确定性失败。`CancellationError` 已在上面单独拦掉。
    private static func failure(from error: Error, attempts: Int) -> HistorySyncFailure {
        let status = (error as? HTTPStatusProviding)?.httpStatusHint
        switch HistoryLoadFailure.classify(error) {
        case .transient:
            return HistorySyncFailure(cause: .transient, status: status, attempts: attempts)
        case .permanent:
            if let status, (400...499).contains(status) {
                return HistorySyncFailure(cause: .rejected, status: status, attempts: attempts)
            }
            return HistorySyncFailure(cause: .invalidPage, status: status, attempts: attempts)
        }
    }

    // MARK: - 合并

    /// 把一页并进已确认历史，推进游标，返回变更计数。
    ///
    /// 四条硬规则：
    /// - **去重**：主键是 `id`。同一 `id` 只留一份。
    /// - **防回退**：`olderOffset` 只减不增，`rawEndIndex` 只增不减；正文不会因为
    ///   一次「还没写完」的刷新被清空；工具卡的完成态与结果不会被空值覆盖。
    /// - **防跨会话污染**：页面 `sessionID` 已在 `validate` 里核对过；`reset()` 还会
    ///   推进代次，让在途的旧会话响应直接作废。
    /// - **不删行**：尾部刷新永远不做「服务端没有的就删掉」。历史是显示用的，
    ///   删行会打断滚动锚点；真要清空走 `reset()`。
    private func apply(page: Page, placement: HistorySyncPlacement) -> HistorySyncChange {
        let previousOlderOffset = cursor.olderOffset
        let previousRawEnd = cursor.rawEndIndex

        let messageMerge = Self.mergeRows(
            current: messages,
            incoming: page.messages,
            placement: placement,
            id: { $0.id },
            sourceIndex: { $0.sourceIndex },
            prefer: { Self.preferredMessage($0, $1) })

        let toolMerge = Self.mergeRows(
            current: tools,
            incoming: page.tools,
            placement: placement,
            id: { $0.id },
            sourceIndex: { _ in nil },
            prefer: { Self.preferredTool($0, $1) })

        // 锚点已经不在窗口里的工具卡不能留：它会被渲染到错误的轮次上。
        let visibleIDs = Set(messageMerge.rows.map { $0.id })
        let keptTools = toolMerge.rows.filter { tool in
            guard let anchor = tool.afterMessageID else { return true }
            return visibleIDs.contains(anchor)
        }

        messages = messageMerge.rows
        tools = keptTools

        let olderOffset = Self.lower(previousOlderOffset, page.olderOffset)
        let rawEndIndex = Self.higher(previousRawEnd, page.rawMessageEndIndex)
        let regressed = previousRawEnd.map { page.rawMessageEndIndex < $0 } ?? false
        let reachedStart = olderOffset <= 0
        cursor = HistorySyncCursor(olderOffset: olderOffset,
                                   rawEndIndex: rawEndIndex,
                                   exhausted: cursor.exhausted || reachedStart)
        if page.messagesTruncated { messagesTruncated = true }

        return HistorySyncChange(
            placement: placement,
            addedMessages: messageMerge.added,
            updatedMessages: messageMerge.updated,
            addedTools: toolMerge.added,
            updatedTools: toolMerge.updated,
            droppedTools: toolMerge.rows.count - keptTools.count,
            olderOffset: olderOffset,
            rawEndIndex: rawEndIndex,
            windowRegressed: regressed,
            messagesTruncated: messagesTruncated,
            reachedStart: reachedStart)
    }

    /// 通用的「并集 + 去重 + 排序」合并。
    ///
    /// 排序键是 `(sourceIndex ?? Int.max, 首次出现顺序)`。第二个键让排序在全 nil
    /// 索引的页面上仍然是确定的（Swift 的 `sort` 不保证稳定）。
    private static func mergeRows<Row>(
        current: [Row],
        incoming: [Row],
        placement: HistorySyncPlacement,
        id: (Row) -> String,
        sourceIndex: (Row) -> Int?,
        prefer: (Row, Row) -> (value: Row, replaced: Bool)
    ) -> (rows: [Row], added: Int, updated: Int) {

        var byID: [String: Row] = [:]
        var ordinals: [String: Int] = [:]
        var order: [String] = []

        func register(_ value: Row) {
            let key = id(value)
            guard byID[key] == nil else { return }
            byID[key] = value
            ordinals[key] = order.count
            order.append(key)
        }

        var currentIDs = Set<String>()
        for value in current { currentIDs.insert(id(value)) }

        switch placement {
        case .tail:
            for value in current { register(value) }
            for value in incoming { register(value) }
        case .older:
            for value in incoming { register(value) }
            for value in current { register(value) }
        }

        var added = 0
        var updated = 0
        var seenIncoming = Set<String>()
        for value in incoming {
            let key = id(value)
            let isNewHere = seenIncoming.insert(key).inserted
            if isNewHere && !currentIDs.contains(key) { added += 1 }
            // 只有「本来就存在」的行才算更新；新行已经在 register 里就位。
            guard currentIDs.contains(key), let existing = byID[key] else { continue }
            let choice = prefer(existing, value)
            if choice.replaced {
                byID[key] = choice.value
                updated += 1
            }
        }

        let rows = order.compactMap { key -> Row? in byID[key] }
            .sorted { lhs, rhs in
                let left = sourceIndex(lhs) ?? Int.max
                let right = sourceIndex(rhs) ?? Int.max
                if left != right { return left < right }
                return (ordinals[id(lhs)] ?? Int.max) < (ordinals[id(rhs)] ?? Int.max)
            }
        return (rows, added, updated)
    }

    /// 同一条消息的两份副本选哪份。
    ///
    /// 默认**服务端赢**（它是权威），只有三种情况保留本地这份：
    /// - 本地有服务端下标、新副本没有（新副本定不了位）；
    /// - 本地有可见正文、新副本是空的（典型场景：服务端行还没写完，或者这一页
    ///   只带了元数据。不能让一次刷新把已经显示的回复清空）；
    /// - 同一个 `id` 的角色变了（契约被违反，保持屏幕上那一份，避免角色闪跳）。
    private static func preferredMessage(_ existing: Message,
                                         _ incoming: Message) -> (value: Message, replaced: Bool) {
        if existing.sourceIndex != nil && incoming.sourceIndex == nil {
            return (existing, false)
        }
        if existing.role != incoming.role {
            return (existing, false)
        }
        if hasVisibleText(existing.content) && !hasVisibleText(incoming.content) {
            return (existing, false)
        }
        return (incoming, true)
    }

    /// 工具卡的完成态与结果只前进不后退：流式期间的半成品不能覆盖已落定的完整结果。
    private static func preferredTool(_ existing: Tool,
                                      _ incoming: Tool) -> (value: Tool, replaced: Bool) {
        if existing.done && !incoming.done { return (existing, false) }
        if !existing.result.isEmpty && incoming.result.isEmpty { return (existing, false) }
        if !existing.args.isEmpty && incoming.args.isEmpty { return (existing, false) }
        return (incoming, true)
    }

    /// 便宜的「有没有东西可看」判定，只用来防止「有内容被空内容覆盖」。
    ///
    /// 它**不是**渲染判定：零宽字符、控制字符这些交给 `ChatRenderableText`。
    /// 这里只需要一个不会误删正文的保守下界。
    private static func hasVisibleText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 游标只减不增（越往前越小）。首次观察时直接采用页面值。
    private static func lower(_ known: Int?, _ candidate: Int) -> Int {
        min(known ?? candidate, candidate)
    }

    /// 窗口结束下标只增不减（防迟到/更短的响应把高水位打回去）。
    private static func higher(_ known: Int?, _ candidate: Int) -> Int {
        max(known ?? candidate, candidate)
    }

    // MARK: - 状态落定

    private func settle(_ value: HistorySyncStatus) {
        settledStatus = value
        status = value
    }
}

// MARK: - 适配既有类型
//
// 这三个 extension 是**唯一**与具体模型耦合的地方，且都只做「把已有属性对上协议」，
// 不改任何类型的行为。如果某个离线套件要单独编译本文件，把这一段排除即可。

extension ChatMessage: HistorySyncMessage {}

extension ChatTool: HistorySyncTool {}

extension ChatSnapshot: HistorySyncPage {}
