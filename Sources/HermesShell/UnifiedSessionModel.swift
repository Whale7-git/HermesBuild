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

/// Presentation-only aggregator. Never takes ownership of POST, run state or
/// the selected backend; each source is scoped to an independently created GET client.
/// At most three sources are in flight per wave. A failed host never erases
/// successful hosts' results, and old generations cannot publish into new searches.
@MainActor
final class UnifiedSessionModel: ObservableObject {
    @Published private(set) var records: [UnifiedSessionRecord] = []
    @Published private(set) var failures: [UnifiedSessionIdentity: String] = [:]
    @Published private(set) var loading: Set<UnifiedSessionIdentity> = []

    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var lastLists: [UnifiedSessionIdentity: [SessionSummary]] = [:]
    private var sections: [UnifiedSessionIdentity: [UnifiedSessionRecord]] = [:]

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        loading = []
    }

    func start(sources: [UnifiedSessionSource], query: String) {
        cancel()
        let ticket = generation
        let live = Set(sources.map(\.identity))
        lastLists = lastLists.filter { live.contains($0.key) }
        sections = [:]
        failures = [:]
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for source in sources {
            if let remembered = lastLists[source.identity] ?? source.cached {
                sections[source.identity] = Self.localRows(source, messages: remembered, query: term)
            }
        }
        publish()
        loading = live
        task = Task { [weak self] in
            guard let self else { return }
            for start in stride(from: 0, to: sources.count, by: 3) {
                guard !Task.isCancelled, self.generation == ticket else { return }
                let wave = Array(sources[start..<min(start + 3, sources.count)])
                await withTaskGroup(of: Outcome.self) { group in
                    for source in wave {
                        group.addTask { @MainActor in
                            do {
                                if !term.isEmpty, let search = source.searchFullBody {
                                    let hits = try await search(term)
                                    let rows = hits.map { hit in
                                        UnifiedSessionRecord(identity: source.identity,
                                            instanceName: source.instanceName, session: hit.session,
                                            excerpt: hit.preview ?? hit.session.preview,
                                            matchedFullBody: hit.matchType == "content")
                                    }
                                    return Outcome(identity: source.identity,
                                                   records: rows, list: nil, error: nil)
                                }
                                let sessions = try await source.load()
                                return Outcome(identity: source.identity,
                                    records: Self.localRows(source, messages: sessions, query: term),
                                    list: sessions, error: nil)
                            } catch {
                                return Outcome(identity: source.identity,
                                    records: nil, list: nil, error: error.localizedDescription)
                            }
                        }
                    }
                    for await outcome in group {
                        guard self.generation == ticket, !Task.isCancelled else { continue }
                        self.loading.remove(outcome.identity)
                        if let rows = outcome.records {
                            self.sections[outcome.identity] = rows
                            if let list = outcome.list { self.lastLists[outcome.identity] = list }
                            self.failures.removeValue(forKey: outcome.identity)
                        } else {
                            self.failures[outcome.identity] = outcome.error ?? "连接失败"
                        }
                        self.publish()
                    }
                }
            }
            if self.generation == ticket { self.task = nil }
        }
    }

    func waitForRefresh() async { await task?.value }

    private struct Outcome {
        let identity: UnifiedSessionIdentity
        let records: [UnifiedSessionRecord]?
        let list: [SessionSummary]?
        let error: String?
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
