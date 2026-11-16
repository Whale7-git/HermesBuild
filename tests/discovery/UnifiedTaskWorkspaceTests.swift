import Foundation

@MainActor func unifiedTaskWorkspaceTests() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func session(_ id: String, streaming: Bool?, at: Double = 1_999_999_990) throws -> SessionSummary {
        var json: [String: Any] = ["session_id": id, "title": id, "updated_at": at]
        if let streaming { json["is_streaming"] = streaming }
        return try JSONDecoder().decode(SessionSummary.self,
            from: JSONSerialization.data(withJSONObject: json))
    }
    func identity(_ name: String) -> UnifiedSessionIdentity {
        UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: name,
                               accountScope: "account-" + name)
    }
    let a = identity("nas")
    let b = identity("win")
    let c = identity("linux")
    let sameA = UnifiedSessionRecord(identity: a, instanceName: "NAS",
                                     session: try session("same", streaming: true),
                                     excerpt: nil, matchedFullBody: false)
    let sameB = UnifiedSessionRecord(identity: b, instanceName: "Windows",
                                     session: try session("same", streaming: true),
                                     excerpt: nil, matchedFullBody: false)
    let unknown = UnifiedSessionRecord(identity: c, instanceName: "Linux",
                                      session: try session("unknown", streaming: nil),
                                      excerpt: nil, matchedFullBody: false)
    let approval = SessionTaskObservation(signals: [.waitingForApproval], observedAt: now)
    let restore = SessionTaskObservation(signals: [.needsVerification], observedAt: now)
    let states: [UnifiedSessionIdentity: UnifiedTaskSourceState] = [
        a: .init(observations: ["same": approval], lastSuccessfulList: now.addingTimeInterval(-20),
                 failed: false),
        b: .init(observations: ["same": restore], lastSuccessfulList: now.addingTimeInterval(-500),
                 failed: true),
        c: .init(observations: [:], lastSuccessfulList: now, failed: false)
    ]
    let entries = UnifiedTaskWorkspace.entries(
        records: [sameA, sameB, unknown], states: states, now: now)
    expect(entries.count == 2 && entries[0].record.id != entries[1].record.id,
           "same Session ID remains disjoint across endpoint and account")
    expect(entries[0].group == .attention && entries[0].record.id == sameA.id,
           "recently confirmed host retains scoped local attention signal")
    expect(entries[1].group == .verification && entries[1].record.id == sameB.id,
           "failed host is unverified even when cached is_streaming is true")
    expect(entries[1].status.contains("上次记录") &&
           entries[1].evidence.contains("刷新失败"),
           "failed refresh never looks like a live approval")
    expect(entries.allSatisfy { $0.record.id != unknown.id },
           "Gateway nil is_streaming does not invent a running task")

    let runningOnly = UnifiedTaskWorkspace.entries(
        records: [sameA],
        states: [a: .init(observations: [:], lastSuccessfulList: now.addingTimeInterval(-30),
                         failed: false)], now: now)
    expect(runningOnly.count == 1 && runningOnly[0].group == .running,
           "recent confirmed server flag may appear in running group")
    let expired = UnifiedTaskWorkspace.entries(
        records: [sameA],
        states: [a: .init(observations: [:], lastSuccessfulList: now.addingTimeInterval(-121),
                         failed: false)], now: now)
    expect(expired.count == 1 && expired[0].group == .verification,
           "2-minute evidence timeout demotes cached running to verification")
    let future = UnifiedTaskWorkspace.entries(
        records: [sameA],
        states: [a: .init(observations: [:], lastSuccessfulList: now.addingTimeInterval(5),
                         failed: false)], now: now)
    expect(future[0].group == .verification,
           "future clock timestamps cannot certify running")
    let ended = UnifiedTaskWorkspace.entries(
        records: [UnifiedSessionRecord(identity: a, instanceName: "NAS",
                                       session: try session("done", streaming: false),
                                       excerpt: nil, matchedFullBody: false)],
        states: [a: .init(observations: [:], lastSuccessfulList: now, failed: false)],
        now: now)
    expect(ended.isEmpty, "completed and unknown idle sessions do not flood the task center")

    let many = (0..<10).map { index -> UnifiedSessionRecord in
        let scope = identity("host-\(index)")
        return UnifiedSessionRecord(identity: scope, instanceName: "Host \(index)",
                                    session: try! session("same", streaming: true),
                                    excerpt: nil, matchedFullBody: false)
    }
    let manyStates = Dictionary(uniqueKeysWithValues: many.map {
        ($0.identity, UnifiedTaskSourceState(observations: [:],
            lastSuccessfulList: now, failed: false))
    })
    let ten = UnifiedTaskWorkspace.entries(records: many, states: manyStates, now: now)
    expect(ten.count == 10 && Set(ten.map(\.id)).count == 10 &&
           ten.allSatisfy { $0.group == .running },
           "10 independent Hermes instances retain unique task navigation identity")

    let suite = "build195-workspace-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let endpoint = "unit-endpoint"
    let local = "account-a"
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = SessionTaskStore.save(["same": approval], instanceID: endpoint,
                              accountScope: local, defaults: defaults)
    expect(SessionTaskStore.load(instanceID: endpoint, accountScope: local,
                                 defaults: defaults)["same"] != nil &&
           SessionTaskStore.load(instanceID: endpoint, accountScope: "account-b",
                                 defaults: defaults)["same"] == nil,
           "task observations never leak across account keys")
    print("UNIFIED_TASK_PASS multi-host status, stale and offline evidence, account isolation")
}
