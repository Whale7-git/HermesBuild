import Foundation

// UI observation does not participate in these offline state-machine checks.
#if !canImport(SwiftUI)
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
#endif

@MainActor final class RaceService: NativeChatService {
    var active: String? = "run"
    var historyCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var approvalCalls = 0
    var streams = 0
    var frames: [SSEFrame] = []
    var approvals: [CheckedContinuation<String?, Error>] = []
    var clarifyCalls: [(String, Int, String)] = []
    var stops: [CheckedContinuation<Void, Error>] = []
    var holdStop = false
    var failStop = false
    var recoveryUnavailable = false
    var runRecoveryUnavailable: Bool { recoveryUnavailable }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
            "session_id": sessionID, "messages": [], "read_only": false,
            "active_stream_id": active as Any? ?? NSNull()
        ]))
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        startCalls += 1
        return "unexpected-replayed-run"
    }
    func stopNativeTurn(streamID: String) async throws {
        stopCalls += 1
        if holdStop { try await withCheckedThrowingContinuation { stops.append($0) } }
        if failStop { throw URLError(.timedOut) }
        active = nil
    }
    func approveNativeTurn(runID: String, choice: String, requestID: String?) async throws -> String? {
        approvalCalls += 1
        return try await withCheckedThrowingContinuation { approvals.append($0) }
    }
    func clarifyNativeTurn(runID: String, answer: String, requestID: String,
                           executionGeneration: Int) async throws -> String? {
        clarifyCalls.append((requestID, executionGeneration, answer))
        return nil
    }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        streams += 1
        while !Task.isCancelled {
            if !frames.isEmpty {
                if try await onFrame(frames.removeFirst()) { return }
            } else { try await Task.sleep(nanoseconds: 1_000_000) }
        }
    }
    func approval(_ id: String) {
        frames.append(SSEFrame(event: "approval", data:
            "{\"request_id\":\"\(id)\",\"message\":\"Offline approval\",\"choices\":[\"once\",\"deny\"]}", id: id))
    }
}

