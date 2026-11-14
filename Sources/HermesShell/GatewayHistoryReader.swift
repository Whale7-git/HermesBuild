import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 单次 `read()` 的网络请求预算。
///
/// F-78：服务端 `has_more` 恒真（或分页永远不收敛）时，二分校准会变成请求放大器。
/// 给每次读取一个硬上限，超了抛明确错误，而不是把用户拖进几十次串行往返。
@MainActor
final class GatewayRequestBudget {
    private var remaining: Int
    let limit: Int

    init(limit: Int) { self.limit = limit; self.remaining = limit }

    func spend() throws {
        guard remaining > 0 else {
            throw APIError.http(429, "本次历史读取已发出 \(limit) 次请求仍未收敛，请稍后刷新重试")
        }
        remaining -= 1
    }
}

/// 一次 `count()` 里**二分**步数的上限。
///
/// F-60：原来二分没有上限，最坏 ~24 步，再乘外层 3 轮重试就是 70+ 次串行往返。
/// 现在每次校准最多 12 步二分（定界用的几次探测不计入，它们通常只有 1~2 次）。
/// 整次读取另由 `GatewayRequestBudget` 兜底 30 次请求。
enum GatewayProbeLimit {
    static let perCalibration = 12
}

/// 分页锚点的内存边界。
///
/// F-23：`anchors` / `sessionOrder` 是 `@MainActor` 上的字典，随会话数增长，
/// 原来这两个上限（64 / 256）是散在 `remember()` 里的字面量，淘汰行为也没有测试
/// 锁住。提成命名常量后，测试可以直接断言边界，不用猜实现里的魔数。
///
/// 不设 `private`：离线测试（`tests/gatewaybackend`）与本文件同处一个编译单元，
/// 断言要引用同一个常量，否则常量改小/改大时测试会跟着失效。属于「仅测试可见」
/// 的便利，业务代码不应依赖它。
enum GatewayAnchorLimits {
    /// 最多为多少个会话保留锚点。超限时按 `sessionOrder` 淘汰**最久没被写入**的那个
    /// （每次 `remember` 都会把该会话移到队尾，所以是「最近使用」序）。
    static let sessions = 64
    /// 单个会话最多保留多少个页起始锚点（超出时丢 offset 最小的那个）。
    static let anchorsPerSession = 256
}

/// Oldest-first offsets do not move when another device appends messages.
/// Metadata counts are hints only: the fetched window must establish its own end.
@MainActor
final class GatewayHistoryReader {
    private var anchors: [String: [Int: String]] = [:]
    private var sessionOrder: [String] = []
    /// 每个会话一把串行锁：`read()` 是 @MainActor async 且内部多次 await，
    /// 并发刷新会交错执行，后完成的 `remember()` 会覆盖先完成那次读到的锚点，
    /// 导致误报「历史已被修改」或把错页坐标提交给 UI。
    ///
    /// 早期实现用 `Task { _ = await previous?.value }` 做链，再把
    /// `readSerialized()` 放在链外——后发起的读取等完空壳就立刻开始，
    /// 与前一轮完全并发，串行化形同不存在。改用「先抢锁、再读、最后释放」：
    /// 锁的生命周期覆盖整段 `readSerialized()`，后来者必须真正等前一轮读完。
    ///
    /// 不用 `Task` 包住读取，是因为 `load` 是非逃逸参数，不能被逃逸闭包捕获。
    private var busy: Set<String> = []
    /// 每个会话的等待队列，按 FIFO 唤醒，避免后到者插队饿死先到者。
    private struct WaitingRead {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [String: [WaitingRead]] = [:]

    /// 单次读取最多发多少次网络请求（F-78）。正常路径 2~4 次；二分校准最多再花 12 次。
    private static let requestBudget = 30

    struct Window {
        let data: Data
        let offset: Int
    }

    /// Acquire one session's FIFO read permit. A cancelled waiter is removed
    /// immediately and its continuation is resumed with CancellationError.
    /// Cancellation racing with a grant must release the transferred permit.
    private func acquire(sessionID: String) async throws {
        try Task.checkCancellation()
        if !busy.contains(sessionID) {
            busy.insert(sessionID)
            return
        }
        let ticket = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[sessionID, default: []].append(
                    WaitingRead(ticket: ticket, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiting(sessionID: sessionID, ticket: ticket)
            }
        }
        // release() may have handed this permit to us just as we were
        // cancelled. At that point nobody else owns it until we release it.
        if Task.isCancelled {
            release(sessionID: sessionID)
            throw CancellationError()
        }
    }

