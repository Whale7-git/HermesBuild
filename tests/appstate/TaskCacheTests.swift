import Foundation

extension AppStateTests {
    @MainActor static func assertTaskSnapshots(_ model: AppState, _ label: String) {
        let expected = SessionTaskCenter.summaries(sessions: model.sessions,
                                                  observations: model.sessionTaskObservations)
        precondition(model.sessionTaskSummaries == expected, "\(label): cached summaries")
        for row in model.sessions {
            precondition(model.taskSummary(for: row.id) == expected.first { $0.sessionID == row.id },
                         "\(label): dictionary matches original first lookup")
        }
        for pinned in [false, true] {
            let rows = model.sessions.filter { !pinned || $0.pinned == true }
            let direct = SessionHomeSections(sessions: rows, taskSummaries: expected)
            let cached = model.homeSections(pinnedOnly: pinned)
            precondition(cached.attention == direct.attention && cached.running == direct.running
                         && cached.pinned == direct.pinned && cached.recent == direct.recent,
                         "\(label): all four sections must match filter \(pinned)")
        }
        print("TASK_CACHE_PATH_PASS \(label)")
    }

    @MainActor static func sessionRecoveryEvidenceTests() throws {
        func snapshot(active: String? = nil, unknown: Bool = false,
                      readOnly: Bool = false) throws -> ChatSnapshot {
            var session: [String: Any] = [
                "session_id": "proof-session",
                "messages": [["role": "user", "content": "accepted"]],
                "read_only": readOnly
            ]
            if let active { session["active_stream_id"] = active }
            return try ChatSnapshot(
                data: JSONSerialization.data(withJSONObject: session),
                runStatusUnknown: unknown)
        }
        let absent = try snapshot()
        let unknown = try snapshot(unknown: true)
        let running = try snapshot(active: "run-original")
        let restricted = try snapshot(readOnly: true)
        // Three scopes, twelve unresolved sessions: unattempted work wins
        // even when the first batch has already passed its cooldown.
        let keys = (0..<12).map { index in
            SessionRecoveryCoordinator.Key(instanceID: "host-\(index % 3)",
                accountScope: "account", sessionID: "session-\(index)")
        }
        let tracked = SessionTaskObservation(signals: [.recoveryTracked])
        precondition(SessionRecoveryCoordinator.recoverySignal(for: tracked) == .recoveryTracked)
        precondition(SessionTaskCenter.summary(sessionID: "tracked", serverStreaming: false,
            observation: tracked) == nil, "internal recovery index is not a user-facing warning")
        precondition(SessionTaskCenter.persistable(tracked.signals) == [.recoveryTracked])
        let failed = SessionTaskObservation(signals: [.terminalFailed])
        precondition(SessionRecoveryCoordinator.recoverySignal(for: failed) == nil)
        let failedSummary = SessionTaskCenter.summary(sessionID: "failed", serverStreaming: false, observation: failed)
        precondition(failedSummary?.needsAttention == true && failedSummary?.title == "任务失败")
        let cancelled = SessionTaskObservation(signals: [.terminalCancelled])
        precondition(SessionRecoveryCoordinator.recoverySignal(for: cancelled) == nil)
        precondition(SessionTaskCenter.summary(sessionID: "cancelled", serverStreaming: false,
            observation: cancelled)?.title == "任务已取消")
        let first = SessionRecoveryCoordinator.eligibleKeys(keys, attempted: [:], now: 100)
        precondition(first.count == 5)
        let attempted = Dictionary(uniqueKeysWithValues: first.map { ($0, 100.0) })
        let second = SessionRecoveryCoordinator.eligibleKeys(keys, attempted: attempted, now: 161)
        precondition(second.count == 5 && Set(first).isDisjoint(with: Set(second)))
        let secondAttempts = attempted.merging(
            Dictionary(uniqueKeysWithValues: second.map { ($0, 161.0) })) { _, new in new }
        let third = SessionRecoveryCoordinator.eligibleKeys(keys, attempted: secondAttempts, now: 222)
        precondition(Set(first + second + third) == Set(keys))
        precondition(SessionRecoveryCoordinator.eligibleKeys(first, attempted: attempted,
            now: 101).isEmpty)
        precondition(SessionRecoveryCoordinator.canRetireAcceptedReceipt(
            from: absent, sessionID: "proof-session"), "verified absent allows read-only reconciliation")
        precondition(!SessionRecoveryCoordinator.canRetireAcceptedReceipt(
            from: unknown, sessionID: "proof-session"),
            "failed status lookup must not retire a durable accepted Run")
        precondition(!SessionRecoveryCoordinator.canRetireAcceptedReceipt(
            from: running, sessionID: "proof-session"),
            "a running Run must preserve its durable receipt")
        precondition(!SessionRecoveryCoordinator.canRetireAcceptedReceipt(
            from: restricted, sessionID: "proof-session"),
            "read-only history cannot retire a durable accepted Run")
        precondition(!SessionRecoveryCoordinator.canRetireAcceptedReceipt(
            from: absent, sessionID: "other-session"),
            "cross-session history cannot retire a durable accepted Run")
        print("TASK_RECOVERY_EVIDENCE_PASS active, absent, unknown, read-only and wrong-session")
    }

