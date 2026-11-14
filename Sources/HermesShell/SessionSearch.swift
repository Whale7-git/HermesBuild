import Foundation
#if canImport(Combine)
import Combine
#endif

/// 本地过滤出的命中项（网关模式用）：服务端搜不了，就在客户端筛完再包成同一种类型，
/// 上层的搜索结果界面不需要区分数据是远端搜的还是本地筛的。
extension SessionSearchHit {
    init(session: SessionSummary, matchType: String?, preview: String?) {
        self.init(session: session, matchTypeValue: matchType, previewValue: preview)
    }

    private init(session: SessionSummary, matchTypeValue: String?, previewValue: String?) {
        self.session = session
        self.matchType = matchTypeValue
        self.preview = previewValue
    }
}

struct SessionSearchHit: Identifiable, Decodable {
    let session: SessionSummary
    let matchType: String?
    let preview: String?
    var id: String { session.sessionId }
    private enum CodingKeys: String, CodingKey { case matchType = "match_type", preview = "match_preview" }
    init(from decoder: Decoder) throws {
        session = try SessionSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchType = try c.decodeIfPresent(String.self, forKey: .matchType)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
    }
}

enum SessionDiscoveryError: LocalizedError {
    case invalidResponse
    case invalidRequest
    /// 当前后端没有搜索/归档能力（例如未配置回落 WebUI 的网关实例）。
    case unsupported
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器会话响应不完整，请刷新重试。"
        case .invalidRequest: return "搜索词或分页参数无效，请刷新重试。"
        case .unsupported: return "当前后端不支持搜索与归档。"
        }
    }
}

struct SessionSearchResponse {
    let hits: [SessionSearchHit]

    /// 本地筛出的结果（网关模式）。走同一个类型，界面不用分叉。
    init(hits: [SessionSearchHit]) {
        self.hits = hits
    }
    init(data: Data) throws {
        struct Envelope: Decodable { let sessions: [SessionSearchHit]; let count: Int }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.count == value.sessions.count,
              value.sessions.allSatisfy({ !$0.id.isEmpty }) else { throw SessionDiscoveryError.invalidResponse }
        var seen = Set<String>()
        hits = value.sessions.filter { seen.insert($0.id).inserted }
    }
}

@MainActor final class SessionSearchModel: ObservableObject {
    @Published private(set) var hits: [SessionSearchHit] = []
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?
    @Published private(set) var scope = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var activeQuery = ""
    private let debounce: () async throws -> Void

    init(debounce: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 350_000_000) }) {
        self.debounce = debounce
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        activeQuery = ""
        hits = []
        loading = false
        errorText = nil
    }

    @discardableResult
    func update(query: String, scope: String, service: SessionDiscoveryService,
                debounced: Bool = true, preserveResults: Bool = true) -> Task<Void, Never>? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 输入过程中（同一 scope 内关键词被延伸或回退）保留上一批结果，
        // 避免每敲一个字符整表闪白；换 scope 或换成另一个词才真正清空。
        let retained = preserveResults && !q.isEmpty && self.scope == scope
            && Self.refines(q, activeQuery) ? hits : []
        cancel()
        self.scope = scope
        hits = retained
        guard !q.isEmpty else { return nil }
        activeQuery = q
        let ticket = generation
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == ticket { self.loading = false; self.task = nil }
            }
            do {
                if debounced { try await self.debounce() }
                try Task.checkCancellation()
                let result = try await service.searchSessions(query: q)
                guard self.generation == ticket, self.scope == scope, !Task.isCancelled else { return }
                self.hits = result.hits
            } catch {
                guard self.generation == ticket, !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
            }
        }
        return task
    }

    /// 同一次输入的两个状态互为前缀（继续敲字或退格）才算「同一个查询」。
    /// 换成另一个词视为语义变化，立即清空旧结果，避免把无关命中当成结果。
    private static func refines(_ candidate: String, _ previous: String) -> Bool {
        guard !previous.isEmpty else { return false }
        return candidate.hasPrefix(previous) || previous.hasPrefix(candidate)
    }

    /// Pull/footer refresh awaits the actual current search, including an
    /// already-running request for this scope. A new request skips typing debounce.
    func refresh(query: String, scope: String, service: SessionDiscoveryService) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.scope == scope, activeQuery == q, let task { await task.value; return }
        await update(query: query, scope: scope, service: service, debounced: false, preserveResults: true)?.value
    }
}