    private func cancelWaiting(sessionID: String, ticket: UUID) {
        guard var queue = waiters[sessionID],
              let index = queue.firstIndex(where: { $0.ticket == ticket }) else { return }
        let waiter = queue.remove(at: index)
        waiters[sessionID] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(sessionID: String) {
        if var queue = waiters[sessionID], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[sessionID] = queue.isEmpty ? nil : queue
            // Ownership is transferred while busy remains true.
            next.continuation.resume()
        } else {
            busy.remove(sessionID)
        }
    }

    func read(sessionID: String, before: Int?, requests: GatewayRequests,
              load: (URLRequest) async throws -> Data) async throws -> Window {
        try await acquire(sessionID: sessionID)
        defer { release(sessionID: sessionID) }
        try Task.checkCancellation()
        return try await readSerialized(sessionID: sessionID, before: before,
                                        requests: requests, load: load)
    }

    private func readSerialized(sessionID: String, before: Int?, requests: GatewayRequests,
                                load: (URLRequest) async throws -> Data) async throws -> Window {
        let size = GatewayPaging.pageSize()
        let budget = GatewayRequestBudget(limit: Self.requestBudget)
        if let before {
            if before > 0, let anchor = anchors[sessionID]?[before] {
                let start = max(0, before - size)
                let rows = try await page(start: start, limit: before - start + 1,
                                          sessionID: sessionID, requests: requests,
                                          load: load, budget: budget)
                guard rows.list.count == before - start + 1,
                      identifier(rows.list.last) == anchor else {
                    throw GatewayDecodeError.malformed("历史已被修改，请刷新会话后再加载更早消息")
                }
                let list = Array(rows.list.dropLast())
                remember(list, start: start, sessionID: sessionID)
                return try window(root: rows.root, list: list, start: start)
            }

            // F-47：锚点只存在内存里，`switchTo` / 账号退役 / 密钥恢复都会重建
            // backend 并连带清空它。原来这里直接抛「分页位置已失效」，用户点一次
            // 「加载更早」就必然失败一次。现在降级：把 `before` 当 offset 直接读一页。
            //
            // 只接受「完整一页」：`count == before - start` 说明 [start, before) 这段
            // 在服务端真实存在，坐标可信。返回不满一页说明 before 已经越过真实尾部，
            // 这时按 start 标注 offset 会把错误的绝对坐标交给 UI（sourceIndex 全错），
            // 所以宁可放弃这一页、退回首次读取重新对齐。
            //
            // 已知取舍：没有锚点就没法校验「这一页的首行是不是当初那一行」。如果期间
            // 服务端删过中间的行，返回的窗口可能整体偏移。这是 F-47 要求的降级代价——
            // 下一次 `remember()` 会重建锚点，之后的翻页重新有校验。
            if before > 0 {
                let start = max(0, before - size)
                let rows = try await page(start: start, limit: before - start,
                                          sessionID: sessionID, requests: requests,
                                          load: load, budget: budget)
                if rows.list.count == before - start {
                    remember(rows.list, start: start, sessionID: sessionID)
                    return try window(root: rows.root, list: rows.list, start: start)
                }
            }
            // 落到下面的首次读取：before 无效或猜出来的页对不上，当作没有游标重读尾部。
        }

        try budget.spend()
        let metadata = try await load(requests.session(sessionID: sessionID))
        let root = try object(metadata)
        guard let session = root["session"] as? [String: Any],
              let number = session["message_count"] as? NSNumber,
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 16_777_216 else { throw APIError.badResponse }
        var total = number.intValue
        // 服务端自报的总数只信一次：如果按它取到的窗口仍然不是真正的尾部，
        // 说明这个 `total` 本身不可靠（缓存滞后 / 统计口径不同），下一轮必须
        // 回到客户端探测，否则会在同一个错误的 total 上原地重试三次再报错。
        var servedTotalUsed = false
        // At most two retries if compaction/truncation races the count probe.
        for _ in 0..<3 {
            let start = max(0, total - size)
            let rows = try await page(start: start, limit: size + 1,
                                      sessionID: sessionID, requests: requests,
                                      load: load, budget: budget)
            if rows.list.count <= size && (start == 0 || rows.list.count == size) {
                // <=60 from index zero, or exactly 60 with no 61st row: this is a real tail.
                remember(rows.list, start: start, sessionID: sessionID)
                var response = rows.root
                response["model"] = session["model"]
                response["model_provider"] = session["model_provider"]
                return try window(root: response, list: rows.list, start: start)
            }
            // F-60：服务端已经给了权威计数就不要再二分探测。`pagination.total`
            // 是本会话的总行数，比客户端逐条探测便宜一个数量级。
            if !servedTotalUsed, let served = Self.servedTotal(rows.root), served != total {
                servedTotalUsed = true
                total = served
                continue
            }
            if !rows.list.isEmpty && rows.list.count < size {
                total = start + rows.list.count
            } else {
                total = try await count(hint: total, sessionID: sessionID, requests: requests,
                                        load: load, budget: budget)
            }
        }
        throw GatewayDecodeError.malformed("历史正在变化，请稍后刷新")
    }