    @MainActor static func taskCacheTests() async throws {
        try sessionRecoveryEvidenceTests()
        let a = HermesInstance(name: "Cache A", baseURL: "https://task-cache-a.test")
        let b = HermesInstance(name: "Cache B", baseURL: "https://task-cache-b.test")
        try InstanceStore.save([a, b], credentials: credentials)
        InstanceStore.activeID = a.id
        HermesAPI.heldLists = [a.baseURL, b.baseURL]
        let model = AppState(credentials: credentials)
        func rows() -> [SessionSummary] {
            [.placeholder(id: "a"), .placeholder(id: "b"), .placeholder(id: "c")]
        }
        model.sessions = rows()
        model.setSessionTaskSignals([.needsVerification], for: "a")
        assertTaskSnapshots(model, "initial")
        let revision = model.taskSummaryRevision
        let builds = model.taskDerivationCount
        let homeBuilds = model.homePartitionBuildCount
        for _ in 0..<100 {
            _ = model.sessionTaskSummaries
            _ = model.homeSections(pinnedOnly: true)
            _ = model.homeSections(pinnedOnly: false)
            _ = model.taskSummary(for: "a")
        }
        precondition(model.taskDerivationCount == builds && model.homePartitionBuildCount == homeBuilds,
                     "repeated UI readers must not recompute")
        model.setSessionTaskSignals([.needsVerification], for: "a")
        precondition(model.taskSummaryRevision == revision && model.taskDerivationCount == builds)
        await model.rename(sessionID: "a", title: "renamed")
        assertTaskSnapshots(model, "rename subscript")
        precondition(model.taskSummaryRevision == revision, "rename is not a task change")
        await model.loadModels()
        HermesAPI.confirmedModelHistory = true
        let switched = await model.setModel(model.modelCatalog!.options[0], for: "a")
        HermesAPI.confirmedModelHistory = false
        precondition(switched)
        assertTaskSnapshots(model, "model subscript")
        precondition(model.taskSummaryRevision == revision, "model edit is not a task change")
        await model.togglePin(sessionID: "a")
        assertTaskSnapshots(model, "pin subscript and filter switch")
        precondition(model.homeSections(pinnedOnly: true).attention.map(\.id) == ["a"])
        // Batch paths perform local mutation before awaiting a controlled refresh.
        let batchPin = Task { await model.setPinned(true, ids: ["b", "c"]) }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        assertTaskSnapshots(model, "batch pin subscript")
        precondition(model.homeSections(pinnedOnly: true).recent.count == 0)
        precondition(model.homeSections(pinnedOnly: true).pinned.count == 2)
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: model.sessions)
        _ = await batchPin.value
        assertTaskSnapshots(model, "refresh whole table")
        await model.delete(sessionID: "c")
        assertTaskSnapshots(model, "single delete removeAll")
        precondition(model.taskSummary(for: "c") == nil)
        await model.archive(sessionID: "b")
        assertTaskSnapshots(model, "single archive removeAll")
        model.sessions = rows()
        _ = model.homeSections(pinnedOnly: false)
        let batchDelete = Task { await model.deleteSessions(ids: ["b", "c"]) }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        assertTaskSnapshots(model, "batch delete removeAll")
        precondition(model.sessions.map(\.id) == ["a"])
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: model.sessions)
        _ = await batchDelete.value
        model.sessions = rows()
        _ = model.homeSections(pinnedOnly: false)
        let batchArchive = Task { await model.archiveSessions(ids: ["b", "c"]) }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        assertTaskSnapshots(model, "batch archive removeAll")
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: model.sessions)
        _ = await batchArchive.value
        // No live row for this observation: prune + list replacement must be one lazy derivation.
        model.setSessionTaskSignals([.recoveryIssue], for: "gone")
        _ = model.sessionTaskSummaries
        let beforeRefresh = model.taskDerivationCount
        let refresh = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: rows())
        await refresh.value
        assertTaskSnapshots(model, "prune plus refresh")
        precondition(model.taskDerivationCount == beforeRefresh + 1,
                     "prune and sessions replacement coalesce before read")
        model.setSessionTaskSignals([.recoveryIssue], for: "a")
        _ = model.sessionTaskSummaries
        model.switchTo(1)
        assertTaskSnapshots(model, "instance switch whole table")
        await spin { HermesAPI.pendingLists[b.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: b.baseURL)!.resume(returning: rows())
        await spin { !model.loadingSessions }
        assertTaskSnapshots(model, "instance refresh")
        precondition(model.sessionTaskObservations.isEmpty)
        model.setSessionTaskSignals([.needsVerification], for: "a")
        _ = model.sessionTaskSummaries
        await model.clearCachedHistory()
        assertTaskSnapshots(model, "clear cache observations")
        precondition(model.sessionTaskObservations.isEmpty)
        model.setSessionTaskSignals([.waitingForApproval], for: "a")
        _ = model.sessionTaskSummaries
        let priorScope = model.historyAccountScope
        let login = Task { await model.signIn(password: "fixture-only") }
        await spin { HermesAPI.pendingLists[b.baseURL] != nil }
        assertTaskSnapshots(model, "account rotation whole table")
        precondition(model.historyAccountScope != priorScope && model.sessionTaskObservations.isEmpty)
        HermesAPI.pendingLists.removeValue(forKey: b.baseURL)!.resume(returning: rows())
        await login.value
        model.sessions = [.placeholder(id: "dup"), .placeholder(id: "dup")]
        model.setSessionTaskSignals([.needsVerification], for: "dup")
        assertTaskSnapshots(model, "duplicate IDs")
        HermesAPI.heldLists = []
        print("TASK_CACHE_PASS all 11 sessions mutation paths and observation lifecycle")
    }
}
