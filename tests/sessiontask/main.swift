import Foundation

func row(_ id: String, pinned: Bool = false, running: Bool = false) -> SessionSummary {
    SessionSummary(sessionId: id, title: id, updatedAt: 1, createdAt: nil,
                   messageCount: nil, profile: nil, source: nil, archived: false,
                   pinned: pinned, preview: nil, isStreaming: running, model: nil, workspace: nil)
}
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
var state = SessionTaskDerivedState()
let rows = [row("verify", pinned: true), row("run", running: true), row("plain")]
let facts = ["verify": SessionTaskObservation(signals: [.needsVerification])]
state.update(sessions: rows, observations: facts)
check(state.summaries.map(\.sessionID) == ["verify", "run"], "stable task ordering")
check(state.byID["verify"]?.needsAttention == true, "indexed task matches summary")
check(state.all.attention.map(\.sessionId) == ["verify"], "all snapshot attention")
check(state.pinnedOnly.attention.map(\.sessionId) == ["verify"], "pinned attention")
check(state.pinnedOnly.running.isEmpty, "pinned filter excludes unpinned run")
let revision = state.revision
let derivations = state.derivationCount
let partitions = state.homeBuildCount
for _ in 0..<1000 {
    _ = state.byID["verify"]
    _ = state.all.recent
    _ = state.pinnedOnly.attention
}
check(state.derivationCount == derivations && state.homeBuildCount == partitions,
      "reading every row and both filters must not rebuild")
state.update(sessions: rows, observations: facts)
check(state.derivationCount == derivations, "identical inputs are zero derivation")
var renamed = rows
renamed[0] = renamed[0].withTitle("renamed")
state.update(sessions: renamed, observations: facts)
check(state.revision == revision, "title-only edit does not change task revision")
check(state.all.attention.first?.title == "renamed", "title edit invalidates home snapshot")
state.update(sessions: rows, observations: ["verify": SessionTaskObservation(signals: [.needsVerification], observedAt: .distantPast)])
check(state.revision == revision, "timestamp-only observation does not change semantic revision")
state.update(sessions: rows, observations: [:])
check(state.revision == revision + 1, "real signal change increments revision exactly once")
check(state.all.attention.isEmpty && state.pinnedOnly.pinned.map(\.sessionId) == ["verify"],
      "both snapshots reflect cleared attention")
let duplicateRows = [row("dup", pinned: true, running: true), row("dup", pinned: true, running: true)]
state.update(sessions: duplicateRows, observations: [:])
check(state.byID.count == 1 && state.summaries.count == 2, "duplicate IDs preserve rows without crashing index")
check(state.all.running.count == 2, "duplicate rows do not crash home task dictionary")
// Same ID carrying different signals must not crash and must resolve to the
// first summary in the merged order, matching the previous `.first {}` lookup.
state.update(sessions: [row("dup", pinned: true, running: true)],
             observations: ["dup": SessionTaskObservation(signals: [.needsVerification])])
check(state.byID["dup"]?.signals == state.summaries.first?.signals,
      "differing signals for one ID resolve to the same first summary")
check(state.byID["dup"]?.needsAttention == true,
      "attention fact for a single ID survives the merge")
// build166: clarify is actionable but distinct from an approval, and
// equal-priority tasks sort by the latest observation rather than session ID.
let clarify = SessionTaskCenter.summary(
    sessionID: "clarify", serverStreaming: nil,
    observation: SessionTaskObservation(signals: [.waitingForClarify]))
check(clarify?.needsAttention == true && clarify?.title == "等待你补充信息",
      "clarify is a first-class task instead of a misleading approval")
let taskRows = [row("a", running: true), row("z", running: true)]
let taskObservations = [
    "a": SessionTaskObservation(signals: [.running],
                                observedAt: Date(timeIntervalSince1970: 10)),
    "z": SessionTaskObservation(signals: [.running],
                                observedAt: Date(timeIntervalSince1970: 20))
]
check(SessionTaskCenter.summaries(sessions: taskRows, observations: taskObservations)
      .map(\.sessionID) == ["z", "a"],
      "equal-priority tasks order by most recent observation")
check(SessionTaskCenter.summaries(
      sessions: [row("dup", running: true), row("dup", running: true)],
      observations: [:]).count == 2,
      "duplicate session IDs cannot crash activity ordering")

let large = (0..<2000).map { row("row-\($0)", pinned: $0 % 2 == 0, running: true) }
state.update(sessions: large, observations: [:])
let count = state.derivationCount
for item in large { check(state.byID[item.id] != nil, "large lookup resolves row") }
check(state.derivationCount == count, "large row count does not multiply derivations")
state.update(sessions: [], observations: [:])
check(state.summaries.isEmpty && state.all.running.isEmpty && state.pinnedOnly.pinned.isEmpty,
      "empty scope cannot retain old snapshots")
print("TASK_DERIVED_PASS \(checks) assertions")