    /// 从分页响应里读服务端自报的总条数。没有就返回 nil，由调用方回退二分。
    ///
    /// 只认明确的整数字段：`pagination.total` 优先，其次是顶层 `total`。
    /// 负数或超出分页上界一律当没报，避免被畸形响应带偏。
    private static func servedTotal(_ root: [String: Any]) -> Int? {
        let candidates: [Any?] = [
            (root["pagination"] as? [String: Any])?["total"],
            root["total"]
        ]
        for raw in candidates {
            guard let raw, !(raw is NSNull) else { continue }
            let double: Double?
            if let number = raw as? NSNumber { double = number.doubleValue }
            else if let text = raw as? String { double = Double(text) }
            else { double = nil }
            guard let value = double, value.isFinite, value >= 0, value <= 16_777_216 else { continue }
            return Int(value)
        }
        return nil
    }

    private func count(hint: Int, sessionID: String, requests: GatewayRequests,
                       load: (URLRequest) async throws -> Data,
                       budget: GatewayRequestBudget) async throws -> Int {
        // F-60：二分步数上限 12（原实现无上限，最坏 ~24 步，再乘外层 3 轮重试
        // 就是 70+ 次串行往返；弱网下「加载更早消息」会长时间转圈）。
        //
        // 关键优化：先验证 `hint`（就是 `message_count`）本身。
        // - `hint` 不存在且 `hint-1` 存在 ⇒ 总数正好是 hint，**2 次探测**收工；
        // - `hint` 存在 ⇒ 从 hint 往上翻倍定界；
        // - 两者都不存在 ⇒ 往下的括号是 [0, hint-1]，再二分。
        // 这样常见路径（服务端计数准确）不再从 0 开始二分。
        //
        // 二分额度用尽时返回 `low`（已确认存在的下界）而不抛错：调用方会用这个
        // 值再取一页，只要不是真正的尾部就会再校准一轮，三轮都对不上才报错。
        // `low` 只会偏小，最坏多花一两次请求，不会把错误的窗口当成最新一屏。
        let anchor = max(0, hint)
        guard anchor > 0 else { return 0 }

        if try await exists(at: anchor, sessionID: sessionID, requests: requests,
                            load: load, budget: budget) {
            // 总数 > anchor：向上翻倍找上界。`low` 始终是「已确认存在 + 1」，
            // `high` 退出循环时一定是「已确认不存在」。
            var low = anchor + 1
            var high = min(16_777_216, anchor * 2)
            while try await exists(at: high, sessionID: sessionID, requests: requests,
                                   load: load, budget: budget) {
                guard high < 16_777_216 else {
                    throw APIError.http(413, "会话历史超出分页范围")
                }
                low = high + 1
                high = min(16_777_216, high * 2)
            }
            return try await binarySearch(low: low, high: high, sessionID: sessionID,
                                          requests: requests, load: load, budget: budget)
        }

        // anchor 不存在：anchor-1 存在就正好是 anchor 条。
        if try await exists(at: anchor - 1, sessionID: sessionID, requests: requests,
                            load: load, budget: budget) {
            return anchor
        }
        // 更小的总数（压缩 / 截断）：在 [0, anchor-1) 里二分，anchor-1 已确认不存在。
        return try await binarySearch(low: 0, high: anchor - 1, sessionID: sessionID,
                                      requests: requests, load: load, budget: budget)
    }

