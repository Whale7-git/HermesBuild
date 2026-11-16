import Foundation

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard value() else {
        print("FAIL: \(label)")
        exit(1)
    }
}

func session(_ id: String, updated: Double? = nil, pinned: Bool? = nil,
             streaming: Bool? = nil) -> SessionSummary {
    SessionSummary(sessionId: id, title: id, updatedAt: updated, createdAt: nil,
                   messageCount: nil, profile: nil, source: nil, archived: false,
                   pinned: pinned, preview: nil, isStreaming: streaming,
                   model: nil, workspace: nil)
}

let sections = SessionHomeSections(sessions: [
    session("pinned-a", updated: 10, pinned: true),
    session("running-old", updated: 20, pinned: true, streaming: true),
    session("recent-a", updated: 30),
    session("running-new", updated: 40, streaming: true),
    session("recent-b", updated: 50, pinned: false),
])
expect(sections.running.map(\.sessionId) == ["running-new", "running-old"],
       "running sessions sort newest first")
expect(sections.pinned.map(\.sessionId) == ["pinned-a"],
       "running pinned sessions are removed from the pinned section")
expect(sections.recent.map(\.sessionId) == ["recent-a", "recent-b"],
       "ordinary sessions keep the server-provided order")

let tied = SessionHomeSections(sessions: [
    session("first", updated: 100, streaming: true),
    session("second", updated: 100, streaming: true),
    session("third", updated: 90, streaming: true),
])
expect(tied.running.map(\.sessionId) == ["first", "second", "third"],
       "equal timestamps keep source order")

let missingDate = SessionHomeSections(sessions: [
    session("dated", updated: 1, streaming: true),
    session("missing", streaming: true),
])
expect(missingDate.running.map(\.sessionId) == ["dated", "missing"],
       "missing dates sort after known dates without crashing")

let empty = SessionHomeSections(sessions: [])
expect(empty.running.isEmpty && empty.pinned.isEmpty && empty.recent.isEmpty,
       "empty session lists produce empty sections")

let duplicateInput = SessionHomeSections(sessions: [
    session("same", updated: 2, pinned: true, streaming: true),
    session("same", updated: 2, pinned: true, streaming: true),
])
expect(duplicateInput.running.map(\.sessionId) == ["same", "same"],
       "the view keeps upstream identity instead of silently deleting rows")

let observed = [
    "approval": SessionTaskObservation(
        signals: [.waitingForApproval, .running], observedAt: Date(timeIntervalSince1970: 10)),
    "recovery": SessionTaskObservation(
        signals: [.recoveryIssue], observedAt: Date(timeIntervalSince1970: 11)),
    "verify": SessionTaskObservation(
        signals: [.needsVerification], observedAt: Date(timeIntervalSince1970: 12)),
]
let tasks = SessionTaskCenter.summaries(sessions: [
    session("approval", updated: 30, streaming: true),
    session("recovery", updated: 20),
    session("verify", updated: 10),
    session("plain-running", updated: 40, streaming: true),
], observations: observed)
expect(tasks.map(\.sessionID) == ["approval", "recovery", "verify", "plain-running"],
       "attention tasks sort before ordinary running work")
expect(tasks[0].signals.contains(.waitingForApproval)
       && tasks[0].signals.contains(.running),
       "server running and local approval merge into one task")
expect(tasks[1].signals == [.recoveryIssue] && tasks[2].signals == [.needsVerification],
       "local-only attention facts remain visible without server streaming")
expect(tasks[3].signals == [.running],
       "server streaming is represented without inventing a local approval")

let taskSections = SessionHomeSections(sessions: [
    session("approval", updated: 30, pinned: true, streaming: true),
    session("running", updated: 20, pinned: true, streaming: true),
    session("normal", updated: 10),
], taskSummaries: tasks)
expect(taskSections.attention.map(\.sessionId) == ["approval"],
       "home has a dedicated needs-attention group")
expect(taskSections.running.map(\.sessionId) == ["running"],
       "running section excludes rows already shown under attention")
expect(taskSections.pinned.isEmpty,
       "pinned task rows are not duplicated in ordinary pinned list")
expect(taskSections.recent.map(\.sessionId) == ["normal"],
       "ordinary recent rows stay outside task groups")

let stale = SessionTaskCenter.summary(
    sessionID: "stale",
    serverStreaming: false,
    observation: SessionTaskObservation(signals: [.running], observedAt: Date()))
expect(stale == nil, "a completed server run clears a stale local running signal")
expect(SessionTaskCenter.persistable([.running, .waitingForApproval]) == [.waitingForApproval],
       "server-only running state is not written to the local task store")

let defaultsName = "HermesTaskStore-" + UUID().uuidString
let defaults = UserDefaults(suiteName: defaultsName)!
let storeKey = SessionTaskStore.key(instanceID: "i", accountScope: "a")
let oldDate = Date(timeIntervalSince1970: 1)
let persistedFacts = [
    "approval": SessionTaskObservation(signals: [.waitingForApproval, .running], observedAt: oldDate),
    "verify": SessionTaskObservation(signals: [.needsVerification], observedAt: oldDate),
    "recovery": SessionTaskObservation(signals: [.recoveryIssue], observedAt: oldDate),
    "only-running": SessionTaskObservation(signals: [.running], observedAt: oldDate),
]
defaults.set(try JSONEncoder().encode(persistedFacts), forKey: storeKey)
let loaded = SessionTaskStore.load(instanceID: "i", accountScope: "a", defaults: defaults)
if case .loaded(let rows) = SessionTaskStore.inspect(
    instanceID: "i", accountScope: "a", defaults: defaults) {
    expect(rows.count == loaded.count, "valid task record has an explicit loaded result")
} else { expect(false, "valid task record must not be reported corrupt") }
expect(loaded.values.allSatisfy { !$0.signals.contains(.running) },
       "load already filters running even from legacy persisted data")
expect(loaded["approval"]?.signals == [.waitingForApproval]
       && loaded["verify"]?.signals == [.needsVerification]
       && loaded["recovery"]?.signals == [.recoveryIssue],
       "elapsed time never expires approval verification or recovery")
expect(loaded["approval"]?.observedAt == 1, "load preserves observation timestamp")
expect(SessionTaskStore.load(instanceID: "other", accountScope: "a", defaults: defaults).isEmpty
       && SessionTaskStore.load(instanceID: "i", accountScope: "other", defaults: defaults).isEmpty,
       "task store is isolated by both instance and account")
let pruned = SessionTaskCenter.prune(observations: loaded, liveSessionIDs: ["approval", "verify"])
expect(Set(pruned.keys) == ["approval", "verify"], "prune removes absent IDs and empty facts")
// Bad JSON must not become an authoritative empty state or get overwritten
// until the user explicitly clears the damaged record.
let corruptBytes = Data("{not-valid-json".utf8)
defaults.set(corruptBytes, forKey: storeKey)
if case .corrupt = SessionTaskStore.inspect(instanceID: "i", accountScope: "a",
                                           defaults: defaults) {
    expect(true, "corruption distinguished from missing state")
} else { expect(false, "corrupt task record must report a load error") }
expect(defaults.data(forKey: storeKey) == corruptBytes,
       "failed decode preserves original bytes for recovery")
SessionTaskStore.remove(instanceID: "i", accountScope: "a", defaults: defaults)
expect(SessionTaskStore.load(instanceID: "i", accountScope: "a", defaults: defaults).isEmpty,
       "explicit scope cleanup persists across store reload")
defaults.removePersistentDomain(forName: defaultsName)

print("SESSION_HOME_PASS \(checks) assertions")
