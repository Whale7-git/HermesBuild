import Foundation

@MainActor final class ActivityRecoveryService: NativeChatService {
    var rows: [[String: Any]] = [["id": "recent", "role": "user", "content": "question"]]
    var offset = 2
    var active: String?
    var tools: [ChatTool] = []
    var failHistory = false
    var authFailure = false
    var eof = false
    var emitDone = false
    var terminalEvent = "done"
    var historyCalls = 0
    var postCalls = 0
    var stopCalls = 0
    var streamCalls = 0
    var frames: [SSEFrame] = []
    var holdHistory = false
    var pendingHistory: CheckedContinuation<ChatSnapshot, Error>?

    func snapshot() throws -> ChatSnapshot {
        try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
            "session_id": "activity", "_messages_offset": offset, "messages": rows,
            "active_stream_id": active as Any? ?? NSNull(), "read_only": false,
            "tool_calls": tools.map { ["id": $0.id, "name": $0.name, "done": $0.done, "is_error": $0.isError] }
        ]))
    }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        if authFailure { throw URLError(.userAuthenticationRequired) }
        if failHistory { throw URLError(.notConnectedToInternet) }
        if let before {
            precondition(before == 2)
            return try ChatSnapshot(data: Data(#"{"session_id":"activity","messages":[{"id":"old-user","role":"user","content":"old"},{"id":"old-answer","role":"assistant","content":"old answer","tool_calls":[{"id":"old-tool","name":"read","done":true,"result":"old result"}]}]}"#.utf8))
        }
        if holdHistory { return try await withCheckedThrowingContinuation { pendingHistory = $0 } }
        return try snapshot()
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        postCalls += 1
        return "run"
    }
    func stopNativeTurn(streamID: String) async throws { stopCalls += 1; active = nil }
    func requiresAuthentication(after error: Error) -> Bool {
        (error as? URLError)?.code == .userAuthenticationRequired
    }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
        streamCalls += 1
        for frame in frames { if try await onFrame(frame) { return } }
        if emitDone {
            active = nil
            let data = try JSONSerialization.data(withJSONObject: ["session_id": "activity", "_messages_offset": offset, "messages": rows])
            _ = try await onFrame(SSEFrame(event: terminalEvent, data: String(decoding: data, as: UTF8.self), id: "terminal"))
            return
        }
        if eof { return }
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
}

