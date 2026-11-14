import Foundation

/// Immutable-to-read derived snapshots. AppState marks them dirty from every
/// input write; update is called lazily, after a complete synchronous mutation.
struct SessionTaskDerivedState {
    private(set) var summaries: [SessionTaskSummary] = []
    private(set) var byID: [String: SessionTaskSummary] = [:]
    /// Only visible task changes advance this revision, not titles/timestamps.
    private(set) var revision: UInt64 = 0
    private(set) var all = SessionHomeSections(sessions: [])
    private(set) var pinnedOnly = SessionHomeSections(sessions: [])
    private(set) var derivationCount: UInt64 = 0
    private(set) var homeBuildCount: UInt64 = 0
    private var previousSessions: [SessionSummary] = []
    private var previousObservations: [String: SessionTaskObservation] = [:]

    mutating func update(sessions: [SessionSummary],
                         observations: [String: SessionTaskObservation]) {
        let sessionsChanged = sessions != previousSessions
        guard sessionsChanged || observations != previousObservations else { return }
        derivationCount &+= 1
        let next = SessionTaskCenter.summaries(sessions: sessions, observations: observations)
        let tasksChanged = next != summaries
        if tasksChanged {
            summaries = next
            byID = Dictionary(next.map { ($0.sessionID, $0) },
                              uniquingKeysWith: { first, _ in first })
            revision &+= 1
        }
        if sessionsChanged || tasksChanged {
            all = SessionHomeSections(sessions: sessions, taskSummaries: summaries)
            pinnedOnly = SessionHomeSections(sessions: sessions.filter { $0.pinned == true },
                                             taskSummaries: summaries)
            homeBuildCount &+= 1
        }
        previousSessions = sessions
        previousObservations = observations
    }
}
