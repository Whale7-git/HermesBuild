import Foundation

/// Scripted history service. Controlled pages only; never a real API call.
@MainActor final class PagedHistoryService: NativeChatService {
    private let initial: ChatSnapshot
    private let pages: [Int: ChatSnapshot]
    var failure: Error?
    var holdStream = false
    var holdOlderPage = false
    var pendingOlder: CheckedContinuation<ChatSnapshot, Error>?
    private(set) var calls: [Int?] = []

    init(initial: ChatSnapshot, pages: [Int: ChatSnapshot]) {
        self.initial = initial
        self.pages = pages
    }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        calls.append(before)
        if let failure { throw failure }
        if before != nil && holdOlderPage {
            return try await withCheckedThrowingContinuation { pendingOlder = $0 }
        }
        if let before, let page = pages[before] { return page }
        if before == nil { return initial }
        throw URLError(.badServerResponse)
    }

    func startNativeTurn(sessionID: String, text: String) async throws -> String { "stream" }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
        while holdStream && !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func stopNativeTurn(streamID: String) async throws {}
}

private func pagedSnapshot(_ sessionID: String, rows: Range<Int>, offset: Int,
                           toolOnLastRow: Bool = false) throws -> ChatSnapshot {
    var messages: [[String: Any]] = []
    for index in rows {
        var row: [String: Any] = ["id": "row-\(index)", "role": "assistant", "content": "m\(index)"]
        if toolOnLastRow, index == rows.upperBound - 1 {
            row["tool_calls"] = [["id": "tool-\(index)", "name": "grep", "args": "x", "result": "ok"]]
        }
        messages.append(row)
    }
    let session: [String: Any] = [
        "session_id": sessionID,
        "messages": messages,
        "_messages_offset": offset,
        "read_only": false,
    ]
    return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": session]))
}

