import Foundation

@MainActor final class UnifiedFixture {
    var waiting: [UUID: CheckedContinuation<[SessionSummary], Error>] = [:]
    func held(_ identity: UnifiedSessionIdentity, name: String,
              cached: [SessionSummary]? = nil) -> UnifiedSessionSource {
        UnifiedSessionSource(identity: identity, instanceName: name, cached: cached,
            load: {
                try await withCheckedThrowingContinuation {
                    (cont: CheckedContinuation<[SessionSummary], Error>) in
                    self.waiting[identity.instanceID] = cont
                }
            }, searchFullBody: nil)
    }
}

@MainActor func unifiedSessionTests() async throws {
    func summary(_ id: String, title: String) throws -> SessionSummary {
        let dictionary: [String: Any] = ["session_id": id, "title": title]
        return try JSONDecoder().decode(SessionSummary.self,
            from: JSONSerialization.data(withJSONObject: dictionary))
    }
    let a = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "ep-A",
                                   accountScope: "account-A")
    let b = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "ep-B",
                                   accountScope: "account-B")
    expect(a.matches(instanceID: a.instanceID, endpointIdentity: "ep-A",
                     accountScope: "account-A"), "all three identity fields match")
    expect(!a.matches(instanceID: b.instanceID, endpointIdentity: "ep-A",
                      accountScope: "account-A") &&
           !a.matches(instanceID: a.instanceID, endpointIdentity: "ep-A",
                      accountScope: "account-B"), "host and account mismatch fail closed")

    let duplicate = try summary("shared", title: "same Session ID")
    let fixture = UnifiedFixture()
    let model = UnifiedSessionModel()
    model.start(sources: [fixture.held(a, name: "Host A", cached: [duplicate]),
                          fixture.held(b, name: "Host B", cached: [duplicate])], query: "")
    expect(model.records.count == 2 && Set(model.records.map(\.id)).count == 2,
           "two different hosts retain both copies of one Session ID")
    await spin { fixture.waiting.count == 2 }
    fixture.waiting.removeValue(forKey: a.instanceID)!.resume(returning: [duplicate])
    fixture.waiting.removeValue(forKey: b.instanceID)!.resume(throwing: URLError(.timedOut))
    await model.waitForRefresh()
    expect(model.records.count == 2 && model.failures[b] != nil && model.failures[a] == nil,
           "one failed backend keeps cached records without erasing successful host")
    expect(model.loading.isEmpty, "per-host loading flags settle")

    let body = try summary("body-only", title: "unrelated")
    let gateway = try summary("gateway-hit", title: "needle heading")
    let ignored = try summary("ignored", title: "other")
    let web = UnifiedSessionSource(identity: a, instanceName: "WebUI", cached: nil,
        load: { throw URLError(.unsupportedURL) },
        searchFullBody: { _ in
            [SessionSearchHit(session: body, matchType: "content", preview: "needle in body")]
        })
    let local = UnifiedSessionSource(identity: b, instanceName: "Gateway", cached: nil,
        load: { [gateway, ignored] }, searchFullBody: nil)
    model.start(sources: [web, local], query: "needle")
    await model.waitForRefresh()
    expect(Set(model.records.map(\.session.sessionId)) == ["body-only", "gateway-hit"],
           "server full-body hit and Gateway title-only hit both appear")
    expect(model.records.first(where: { $0.session.sessionId == "body-only" })?.matchedFullBody == true,
           "the full-body hit is accurately labeled")

    let hanging = UnifiedFixture()
    model.start(sources: [hanging.held(a, name: "Old")], query: "")
    await spin { hanging.waiting[a.instanceID] != nil }
    let fresh = try summary("fresh", title: "new")
    model.start(sources: [UnifiedSessionSource(identity: b, instanceName: "New", cached: nil,
        load: { [fresh] }, searchFullBody: nil)], query: "")
    await model.waitForRefresh()
    hanging.waiting.removeValue(forKey: a.instanceID)!.resume(returning: [duplicate])
    for _ in 0..<20 { await Task.yield() }
    expect(model.records.map(\.session.sessionId) == ["fresh"] && model.failures.isEmpty,
           "cancelled older generation must not corrupt new host's search")

    let wave = UnifiedFixture()
    let identities = (0..<5).map { i in
        UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "host-\(i)",
                               accountScope: "account-\(i)")
    }
    model.start(sources: identities.enumerated().map { i, identity in
        wave.held(identity, name: "Host \(i)")
    }, query: "")
    await spin { wave.waiting.count == 3 }
    expect(wave.waiting.count == 3, "no more than three concurrent instance loads")
    for identity in identities.prefix(3) {
        wave.waiting.removeValue(forKey: identity.instanceID)!.resume(returning: [duplicate])
    }
    await spin { wave.waiting.count == 2 }
    for identity in identities.suffix(2) {
        wave.waiting.removeValue(forKey: identity.instanceID)!.resume(returning: [duplicate])
    }
    await model.waitForRefresh()
    expect(model.records.count == 5 && Set(model.records.map(\.id)).count == 5,
           "all five hosts publish independent, collision-free rows")
    print("UNIFIED_SEARCH_PASS scoped identity, partial failures, two search modes, stale callbacks, concurrency cap")
}
