import Foundation

@MainActor final class Pages {
    var calls: [Int?] = []
    var failBefore: Int?
    var failFirst = false
    var authentication = false
    var wrongSession = false
    var stalled = false
    var gap = false
    var active = false
    var duplicate = false
    var truncated = false

    func snapshot(offset: Int, rows: [[String: Any]], session: String = "s", active: Bool = false,
                  truncated: Bool = false) throws -> ChatSnapshot {
        var fields: [String: Any] = ["session_id": session, "messages": rows,
            "_messages_offset": offset, "_messages_truncated": truncated, "read_only": false]
        if active { fields["active_stream_id"] = "already-running" }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: fields))
    }
    func history(_ before: Int?) async throws -> ChatSnapshot {
        calls.append(before)
        if failFirst || (before != nil && before == failBefore) {
            if authentication { throw TranscriptPagerError.authenticationRequired }
            throw URLError(.notConnectedToInternet)
        }
        if before == nil {
            return try snapshot(offset: 4, rows: [
                ["id": duplicate ? "m0" : "m4", "role": "user", "content": "latest question"],
                ["id": "m5", "role": "assistant", "content": "latest answer"]], active: active)
        }
        if before == 4 {
            if stalled { return try snapshot(offset: 4, rows: []) }
            return try snapshot(offset: gap ? 1 : 2, rows: [
                ["role": "tool", "tool_call_id": "t", "content": "tool result"],
                ["role": "tool", "tool_call_id": "t2", "content": "second tool result"]],
                session: wrongSession ? "different" : "s")
        }
        return try snapshot(offset: 0, rows: [
            ["id": "m0", "role": "user", "content": "first question"],
            ["id": "m1", "role": "assistant", "content": "first answer",
             "tool_calls": [["id": "t", "function": ["name": "lookup", "arguments": "{\"q\":1}"]]]]],
            truncated: truncated)
    }
}