extension ModelTests {
    @MainActor static func activityRecoveryTests() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1; precondition(condition(), label)
        }
        expect(ChatNoticeAction.choose(hasPendingSend: false, uncertain: true,
            persistenceIssue: false, recoveryDegraded: true) == .verifyStatus,
            "unresolved run must override degraded-recovery details")
        expect(ChatNoticeAction.choose(hasPendingSend: true, uncertain: true,
            persistenceIssue: false, recoveryDegraded: true) == .reconcilePending,
            "pending POST requires strict history reconciliation")
        expect(ChatNoticeAction.choose(hasPendingSend: false, uncertain: false,
            persistenceIssue: false, recoveryDegraded: true) == .details,
            "recovery-only notice opens details")
        expect(ChatNoticeAction.choose(hasPendingSend: false, uncertain: true,
            persistenceIssue: true, recoveryDegraded: true) == .details,
            "persistence warning opens details")
        expect(ChatNoticeAction.choose(hasPendingSend: false, uncertain: true,
            persistenceIssue: false, recoveryDegraded: true).title == "核对状态",
            "label must match the verification action")
        expect(RunTerminalEvidence.outcome(of: SSEFrame(event: "stream_end",
            data: #"{"status":"unknown"}"#, id: "1")) == nil, "unknown stream end is not completion")
        expect(RunTerminalEvidence.outcome(of: SSEFrame(event: "apperror",
            data: #"{"message":"network"}"#, id: "2")) == nil, "transport error is not failed Run")
        expect(RunTerminalEvidence.outcome(of: SSEFrame(event: "apperror",
            data: #"{"status":"failed"}"#, id: "3")) == .failed, "typed failure is durable evidence")
        expect(RunTerminalEvidence.outcome(of: SSEFrame(event: "stream_end",
            data: #"{"status":"work_limit"}"#, id: "4")) == .interrupted, "work limit cannot dispatch queue")
        let service = ActivityRecoveryService()
        let model = NativeChatModel(sessionID: "activity", api: service)
        await model.load()
        expect(model.activity == .ready, "canonical idle state is ready")
        await model.loadOlder()
        // The production snapshot parser controls history tool anchoring.
        expect(model.transcript.tools.contains(where: { $0.id == "old-tool" }), "older tool loaded")
        model.draft = "keep my next draft"
        model.disconnect()
        expect(model.activity == .suspended && !model.streamConnected, "background disconnect reports paused, not completed")
        expect(model.completedReplies == 0 && service.stopCalls == 0, "disconnect never announces completion or stops backend")
        service.active = "run"
        service.tools = [ChatTool(id: "current", name: "terminal", args: "", result: "", done: false, isError: false, afterMessageID: "recent")]
        await model.resumeForeground()
        print("ACTIVITY_STAGE active foreground attachment")
        try await eventually { service.streamCalls == 1 }
        expect(model.activity == .connecting, "attached stream with no frames says connecting")
        expect(model.transcript.messages.map(\.id) == ["old-user", "old-answer", "recent"], "active foreground recovery retains older canonical messages")
        expect(model.olderOffset == 0, "oldest fetched cursor is retained while active")
        expect(model.transcript.tools.contains(where: { $0.id == "old-tool" }), "active recovery retains older tool details")
        expect(model.draft == "keep my next draft" && service.postCalls == 0, "foreground GET never resends or clears draft")
        model.disconnect()
        service.active = nil
        await model.resumeForeground()
        expect(model.activity == .ready && !model.streamConnected, "idle recovery clears active status")
        expect(model.olderOffset == 0 && model.transcript.tools.contains(where: { $0.id == "old-tool" }), "idle recovery retains history cursor and tools")
        expect(model.completedReplies == 0, "idle GET without done event is not claimed as successful completion")

        service.holdHistory = true
        let late = Task { await model.resumeForeground() }
        print("ACTIVITY_STAGE delayed foreground GET")
        try await eventually { service.pendingHistory != nil }
        model.disconnect()
        let before = model.transcript.messages
        service.rows = [["id": "late", "role": "assistant", "content": "must not overwrite"]]
        service.pendingHistory?.resume(returning: try service.snapshot()); service.pendingHistory = nil
        await late.value
        expect(model.transcript.messages == before && model.activity == .suspended, "late noncancellable GET cannot overwrite a background session")
        service.holdHistory = false
        service.failHistory = true
        await model.resumeForeground()
        expect(model.activity == .needsVerification && !model.canSend, "failed resume shows unknown state and locks send")
        expect(model.draft == "keep my next draft" && service.postCalls == 0, "failed resume retains draft and never POSTs")
        service.failHistory = false
        service.rows = [["id": "changed", "role": "assistant", "content": "different history"]]
        await model.resumeForeground()
        expect(model.transcript.messages.map(\.id) == ["changed"], "changed canonical overlap cannot resurrect old prefix")
        model.disconnect()

        let lost = ActivityRecoveryService()
        lost.active = "run"; lost.eof = true
        let unknown = NativeChatModel(sessionID: "activity", api: lost)
        await unknown.load()
        print("ACTIVITY_STAGE bounded recovery")
        try await eventually { unknown.uncertain && !unknown.reconnecting }
        expect(unknown.activity == .needsVerification && !unknown.activity.showsProgress, "exhausted recovery does not display an endless reply spinner")
        expect(lost.historyCalls == 4 && lost.postCalls == 0, "recovery stays bounded to three GET retries, no replay")
        expect(unknown.completedReplies == 0 && !unknown.canSend, "recovery exhaustion is not successful completion")
        unknown.disconnect()

        let success = ActivityRecoveryService()
        success.emitDone = true
        let complete = NativeChatModel(sessionID: "activity", api: success)
        await complete.load()
        await complete.loadOlder()
        complete.disconnect()
        success.active = "run"
        await complete.resumeForeground()
        // Ordinary recovery stays compact even after the initial quiet window,
        // while genuine delivery/storage problems must not be hidden.
        let compact = SessionPresentationState(activity: .needsVerification,
            transcriptAvailable: true, routineRecovery: true, requiresAction: false,
            verificationPending: true, errorPresent: true, warningPresent: true, notice: "retry")
        expect(compact.showsProgress && !compact.showsNotice && !compact.needsVerification
            && compact.notice == nil, "routine recovery remains compact across surfaces")
        let actionable = SessionPresentationState(activity: .needsVerification,
            transcriptAvailable: true, routineRecovery: true, requiresAction: true,
            verificationPending: true, errorPresent: true, warningPresent: true, notice: "delivery")
        expect(actionable.showsNotice && actionable.needsVerification && actionable.hasError
            && actionable.notice == "delivery", "real action and persistence failures remain visible")
        let stopPresentation = SessionPresentationState(activity: .stopping,
            transcriptAvailable: true, routineRecovery: true, requiresAction: false,
            verificationPending: true, errorPresent: false, warningPresent: true, notice: "stop")
        expect(stopPresentation.title == ChatActivity.stopping.title,
            "automatic recovery cannot hide an outstanding STOP")
        print("ACTIVITY_STAGE confirmed terminal completion")
        try await eventually { complete.completedReplies == 1 }
        expect(complete.activity == .ready && complete.completedReplies == 1, "done plus canonical idle history emits one real completion")
        expect(complete.transcript.messages.map(\.id) == ["old-user", "old-answer", "recent"], "done frame and final GET both preserve older canonical messages")
        expect(complete.transcript.tools.contains(where: { $0.id == "old-tool" }), "done frame cannot drop older tool details before reconciliation")
        complete.disconnect()

        let cancelled = ActivityRecoveryService()
        cancelled.active = "run"; cancelled.emitDone = true; cancelled.terminalEvent = "cancel"
        let cancelledModel = NativeChatModel(sessionID: "activity", api: cancelled)
        await cancelledModel.load()
        try await eventually { !cancelledModel.running && !cancelledModel.reconciling }
        expect(cancelledModel.completedReplies == 0, "server cancellation never emits successful completion")
        expect(cancelledModel.notice == "回复已取消，历史已同步。", "cancellation remains explicitly visible")
        cancelledModel.disconnect()

        let toolService = ActivityRecoveryService()
        toolService.active = "run"
        toolService.frames = [SSEFrame(event: "tool", data: #"{"tid":"live","name":"terminal"}"#, id: "1")]
        let toolModel = NativeChatModel(sessionID: "activity", api: toolService)
        await toolModel.load()
        print("ACTIVITY_STAGE connected tool")
        try await eventually { toolModel.streamConnected }
        expect(toolModel.activity == .tool("terminal"), "active current-turn tool has a truthful phase")
        toolModel.disconnect()
        toolService.authFailure = true
        await toolModel.resumeForeground()
        expect(toolModel.authenticationRequired && toolModel.activity == .needsLogin, "authentication loss has its own state")
        expect(toolModel.transcript.messages.isEmpty && toolModel.completedReplies == 0, "authentication retirement clears old account content without completion")
        toolModel.disconnect()

        // A page transition must not infer stop/complete from a disconnected
        // long agent transcript. The navigation layer is not a STOP endpoint.
        let many = ActivityRecoveryService()
        many.tools = (0..<150).map { i in
            ChatTool(id: "tool-\(i)", name: "read", args: "", result: "ok",
                     done: true, isError: false, afterMessageID: "recent")
        }
        let longSession = NativeChatModel(sessionID: "activity", api: many)
        await longSession.load()
        expect(longSession.transcript.tools.count == 150,
               "150 historical tool records are retained on initial Session load")
        longSession.draft = "draft survives navigation"
        longSession.disconnect()
        expect(many.postCalls == 0 && many.stopCalls == 0,
               "page detachment with 150 tools never submits or stops")
        await longSession.resumeForeground()
        expect(many.postCalls == 0 && many.stopCalls == 0
               && longSession.draft == "draft survives navigation",
               "foreground return with 150 tools keeps draft and issues GET only")
        expect(longSession.transcript.tools.count == 150,
               "long Session tool history survives a read-only resume")
        longSession.disconnect()

        let old = ChatTool(id: "old", name: "old", args: "", result: "", done: false, isError: false, afterMessageID: "u1")
        let fresh = ChatTool(id: "new", name: "new", args: "", result: "", done: false, isError: false, afterMessageID: "u2")
        let messages = [ChatMessage(id: "u1", role: "user", content: "old"), ChatMessage(id: "u2", role: "user", content: "new")]
        expect(ChatActivity.activeToolIDs(messages: messages, tools: [old, fresh]) == ["new"], "old unfinished tools do not reactivate during a new turn")
        expect(ChatActivity.activeToolIDs(messages: [], tools: [old]).isEmpty, "unloaded anchors never fabricate tool activity")
        print("ACTIVITY_RECOVERY_PASS \(checks) assertions (controlled services, no production requests or UIKit)")
    }
}
