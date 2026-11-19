import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var checks = 0

private func browserScrollPolicyTests() {
    let bookmarks = ["a", "b", "c", "d"]
expect(UnifiedBrowserScrollPolicy.reconcile(
    anchor: "c", index: 2, available: bookmarks, resolved: true) == "c",
    "refresh retains an existing visible session or task row")
expect(UnifiedBrowserScrollPolicy.reconcile(
    anchor: "c", index: 2, available: ["a", "d"], resolved: false) == "c",
    "unresolved loading must not replace the saved row")
expect(UnifiedBrowserScrollPolicy.reconcile(
    anchor: "c", index: 2, available: ["a", "b", "d"], resolved: true) == "d",
    "missing row falls back to nearest surviving index")
expect(UnifiedBrowserScrollPolicy.reconcile(
    anchor: "c", index: 8, available: ["a", "b"], resolved: true) == "b",
    "fallback clamps an old index to the refreshed list")
expect(UnifiedBrowserScrollPolicy.reconcile(
    anchor: "c", index: 2, available: [], resolved: true) == nil,
    "empty resolved results clear an invalid bookmark")
expect(UnifiedBrowserScrollPolicy.reconcile(
    anchor: nil, index: 1, available: bookmarks, resolved: true) == nil,
    "new query or account has no inherited scroll bookmark")

    let failing = UnifiedSessionIdentity(
        instanceID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        endpointIdentity: "http://failing-host:8000", accountScope: "account-f")
    let healthy = UnifiedSessionIdentity(
        instanceID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        endpointIdentity: "http://healthy-host:8000", accountScope: "account-h")
    let sameSessionDifferentAccount = UnifiedSessionIdentity(
        instanceID: failing.instanceID,
        endpointIdentity: failing.endpointIdentity, accountScope: "other-account")
    let failingRow = failing.recordIDPrefix + "11:session-xyz"
    let healthyRow = healthy.recordIDPrefix + "11:session-xyz"
    let alienAccountRow = sameSessionDifferentAccount.recordIDPrefix + "11:session-xyz"
    expect(UnifiedBrowserScrollPolicy.onFailedSource(failingRow, failures: [failing]),
           "a failed source is identified by complete host/endpoint/account scope")
    expect(!UnifiedBrowserScrollPolicy.onFailedSource(healthyRow, failures: [failing])
           && !UnifiedBrowserScrollPolicy.onFailedSource(
               alienAccountRow, failures: [failing]),
           "identical server session IDs and hosts with other accounts do not collide")
    expect(UnifiedBrowserScrollPolicy.reconcile(
        anchor: failingRow, index: 1, available: [healthyRow],
        resolved: true, failedSources: [failing]) == failingRow,
        "one successful host never replaces a failed host's bookmark")
    expect(UnifiedBrowserScrollPolicy.reconcile(
        anchor: failingRow, index: 1, available: [healthyRow],
        resolved: true, failedSources: [healthy]) == healthyRow,
        "unrelated host failures do not block a verified old-host deletion fallback")
    expect(UnifiedBrowserScrollPolicy.reconcile(
        anchor: failingRow, index: 1, available: [healthyRow],
        resolved: true, failedSources: []) == healthyRow,
        "successful host retry without old session can release bookmark")
    expect(UnifiedBrowserScrollPolicy.reconcile(
        anchor: failingRow, index: 1, available: [failingRow, healthyRow],
        resolved: true, failedSources: [failing]) == failingRow,
        "a row still present in cache must retain its exact position on failure")
    expect(UnifiedBrowserScrollPolicy.reconcile(
        anchor: failingRow, index: 1, available: [],
        resolved: true, failedSources: [failing]) == failingRow,
        "failure with no loaded rows cannot certify an empty result")
    expect(!UnifiedBrowserScrollPolicy.shouldCapture(
        userOwnsScroll: false, id: healthyRow, available: [healthyRow]),
        "programmatic restore or reflow never overwrites a saved bookmark")
    expect(UnifiedBrowserScrollPolicy.shouldCapture(
        userOwnsScroll: true, id: healthyRow, available: [healthyRow]),
        "a user-driven visible row may update its section's bookmark")
    expect(!UnifiedBrowserScrollPolicy.shouldCapture(
        userOwnsScroll: true, id: failingRow, available: [healthyRow]),
        "stale rows outside the current list are never recorded")

    // build210: programmatic offset animations never claim the user's anchor.
    var ownership = UnifiedBrowserScrollOwnership()
    expect(!ownership.userOwnsScroll && ownership.datasetChanged(),
           "initial programmatic refresh may reconcile normally")
    expect(!ownership.receive(.idle) && !ownership.userOwnsScroll,
           "programmatic animation settling does not create user ownership")
    expect(!ownership.receive(.decelerating) && !ownership.userOwnsScroll,
           "momentum without a prior finger drag cannot capture a bookmark")

    expect(!ownership.receive(.interacting) && ownership.userOwnsScroll,
           "finger drag claims browser offset ownership")
    expect(UnifiedBrowserScrollPolicy.shouldCapture(
        userOwnsScroll: ownership.userOwnsScroll, id: "b", available: bookmarks),
        "drag-time scroll position may update the current section")
    expect(!ownership.datasetChanged() && ownership.deferredReconcile,
           "a refresh during a finger drag defers programmatic restoration")
    expect(!ownership.receive(.decelerating) && ownership.userOwnsScroll,
           "inertial deceleration remains part of the user's scroll")
    expect(!ownership.datasetChanged() && ownership.deferredReconcile,
           "late host refresh during momentum remains deferred")
    expect(UnifiedBrowserScrollPolicy.shouldCapture(
        userOwnsScroll: ownership.userOwnsScroll, id: "d", available: bookmarks),
        "final momentum position is captured before idle releases ownership")
    expect(ownership.receive(.idle) && !ownership.userOwnsScroll
           && !ownership.deferredReconcile,
           "idle flushes pending refresh exactly once after capturing final row")
    expect(!ownership.receive(.idle) && ownership.datasetChanged(),
           "subsequent programmatic layout changes may reconcile but not recapture")
    expect(!UnifiedBrowserScrollPolicy.shouldCapture(
        userOwnsScroll: ownership.userOwnsScroll, id: "a", available: bookmarks),
        "post-gesture programmatic position cannot overwrite the user's bookmark")

    // A short drag has no momentum; a route/identity reset cancels old tasks.
    expect(!ownership.receive(.interacting), "new drag begins without a flush")
    expect(!ownership.datasetChanged(), "a short dragging refresh stays deferred")
    ownership.reset()
    expect(!ownership.receive(.idle) && !ownership.userOwnsScroll
           && !ownership.deferredReconcile,
           "switching route, search or account retires old gesture ownership")
    expect(!ownership.receive(.interacting)
           && !ownership.receive(.idle) && !ownership.userOwnsScroll,
           "short drag without momentum commits at the final idle transition")
}

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { print("FAIL: \(message)"); exit(1) }
}