@MainActor final class SessionArchiveModel: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?
    @Published private(set) var scope = ""
    @Published private(set) var total = 0
    @Published private(set) var nextOffset: Int? = 0
    private var generation = UUID()
    private var reloadTask: Task<Void, Never>?
    private let pageSize: Int

    init(pageSize: Int = 40) { self.pageSize = pageSize }

    func reset() {
        generation = UUID()
        reloadTask?.cancel()
        reloadTask = nil
        sessions = []
        loading = false
        errorText = nil
        total = 0
        nextOffset = 0
    }

    func reload(scope: String, service: SessionDiscoveryService) async {
        if self.scope == scope, let reloadTask { await reloadTask.value; return }
        if self.scope != scope { reset() }
        else {
            // Retain the visible archive while re-reading page zero. The new
            // generation rejects any older load-more response; page zero only
            // replaces these rows once its own GET succeeds.
            generation = UUID()
            reloadTask?.cancel()
            reloadTask = nil
            loading = false
            errorText = nil
            nextOffset = 0
        }
        self.scope = scope
        let ticket = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadMore(service: service)
        }
        reloadTask = task
        await task.value
        if generation == ticket { reloadTask = nil }
    }

    func loadMore(service: SessionDiscoveryService) async {
        guard !loading, let offset = nextOffset else { return }
        let ticket = generation
        loading = true
        errorText = nil
        defer { if generation == ticket { loading = false } }
        do {
            let page = try await service.archivedSessions(offset: offset, limit: pageSize)
            guard generation == ticket, !Task.isCancelled else { return }
            guard page.offset == offset, page.limit == pageSize else { throw SessionDiscoveryError.invalidResponse }
            var seen = offset == 0 ? Set<String>() : Set(sessions.map(\.sessionId))
            let rows = page.sessions.filter { seen.insert($0.sessionId).inserted }
            if offset == 0 { sessions = rows }
            else { sessions.append(contentsOf: rows) }
            total = page.total
            nextOffset = page.nextOffset
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            errorText = error.localizedDescription
        }
    }
}

/// 本地分页出的归档页（网关模式用）。`nextOffset` 的算法与服务端一致：
/// 只有确实还有下一段才给值，否则调用方会一直 loadMore。
extension ArchivedSessionPage {
    init(sessions: [SessionSummary], total: Int, offset: Int, limit: Int) {
        self.init(sessions: sessions, totalValue: total, offsetValue: offset, limitValue: limit)
    }

    private init(sessions: [SessionSummary], totalValue: Int, offsetValue: Int, limitValue: Int) {
        self.sessions = sessions
        self.total = totalValue
        self.offset = offsetValue
        self.limit = limitValue
        let next = offsetValue + sessions.count
        self.nextOffset = next < totalValue ? next : nil
    }
}

struct ArchivedSessionPage {
    let sessions: [SessionSummary]
    let total: Int
    let offset: Int
    let limit: Int
    let nextOffset: Int?
    init(data: Data) throws {
        struct Envelope: Decodable {
            let sessions: [SessionSummary]
            let archived_count: Int
            let archived_offset: Int
            let archived_limit: Int
        }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        let rows = value.sessions.filter { $0.archived == true }
        guard value.archived_count >= 0, value.archived_offset >= 0,
              value.archived_limit > 0, rows.count <= value.archived_limit,
              rows.allSatisfy({ !$0.sessionId.isEmpty }) else { throw SessionDiscoveryError.invalidResponse }
        sessions = rows
        total = value.archived_count
        offset = value.archived_offset
        limit = value.archived_limit
        let next = offset + rows.count
        // A non-advancing page must not cause an infinite load-more loop.
        guard !rows.isEmpty || next >= total else { throw SessionDiscoveryError.invalidResponse }
        nextOffset = next < total ? next : nil
    }
}