/// Build50: paging must accept or refuse a whole page before touching the
/// window. The old order prepended and then trimmed the oldest rows, deleting
/// the page just fetched while the cursor still advanced past it.
@MainActor
func runPagingBudgetTests() async throws {
    // 1. An accepted page becomes visible and advances the cursor.
    do {
        let sessionID = "paging-accept"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1900, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 900..<1000, offset: 900)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        precondition(model.olderOffset == 1000 && model.transcript.messages.count == 900)
        await model.loadOlder()
        precondition(model.transcript.messages.count == 1000, "accepted page must stay mounted")
        precondition(model.transcript.messages.first?.id == "row-900", "prepended page must be visible")
        precondition(model.olderOffset == 900, "cursor advances only with an accepted page")
        precondition(model.olderLimitReached == false)
        print("PAGING_PASS accepted page prepends and advances cursor")
    }

    // 2. A page that would exceed the message budget is refused atomically.
    do {
        let sessionID = "paging-refuse-count"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<3000, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 900..<1000, offset: 900)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        precondition(model.transcript.messages.count == 2000)
        await model.loadOlder()
        precondition(model.transcript.messages.count == 2000, "refused page must not mutate the window")
        precondition(model.transcript.messages.first?.id == "row-1000")
        precondition(model.olderOffset == 1000, "refused page must not advance the cursor")
        precondition(model.olderLimitReached && model.notice != nil, "limit must be explained, not silent")
        await model.loadOlder()
        precondition(service.calls.filter { $0 == 1000 }.count == 1, "a refused range must not be re-requested")
        print("PAGING_PASS over-budget page refused without moving cursor")
    }

    // 3. A duplicate-only page must not loop or duplicate rows.
    do {
        let sessionID = "paging-dup"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 900)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        await model.loadOlder()
        precondition(model.transcript.messages.count == 100, "duplicate rows must not grow the window")
        precondition(model.olderOffset == 900)
        print("PAGING_PASS duplicate page stays deduplicated")
    }

    // 4. A failed page leaves the cursor untouched and surfaces the error.
    do {
        let sessionID = "paging-error"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 1000)
        let service = PagedHistoryService(initial: initial, pages: [:])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        // Fail only the older-page request; the first load must stay usable.
        service.failure = URLError(.timedOut)
        await model.loadOlder()
        precondition(model.transcript.messages.count == 100)
        precondition(model.olderOffset == 1000, "failed page must not move the cursor")
        precondition(model.error != nil)
        print("PAGING_PASS failed page keeps cursor and reports error")
    }

    // 5. Empty page without progress must not fabricate rows.
    do {
        let sessionID = "paging-empty"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 1000..<1000, offset: 1000)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        await model.loadOlder()
        precondition(model.transcript.messages.count == 100)
        precondition(model.olderOffset == 1000)
        print("PAGING_PASS empty page changes nothing")
    }

    // 6. Tools anchored to the newly accepted page survive.
    do {
        let sessionID = "paging-tool"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 900..<1000, offset: 900, toolOnLastRow: true)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        await model.loadOlder()
        precondition(model.transcript.tools.contains { $0.id == "tool-999" && $0.afterMessageID == "row-999" },
                     "tool anchored to the accepted page must be kept")
        print("PAGING_PASS anchored tool kept with its page")
    }

    // 7. A long-running agent must not block reading older immutable rows.
    // The older GET must not detach/restart the active run or replay its POST.
    do {
        let sessionID = "paging-during-run"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 900..<1000, offset: 900)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        service.holdStream = true
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        model.draft = "do a long analysis"
        let started = await model.send()
        precondition(started && model.running && model.canLoadOlderHistory,
                     "live assistant must allow historical paging")
        await model.loadOlder()
        precondition(model.olderOffset == 900 && model.running && model.streamID == "stream",
                     "older GET preserves stream identity and advances only the history cursor")
        precondition(model.transcript.messages.first?.id == "row-900",
                     "history is prepended while the assistant keeps running")
        precondition(service.calls.filter { $0 == 1000 }.count == 1,
                     "one request is issued for the old cursor")
        model.disconnect()
    }

    // 8. A cancelled view-owned older GET must not set a misleading error.
    // The service deliberately ignores cancellation until the test releases
    // its continuation, reproducing a non-cooperative transport callback.
    do {
        let sessionID = "paging-cancelled"
        let initial = try pagedSnapshot(sessionID, rows: 1000..<1100, offset: 1000)
        let page = try pagedSnapshot(sessionID, rows: 900..<1000, offset: 900)
        let service = PagedHistoryService(initial: initial, pages: [1000: page])
        let model = NativeChatModel(sessionID: sessionID, api: service)
        await model.load()
        service.holdOlderPage = true
        let cancelled = Task { await model.loadOlder() }
        for _ in 0..<2000 {
            if service.pendingOlder != nil { break }
            await Task.yield()
        }
        precondition(service.pendingOlder != nil, "older request must be in flight")
        cancelled.cancel()
        service.pendingOlder?.resume(throwing: CancellationError())
        service.pendingOlder = nil
        await cancelled.value
        precondition(model.error == nil && model.olderOffset == 1000,
                     "cancelled older GET never mutates history or shows a paging error")
        precondition(model.transcript.messages.count == 100,
                     "cancelled older page retains existing history")

        // Cancellation followed by a late *successful* history result is
        // still untrusted after the Session has been suspended.
        let late = Task { await model.loadOlder() }
        for _ in 0..<2000 {
            if service.pendingOlder != nil { break }
            await Task.yield()
        }
        precondition(service.pendingOlder != nil, "late page fixture must be in flight")
        model.disconnect()
        service.pendingOlder?.resume(returning: page)
        service.pendingOlder = nil
        await late.value
        precondition(model.olderOffset == 1000 && model.transcript.messages.count == 100,
                     "late successful page after disconnect must not prepend or advance cursor")
        print("PAGING_PASS cancellation and late success cannot corrupt a retired session")
    }

    print("PAGING_BUDGET_PASS 8 scenarios")
}
