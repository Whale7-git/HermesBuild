import Foundation

/// Scripted history service. Controlled pages only; never a real API call.
@MainActor final class PagedHistoryService: NativeChatService {
    private let initial: ChatSnapshot
    private let pages: [Int: ChatSnapshot]
    var failure: Error?
    private(set) var calls: [Int?] = []

    init(initial: ChatSnapshot, pages: [Int: ChatSnapshot]) {
        self.initial = initial
        self.pages = pages
    }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        calls.append(before)
        if let failure { throw failure }
        if let before, let page = pages[before] { return page }
        if before == nil { return initial }
        throw URLError(.badServerResponse)
    }

    func startNativeTurn(sessionID: String, text: String) async throws -> String { "stream" }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {}
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

    print("PAGING_BUDGET_PASS 6 scenarios")
}
