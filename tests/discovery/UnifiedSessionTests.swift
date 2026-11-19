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

    // A stale-only automatic refresh is upgraded in place when the user
    // chooses full refresh. Both hosts must be fetched exactly once, and the
    // returned task must not finish until the queued additional host finishes.
    do {
        let a = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "partial-a",
                                       accountScope: "account")
        let b = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "partial-b",
                                       accountScope: "account")
        let f = UnifiedFixture()
        let one = f.held(a, name: "stale")
        let two = f.held(b, name: "fresh")
        let center = UnifiedSessionModel()
        let partial = center.start(sources: [one, two], query: "", only: Set([a]))
        await spin { f.waiting[a.instanceID] != nil }
        let forced = center.start(sources: [one, two], query: "")
        expect(f.calls[a.instanceID] == 1,
               "manual refresh reuses the ongoing stale-host GET")
        f.waiting.removeValue(forKey: a.instanceID)!
            .resume(returning: [try row("partial-a")])
        await spin { f.waiting[b.instanceID] != nil }
        expect(f.calls[b.instanceID] == 1 && center.loading.contains(b),
               "manual full refresh also schedules previously fresh host")
        f.waiting.removeValue(forKey: b.instanceID)!
            .resume(returning: [try row("partial-b")])
        await partial.value; await forced.value
        expect(center.records.count == 2 && center.loading.isEmpty,
               "full refresh completion includes both hosts with one GET each")
    }

    // build209: mixed three-host completion must not treat one successful
    // host as proof that another host's bookmarked row was deleted.
    do {
        let first = UnifiedSessionIdentity(instanceID: UUID(),
            endpointIdentity: "209-a", accountScope: "first")
        let missing = UnifiedSessionIdentity(instanceID: UUID(),
            endpointIdentity: "209-b", accountScope: "second")
        let third = UnifiedSessionIdentity(instanceID: UUID(),
            endpointIdentity: "209-c", accountScope: "third")
        let f = UnifiedFixture()
        let sourceA = f.held(first, name: "A")
        let sourceB = f.held(missing, name: "B")
        let sourceC = f.held(third, name: "C")
        let center = UnifiedSessionModel()
        let saved = UnifiedSessionRecord(identity: missing, instanceName: "B",
            session: try row("old-bookmark"), excerpt: nil,
            matchedFullBody: false).id
        let started = center.start(sources: [sourceA, sourceB, sourceC], query: "")
        await spin { f.waiting.count == 3 }
        f.waiting.removeValue(forKey: first.instanceID)!
            .resume(returning: [try row("healthy-A")])
        f.waiting.removeValue(forKey: missing.instanceID)!
            .resume(throwing: URLError(.timedOut))
        f.waiting.removeValue(forKey: third.instanceID)!
            .resume(returning: [try row("healthy-C")])
        await started.value
        let available = center.records.map(\.id)
        expect(center.hasResolvedSnapshot && center.failures[missing] != nil
               && center.loading.isEmpty && available.count == 2,
               "three-host snapshot is partially successful, with a failed source")
        expect(UnifiedBrowserScrollPolicy.reconcile(anchor: saved, index: 1,
               available: available, resolved: center.hasResolvedSnapshot,
               failedSources: Set(center.failures.keys)) == saved,
               "mixed success/timeout keeps the absent failed host's bookmark")
        let retry = Task { await center.retry(source: sourceB, query: "") }
        await spin { f.waiting[missing.instanceID] != nil }
        f.waiting.removeValue(forKey: missing.instanceID)!
            .resume(returning: [try row("confirmed-new")])
        await retry.value
        let freshRows = center.records.map(\.id)
        let after = UnifiedBrowserScrollPolicy.reconcile(
            anchor: saved, index: 1, available: freshRows,
            resolved: center.hasResolvedSnapshot,
            failedSources: Set(center.failures.keys))
        expect(center.failures[missing] == nil && after != nil && after != saved
               && freshRows.contains(after!),
               "successful retry may fall back only after the old row is confirmed gone")
    }

    // After leaving and re-entering a fresh cache, retry must still work
    // even though cancel() has intentionally cleared the old requestKey.
    do {
        let a = UnifiedSessionIdentity(instanceID: UUID(), endpointIdentity: "retry-host",
                                       accountScope: "retry-account")
        let f = UnifiedFixture()
        let src = f.held(a, name: "retry after back", cached: [try row("old")])
        let center = UnifiedSessionModel()
        let initial = center.start(sources: [src], query: "")
        await spin { f.waiting[a.instanceID] != nil }
        f.waiting.removeValue(forKey: a.instanceID)!
            .resume(returning: [try row("cached")])
        await initial.value
        let failed = center.start(sources: [src], query: "")
        await spin { f.waiting[a.instanceID] != nil }
        f.waiting.removeValue(forKey: a.instanceID)!
            .resume(throwing: URLError(.notConnectedToInternet))
        await failed.value
        center.cancel()
        expect(center.refreshIfNeeded(sources: [src], query: "", now: Date()) == nil &&
               center.failures[a] != nil,
               "cached reentry preserves failed host without a new GET")
        let again = Task { await center.retry(source: src, query: "") }
        await spin { f.waiting[a.instanceID] != nil }
        f.waiting.removeValue(forKey: a.instanceID)!
            .resume(returning: [try row("retried")])
        await again.value
        expect(center.records.map(\.session.sessionId) == ["retried"] &&
               center.failures[a] == nil && f.calls[a.instanceID] == 3,
               "retry after cached reentry fetches once and clears failure")
    }

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
    // build197: TaskGroup cancellation cannot bound a transport that ignores
    // cancellation. Detached probe deliberately finishes later; the browser
    // must settle by its own deadline and must not publish the late result.
    let badID = UnifiedSessionIdentity(instanceID: UUID(),
        endpointIdentity: "uncancellable-host", accountScope: "isolated-account")
    let lateRow = try row("late-bad-host")
    let stubborn = UnifiedSessionSource(identity: badID, instanceName: "Noncooperative",
        cached: nil, load: {
            let detached = Task.detached {
                try? await Task.sleep(nanoseconds: 650_000_000)
                return [lateRow]
            }
            return await detached.value
        }, searchFullBody: nil)
    let quickHosts = (0..<4).map { index -> UnifiedSessionSource in
        let identity = UnifiedSessionIdentity(instanceID: UUID(),
            endpointIdentity: "quick-\(index)", accountScope: "scope-\(index)")
        return UnifiedSessionSource(identity: identity, instanceName: "Healthy",
            cached: nil, load: { [lateRow] in
                var copy = lateRow
                copy.title = "healthy-\(index)"
                return [copy]
            }, searchFullBody: nil)
    }
    let hardTimeout = UnifiedSessionModel(hostTimeoutNanoseconds: 25_000_000)
    let start = Date()
    await hardTimeout.start(sources: [stubborn] + quickHosts, query: "").value
    let seconds = Date().timeIntervalSince(start)
    expect(seconds < 0.40,
           "uncancellable host must not postpone browser beyond its deadline (\(seconds)s)")
    expect(hardTimeout.records.count == 4 && hardTimeout.failures[badID] != nil
           && hardTimeout.loading.isEmpty,
           "four healthy hosts complete despite one uncooperative timeout")
    await hardTimeout.start(sources: quickHosts, query: "").value
    try? await Task.sleep(nanoseconds: 720_000_000)
    expect(hardTimeout.records.count == 4
           && !hardTimeout.records.contains(where: { $0.identity == badID }),
           "late response cannot repopulate changed request scope")

    let slowBody = UnifiedSessionSource(identity: badID, instanceName: "Slow Search",
        cached: nil, load: { [] }, searchFullBody: { _ in
            let detached = Task.detached {
                try? await Task.sleep(nanoseconds: 650_000_000)
                return [SessionSearchHit(session: lateRow, matchType: "content", preview: nil)]
            }
            return await detached.value
        })
    let searchTimeout = UnifiedSessionModel(hostTimeoutNanoseconds: 25_000_000)
    let searchStart = Date()
    await searchTimeout.start(sources: [slowBody], query: "body").value
    expect(Date().timeIntervalSince(searchStart) < 0.40
           && searchTimeout.failures[badID] != nil,
           "WebUI full-body search also bounds uncooperative requests")
    // build198: ten independently scoped hosts under the existing three-slot
    // window. Failing hosts must release their browser slot on the deadline;
    // a healthy host must publish without awaiting an unrelated failed GET.
    let tenScopes = (0..<10).map { index in
        UnifiedSessionIdentity(instanceID: UUID(),
            endpointIdentity: "build198-host-\(index)",
            accountScope: "build198-account-\(index)")
    }
    let tenSources = try tenScopes.enumerated().map { index, host -> UnifiedSessionSource in
        let healthyRow = try row("ten-\(index)")
        return UnifiedSessionSource(identity: host, instanceName: "Host \(index)",
            cached: nil, load: {
                if index % 3 == 0 {
                    let delayed = Task.detached {
                        try? await Task.sleep(nanoseconds: 170_000_000)
                        return [healthyRow]
                    }
                    return await delayed.value
                }
                return [healthyRow]
            }, searchFullBody: nil)
    }
    let tenCenter = UnifiedSessionModel(hostTimeoutNanoseconds: 30_000_000)
    let tenStart = Date()
    await tenCenter.start(sources: tenSources, query: "").value
    expect(Date().timeIntervalSince(tenStart) < 0.50,
           "ten-host browser window must finish after bounded independent host deadlines")
    expect(tenCenter.records.count == 6 && tenCenter.failures.count == 4
           && tenCenter.loading.isEmpty,
           "six healthy hosts are visible and four unresponsive hosts have isolated errors")
    expect(Set(tenCenter.records.map(\.identity)).count == 6
           && Set(tenCenter.failures.keys).isDisjoint(
               with: Set(tenCenter.records.map(\.identity))),
           "instance/account identity prevents failure or record crossover")

    print("UNIFIED_DEADLINE_PASS noncooperative host, full-body search and ten-host window")

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
    center.adoptActiveList(identity: b, instanceName: "other account",
                           rows: [try row("event-update")], refreshedAt: Date())
    expect(center.records.map(\.session.sessionId) == ["event-update"],
           "active Gateway list event updates the unified cache without an extra GET")
    expect(fixture.calls[b.instanceID] == 1,
           "adopting a live active-host update must not duplicate GET")

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
    // Returning to a previously resolved query must reuse its full-body
    // result rather than falling back to a title-only projection.
    let latest = Date()
    let backToList = center.refreshIfNeeded(sources: [changed], query: "", now: latest)
    expect(backToList == nil, "recent list query stays fresh across search switching")
    expect(center.records.map(\.session.sessionId) == ["event-update"],
           "previous list rows are restored after leaving search")
    let priorSearch = center.refreshIfNeeded(sources: [changed], query: "private", now: latest)
    expect(priorSearch == nil && center.records.map(\.session.sessionId) == ["private"],
           "returning to a fresh search reuses its scoped matching results")
    expect(fixture.calls[b.instanceID] == 2,
           "cached search does not perform a third network GET")
    // The active host may confirm unchanged rows: the timestamp must still
    // advance without replacing published rows or touching the network.
    center.refreshIfNeeded(sources: [changed], query: "", now: latest)
    let before = center.records.map(\.id)
    center.adoptActiveList(identity: b, instanceName: "other account",
                           rows: [try row("event-update")],
                           refreshedAt: latest.addingTimeInterval(100))
    expect(center.records.map(\.id) == before,
           "unchanged active-host refresh must not rebuild visible record IDs")
    expect(center.refreshIfNeeded(sources: [changed], query: "",
                                  now: latest.addingTimeInterval(340)) == nil,
           "unchanged successful active-host GET advances the five-minute freshness clock")
    print("UNIFIED_CACHE_PASS fresh skip, silent expiry, account isolation, search freshness")
}