@main struct PagerTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        precondition(value(), name)
    }
    @MainActor static func main() async throws {
        let pages = Pages()
        var progress: [TranscriptPager.Progress] = []
        let full = try await TranscriptPager.fetch(sessionID: "s", history: pages.history,
                                                  onProgress: { progress.append($0) })
        expect(full.complete && full.pages == 3, "read through actual beginning")
        expect(pages.calls.count == 3 && pages.calls[0] == nil && pages.calls[1] == 4 && pages.calls[2] == 2,
               "use exclusive raw offsets, including tool-only pages")
        expect(full.messages.map(\.id) == ["m0", "m1", "m4", "m5"], "chronological visible messages")
        expect(progress.map(\.messages) == [0, 2, 2, 4], "no fabricated percent or message count from tool rows")
        let tool = full.tools.first(where: { $0.id == "t" })!
        expect(tool.name == "lookup" && tool.args == "{\"q\":1}" && tool.result == "tool result",
               "merge tool call across raw page boundary")
        expect(tool.done && tool.afterMessageID == "m1", "recover anchored tool status")

        let capped = Pages()
        let cap = try await TranscriptPager.fetch(sessionID: "s", limits: .init(pages: 1), history: capped.history)
        expect(!cap.complete && cap.pages == 1 && capped.calls.count == 1, "page limit stays explicitly partial")

        let offline = Pages(); offline.failBefore = 4
        let partial = try await TranscriptPager.fetch(sessionID: "s", history: offline.history)
        expect(!partial.complete && partial.messages.count == 2, "mid-pagination error retains bounded partial result")
        expect(partial.partialReason?.contains("获取更早历史失败") == true, "error reason is explicit")

        let firstFailure = Pages(); firstFailure.failFirst = true
        do {
            _ = try await TranscriptPager.fetch(sessionID: "s", history: firstFailure.history)
            expect(false, "initial network failure must throw")
        } catch is URLError { expect(true, "no empty success on first failure") }

        let auth = Pages(); auth.failBefore = 4; auth.authentication = true
        do {
            _ = try await TranscriptPager.fetch(sessionID: "s", history: auth.history)
            expect(false, "authentication failure cannot offer cached partial export")
        } catch TranscriptPagerError.authenticationRequired { expect(true, "auth failure drops export") }

        for mode in ["session", "cursor", "gap", "conflict", "truncated"] {
            let fixture = Pages()
            fixture.wrongSession = mode == "session"
            fixture.stalled = mode == "cursor"
            fixture.gap = mode == "gap"
            fixture.duplicate = mode == "conflict"
            fixture.truncated = mode == "truncated"
            let result = try await TranscriptPager.fetch(sessionID: "s", history: fixture.history)
            expect(!result.complete && result.partialReason != nil, "unsafe \(mode) never claims full history")
            expect(fixture.calls.count <= 3, "unsafe \(mode) cannot create a request loop")
        }

        let busy = Pages(); busy.active = true
        do {
            _ = try await TranscriptPager.fetch(sessionID: "s", history: busy.history)
            expect(false, "active history cannot be a settled archive")
        } catch TranscriptPagerError.empty { expect(busy.calls.count == 1, "no stop or retry of active run") }

        let bounded = Pages()
        let bytes = try await TranscriptPager.fetch(sessionID: "s", limits: .init(bytes: 900), history: bounded.history)
        expect(!bytes.complete && bytes.retainedBytes <= 900 && bytes.pages == 1, "content budget commits only whole pages")

        let zero = Pages()
        do {
            _ = try await TranscriptPager.fetch(sessionID: "s", limits: .init(pages: 0), history: zero.history)
            expect(false, "zero budget cannot claim success")
        } catch TranscriptPagerError.empty { expect(zero.calls.isEmpty, "zero budget never fetches") }

        // Simulate a non-cancellable GET returning after its task was cancelled.
        var pending: CheckedContinuation<ChatSnapshot, Error>?
        var callbacks = 0
        let delayed = Task {
            try await TranscriptPager.fetch(sessionID: "s", history: { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }, onProgress: { _ in callbacks += 1 })
        }
        for _ in 0..<2000 {
            if pending != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(pending != nil, "deferred GET started")
        delayed.cancel()
        pending?.resume(returning: try Pages().snapshot(offset: 0, rows: [["id": "late", "role": "user", "content": "late"]]))
        pending = nil
        do { _ = try await delayed.value; expect(false, "cancelled task cannot publish late data") }
        catch is CancellationError { expect(callbacks == 1, "only initial progress, no late success") }

        let cancelledPages = Pages()
        var cancelAfterPage: Task<TranscriptPager.Result, Error>?
        cancelAfterPage = Task {
            try await TranscriptPager.fetch(sessionID: "s", history: cancelledPages.history, onProgress: { progress in
                if progress.pages == 1 { cancelAfterPage?.cancel() }
            })
        }
        do { _ = try await cancelAfterPage!.value; expect(false, "cancel must not return a partial success") }
        catch is CancellationError { expect(cancelledPages.calls.count == 1, "cancel stops before next GET") }
        cancelAfterPage = nil

        do {
            _ = try await TranscriptPager.fetch(sessionID: "s", history: { _ in
                try Pages().snapshot(offset: 0, rows: [
                    ["id": "duplicate", "role": "user", "content": "first"],
                    ["id": "duplicate", "role": "assistant", "content": "second"]])
            })
            expect(false, "conflicting duplicate IDs inside one page cannot be silently collapsed")
        } catch TranscriptPagerError.empty { expect(true, "reject conflicting page before committing any rows") }

        let archived = try await TranscriptPager.fetch(sessionID: "s", history: { _ in
            try ChatSnapshot(data: Data(#"{"session_id":"s","read_only":true,"messages":[{"id":"archived","role":"user","content":"read only"}]}"#.utf8))
        })
        expect(archived.complete && archived.messages.count == 1, "read-only archived history can still be exported")

        print("TRANSCRIPT_PAGER_PASS \(checks) assertions: contiguous paging, limits, tool merge, auth and cancellation; no production requests")
    }
}
