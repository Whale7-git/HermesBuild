import Foundation
#if canImport(Combine)
import Combine
#endif

/// All three values must match before a cross-instance result can navigate.
/// A Session ID alone is not globally unique, even between two Gateway hosts.
struct UnifiedSessionIdentity: Hashable {
    let instanceID: UUID
    let endpointIdentity: String
    let accountScope: String

    func matches(instanceID: UUID, endpointIdentity: String, accountScope: String) -> Bool {
        self.instanceID == instanceID && self.endpointIdentity == endpointIdentity
            && self.accountScope == accountScope
    }
}

struct UnifiedSessionRecord: Identifiable {
    let identity: UnifiedSessionIdentity
    let instanceName: String
    let session: SessionSummary
    let excerpt: String?
    let matchedFullBody: Bool

    var id: String {
        // Length-prefixed tuple avoids ambiguity when server session IDs contain separators.
        let parts = [identity.instanceID.uuidString, identity.endpointIdentity,
                     identity.accountScope, session.sessionId]
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct UnifiedSessionSource {
    let identity: UnifiedSessionIdentity
    let instanceName: String
    /// Snapshot from the existing per-account list cache, never an unscoped cache.
    let cached: [SessionSummary]?
    let load: @MainActor () async throws -> [SessionSummary]
    /// Only provided for a backend that genuinely supports server full-body search.
    let searchFullBody: (@MainActor (String) async throws -> [SessionSearchHit])?
    /// AppState's last successful scoped list read. Nonempty full-body searches
    /// are never treated as already resolved by this timestamp.
    var cachedAt: Date? = nil
}

/// Scoped, display-only discovery. A full refresh owns one generation and
/// coalesces equivalent requests; a host-specific retry only touches that host.
/// Sliding-window scheduling keeps three GET/search calls in flight at most.
@MainActor
final class UnifiedSessionModel: ObservableObject {
    @Published private(set) var records: [UnifiedSessionRecord] = []
    @Published private(set) var failures: [UnifiedSessionIdentity: String] = [:]
    @Published private(set) var loading: Set<UnifiedSessionIdentity> = []

    /// A positive, per-host deadline applies to BOTH WebUI full-body searches
    /// and Gateway list reads. The transport must honor Swift task cancellation.
    private let hostTimeoutNanoseconds: UInt64

    init(hostTimeoutNanoseconds: UInt64 = 20_000_000_000) {
        self.hostTimeoutNanoseconds = max(1_000_000, hostTimeoutNanoseconds)
    }

    private struct RequestKey: Equatable {
        let identities: [UnifiedSessionIdentity]
        let query: String
    }

    private struct CacheKey: Hashable {
        let identity: UnifiedSessionIdentity
        let query: String
    }

    private var cachedKey: RequestKey?
    private var lastSuccess: [CacheKey: Date] = [:]
    private let cacheLifetime: TimeInterval = 300
    @Published private(set) var hasResolvedSnapshot = false

    private var generation = UUID()
    private var requestKey: RequestKey?
    private var task: Task<Void, Never>?
    private var retries: [UnifiedSessionIdentity: Task<Void, Never>] = [:]
    private var lastLists: [UnifiedSessionIdentity: [SessionSummary]] = [:]
    private var sections: [UnifiedSessionIdentity: [UnifiedSessionRecord]] = [:]

    func cancel() {
        generation = UUID()
        task?.cancel()
        retries.values.forEach { $0.cancel() }
        task = nil
        retries.removeAll()
        requestKey = nil
        loading = []
    }

    /// For automatic entry: serve scoped rows first, and fetch only sources
    /// missing a fresh successful snapshot. The model is owned by RootView,
    /// not the transient browser View; returning within TTL does no GET.
    @discardableResult
    func refreshIfNeeded(sources: [UnifiedSessionSource], query: String,
                         now: Date = Date()) -> Task<Void, Never>? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = RequestKey(identities: sources.map(\.identity), query: term)
        if cachedKey != key {
            // Cancel the previous query even when this new one is fully cached.
            // Otherwise a stale completion can still publish in the new view.
            cancel()
            sections = [:]
            cachedKey = key
            lastSuccess = lastSuccess.filter { $0.key.query == term }
            for source in sources {
                if let rows = lastLists[source.identity] ?? source.cached {
                    sections[source.identity] = Self.localRows(source,
                                                               messages: rows, query: term)
                    // A list timestamp is only trustworthy alongside the
                    // actual cached rows, including a verified empty list.
                    if term.isEmpty, let date = source.cachedAt {
                        let itemKey = CacheKey(identity: source.identity, query: term)
                        if lastSuccess[itemKey] == nil { lastSuccess[itemKey] = date }
                    }
                }
            }
            publish()
        }
        hasResolvedSnapshot = sources.contains { source in
            lastSuccess[CacheKey(identity: source.identity, query: term)] != nil
        }
        let stale = Set(sources.filter { source in
            guard let at = lastSuccess[CacheKey(identity: source.identity, query: term)],
                  now.timeIntervalSince(at) >= 0 &&
                  now.timeIntervalSince(at) < cacheLifetime else { return true }
            return false
        }.map(\.identity))
        if stale.isEmpty { return nil }
        return start(sources: sources, query: term, only: stale)
    }

    /// All automatic, pull and menu refreshes call this same entry point.
    /// Repeated requests for the same query + scoped sources JOIN the current
    /// task, instead of cancelling it and opening duplicate network requests.
    /// After completion an explicit refresh starts again, preserving visible
    /// rows until their authoritative replacements arrive.
    @discardableResult
    func start(sources: [UnifiedSessionSource], query: String,
               only: Set<UnifiedSessionIdentity>? = nil) -> Task<Void, Never> {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = RequestKey(identities: sources.map(\.identity), query: term)
        if requestKey == key, let task { return task }
        let sameQueryAndScope = cachedKey == key
        cancel()
        requestKey = key
        cachedKey = key
        let ticket = generation
        let live = Set(key.identities)
        let targets = sources.filter { only?.contains($0.identity) ?? true }
        lastLists = lastLists.filter { live.contains($0.key) }
        lastSuccess = lastSuccess.filter { live.contains($0.key.identity) }
        if only == nil { failures = [:] }
        else { for target in targets { failures.removeValue(forKey: target.identity) } }
        if !sameQueryAndScope {
            sections = [:]
            for source in sources {
                if let remembered = lastLists[source.identity] ?? source.cached {
                    sections[source.identity] = Self.localRows(source,
                                                               messages: remembered, query: term)
                }
            }
            publish()
        }
        loading = Set(targets.map(\.identity))
        let running = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Outcome.self) { group in
                var next = 0
                for _ in 0..<min(3, targets.count) {
                    let source = targets[next]
                    next += 1
                    group.addTask { @MainActor in
                        await Self.loadOutcome(source, query: term, timeout: self.hostTimeoutNanoseconds)
                    }
                }
                while let result = await group.next() {
                    guard !Task.isCancelled, self.generation == ticket else {
                        group.cancelAll()
                        break
                    }
                    self.accept(result, query: term)
                    if next < targets.count {
                        let source = targets[next]
                        next += 1
                        group.addTask { @MainActor in
                            await Self.loadOutcome(source, query: term, timeout: self.hostTimeoutNanoseconds)
                        }
                    }
                }
            }
            if self.generation == ticket { self.task = nil }
        }
        task = running
        return running
    }

    func waitForRefresh() async { await task?.value }

    /// Adopt only a successful active-host list refresh already performed by
    /// AppState (e.g. a Gateway run-state event). No duplicate GET.
    func adoptActiveList(identity: UnifiedSessionIdentity, instanceName: String,
                         rows: [SessionSummary], refreshedAt: Date?) {
        guard cachedKey?.query == "",
              cachedKey?.identities.contains(identity) == true,
              !loading.contains(identity) else { return }
        let previous = lastLists[identity]
        guard previous != rows else { return }
        lastLists[identity] = rows
        let local = rows.filter { $0.archived != true }.map { summary in
            UnifiedSessionRecord(identity: identity, instanceName: instanceName,
                                 session: summary, excerpt: summary.preview,
                                 matchedFullBody: false)
        }
        sections[identity] = local
        if let refreshedAt {
            lastSuccess[CacheKey(identity: identity, query: "")] = refreshedAt
        }
        hasResolvedSnapshot = true
        publish()
    }

    /// Retry exactly one failed source. Other hosts' loading flags, rows and
    /// search results are never cleared or fetched again by this action.
    func retry(source: UnifiedSessionSource, query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = requestKey, key.query == term,
              key.identities.contains(source.identity) else { return }
        if loading.contains(source.identity) {
            if let retry = retries[source.identity] { await retry.value }
            else { await task?.value }
            return
        }
        let ticket = generation
        loading.insert(source.identity)
        failures.removeValue(forKey: source.identity)
        // Capture the immutable budget before the weak-self task begins.
        let timeout = hostTimeoutNanoseconds
        let run = Task { [weak self] in
            let result = await Self.loadOutcome(source, query: term, timeout: timeout)
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            self.accept(result, query: term)
        }
        retries[source.identity] = run
        await run.value
        if generation == ticket { retries.removeValue(forKey: source.identity) }
    }

    private struct Outcome {
        let identity: UnifiedSessionIdentity
        let records: [UnifiedSessionRecord]?
        let list: [SessionSummary]?
        let error: String?
    }

    private static func loadOutcome(_ source: UnifiedSessionSource,
                                    query: String, timeout: UInt64) async -> Outcome {
        do {
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    if !query.isEmpty, let search = source.searchFullBody {
                        let hits = try await search(query)
                        let rows = hits.map { hit in
                            UnifiedSessionRecord(identity: source.identity,
                                instanceName: source.instanceName,
                                session: hit.session,
                                excerpt: hit.preview ?? hit.session.preview,
                                matchedFullBody: hit.matchType == "content")
                        }
                        return Outcome(identity: source.identity,
                                       records: rows, list: nil, error: nil)
                    }
                    let messages = try await source.load()
                    return Outcome(identity: source.identity,
                        records: Self.localRows(source, messages: messages, query: query),
                        list: messages, error: nil)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw URLError(.badServerResponse) }
                return first
            }
        } catch {
            return Outcome(identity: source.identity, records: nil, list: nil,
                           error: error.localizedDescription)
        }
    }

    private func accept(_ outcome: Outcome, query: String) {
        loading.remove(outcome.identity)
        if let rows = outcome.records {
            sections[outcome.identity] = rows
            if let list = outcome.list { lastLists[outcome.identity] = list }
            lastSuccess[CacheKey(identity: outcome.identity, query: query)] = Date()
            hasResolvedSnapshot = true
            failures.removeValue(forKey: outcome.identity)
        } else {
            failures[outcome.identity] = outcome.error ?? "连接失败"
        }
        publish()
    }

    private static func localRows(_ source: UnifiedSessionSource, messages: [SessionSummary],
                                  query: String) -> [UnifiedSessionRecord] {
        messages.filter { session in
            guard session.archived != true else { return false }
            return query.isEmpty || session.displayTitle.localizedStandardContains(query)
                || (session.preview?.localizedStandardContains(query) ?? false)
        }.map { session in
            UnifiedSessionRecord(identity: source.identity, instanceName: source.instanceName,
                                 session: session, excerpt: session.preview, matchedFullBody: false)
        }
    }

    private func publish() {
        records = sections.values.flatMap { $0 }.sorted { lhs, rhs in
            let lt = lhs.session.updatedDate?.timeIntervalSince1970 ?? 0
            let rt = rhs.session.updatedDate?.timeIntervalSince1970 ?? 0
            if lt != rt { return lt > rt }
            if lhs.instanceName != rhs.instanceName { return lhs.instanceName < rhs.instanceName }
            return lhs.id < rhs.id
        }
    }
}