    /// 在 `[low, high)` 里二分，`high` 必须已确认不存在。
    /// 探测额度用尽时返回当前 `low`（保守下界，调用方会再校准）。
    private func binarySearch(low: Int, high: Int, sessionID: String, requests: GatewayRequests,
                              load: (URLRequest) async throws -> Data,
                              budget: GatewayRequestBudget) async throws -> Int {
        var low = low
        var high = high
        var steps = 0
        while low < high, steps < GatewayProbeLimit.perCalibration {
            steps += 1
            let middle = low + (high - low) / 2
            if try await exists(at: middle, sessionID: sessionID, requests: requests,
                                load: load, budget: budget) {
                low = middle + 1
            } else { high = middle }
        }
        return low
    }

    private func exists(at index: Int, sessionID: String, requests: GatewayRequests,
                        load: (URLRequest) async throws -> Data,
                        budget: GatewayRequestBudget) async throws -> Bool {
        try await !page(start: index, limit: 1, sessionID: sessionID, requests: requests,
                        load: load, budget: budget).list.isEmpty
    }

    private func page(start: Int, limit: Int, sessionID: String, requests: GatewayRequests,
                      load: (URLRequest) async throws -> Data,
                      budget: GatewayRequestBudget) async throws -> (root: [String: Any], list: [[String: Any]]) {
        try Task.checkCancellation()
        try budget.spend()
        let data = try await load(requests.messages(sessionID: sessionID, limit: limit, offset: start, order: "oldest"))
        let root = try object(data)
        guard let list = root["data"] as? [[String: Any]] else { throw APIError.badResponse }
        return (root, list)
    }

    private func remember(_ rows: [[String: Any]], start: Int, sessionID: String) {
        sessionOrder.removeAll { $0 == sessionID }
        sessionOrder.append(sessionID)
        // 会话数超限时按 `sessionOrder` 淘汰**最旧**的那个（FIFO，不是随机）：
        // 最久没被读过的会话，它的锚点最不可能再被用到。
        while sessionOrder.count > GatewayAnchorLimits.sessions {
            anchors.removeValue(forKey: sessionOrder.removeFirst())
        }
        if let first = identifier(rows.first) { anchors[sessionID, default: [:]][start] = first }
        if let bucket = anchors[sessionID], bucket.count > GatewayAnchorLimits.anchorsPerSession,
           let discard = bucket.keys.sorted().first(where: { $0 != start }) {
            anchors[sessionID]?.removeValue(forKey: discard)
        }
        // Keep bounded page anchors across refreshes: an overlapping export still needs its cursor.
    }

    /// 仅供离线测试：返回锚点表的只读快照。
    ///
    /// F-23：淘汰是内存边界的核心行为，但它只体现在私有状态里，从外部无法断言。
    /// 这里给测试一个**只读**视图（数组/字典都是值类型拷贝，改不动内部状态），
    /// 让「插 70 个会话后只剩 64 个、且被丢的是最早的」能被测试锁住。
    /// 生产代码不要调用它——它只是把内部结构暴露给断言用。
    func anchorSnapshotForTesting() -> (sessions: [String], anchorCounts: [String: Int]) {
        (sessionOrder, anchors.mapValues { $0.count })
    }

    /// 仅供离线测试：返回某个会话当前保留的锚点 offset，升序。
    ///
    /// F-23：`anchorsPerSession` 的淘汰方向（丢 offset 最小的那个）只体现在桶的
    /// 键集合里，计数快照看不出「丢的是哪一页」。这里同样只给只读拷贝。
    func anchorOffsetsForTesting(sessionID: String) -> [Int] {
        (anchors[sessionID]?.keys).map { Array($0).sorted() } ?? []
    }

    private func identifier(_ row: [String: Any]?) -> String? {
        guard let value = row?["id"] ?? row?["message_id"] else { return nil }
        if let text = value as? String { return text }
        return (value as? NSNumber)?.stringValue
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        return value
    }

    private func window(root: [String: Any], list: [[String: Any]], start: Int) throws -> Window {
        var root = root
        root["data"] = list
        return Window(data: try JSONSerialization.data(withJSONObject: root), offset: start)
    }
}
