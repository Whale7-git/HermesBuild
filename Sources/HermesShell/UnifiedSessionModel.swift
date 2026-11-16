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

    /// All automatic, pull and menu refreshes call this same entry point.
    /// Repeated requests for the same query + scoped sources JOIN the current
    /// task, instead of cancelling it and opening duplicate network requests.
    /// After completion an explicit refresh starts again, preserving visible
    /// rows until their authoritative replacements arrive.
    @discardableResult
    func start(sources: [UnifiedSessionSource], query: String) -> Task<Void, Never> {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = RequestKey(identities: sources.map(\.identity), query: term)
        if requestKey == key, let task { return task }
        let sameQueryAndScope = requestKey == key
        cancel()
        requestKey = key
        let ticket = generation
        let live = Set(key.identities)
        lastLists = lastLists.filter { live.contains($0.key) }
        failures = [:]
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
        loading = live
        let running = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Outcome.self) { group in
                var next = 0
                for _ in 0..<min(3, sources.count) {
                    let source = sources[next]
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
                    self.accept(result)
                    if next < sources.count {
                        let source = sources[next]
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
        let run = Task { [weak self] in
            let result = await Self.loadOutcome(source, query: term, timeout: self.hostTimeoutNanoseconds)
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            self.accept(result)
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

    private func accept(_ outcome: Outcome) {
        loading.remove(outcome.identity)
        if let rows = outcome.records {
            sections[outcome.identity] = rows
            if let list = outcome.list { lastLists[outcome.identity] = list }
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
