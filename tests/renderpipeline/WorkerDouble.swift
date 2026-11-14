import Foundation

struct MarkdownRenderMetrics: Sendable {
    var parsedBytes = 0
    var reusedBytes = 0
    var activeBytes = 0
}
struct MarkdownRenderSnapshot: Sendable {
    let content: AttributedString
    let highlightAfter: Int?
    let metrics: MarkdownRenderMetrics
}

/// Controllable async parser double; no Foundation Markdown or layout claims.
actor ChatMarkdownWorker {
    func render(_ source: String, finished: Bool) async throws -> MarkdownRenderSnapshot {
        try await RenderProbe.shared.render(source, finished: finished)
    }
}

@MainActor
final class RenderProbe {
    static let shared = RenderProbe()
    var requests: [MarkdownRenderRequest] = []
    var held = Set<String>()
    var failing = Set<String>()
    enum ParseError: Error { case fixture }
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func render(_ source: String, finished: Bool) async throws -> MarkdownRenderSnapshot {
        requests.append(.init(source: source, finished: finished))
        if held.contains(source) {
            await withCheckedContinuation { continuations[source] = $0 }
        }
        if failing.contains(source) { throw ParseError.fixture }
        // Deliberately ignore task cancellation until the document sees the
        // result. This catches premature permit release and late publication.
        return MarkdownRenderSnapshot(content: AttributedString("parsed:" + source),
            highlightAfter: finished ? nil : 0,
            metrics: .init(parsedBytes: source.utf8.count, activeBytes: source.utf8.count))
    }

    func release(_ source: String) {
        held.remove(source)
        continuations.removeValue(forKey: source)?.resume()
    }
}

@MainActor
enum ChatMarkdownParser {
    static var cacheGeneration: UInt64 = 0
    static var cache: [String: AttributedString] = [:]
    static func cachedDocument(_ source: String) -> AttributedString? { cache[source] }
    static func remember(_ document: AttributedString, source: String) { cache[source] = document }
    static func clearCache() { cacheGeneration &+= 1; cache = [:] }
}

@MainActor
final class ChatPerformanceRecorder {
    static let shared = ChatPerformanceRecorder()
    struct Sample {}
    func begin() -> Sample? { nil }
    func finish(_ metric: ChatPerformanceStatistics.Metric, _ sample: Sample?) {}
}