@MainActor final class ControlledService: SessionDiscoveryService {
    var pending: [String: CheckedContinuation<SessionSearchResponse, Error>] = [:]
    var archivePending: [Int: CheckedContinuation<ArchivedSessionPage, Error>] = [:]
    var calls: [String] = []
    var offsets: [Int] = []
    func searchSessions(query: String) async throws -> SessionSearchResponse {
        calls.append(query)
        return try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func archivedSessions(offset: Int, limit: Int) async throws -> ArchivedSessionPage {
        offsets.append(offset)
        return try await withCheckedThrowingContinuation { archivePending[offset] = $0 }
    }
    func finish(_ query: String, id: String) throws {
        pending.removeValue(forKey: query)!.resume(returning: try SessionSearchResponse(data: Data("{\"sessions\":[{\"session_id\":\"\(id)\",\"match_type\":\"content\"}],\"count\":1}".utf8)))
    }
}
@MainActor func spin(_ predicate: () -> Bool) async {
    for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
    expect(false, "async operation did not reach expected state")
}

@MainActor func refreshTests() async throws {
    let service = ControlledService()
    let search = SessionSearchModel(debounce: {})
    let initial = search.update(query: "same", scope: "A", service: service)
    await spin { service.pending["same"] != nil }
    var refreshEnded = false
    let joined = Task { await search.refresh(query: "same", scope: "A", service: service); refreshEnded = true }
    for _ in 0..<20 { await Task.yield() }
    expect(service.calls == ["same"] && !refreshEnded && search.loading,
           "pull refresh joins an active matching search and awaits its completion")
    try service.finish("same", id: "first")
    await initial?.value; await joined.value
    expect(refreshEnded && search.hits.map(\.id) == ["first"], "joined refresh publishes the real search result")

    let fresh = Task { await search.refresh(query: "same", scope: "A", service: service) }
    await spin { service.pending["same"] != nil }
    expect(service.calls == ["same", "same"] && search.hits.map(\.id) == ["first"],
           "refreshing a finished query requests the server while preserving visible results")
    try service.finish("same", id: "updated")
    await fresh.value
    expect(search.hits.map(\.id) == ["updated"] && !search.loading, "fresh search replaces the previous result")

    let failedSearch = Task { await search.refresh(query: "same", scope: "A", service: service) }
    await spin { service.pending["same"] != nil }
    service.pending.removeValue(forKey: "same")!.resume(throwing: URLError(.timedOut))
    await failedSearch.value
    expect(search.hits.map(\.id) == ["updated"] && search.errorText != nil && !search.loading,
           "failed same-query refresh keeps previous results and publishes retry feedback")

    let old = Task { await search.refresh(query: "old-refresh", scope: "A", service: service) }
    await spin { service.pending["old-refresh"] != nil }
    let latest = Task { await search.refresh(query: "new-refresh", scope: "B", service: service) }
    await spin { service.pending["new-refresh"] != nil }
    expect(search.hits.isEmpty, "query or scope changes immediately clear the previous query's results")
    service.pending.removeValue(forKey: "old-refresh")!.resume(throwing: URLError(.timedOut))
    await old.value
    expect(search.loading && search.errorText == nil && search.scope == "B",
           "late refreshed search failure does not clear a new scope's busy state")
    try service.finish("new-refresh", id: "new-scope")
    await latest.value
    expect(search.hits.map(\.id) == ["new-scope"], "query/scope changes cancel the previous refresh ownership")

    let archives = SessionArchiveModel(pageSize: 2)
    let archiveService = ControlledService()
    let reload = Task { await archives.reload(scope: "A", service: archiveService) }
    await spin { archiveService.archivePending[0] != nil }
    var secondEnded = false
    let duplicate = Task { await archives.reload(scope: "A", service: archiveService); secondEnded = true }
    for _ in 0..<20 { await Task.yield() }
    expect(archiveService.offsets == [0] && !secondEnded,
           "footer and pull archive refresh share one first-page request and both await it")
    let page = try ArchivedSessionPage(data: Data(#"{"sessions":[{"session_id":"a1","archived":true},{"session_id":"a2","archived":true}],"archived_count":4,"archived_limit":2,"archived_offset":0}"#.utf8))
    archiveService.archivePending.removeValue(forKey: 0)!.resume(returning: page)
    await reload.value; await duplicate.value
    expect(archives.sessions.map(\.id) == ["a1", "a2"] && secondEnded, "coalesced archive reload publishes rows")
    let more = Task { await archives.loadMore(service: archiveService) }
    await spin { archiveService.archivePending[2] != nil }
    let restart = Task { await archives.reload(scope: "A", service: archiveService) }
    await spin { archiveService.archivePending[0] != nil }
    archiveService.archivePending.removeValue(forKey: 2)!.resume(returning: try ArchivedSessionPage(data: Data(#"{"sessions":[{"session_id":"obsolete","archived":true}],"archived_count":3,"archived_limit":2,"archived_offset":2}"#.utf8)))
    await more.value
    expect(archives.sessions.map(\.id) == ["a1", "a2"] && archives.loading,
           "pull refresh preserves original rows while rejecting a late load-more page")
    archiveService.archivePending.removeValue(forKey: 0)!.resume(returning: try ArchivedSessionPage(data: Data(#"{"sessions":[{"session_id":"fresh-archive","archived":true}],"archived_count":1,"archived_limit":2,"archived_offset":0}"#.utf8)))
    await restart.value
    expect(archiveService.offsets == [0, 2, 0] && archives.sessions.map(\.id) == ["fresh-archive"] && archives.nextOffset == nil,
           "archive refresh restarts real pagination at zero instead of appending a stale page")
    let failedArchive = Task { await archives.reload(scope: "A", service: archiveService) }
    await spin { archiveService.archivePending[0] != nil }
    archiveService.archivePending.removeValue(forKey: 0)!.resume(throwing: URLError(.timedOut))
    await failedArchive.value
    expect(archives.sessions.map(\.id) == ["fresh-archive"] && archives.errorText != nil && archives.nextOffset == 0,
           "failed first-page refresh preserves the visible archive and retries page zero")
    let clearedArchive = Task { await archives.reload(scope: "A", service: archiveService) }
    await spin { archiveService.archivePending[0] != nil }
    archiveService.archivePending.removeValue(forKey: 0)!.resume(returning: try ArchivedSessionPage(data: Data(#"{"sessions":[],"archived_count":0,"archived_limit":2,"archived_offset":0}"#.utf8)))
    await clearedArchive.value
    expect(archives.sessions.isEmpty && archives.errorText == nil && archives.nextOffset == nil,
           "a successful empty refresh really replaces a previously populated archive")
}

@main struct DiscoveryTests {
    @MainActor static func main() async throws {
        let requests = ChatRequests(baseURL: URL(string: "https://example.test/prefix")!)
        let search = try requests.searchSessions(query: "中文 + & ?")
        let parts = URLComponents(url: search.url!, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
        expect(parts.path == "/prefix/api/sessions/search", "search uses deployed route and base path")
        expect(q["q"] == "中文 + & ?", "search preserves Unicode and reserved characters")
        expect(parts.percentEncodedQuery!.contains("%2B"), "literal plus is form-urlencoded safe")
        expect(q["content"] == "1" && q["depth"] == "0", "search scans full server transcript, not first five messages")
        expect(q["all_profiles"] == "0", "search stays in active profile")
        expect(search.httpMethod == "GET" && search.httpBody == nil, "search is read only")
        let archive = try requests.archivedSessions(offset: 40, limit: 20)
        let a = URLComponents(url: archive.url!, resolvingAgainstBaseURL: false)!
        let aq = Dictionary(uniqueKeysWithValues: a.queryItems!.map { ($0.name, $0.value!) })
        expect(a.path == "/prefix/api/sessions", "archive uses list route")
        expect(aq["archived_offset"] == "40" && aq["archived_limit"] == "20", "archive sends real server pagination")
        expect(aq["include_archived"] == "1" && aq["all_profiles"] == "0", "archive explicitly scopes request")
        let results = try SessionSearchResponse(data: Data(#"{"sessions":[{"session_id":"body-only","title":"无关键词标题","match_type":"content","match_preview":"命中正文"}],"count":1,"query":"正文"}"#.utf8))
        expect(results.hits.count == 1 && results.hits[0].session.sessionId == "body-only", "body-only result survives without local title filtering")
        expect(results.hits[0].matchType == "content" && results.hits[0].preview == "命中正文", "server match type and excerpt preserved")
        let page = try ArchivedSessionPage(data: Data(#"{"sessions":[{"session_id":"active","archived":false},{"session_id":"a1","archived":true},{"session_id":"a2","archived":true}],"archived_count":3,"archived_limit":2,"archived_offset":0}"#.utf8))
        expect(page.sessions.map(\.sessionId) == ["a1", "a2"], "archive strips repeated unpaged active rows")
        expect(page.nextOffset == 2 && page.total == 3, "cursor advances by server archived row count")
        let last = try ArchivedSessionPage(data: Data(#"{"sessions":[{"session_id":"a3","archived":true}],"archived_count":3,"archived_limit":2,"archived_offset":2}"#.utf8))
        expect(last.nextOffset == nil, "last archive page terminates")
        for bad in [#"{"error":"not a result"}"#, #"{"sessions":[],"count":2}"#] {
            do { _ = try SessionSearchResponse(data: Data(bad.utf8)); expect(false, "malformed search must not look empty") }
            catch { expect(true, "malformed search rejected") }
        }
        do { _ = try ArchivedSessionPage(data: Data(#"{"sessions":[],"archived_count":3}"#.utf8)); expect(false, "missing paging metadata rejected") }
        catch { expect(true, "missing paging metadata rejected") }
        let service = ControlledService()
        let model = SessionSearchModel(debounce: {})
        let oldRequest = model.update(query: "old", scope: "A", service: service)
        await spin { service.pending["old"] != nil }
        let newRequest = model.update(query: "new", scope: "B", service: service)
        await spin { service.pending["new"] != nil }
        try service.finish("old", id: "leaked-A")
        await oldRequest?.value
        expect(model.hits.isEmpty && model.loading, "late old-instance response cannot publish or clear new busy state")
        try service.finish("new", id: "only-B")
        await newRequest?.value
        expect(model.hits.map(\.id) == ["only-B"] && model.scope == "B", "new instance result wins")
        let badRequest = model.update(query: "bad", scope: "B", service: service)
        await spin { service.pending["bad"] != nil }
        service.pending.removeValue(forKey: "bad")!.resume(throwing: URLError(.notConnectedToInternet))
        await badRequest?.value
        expect(model.errorText != nil && model.hits.isEmpty, "search network error remains visible and clears stale results")
        model.update(query: "  ", scope: "B", service: service)
        expect(!model.loading && model.hits.isEmpty && model.errorText == nil, "blank query cancels and resets state")
        let delayed = SessionSearchModel()
        let delayedRequest = delayed.update(query: "never-request", scope: "B", service: service)
        delayed.cancel()
        await delayedRequest?.value
        expect(!service.calls.contains("never-request") && !delayed.loading, "cancel stops debounce before network starts")
        let earlyQuery = model.update(query: "early", scope: "B", service: service)
        await spin { service.pending["early"] != nil }
        let latestQuery = model.update(query: "latest", scope: "B", service: service)
        await spin { service.pending["latest"] != nil }
        try service.finish("latest", id: "latest-only")
        await latestQuery?.value
        service.pending.removeValue(forKey: "early")!.resume(throwing: URLError(.timedOut))
        await earlyQuery?.value
        expect(model.hits.map(\.id) == ["latest-only"] && model.errorText == nil, "late same-instance search failure cannot overwrite newer result")
        let cancelledRequest = model.update(query: "cancel-inflight", scope: "B", service: service)
        await spin { service.pending["cancel-inflight"] != nil }
        model.cancel()
        try service.finish("cancel-inflight", id: "must-not-return")
        await cancelledRequest?.value
        expect(model.hits.isEmpty && !model.loading && model.errorText == nil, "cancelled in-flight result cannot repopulate a hidden search")
        let archives = SessionArchiveModel(pageSize: 2)
        let archiveService = ControlledService()
        let firstLoad = Task { await archives.reload(scope: "A", service: archiveService) }
        await spin { archiveService.archivePending[0] != nil }
        await archives.loadMore(service: archiveService)
        expect(archiveService.offsets == [0], "busy gate prevents duplicate archive page requests")
        archiveService.archivePending.removeValue(forKey: 0)!.resume(returning: page)
        await firstLoad.value
        expect(archives.sessions.map(\.sessionId) == ["a1", "a2"] && archives.nextOffset == 2, "archive first page is published")
        let failedMore = Task { await archives.loadMore(service: archiveService) }
        await spin { archiveService.archivePending[2] != nil }
        archiveService.archivePending.removeValue(forKey: 2)!.resume(throwing: URLError(.timedOut))
        await failedMore.value
        expect(archives.sessions.count == 2 && archives.nextOffset == 2 && archives.errorText != nil, "load-more failure preserves rows and retry cursor")
        let retryMore = Task { await archives.loadMore(service: archiveService) }
        await spin { archiveService.archivePending[2] != nil }
        archiveService.archivePending.removeValue(forKey: 2)!.resume(returning: try ArchivedSessionPage(data: Data(#"{"sessions":[{"session_id":"a2","archived":true},{"session_id":"a3","archived":true}],"archived_count":4,"archived_limit":2,"archived_offset":2}"#.utf8)))
        await retryMore.value
        expect(archives.sessions.map(\.sessionId) == ["a1", "a2", "a3"] && archives.nextOffset == nil, "overlap deduplicates rows but cursor uses raw server count")
        expect(archiveService.offsets == [0, 2, 2], "retry uses identical server cursor, not local slicing")
        let staleService = ControlledService()
        let freshService = ControlledService()
        let oldArchive = Task { await archives.reload(scope: "old", service: staleService) }
        await spin { staleService.archivePending[0] != nil }
        let newArchive = Task { await archives.reload(scope: "new", service: freshService) }
        await spin { freshService.archivePending[0] != nil }
        staleService.archivePending.removeValue(forKey: 0)!.resume(returning: page)
        await oldArchive.value
        expect(archives.sessions.isEmpty && archives.loading && archives.scope == "new", "late archive page cannot contaminate new instance or clear busy state")
        freshService.archivePending.removeValue(forKey: 0)!.resume(returning: try ArchivedSessionPage(data: Data(#"{"sessions":[],"archived_count":0,"archived_limit":2,"archived_offset":0}"#.utf8)))
        await newArchive.value
        expect(archives.sessions.isEmpty && !archives.loading && archives.nextOffset == nil, "empty archive is a valid terminal page")
        var requestedURLs: [URL] = []
        let liveContract = SessionListService(requests: requests) { request in
            requestedURLs.append(request.url!)
            if request.url!.path.hasSuffix("/search") {
                return Data(#"{"sessions":[{"session_id":"remote-body","match_type":"content"}],"count":1}"#.utf8)
            }
            return Data(#"{"sessions":[{"session_id":"page-two","archived":true}],"archived_count":3,"archived_limit":2,"archived_offset":2}"#.utf8)
        }
        let fetchedHit = try await liveContract.searchSessions(query: "deep")
        let fetchedPage = try await liveContract.archivedSessions(offset: 2, limit: 2)
        expect(fetchedHit.hits.first?.id == "remote-body" && fetchedPage.sessions.first?.sessionId == "page-two", "service returns decoded network responses")
        expect(requestedURLs.count == 2 && requestedURLs[1].query!.contains("archived_offset=2"), "service really requests next page")
        let brokenContract = SessionListService(requests: requests) { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await brokenContract.searchSessions(query: "fail"); expect(false, "network failure must propagate") }
        catch { expect(true, "network failure propagates") }
        do { _ = try requests.searchSessions(query: "  \n "); expect(false, "blank search must not trigger server all-session fallback") }
        catch { expect(true, "blank search rejected") }
        for pair in [(-1, 20), (0, 0), (0, 2001), (200001, 20)] {
            do { _ = try requests.archivedSessions(offset: pair.0, limit: pair.1); expect(false, "invalid archive cursor must not be silently clamped by server") }
            catch { expect(true, "invalid archive bounds rejected") }
        }
        do { _ = try ArchivedSessionPage(data: Data(#"{"sessions":[],"archived_count":10,"archived_limit":2,"archived_offset":0}"#.utf8)); expect(false, "nonadvancing archive page cannot silently finish") }
        catch { expect(true, "nonadvancing archive page rejected") }
        browserScrollPolicyTests()
        try await refreshTests()
        try await unifiedSessionTests()
        try await unifiedRefreshTests()
        try await unifiedCacheTests()
        try unifiedTaskWorkspaceTests()
        print("PASS: \(checks) discovery checks")
    }
}
