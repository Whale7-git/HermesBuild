import Foundation

@MainActor final class UnifiedFixture {
    var waiting: [UUID: CheckedContinuation<[SessionSummary], Error>] = [:]
    var calls: [UUID: Int] = [:]
    func held(_ identity: UnifiedSessionIdentity, name: String,
              cached: [SessionSummary]? = nil) -> UnifiedSessionSource {
        UnifiedSessionSource(identity: identity, instanceName: name, cached: cached,
            load: {
                self.calls[identity.instanceID, default: 0] += 1
                return try await withCheckedThrowingContinuation {
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
    // A completed source frees one slot immediately: the fourth host does
    // not wait for the remaining two in the original wave to finish.
    wave.waiting.removeValue(forKey: identities[0].instanceID)!.resume(returning: [duplicate])
    await spin { wave.waiting[identities[3].instanceID] != nil }
    expect(wave.waiting.count == 3 && wave.calls.count == 4,
           "sliding window starts fourth host while two earlier hosts remain pending")
    for identity in identities[1...2] {
        wave.waiting.removeValue(forKey: identity.instanceID)!.resume(returning: [duplicate])
    }
    await spin { wave.waiting[identities[4].instanceID] != nil }
    for identity in identities.suffix(2) {
        wave.waiting.removeValue(forKey: identity.instanceID)!.resume(returning: [duplicate])
    }
    await model.waitForRefresh()
    expect(model.records.count == 5 && Set(model.records.map(\.id)).count == 5,
           "all five hosts publish independent, collision-free rows")
    print("UNIFIED_SEARCH_PASS scoped identity, partial failures, two search modes, stale callbacks, concurrency cap")
}

@MainActor func unifiedRefreshTests() async throws {
    func row(_ id: String) throws -> SessionSummary {
        try JSONDecoder().decode(SessionSummary.self,
             from: Data("{\"session_id\":\"\(id)\",\"title\":\"\(id)\"}".utf8))
    }
    let identity = UnifiedSessionIdentity(instanceID: UUID(),
                                         endpointIdentity: "refresh-host",
                                         accountScope: "refresh-account")
    let fixture = UnifiedFixture()
    let source = fixture.held(identity, name: "Host", cached: [try row("cached")])
    let model = UnifiedSessionModel()

    let first = model.start(sources: [source], query: "")
    await spin { fixture.waiting[identity.instanceID] != nil }
    let joined = model.start(sources: [source], query: "")
    for _ in 0..<20 { await Task.yield() }
    expect(fixture.calls[identity.instanceID] == 1,
           "simultaneous automatic, pull and menu refresh share exactly one GET")
    fixture.waiting.removeValue(forKey: identity.instanceID)!
        .resume(returning: [try row("authoritative")])
    await first.value; await joined.value
    expect(model.records.map(\.session.sessionId) == ["authoritative"],
           "one shared refresh replaces cached window on success")

    let failed = model.start(sources: [source], query: "")
    expect(model.records.map(\.session.sessionId) == ["authoritative"],
           "same-query manual refresh keeps previously verified rows visible")
    await spin { fixture.waiting[identity.instanceID] != nil }
    fixture.waiting.removeValue(forKey: identity.instanceID)!
        .resume(throwing: URLError(.notConnectedToInternet))
    await failed.value
    expect(model.records.map(\.session.sessionId) == ["authoritative"] &&
           model.failures[identity] != nil,
           "offline refresh retains rows and records a host-specific error")

    let retry = Task { await model.retry(source: source, query: "") }
    await spin { fixture.waiting[identity.instanceID] != nil }
    expect(model.loading == Set([identity]), "retry sets only the failed host loading flag")
    fixture.waiting.removeValue(forKey: identity.instanceID)!
        .resume(returning: [try row("recovered")])
    await retry.value
    expect(model.records.map(\.session.sessionId) == ["recovered"] &&
           model.failures.isEmpty && model.loading.isEmpty,
           "retry only replaces its source and clears stale error state")
    expect(fixture.calls[identity.instanceID] == 3,
           "coalesced refresh + failed refresh + single-host retry is three GETs")

    // Cancellation-aware fake transports let timeouts be tested without a
    // 20-second sleep or a real network connection.
    let timeboxed = UnifiedSessionModel(hostTimeoutNanoseconds: 20_000_000)
    let slow = UnifiedSessionSource(identity: identity, instanceName: "Slow",
                                    cached: nil,
                                    load: {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return [try row("unexpected")]
    }, searchFullBody: nil)
    await timeboxed.start(sources: [slow], query: "").value
    expect(timeboxed.failures[identity] != nil && timeboxed.records.isEmpty,
           "slow host GET times out rather than blocking the whole center")
    let slowSearch = UnifiedSessionSource(identity: identity, instanceName: "Slow WebUI",
                                          cached: nil, load: { [] },
                                          searchFullBody: { _ in
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return []
    })
    await timeboxed.start(sources: [slowSearch], query: "content").value
    expect(timeboxed.failures[identity] != nil,
           "full-body search gets the same bounded timeout as session GET")
    print("UNIFIED_REFRESH_PASS joined requests, stable rows, per-host retry, bounded GET/search")
}


@MainActor func unifiedCacheTests() async throws {
    func row(_ id: String) throws -> SessionSummary {
        try JSONDecoder().decode(SessionSummary.self,
             from: Data("{\"session_id\":\"\(id)\",\"title\":\"\(id)\"}".utf8))
    }
    let a = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "ep-188",
                                   accountScope: "user-188")
    let b = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "ep-188-other",
                                   accountScope: "different-user")
    let fixture = UnifiedFixture()
    let now = Date()
    var fresh = fixture.held(a, name: "cached", cached: [try row("saved")])
    fresh.cachedAt = now.addingTimeInterval(-10)
    let center = UnifiedSessionModel()
    let skipped = center.refreshIfNeeded(sources: [fresh], query: "", now: now)
    expect(skipped == nil && fixture.calls[a.instanceID] == nil,
           "fresh scoped list cache needs no network")
    expect(center.records.map(\.session.sessionId) == ["saved"] &&
           center.hasResolvedSnapshot, "cached list appears immediately without spinner")
    expect(center.refreshIfNeeded(sources: [fresh], query: "",
                                  now: now.addingTimeInterval(100)) == nil,
           "reentry during five-minute TTL stays offline")

    let slow = center.refreshIfNeeded(sources: [fresh], query: "",
                                     now: now.addingTimeInterval(360))
    expect(slow != nil && center.records.map(\.session.sessionId) == ["saved"],
           "expired rows stay visible while the automatic refresh starts")
    await spin { fixture.waiting[a.instanceID] != nil }
    fixture.waiting.removeValue(forKey: a.instanceID)!
        .resume(returning: [try row("updated")])
    await slow?.value
    expect(center.records.map(\.session.sessionId) == ["updated"],
           "successful background refresh replaces only the scoped data")

    // A different account is never allowed to reuse host A's Session ID or
    // claim that the old account's recent refresh belongs to the new one.
    let changed = fixture.held(b, name: "other account", cached: nil)
    let switched = center.refreshIfNeeded(sources: [changed], query: "", now: now)
    expect(switched != nil && center.records.isEmpty && !center.hasResolvedSnapshot,
           "account switch discards previously visible account rows and freshness")
    await spin { fixture.waiting[b.instanceID] != nil }
    fixture.waiting.removeValue(forKey: b.instanceID)!.resume(returning: [try row("private")])
    await switched?.value
    expect(center.records.map(\.session.sessionId) == ["private"],
           "new account publishes only its own sessions")

    // Search queries are independently resolved; a scoped list timestamp
    // must never suppress full-body search by claiming a cache hit.
    let searched = center.refreshIfNeeded(sources: [changed], query: "private",
                                          now: Date())
    expect(searched != nil, "new query fetches instead of trusting title cache")
    await spin { fixture.waiting[b.instanceID] != nil }
    fixture.waiting.removeValue(forKey: b.instanceID)!.resume(returning: [try row("private")])
    await searched?.value
    expect(center.records.map(\.session.sessionId) == ["private"],
           "query returns the proper matching rows")
    center.cancel()
    expect(center.refreshIfNeeded(sources: [changed], query: "private", now: Date()) == nil,
           "same scoped query reopened within TTL needs no extra network")
    print("UNIFIED_CACHE_PASS fresh skip, silent expiry, account isolation, search freshness")
}
