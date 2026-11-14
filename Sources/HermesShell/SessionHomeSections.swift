import Foundation

/// Keeps running sessions above pinned and date groups without duplicating
/// them in the regular list. Search and archive views keep their own ordering.
struct SessionHomeSections {
    let attention: [SessionSummary]
    let running: [SessionSummary]
    let pinned: [SessionSummary]
    let recent: [SessionSummary]

    init(sessions: [SessionSummary], taskSummaries: [SessionTaskSummary]? = nil) {
        // Preserve source order when timestamps tie. Swift's sort is not
        // documented as stable, and a moving header would make two refreshes
        // with identical data visibly reorder rows.
        let tasks = Dictionary((taskSummaries ?? []).map { ($0.sessionID, $0) },
                               uniquingKeysWith: { first, _ in first })
        attention = sessions.enumerated()
            .filter { tasks[$0.element.sessionId]?.needsAttention == true }
            .sorted { lhs, rhs in
                let left = lhs.element.updatedDate ?? .distantPast
                let right = rhs.element.updatedDate ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        let attentionIDs = Set(attention.map(\.sessionId))
        running = sessions.enumerated()
            .filter {
                (tasks[$0.element.sessionId]?.isRunning == true || $0.element.isStreaming == true)
                    && !attentionIDs.contains($0.element.sessionId)
            }
            .sorted { lhs, rhs in
                let left = lhs.element.updatedDate ?? .distantPast
                let right = rhs.element.updatedDate ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        let activeIDs = attentionIDs.union(running.map(\.sessionId))
        pinned = sessions.filter {
            $0.pinned == true && !activeIDs.contains($0.sessionId)
        }
        recent = sessions.filter {
            $0.pinned != true && !activeIDs.contains($0.sessionId)
        }
    }
}