enum RaceFailure: Error { case assertion(String) }
@main struct W3W4Tests {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw RaceFailure.assertion(label) }
        print("CHECK \(label)")
    }
    @MainActor static func eventually(_ label: String, _ value: () -> Bool) async throws {
        for _ in 0..<2000 {
            if value() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw RaceFailure.assertion("timed out: \(label)")
    }
    @MainActor static func main() async {
        let name = CommandLine.arguments.dropFirst().first ?? "approval-background-success"
        do {
            try await run(name)
            print("W3W4_PASS \(name)")
        } catch {
            print("W3W4_FAIL \(name): \(error)")
            exit(1)
        }
    }
    @MainActor static func run(_ name: String) async throws {
        let api = RaceService()
        let model = NativeChatModel(sessionID: "offline-race", api: api)
        defer { model.disconnect() }
        await model.load()
        try await eventually("initial stream attached") { api.streams == 1 }

        switch name {
        case "approval-background-success", "approval-background-error":
            api.approval("old")
            try await eventually("approval") { model.pendingApproval?.requestID == "old" }
            let response = Task { await model.respondToApproval("once") }
            try await eventually("approval POST held") { api.approvals.count == 1 }
            model.disconnect()
            let pending = model.pendingApproval, notice = model.notice
            await model.respondToApproval("once")
            try check(api.approvalCalls == 1, "suspended approval does not duplicate POST")
            if name.hasSuffix("error") { api.approvals[0].resume(throwing: URLError(.timedOut)) }
            else { api.approvals[0].resume(returning: nil) }
            await response.value
            try check(model.suspended && model.running && !model.streamConnected,
                      "leaving during approval preserves suspended nonterminal run")
            try check(model.pendingApproval == pending && model.notice == notice && model.error == nil,
                      "stale approval response cannot dismiss card or publish error while suspended")
            try check(!model.approving && model.completedReplies == 0 && api.stopCalls == 0,
                      "approval defer releases only own lock; disconnect never stops backend")
            api.active = nil
            await model.resumeForeground()
            try check(model.pendingApproval == nil && model.phase == .idle,
                      "authoritative idle GET clears old approval on return")
            try check(api.startCalls == 0 && api.approvalCalls == 1,
                      "foreground recovery uses GET/stream only, no send or approval replay")

        case "approval-return-replacement":
            api.approval("old")
            try await eventually("old card") { model.pendingApproval?.requestID == "old" }
            let old = Task { await model.respondToApproval("once") }
            try await eventually("old approval held") { api.approvals.count == 1 }
            model.disconnect()
            await model.resumeForeground()
            api.approval("new")
            try await eventually("new card") { model.pendingApproval?.requestID == "new" }
            let newer = Task { await model.respondToApproval("deny") }
            try await eventually("new approval held") { api.approvals.count == 2 }
            api.approvals[0].resume(returning: nil)
            await old.value
            try check(model.pendingApproval?.requestID == "new" && model.approving,
                      "old response and defer cannot clear replacement card or newer submission lock")
            await model.respondToApproval("deny")
            try check(api.approvalCalls == 2, "replacement approval remains single-flight")
            api.approvals[1].resume(returning: nil)
            await newer.value
            try check(model.pendingApproval == nil && !model.approving && model.running,
                      "current approval completion clears only its own card, not live run")
            try check(api.startCalls == 0 && api.stopCalls == 0, "approval return does not restart or stop turn")

        case "approval-return-same":
            api.approval("same")
            try await eventually("same card") { model.pendingApproval != nil }
            let old = Task { await model.respondToApproval("once") }
            try await eventually("held response") { api.approvals.count == 1 }
            model.disconnect()
            await model.resumeForeground()
            await model.respondToApproval("once")
            try check(api.approvalCalls == 1 && model.approving, "return with same card does not re-POST in-flight decision")
            api.approvals[0].resume(returning: nil)
            await old.value
            try check(model.pendingApproval != nil && !model.approving,
                      "old generation HTTP response cannot decide new generation card")
            api.frames.append(SSEFrame(event: "approval_resolved", data: "{\"request_id\":\"same\"}", id: "resolved"))
            try await eventually("resolution") { model.pendingApproval == nil }
            try check(model.running && api.approvalCalls == 1 && api.startCalls == 0,
                      "current SSE acknowledgement resolves card without replay")

        case "stop-failure":
            api.failStop = true
            await model.stop()
            try check(model.phase == .streaming(connected: false) && model.streamID == "run",
                      "stop failure preserves live run ID and nonterminal phase")
            try check(model.error != nil && model.completedReplies == 0 && !model.canSend,
                      "stop failure does not claim completion or unlock ordinary send")
            try check(model.transcript.notices.isEmpty && api.startCalls == 0,
                      "failed stop does not append confirmed-stop notice or POST again")

        case "stop-background-failure":
            api.holdStop = true
            let stop = Task { await model.stop() }
            try await eventually("stop held") { api.stops.count == 1 }
            model.disconnect()
            api.stops[0].resume(throwing: URLError(.timedOut))
            await stop.value
            print("STATE suspended=\(model.suspended) phase=\(model.phase) streamID=\(model.streamID ?? "nil") running=\(model.running)")
            try check(model.suspended && model.running && model.streamID == "run",
                      "failed stop completing after disconnect must not fake an idle/terminated run")
            // The sticky `.stopping` must still be escapable: an authoritative
            // history GET reconciles the phase to whatever the server reports.
            // Without this, a failed background stop would strand the session in
            // `.stopping` (stop() guards on !stopping, so it could never retry).
            await model.resumeForeground()
            try check(model.phase != .stopping,
                      "an authoritative refresh must release a stranded stopping phase")
            try check(model.canSend || model.streamID != nil,
                      "reconciled phase keeps a usable action")

        case "stop-old-completion-new-stop":
            api.holdStop = true
            let first = Task { await model.stop() }
            try await eventually("first stop held") { api.stops.count == 1 }
            model.disconnect()
            await model.resumeForeground()
            let second = Task { await model.stop() }
            try await eventually("second stop held") { api.stops.count == 2 }
            api.stops[0].resume(throwing: URLError(.timedOut))
            await first.value
            let phaseBeforeSecondResponse = model.phase
            let canSendBeforeSecondResponse = model.canSend
            // Always release the controlled second request before checking the result.
            api.stops[1].resume(throwing: URLError(.timedOut))
            await second.value
            print("STATE beforeSecondResponse=\(phaseBeforeSecondResponse) canSend=\(canSendBeforeSecondResponse) streamID=\(model.streamID ?? "nil")")
            try check(phaseBeforeSecondResponse == .stopping,
                      "old stop defer must not overwrite a newer in-flight stop phase")

        case "run-recovery-stickiness":
            api.recoveryUnavailable = true
            model.noteRunRecoveryState()
            try check(model.runRecoveryNoticeShown, "observed recovery write failure raises warning")
            api.recoveryUnavailable = false
            model.noteRunRecoveryState()
            model.disconnect()
            await model.resumeForeground()
            try check(model.runRecoveryNoticeShown, "warning sticky across successful write and same-model foreground GET")
            api.active = nil
            await model.refresh()
            try check(model.runRecoveryNoticeShown, "idle canonical refresh cannot erase page-sticky failed-run warning")
            let fresh = NativeChatModel(sessionID: "offline-race", api: api)
            defer { fresh.disconnect() }
            await fresh.resumeForeground()
            try check(!fresh.runRecoveryNoticeShown && fresh.pendingApproval == nil && !fresh.uncertain,
                      "new model re-observes healthy backend without stale page recovery state")
            api.recoveryUnavailable = true
            let degraded = NativeChatModel(sessionID: "offline-race", api: api)
            defer { degraded.disconnect() }
            await degraded.resumeForeground()
            try check(degraded.runRecoveryNoticeShown, "new model re-observes backend failure on foreground recovery")
            try check(api.startCalls == 0 && api.stopCalls == 0 && api.approvalCalls == 0,
                      "recovery observation is GET-only and never posts commands")

        default:
            throw RaceFailure.assertion("unknown case: \(name)")
        }
    }
}
