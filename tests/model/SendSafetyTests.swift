import Foundation

/// Controlled transport for reentrancy and lifecycle tests. No live requests.
@MainActor private final class SendSafetyService: NativeChatService {
    var active: String?
    var startCalls = 0
    var steerCalls = 0
    var sent: [(String, [ChatAttachmentPayload])] = []
    var failHistory = false
    var failHistoryAfterStop = false
    var stopAcknowledgementOnly = false
    var stopCalls = 0
    var failStart = false
    var historyRows: [[String: Any]] = []
    var holdSteer = false
    var pendingSteer: CheckedContinuation<String?, Error>?
    var pendingApproval: CheckedContinuation<String?, Error>?
    var clarifyCalls: [(String, Int, String)] = []
    var frames: [SSEFrame] = []
    var historyCalls = 0
    var recoveryUnavailable = false
    var runRecoveryUnavailable: Bool { recoveryUnavailable }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        if failHistory { throw URLError(.notConnectedToInternet) }
        var object: [String: Any] = ["session_id": sessionID, "messages": historyRows,
                                     "read_only": false]
        if let active { object["active_stream_id"] = active }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: object))
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        try await startNativeTurn(sessionID: sessionID, text: text, attachments: [])
    }
    func startNativeTurn(sessionID: String, text: String, attachments: [ChatAttachmentPayload]) async throws -> String {
        startCalls += 1
        sent.append((text, attachments))
        if failStart { throw URLError(.networkConnectionLost) }
        let next = "run-\(startCalls)"
        active = next
        return next
    }
    func stopNativeTurn(streamID: String) async throws {
        stopCalls += 1
        if stopAcknowledgementOnly { return }
        active = nil
        if failHistoryAfterStop { failHistory = true; return }
        // Successful stop scenarios expose canonical terminal history. The
        // failure switch above still exercises an acknowledgement without proof.
        if let (text, attachments) = sent.last {
            historyRows.append(["id": "stopped-user-\(streamID)", "role": "user",
                                "content": text,
                                "attachments": attachments.map { ["path": $0.path] }])
            historyRows.append(["id": "stopped-answer-\(streamID)", "role": "assistant",
                                "content": "stopped"])
        }
    }
    func probeActiveRun(sessionID: String, runID: String) async throws -> ActiveRunProbe {
        active == runID ? .alive : .terminal(.cancelled)
    }
    func steerNativeTurn(sessionID: String, text: String) async throws -> String? {
        steerCalls += 1
        if holdSteer { return try await withCheckedThrowingContinuation { pendingSteer = $0 } }
        return nil
    }
    func approveNativeTurn(runID: String, choice: String, requestID: String?) async throws -> String? {
        try await withCheckedThrowingContinuation { pendingApproval = $0 }
    }
    func clarifyNativeTurn(runID: String, answer: String, requestID: String,
                           executionGeneration: Int) async throws -> String? {
        clarifyCalls.append((requestID, executionGeneration, answer))
        return nil
    }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        while !Task.isCancelled {
            if !frames.isEmpty {
                let next = frames.removeFirst()
                if try await onFrame(next) { return }
            } else { try await Task.sleep(nanoseconds: 1_000_000) }
        }
    }
    func approval(_ id: String) {
        frames.append(SSEFrame(event: "approval", data:
            "{\"request_id\":\"\(id)\",\"message\":\"Review command\",\"choices\":[\"once\",\"deny\"]}", id: id))
    }

    func clarify(_ id: String, generation: Int, choices: [String] = []) {
        var payload: [String: Any] = [
            "request_id": id, "execution_generation": generation,
            "question": "要覆盖还是重命名？",
        ]
        if !choices.isEmpty { payload["choices"] = choices }
        let data = (try? JSONSerialization.data(withJSONObject: payload)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? "{}"
        frames.append(SSEFrame(event: "clarify", data: data, id: "clarify-\(id)"))
    }
}

@MainActor func runSendSafetyTests() async throws {
    let image = ChatAttachmentPayload(name: "queued.jpg", path: "/attachments/queued.jpg",
                                      mime: "image/jpeg", size: 42, isImage: true)

    // A failed recovery write is surfaced without turning the current POST into
    // an ambiguous delivery. The backend can later report a successful write,
    // but the page keeps the warning because the failed run is still not
    // recoverable after relaunch.
    do {
        let service = SendSafetyService()
        service.recoveryUnavailable = true
        let model = NativeChatModel(sessionID: "recovery-warning", api: service)
        await model.load()
        model.draft = "still accepted"
        let accepted = await model.send()
        precondition(accepted && model.streamID == "run-1")
        precondition(model.runRecoveryNoticeShown)
        precondition(!model.uncertain && model.pendingSend == nil,
                     "a recovery-store failure must not turn an accepted POST into an ambiguous send")
        service.recoveryUnavailable = false
        model.noteRunRecoveryState()
        precondition(model.runRecoveryNoticeShown,
                     "a later successful write must not hide the unrecoverable earlier run")
        model.disconnect()
    }

    // A failed draft write is category-only and stays visible until an
    // explicit verified retry for the same kind succeeds.
    do {
        let suite = "HermesDraftFailure-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let failingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesDraftFailureRoot-" + UUID().uuidString)
        try Data("not-a-directory".utf8).write(to: failingRoot)
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failingStore = ChatDraftStore(
            instanceID: "draft-failure", accountScope: "account", sessionID: "session",
            defaults: defaults,
            fileStore: LocalDataFileStore(instanceID: "draft-failure", accountScope: "account",
                                          sessionID: "session", rootDirectory: failingRoot))
        let failingModel = NativeChatModel(sessionID: "draft-failure", api: SendSafetyService(),
                                           draftStore: failingStore)
        failingModel.draft = "must stay in memory"
        failingModel.recordLocalWrite(.failed(.diskWrite), kind: .draft)
        precondition(failingModel.localPersistenceIssue?.kind == .draft)
        precondition(failingModel.localPersistenceIssue?.failure == .diskWrite)
        try FileManager.default.removeItem(at: failingRoot)
        let retried = failingStore.save("recovered text")
        failingModel.recordVerifiedLocalRetry(retried, kind: .draft)
        precondition(retried.succeeded)
        precondition(failingStore.load() == "recovered text")
        precondition(failingModel.localPersistenceIssue == nil,
                     "a verified successful draft write clears only the draft issue")
    }

    // Queue persistence now consumes the actual storage result instead of
    // clearing the warning unconditionally.
    do {
        let suite = "HermesQueueWriteFailure-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesQueueWriteFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-a-directory".utf8).write(to: root)
        let fileStore = LocalDataFileStore(instanceID: "queue-save-result",
                                           accountScope: "account", sessionID: "session",
                                           rootDirectory: root)
        let store = ChatDraftStore(instanceID: "queue-save-result", accountScope: "account",
                                   sessionID: "session", defaults: defaults, fileStore: fileStore)
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-save-result", api: service,
                                    draftStore: store)
        await model.load(); model.transition(to: .streaming(connected: true))
        model.sendMode = .queue; model.draft = "wait"; _ = await model.send()
        precondition(model.localPersistenceIssue?.kind == .queue)
        precondition(model.localPersistenceIssue?.failure == .diskWrite)
        precondition(model.queueSaveFailed)
        precondition(model.queuedTurns.count == 1,
                     "the complete queued turn remains usable in memory after the verified write fails")
        // Fail closed if storage is still broken when the turn becomes eligible.
        // A pending POST without durable evidence cannot be safely retried.
        model.transition(to: .idle)
        model.streamID = nil
        precondition(model.canSend, "test setup must allow an otherwise valid send")
        let callsBeforeFailure = service.startCalls
        let blockedDispatch = await model.flushQueuedIfNeeded()
        precondition(!blockedDispatch && service.startCalls == callsBeforeFailure,
                     "queue persistence failure must prevent the network POST")
        precondition(model.queuedTurns.first?.delivery == .waiting,
                     "failed pre-POST storage cannot leave a submitting state in memory")
        precondition(!model.retryQueuePersistence().succeeded,
                     "an explicit retry reports the same verified failure")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repaired = model.retryQueuePersistence()
        model.recordVerifiedLocalRetry(repaired, kind: .queue)
        precondition(repaired.succeeded && !model.queueSaveFailed
                     && model.localPersistenceIssue == nil,
                     "only a verified explicit retry clears the sticky queue failure")
        model.disconnect()
    }

    // Recovery and enqueue must never silently override a user's pause.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "paused-queue", api: service)
        await model.load()
        model.setQueueAutomaticDispatchPaused(true)
        model.draft = "initial"; _ = await model.send()
        model.sendMode = .queue
        model.draft = "queued"; _ = await model.send()
        precondition(model.queueUserPaused && model.queueAutomaticDispatchPaused,
                     "enqueue must preserve explicit pause")
        model.pauseQueueForRecovery()
        model.resumeQueueAfterRecovery()
        precondition(model.queueUserPaused && model.queueAutomaticDispatchPaused,
                     "recovery cannot override user pause")
        model.setQueueAutomaticDispatchPaused(false)
        precondition(!model.queueAutomaticDispatchPaused,
                     "explicit resume clears user pause after safe recovery")
        model.disconnect()
    }

    // Stop acknowledgement cannot release sending until a terminal status is
    // observed, including when the history contains no final assistant reply.
    do {
        let service = SendSafetyService()
        service.stopAcknowledgementOnly = true
        let model = NativeChatModel(sessionID: "stop-pending", api: service)
        model.stopStatusPollDelaysNanoseconds = [15_000_000, 20_000_000, 30_000_000]
        await model.load()
        model.draft = "work"; _ = await model.send()
        await model.stop()
        precondition(model.stopping && !model.canSend && service.startCalls == 1,
                     "stop acknowledgement alone must keep sending locked")
        await model.verifyPendingStop()
        precondition(model.stopping && service.startCalls == 1,
                     "a still-running run cannot be marked stopped")
        service.active = nil
        try await ModelTests.eventually { !model.stopping }
        precondition(model.canSend && service.startCalls == 1 && service.stopCalls == 1,
                     "bounded GET-only polling resolves terminal without repeating either POST")
        model.disconnect()
    }

    // A run that remains alive must exhaust its polling budget and stay locked.
    do {
        let service = SendSafetyService()
        service.stopAcknowledgementOnly = true
        let model = NativeChatModel(sessionID: "stop-never-terminal", api: service)
        model.stopStatusPollDelaysNanoseconds = [10_000_000, 10_000_000]
        await model.load()
        model.draft = "still running"; _ = await model.send()
        await model.stop()
        try await ModelTests.eventually { model.stopStatusPollTask == nil }
        precondition(model.stopping && !model.canSend && service.startCalls == 1
                     && service.stopCalls == 1,
                     "exhausted polling must not unlock, dispatch or issue another STOP")
        precondition(model.notice?.contains("返回会话时将自动继续核对") == true,
                     "poll budget exhaustion preserves lock and clearly explains safe foreground follow-up")
        model.disconnect()
    }

    // STOP and SSE completion can arrive in either order. An SSE terminal
    // must never bypass the STOP-owned confirmation and queued-send lock.
    do {
        let service = SendSafetyService()
        service.stopAcknowledgementOnly = true
        let model = NativeChatModel(sessionID: "stop-sse-race", api: service)
        model.stopStatusPollDelaysNanoseconds = [2_000_000_000]
        await model.load()
        model.draft = "first"; _ = await model.send()
        model.sendMode = .queue
        model.draft = "never auto-send"; _ = await model.send()
        precondition(model.queuedTurns.count == 1)
        await model.stop()
        precondition(model.stopping && model.queueRecoveryPaused)
        service.frames.append(SSEFrame(event: "stream_end", data: "{}", id: "finish-after-stop"))
        try await ModelTests.eventually { model.buffer.terminal }
        // Give the stream task a chance to finish its async terminal branch.
        await Task.yield()
        precondition(model.stopping && !model.canSend && service.startCalls == 1,
                     "SSE terminal must preserve STOP lock and never dispatch the queued turn")
        service.active = nil
        await model.verifyPendingStop()
        precondition(!model.stopping && service.startCalls == 1
                     && model.queuedTurns.count == 1 && model.queueAutomaticDispatchPaused,
                     "verified cancellation preserves unsent queue for explicit user action")
        model.disconnect()
    }

    // A background/foreground transition cancels timers, not server STOP.
    // Resuming performs only a scoped status + history GET.
    do {
        let service = SendSafetyService()
        service.stopAcknowledgementOnly = true
        let model = NativeChatModel(sessionID: "stop-resume", api: service)
        model.stopStatusPollDelaysNanoseconds = [2_000_000_000]
        await model.load()
        model.draft = "one stop"; _ = await model.send()
        await model.stop()
        model.disconnect()
        precondition(model.stopping && model.suspended)
        service.active = nil
        await model.resumeForeground()
        precondition(!model.stopping && !model.suspended
                     && service.startCalls == 1 && service.stopCalls == 1,
                     "foreground resolves the original run using GET only, never a second POST")
        model.disconnect()
    }

    // Explicit pause is scoped and durable independently from recovery pause,
    // including when no queued turns remain.
    do {
        let suite = "HermesQueueUserPause-179-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance-a", accountScope: "account-a",
                                   sessionID: "session-a", defaults: defaults)
        let first = NativeChatModel(sessionID: "session-a",
                                    api: SendSafetyService(), draftStore: store)
        first.setQueueAutomaticDispatchPaused(true)
        precondition(first.queueUserPaused && store.loadQueueUserPaused())
        first.disconnect()
        let reopened = NativeChatModel(sessionID: "session-a",
                                       api: SendSafetyService(), draftStore: store)
        precondition(reopened.queueUserPaused && reopened.queueAutomaticDispatchPaused,
                     "manual pause survives relaunch even with empty queue")
        let other = ChatDraftStore(instanceID: "instance-a", accountScope: "account-b",
                                   sessionID: "session-a", defaults: defaults)
        precondition(!other.loadQueueUserPaused(),
                     "manual pause must not cross an account boundary")
        reopened.setQueueAutomaticDispatchPaused(false)
        precondition(!store.loadQueueUserPaused(),
                     "explicit resume persists independently of recovery state")
        let again = NativeChatModel(sessionID: "session-a",
                                    api: SendSafetyService(), draftStore: store)
        precondition(!again.queueUserPaused,
                     "new controller reads the explicitly resumed preference")
        again.disconnect()
        reopened.disconnect()
    }

    // Queueing appends complete turns instead of replacing the first payload.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "image note"
        let accepted = await model.send(attachments: [image])
        precondition(accepted && model.queuedText?.contains(image.name) == true)
        model.draft = "keep this newer draft"
        let duplicate = await model.send()
        precondition(duplicate && model.draft.isEmpty)
        precondition(model.queuedTurns.map(\.text) == ["image note", "keep this newer draft"])
        precondition(model.queuedText?.contains("image note") == true)
        await model.stop()
        precondition(service.startCalls == 1, "stopping a run never dispatches its queued turn")
        let flushed = await model.flushQueuedIfNeeded()
        precondition(flushed && service.sent.last?.1 == [image], "queue must retain uploaded refs")
        precondition(model.queuedTurns.map(\.text) == ["keep this newer draft"])
        model.disconnect()
    }

    // build205: the queue's inline editor is independent of a current
    // composer draft, keeps attachment refs and ordering, and cannot POST.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-inline-editor", api: service)
        await model.load()
        let first = ChatQueuedTurn(id: "edit-first", text: "first", attachments: [image],
                                   composerText: "first", origin: .userInput,
                                   automaticAfterStreamID: "exact-run")
        let second = ChatQueuedTurn(id: "edit-second", text: "second", attachments: [],
                                    composerText: "second", origin: .userInput,
                                    automaticAfterStreamID: "exact-run")
        model.setQueuedTurns([first, second])
        model.draft = "unrelated draft"
        precondition(model.beginQueuedTurnEdit(id: first.id) == first)
        precondition(model.beginQueuedTurnEdit(id: second.id) == nil)
        precondition(ChatQueueDispatchPlan.make(turns: model.queuedTurns,
            completedStreamID: "exact-run", paused: false, editing: true) == .blocked)
        let blocked = await model.flushQueuedIfNeeded()
        precondition(!blocked && service.startCalls == 0)
        model.removeQueuedTurn(id: first.id)
        model.setQueuedTurns([])
        model.moveQueuedTurn(id: second.id, before: first.id)
        precondition(model.queuedTurns == [first, second])
        precondition(model.commitQueuedTurnEdit(id: first.id, composerText: "edited"))
        precondition(model.queuedTurns.map(\.id) == [first.id, second.id])
        precondition(model.queuedTurns[0].attachments == [image])
        precondition(model.queuedTurns[0].text == "edited")
        precondition(model.queuedTurns[0].automaticAfterStreamID == "exact-run")
        precondition(model.draft == "unrelated draft" && model.queueEditingTurnID == nil)
        precondition(service.startCalls == 0, "saving cannot submit the turn")

        precondition(model.beginQueuedTurnEdit(id: second.id) != nil)
        precondition(!model.commitQueuedTurnEdit(id: second.id, composerText: "  "))
        model.cancelQueuedTurnEdit(id: second.id)
        precondition(model.queuedTurns[1] == second)
        var unknown = second
        unknown.delivery = .uncertain
        model.setQueuedTurns([unknown])
        precondition(model.beginQueuedTurnEdit(id: unknown.id) == nil)
        let attachmentOnly = first.edited(composerText: " ",
            attachmentOnlyText: NativeChatModel.attachmentOnlyText)
        precondition(attachmentOnly?.attachments == [image])
        precondition(attachmentOnly?.origin == .systemPlaceholder)
        precondition(attachmentOnly?.text == NativeChatModel.attachmentOnlyText)
        precondition(model.draft == "unrelated draft")
        model.disconnect()
    }

    // Queue management preserves order, attachment payloads and the 20-turn
    // bound; manual dispatch bypasses the stream gate for the selected first row.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-management", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue
        model.draft = "one"; _ = await model.send()
        model.draft = "two"; _ = await model.send(attachments: [image])
        model.draft = "three"; _ = await model.send()
        let ids = model.queuedTurns.map(\.id)
        precondition(ids.count == 3)
        model.moveQueuedTurn(id: ids[2], before: ids[0])
        precondition(model.queuedTurns.map(\.text) == ["three", "one", "two"])
        let movedIDs = model.queuedTurns.map(\.id)
        precondition(model.updateQueuedTurn(id: movedIDs[0], text: "edited"))
        precondition(model.queuedTurns.map(\.text) == ["edited", "one", "two"])
        model.removeQueuedTurn(id: movedIDs[1])
        precondition(model.queuedTurns.map(\.text) == ["edited", "two"])
        precondition(model.queuedTurns[1].attachments == [image])
        let reordered = ChatQueueOrdering.move(model.queuedTurns,
                                               fromOffsets: IndexSet(integer: 1),
                                               toOffset: 0)
        precondition(reordered.map(\.text) == ["two", "edited"])
        let multiMoved = ChatQueueOrdering.move(
            reordered, fromOffsets: IndexSet([0, 1]), toOffset: 2)
        precondition(multiMoved.map(\.text) == ["two", "edited"],
                     "moving every row preserves the bounded queue contents")
        model.setQueuedTurns(reordered)
        precondition(model.queuedTurns.map(\.text) == ["two", "edited"])
        model.setQueueAutomaticDispatchPaused(true)
        model.markQueuedTurnForManualDispatch(id: reordered[0].id)
        model.setQueueAutomaticDispatchPaused(false)
        await model.stop()
        model.markQueuedTurnForManualDispatch(id: reordered[0].id)
        let manual = await model.flushQueuedIfNeeded()
        precondition(manual && service.sent.last?.0 == "two")

        model.draft = "fill"; _ = await model.send()
        model.sendMode = .queue
        for index in 0..<18 {
            model.draft = "extra-\(index)"
            let accepted = await model.send()
            precondition(accepted)
        }
        precondition(model.queuedTurns.count == 20, "queue reaches its documented bound")
        model.draft = "overflow"
        let overflow = await model.send()
        precondition(!overflow && model.queuedTurns.count == 20 && model.draft == "overflow")
        model.disconnect()
    }

    // Status is aggregated over the whole queue and an uncertain turn is
    // promoted without changing the relative order of ordinary turns.
    do {
        let waitingA = ChatQueuedTurn(
            id: "waiting-a", text: "a", attachments: [], composerText: "a",
            origin: .userInput, automaticAfterStreamID: nil)
        var submitting = ChatQueuedTurn(
            id: "submitting", text: "b", attachments: [], composerText: "b",
            origin: .userInput, automaticAfterStreamID: nil)
        submitting.delivery = .submitting
        var uncertain = ChatQueuedTurn(
            id: "uncertain", text: "c", attachments: [], composerText: "c",
            origin: .userInput, automaticAfterStreamID: nil)
        uncertain.delivery = .uncertain
        let waitingB = ChatQueuedTurn(
            id: "waiting-b", text: "d", attachments: [], composerText: "d",
            origin: .userInput, automaticAfterStreamID: nil)
        let status = ChatQueueStatus(turns: [waitingA, submitting, uncertain, waitingB])
        precondition(status.total == 4 && status.waiting == 2
                     && status.submitting == 1 && status.uncertain == 1)
        precondition(status.summary == "2 条待发送 · 1 条正在提交 · 1 条待核对")
        precondition(status.compactSummary == "4 条 · 1 条待核对")
        let prioritized = ChatQueueOrdering.prioritize(
            [waitingA, submitting, uncertain, waitingB])
        precondition(prioritized.map(\.id) == [
            "uncertain", "submitting", "waiting-a", "waiting-b"
        ], "uncertain first, stable ordinary order")
    }

    // Explicitly paused queues stay paused even when terminal proof retires a receipt.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-paused-terminal", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "wait"; _ = await model.send()
        model.setQueueAutomaticDispatchPaused(true)
        service.active = nil
        service.frames.append(SSEFrame(event: "stream_end", data: "{}", id: "paused-end"))
        try await ModelTests.eventually { !model.running && model.streamID == nil }
        precondition(model.queueAutomaticDispatchPaused && model.queuedTurns.count == 1
                     && service.startCalls == 1,
                     "terminal evidence cannot override an existing queue pause")
        model.disconnect()
    }

    // Automatic dispatch advances one completed stream at a time.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-chain", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue
        model.draft = "second"; _ = await model.send()
        model.draft = "third"; _ = await model.send()
        service.active = nil
        service.frames.append(SSEFrame(event: "stream_end", data: "{}", id: "run-1-end"))
        try await ModelTests.eventually { service.startCalls == 2 }
        precondition(model.queuedTurns.count == 1 && model.queuedTurns[0].text == "third")
        service.active = nil
        service.frames.append(SSEFrame(event: "stream_end", data: "{}", id: "run-2-end"))
        try await ModelTests.eventually { service.startCalls == 3 }
        precondition(model.queuedTurns.isEmpty && service.sent.map(\.0) == ["first", "second", "third"])
        model.disconnect()
    }

    // A restored queue is paused so relaunching the App cannot silently post a
    // turn before the user sees it. Manual dispatch still works.
    do {
        let suite = "HermesQueuePause-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance", accountScope: "account",
                                   sessionID: "queue", defaults: defaults)
        let firstService = SendSafetyService()
        let first = NativeChatModel(sessionID: "queue", api: firstService, draftStore: store)
        await first.load(); first.draft = "first"; _ = await first.send()
        first.sendMode = .queue; first.draft = "wait"; _ = await first.send()
        first.disconnect()
        let nextService = SendSafetyService()
        nextService.historyRows = [
            ["id": "original-user", "role": "user", "content": "first"],
            ["id": "original-answer", "role": "assistant", "content": "completed while away"]
        ]
        let restored = NativeChatModel(sessionID: "queue", api: nextService, draftStore: store)
        precondition(restored.queueAutomaticDispatchPaused)
        await restored.load()
        restored.markQueuedTurnForManualDispatch(id: restored.queuedTurns[0].id)
        let sent = await restored.flushQueuedIfNeeded()
        precondition(sent && nextService.sent.last?.0 == "wait")
        restored.disconnect()
    }

    // Versioned queue persistence preserves order and rejects malformed or
    // duplicate IDs instead of partially restoring an unsafe queue.
    do {
        let second = ChatAttachmentPayload(name: "second.txt", path: "/attachments/second.txt",
                                           mime: "text/plain", size: 12, isImage: false)
        let turns = [
            ChatQueuedTurn(id: "q1", text: "one", attachments: [image],
                           composerText: "one", origin: .userInput,
                           automaticAfterStreamID: "stream-1"),
            ChatQueuedTurn(id: "q2", text: "two", attachments: [second],
                           composerText: "two", origin: .systemPlaceholder,
                           automaticAfterStreamID: "stream-2")
        ]
        let data = ChatSendQueueCodec.encode(turns)!
        let decoded = ChatSendQueueCodec.decode(data)!
        precondition(decoded == turns)
        var uncertain = turns
        uncertain[0].delivery = .uncertain
        let uncertainData = ChatSendQueueCodec.encode(uncertain)!
        precondition(ChatSendQueueCodec.decode(uncertainData) == uncertain,
                     "version 3 preserves an uncertain delivery state")
        let version2 = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "items": [[
                "id": "v2", "text": "legacy multi", "composer_text": "legacy multi",
                "attachments": [], "system_placeholder": false,
                "automatic_after_stream_id": NSNull()
            ]]
        ])
        let migrated = ChatSendQueueCodec.decode(version2)
        precondition(migrated?.count == 1 && migrated?[0].delivery == .waiting,
                     "version 2 without delivery migrates to waiting")
        let duplicate = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "items": [
                ["id": "same", "text": "one", "composer_text": "one", "attachments": [],
                 "system_placeholder": false, "automatic_after_stream_id": NSNull()],
                ["id": "same", "text": "two", "composer_text": "two", "attachments": [],
                 "system_placeholder": false, "automatic_after_stream_id": NSNull()]
            ]
        ])
        precondition(ChatSendQueueCodec.decode(duplicate) == nil)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "text": "legacy", "composer_text": "legacy",
            "attachments": [image.jsonObject], "system_placeholder": true
        ])
        let restored = ChatSendQueueCodec.decode(legacy)
        precondition(restored?.count == 1 && restored?[0].text == "legacy")
        precondition(restored?[0].attachments == [image] && restored?[0].origin == .systemPlaceholder)
        precondition(restored?[0].automaticAfterStreamID == nil)
    }

    // A failed queued POST remains durable and locked. Explicit recovery first
    // proves the server has no copy, then dispatches exactly once.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-recovery", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "uncertain queued"; _ = await model.send()
        await model.stop()
        precondition(service.startCalls == 1 && model.queuedTurns.count == 1)
        service.failStart = true
        let failed = await model.flushQueuedIfNeeded()
        precondition(!failed && service.startCalls == 2)
        precondition(model.queuedTurns.first?.delivery == .uncertain)
        precondition(model.uncertain && !model.canSend)
        let blocked = await model.flushQueuedIfNeeded()
        precondition(!blocked && service.startCalls == 2,
                     "uncertain queue cannot auto-dispatch twice")
        service.failStart = false
        let ready = await model.prepareQueuedTurnForRetry(id: model.queuedTurns[0].id)
        precondition(ready && model.queuedTurns[0].delivery == .waiting)
        precondition(!model.uncertain && model.canSend)
        let retried = await model.flushQueuedIfNeeded()
        precondition(retried && service.startCalls == 3 && model.queuedTurns.isEmpty)
        precondition(service.sent.last?.0 == "uncertain queued")
        model.disconnect()
    }

    // A process interruption while a queued POST was in flight restores the
    // turn as uncertain, never as an auto-dispatch candidate.
    do {
        let suite = "HermesQueueRestoreUncertain-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance", accountScope: "account",
                                   sessionID: "queue-restore", defaults: defaults)
        let turn = ChatQueuedTurn(id: "interrupted", text: "do not resend",
                                  attachments: [], composerText: "do not resend",
                                  origin: .userInput, automaticAfterStreamID: "old-stream",
                                  delivery: .submitting)
        store.saveQueued(ChatSendQueueCodec.encode([turn]))
        let model = NativeChatModel(sessionID: "queue-restore",
                                    api: SendSafetyService(), draftStore: store)
        precondition(model.queuedTurns.count == 1)
        precondition(model.queuedTurns[0].delivery == .uncertain)
        precondition(model.queuedTurns[0].automaticAfterStreamID == nil)
        precondition(model.queueAutomaticDispatchPaused)
        model.disconnect()
    }

    // Build121: a restored in-flight POST is reconciled against its persisted
    // pre-POST boundary before any resend is allowed.
    do {
        let suite = "HermesQueueRestoreEvidence-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance", accountScope: "account",
                                   sessionID: "queue-evidence", defaults: defaults)
        let turn = ChatQueuedTurn(
            id: "restart-delivered", text: "canonical", attachments: [],
            composerText: "canonical", origin: .userInput,
            automaticAfterStreamID: "old-stream", delivery: .submitting,
            historyEnd: 1, knownIDs: ["older"], submittedAt: 1_700_000_000)
        store.saveQueued(ChatSendQueueCodec.encode([turn]))
        let service = SendSafetyService()
        service.historyRows = [
            ["id": "older", "role": "user", "content": "previous"],
            ["id": "canonical", "role": "user", "content": "canonical"]
        ]
        let model = NativeChatModel(sessionID: "queue-evidence",
                                    api: service, draftStore: store)
        precondition(model.queuedTurns.first?.delivery == .uncertain)
        let callsBefore = service.startCalls
        let ready = await model.prepareQueuedTurnForRetry(id: "restart-delivered")
        precondition(!ready && model.queuedTurns.isEmpty)
        precondition(service.historyCalls == 1 && service.startCalls == callsBefore,
                     "a restored delivered POST is proven and never replayed")
        precondition(!model.uncertain && model.canSend)
        model.disconnect()
    }

    do {
        let suite = "HermesQueueRestoreAbsent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance", accountScope: "account",
                                   sessionID: "queue-evidence-absent", defaults: defaults)
        let turn = ChatQueuedTurn(
            id: "restart-absent", text: "send once", attachments: [],
            composerText: "send once", origin: .userInput,
            automaticAfterStreamID: nil, delivery: .submitting,
            historyEnd: 1, knownIDs: ["older"], submittedAt: 1_700_000_000)
        store.saveQueued(ChatSendQueueCodec.encode([turn]))
        let service = SendSafetyService()
        service.historyRows = [
            ["id": "older", "role": "user", "content": "previous"]
        ]
        let model = NativeChatModel(sessionID: "queue-evidence-absent",
                                    api: service, draftStore: store)
        let ready = await model.prepareQueuedTurnForRetry(id: "restart-absent")
        precondition(ready && model.queuedTurns.first?.delivery == .waiting)
        precondition(service.startCalls == 0, "reconciliation itself never POSTs")
        let sent = await model.flushQueuedIfNeeded()
        precondition(sent && service.startCalls == 1 && service.sent.last?.0 == "send once")
        precondition(model.queuedTurns.isEmpty)
        model.disconnect()
    }

    do {
        let suite = "HermesQueueRestoreLegacy-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance", accountScope: "account",
                                   sessionID: "queue-legacy-evidence", defaults: defaults)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "version": 3,
            "items": [[
                "id": "legacy", "text": "old", "composer_text": "old",
                "attachments": [], "system_placeholder": false,
                "automatic_after_stream_id": NSNull(), "delivery": "submitting"
            ]]
        ])
        store.saveQueued(legacy)
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-legacy-evidence",
                                    api: service, draftStore: store)
        let ready = await model.prepareQueuedTurnForRetry(id: "legacy")
        precondition(!ready && model.queuedTurns.count == 1)
        precondition(service.historyCalls == 0 && service.startCalls == 0,
                     "a legacy record without boundary evidence stays fail-closed")
        precondition(model.error?.contains("旧版本") == true)
        let edited = model.updateQueuedTurn(id: "legacy", text: "edited around the check")
        precondition(!edited && model.queuedTurns.first?.text == "old",
                     "an uncertain legacy turn cannot be edited around reconciliation")
        model.disconnect()
    }

    // If reconciliation finds the canonical row, the queue entry is cleared
    // and no POST is replayed.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-delivered", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "already delivered"; _ = await model.send()
        await model.stop()
        service.failStart = true
        _ = await model.flushQueuedIfNeeded()
        precondition(model.queuedTurns.first?.delivery == .uncertain)
        service.historyRows.append([
            "id": "canonical", "role": "user", "content": "already delivered"
        ])
        let callsBeforeRecovery = service.startCalls
        let ready = await model.prepareQueuedTurnForRetry(id: model.queuedTurns[0].id)
        precondition(!ready && model.queuedTurns.isEmpty)
        precondition(service.startCalls == callsBeforeRecovery,
                     "delivered reconciliation must not replay POST")
        precondition(!model.uncertain && model.canSend)
        model.disconnect()
    }

    // A routine refresh can settle the same uncertainty before the user taps
    // retry. Clearing only the bubble and retaining the queue would replay it.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-refresh-delivered", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "delivered by refresh"; _ = await model.send()
        await model.stop()
        service.failStart = true
        _ = await model.flushQueuedIfNeeded()
        precondition(model.queuedTurns.first?.delivery == .uncertain)
        service.historyRows.append([
            "id": "canonical-refresh", "role": "user", "content": "delivered by refresh"
        ])
        let callsBeforeRefresh = service.startCalls
        await model.refresh()
        precondition(model.queuedTurns.isEmpty)
        precondition(model.pendingSend == nil && !model.uncertain)
        precondition(service.startCalls == callsBeforeRefresh,
                     "refresh settlement never replays the queued POST")
        model.disconnect()
    }

    // Steer has no attachment contract: enqueue the complete turn visibly.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "steer-image", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.draft = ""
        let accepted = await model.send(attachments: [image])
        precondition(accepted && service.steerCalls == 0 && model.queuedText != nil)
        await model.stop(); _ = await model.flushQueuedIfNeeded()
        precondition(service.sent.last?.0 == ChatAttachmentPlaceholder.systemText)
        precondition(service.sent.last?.1 == [image])
        model.disconnect()
    }

    // Only one steer POST is allowed while awaiting acknowledgement.
    do {
        let service = SendSafetyService(); service.holdSteer = true
        let model = NativeChatModel(sessionID: "steer-lock", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.draft = "guide"
        let first = Task { await model.send() }
        try await ModelTests.eventually { service.pendingSteer != nil }
        let second = await model.send()
        precondition(!second && service.steerCalls == 1 && model.sendingWhileRunning)
        service.pendingSteer!.resume(returning: nil); service.pendingSteer = nil
        let accepted = await first.value
        precondition(accepted && !model.sendingWhileRunning && model.draft.isEmpty)
        model.disconnect()
    }

    // An interrupt cannot bypass an unsuccessful authoritative history check.
    do {
        let service = SendSafetyService(); service.failHistoryAfterStop = true
        let model = NativeChatModel(sessionID: "interrupt", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .interrupt; model.draft = "keep me"
        let accepted = await model.send()
        precondition(!accepted && service.startCalls == 1 && model.draft == "keep me")
        precondition(model.uncertain && !model.canSend)
        model.disconnect()
    }

    // Cancellation is terminal but does not grant permission to dispatch queue.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "cancel-queue", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "wait"; _ = await model.send()
        service.active = nil
        service.frames.append(SSEFrame(event: "cancel", data: "{}", id: "cancel"))
        try await ModelTests.eventually { !model.running && !model.reconciling }
        precondition(service.startCalls == 1 && model.queuedText == "wait")
        model.draft = "a new explicit turn"; _ = await model.send()
        service.active = nil
        service.frames.append(SSEFrame(event: "stream_end", data: "{}", id: "new-turn-end"))
        try await ModelTests.eventually { !model.running && !model.reconciling }
        precondition(service.startCalls == 2 && model.queuedText == "wait",
                     "a later unrelated completion cannot dispatch a queue held after cancellation")
        model.disconnect()
    }

    // Destroying a chat view must preserve its queued text, attachments and
    // placeholder origin, without auto-posting when the page is opened again.
    do {
        let suite = "HermesQueuedSend-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "instance", accountScope: "account", sessionID: "queue", defaults: defaults)
        let firstService = SendSafetyService()
        let first = NativeChatModel(sessionID: "queue", api: firstService, draftStore: store)
        await first.load(); first.draft = "first"; _ = await first.send()
        first.sendMode = .queue; first.draft = ""; _ = await first.send(attachments: [image])
        first.disconnect()
        let nextService = SendSafetyService()
        nextService.historyRows = [
            ["id": "original-user", "role": "user", "content": "first"],
            ["id": "original-answer", "role": "assistant", "content": "completed while away"]
        ]
        let restored = NativeChatModel(sessionID: "queue", api: nextService, draftStore: store)
        precondition(restored.queuedText?.contains(image.name) == true)
        await restored.load()
        precondition(nextService.startCalls == 0, "restored queue never auto-posts")
        _ = await restored.flushQueuedIfNeeded()
        precondition(nextService.sent.last?.1 == [image] && store.loadQueued() == nil)
        restored.disconnect()
    }

    // An acknowledgement for an old approval must not dismiss its replacement.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "approvals", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        service.approval("old")
        try await ModelTests.eventually { model.pendingApproval?.requestID == "old" }
        let response = Task { await model.respondToApproval("once") }
        try await ModelTests.eventually { service.pendingApproval != nil }
        service.approval("new")
        try await ModelTests.eventually { model.pendingApproval?.requestID == "new" }
        service.pendingApproval!.resume(returning: nil); service.pendingApproval = nil
        await response.value
        precondition(model.pendingApproval?.requestID == "new" && !model.approving)
        service.frames.append(SSEFrame(event: "approval_resolved", data: "{\"request_id\":\"old\"}", id: "old-resolved"))
        service.frames.append(SSEFrame(event: "token", data: "{\"text\":\"settle\"}", id: "settle"))
        try await ModelTests.eventually { model.transcript.lastEventID == "settle" }
        precondition(model.pendingApproval?.requestID == "new", "different request must stay visible")
        service.frames.append(SSEFrame(event: "approval_resolved", data: "{\"request_id\":\"new\"}", id: "new-resolved"))
        try await ModelTests.eventually { model.pendingApproval == nil }
        model.disconnect()
    }
    // Multiple approval requests from one run must coexist. A duplicate frame
    // is an update, while resolving one request must leave its siblings intact.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "approval-queue", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        service.approval("a1")
        service.approval("a2")
        try await ModelTests.eventually {
            model.pendingApprovals.map(\.requestID) == ["a1", "a2"]
        }
        service.approval("a1")
        service.frames.append(SSEFrame(event: "token", data: "{\"text\":\"seen\"}", id: "seen"))
        try await ModelTests.eventually { model.transcript.lastEventID == "seen" }
        precondition(model.pendingApprovals.map(\.requestID) == ["a1", "a2"],
                     "duplicate approval frame must upsert, not duplicate")
        service.frames.append(SSEFrame(event: "approval_resolved",
                                       data: "{\"request_id\":\"a1\"}", id: "a1-resolved"))
        service.frames.append(SSEFrame(event: "token", data: "{\"text\":\"seen\"}", id: "a1-seen"))
        try await ModelTests.eventually { model.transcript.lastEventID == "a1-seen" }
        precondition(model.pendingApprovals.map(\.requestID) == ["a2"],
                     "resolving one approval must preserve sibling requests")
        precondition(!model.canRespondToApproval(requestID: "missing", choice: "once"),
                     "a missing request ID must never fall back to another approval")
        let old = ChatPendingApproval(id: "old", runID: "old-run", requestID: "old",
                                      detail: "", command: nil, choices: ["once"])
        let current = ChatPendingApproval(id: "current", runID: "current-run",
                                          requestID: "current", detail: "",
                                          command: nil, choices: ["once"])
        model.pendingApprovals = [old, current]
        model.removePendingApprovals(for: "current-run")
        precondition(model.pendingApprovals.map(\.id) == ["current"],
                     "snapshot reconciliation preserves the live run and removes stale requests")
        model.pendingApprovals = [old, current]
        model.removePendingApprovals(for: nil)
        precondition(model.pendingApprovals.isEmpty,
                     "a nil active run invalidates every pending approval")
        model.disconnect()
    }
    // clarify：到达要能出卡片，答复要带对三件套（含 execution_generation），
    // settled 要能收掉卡片，换一条提问时旧卡片不能顶替新的。
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "clarify", api: service)
        await model.load(); model.draft = "go"; _ = await model.send()
        service.clarify("c1", generation: 7, choices: ["覆盖", "重命名"])
        try await ModelTests.eventually { model.pendingClarify?.requestID == "c1" }
        precondition(model.pendingClarify?.executionGeneration == 7,
                     "clarify must keep execution_generation for the reply")
        precondition(model.pendingClarify?.choices == ["覆盖", "重命名"],
                     "clarify choices are arbitrary text, not the approval whitelist")
        await model.respondToClarify("重命名")
        precondition(service.clarifyCalls.count == 1,
                     "one tap sends exactly one clarify reply")
        precondition(service.clarifyCalls[0].0 == "c1" && service.clarifyCalls[0].1 == 7,
                     "the reply carries request_id and execution_generation")
        precondition(service.clarifyCalls[0].2 == "重命名",
                     "the reply sends the raw answer text; the server owns parsing")
        precondition(model.pendingClarify == nil, "a successful reply retires the card")

        // 空答复不该发出去：服务端会当成空答案。
        service.clarify("c2", generation: 8)
        try await ModelTests.eventually { model.pendingClarify?.requestID == "c2" }
        let before = service.clarifyCalls.count
        await model.respondToClarify("   ")
        precondition(service.clarifyCalls.count == before,
                     "an empty answer is not submitted")

        // settled 收卡片
        service.frames.append(SSEFrame(event: "clarify_resolved",
                                       data: "{\"request_id\":\"c2\"}", id: "c2-settled"))
        try await ModelTests.eventually { model.pendingClarify == nil }

        // 别的 request 的 settled 不能收掉当前这条
        service.clarify("c3", generation: 9)
        try await ModelTests.eventually { model.pendingClarify?.requestID == "c3" }
        service.frames.append(SSEFrame(event: "clarify_resolved",
                                       data: "{\"request_id\":\"other\"}", id: "other-settled"))
        service.frames.append(SSEFrame(event: "token", data: "{\"text\":\"settle\"}", id: "c3-settle"))
        try await ModelTests.eventually { model.transcript.lastEventID == "c3-settle" }
        precondition(model.pendingClarify?.requestID == "c3",
                     "a settled frame for another request must not retire this card")
        model.disconnect()
    }
    // Multiple clarify requests share a run; input state and exact removal are
    // verified by the queued request contract rather than by one latest slot.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "clarify-queue", api: service)
        await model.load(); model.draft = "go"; _ = await model.send()
        service.clarify("q1", generation: 11)
        service.clarify("q2", generation: 12)
        try await ModelTests.eventually {
            model.pendingClarifies.map(\.requestID) == ["q1", "q2"]
        }
        service.clarify("q1", generation: 11)
        service.frames.append(SSEFrame(event: "token", data: "{\"text\":\"seen\"}", id: "q-seen"))
        try await ModelTests.eventually { model.transcript.lastEventID == "q-seen" }
        precondition(model.pendingClarifies.map(\.requestID) == ["q1", "q2"],
                     "duplicate clarify frame must upsert, not duplicate")
        await model.respondToClarify("answer q1", requestID: "q1")
        precondition(service.clarifyCalls.last?.0 == "q1"
                     && model.pendingClarifies.map(\.requestID) == ["q2"],
                     "answering one clarify must remove only that request")
        precondition(!model.canRespondToClarify(requestID: "missing"),
                     "a missing request ID must never fall back to another clarify")
        model.disconnect()
    }

    // P0：清空全部不能抹掉正在提交的那条。
    //
    // 旧 `setQueuedTurns` 只检查**新数组**里有没有 `.submitting`，空数组必然通过，
    // 于是「清空全部排队消息」会把在途 POST 的记录一起删掉。那条记录的
    // `historyEnd` / `knownIDs` 是重启后核对「到底发出去没有」的唯一证据，
    // 删了就只剩两种坏选择：当没发（可能重复执行）或永久卡住。
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-clear", api: service)
        await model.load(); model.draft = "active"; _ = await model.send()
        model.sendMode = .queue
        model.draft = "waiting-one"; _ = await model.send()
        model.draft = "waiting-two"; _ = await model.send()

        // 手工把第一条标成「正在提交」，模拟 POST 在途。
        // 不能走 `setQueuedTurns`：那个入口本身就会拒绝含 `.submitting` 的新数组
        // （那是它的另一条既有守卫），所以这里直接改模型持有的队列。
        precondition(model.queuedTurns.count == 2)
        let inFlight = model.queuedTurns[0]
        model.queuedTurns[0].delivery = .submitting
        precondition(model.queuedTurns[0].delivery == .submitting,
                     "the test fixture could not mark a turn as submitting")

        // 清空全部：必须整体拒绝，而不是静默清空。
        model.setQueuedTurns([])
        precondition(model.queuedTurns.count == 2,
                     "P0: clearing must not drop the in-flight turn, got \(model.queuedTurns.count) rows")
        precondition(model.queuedTurns[0].id == inFlight.id,
                     "P0: the in-flight record survives with its evidence intact")
        precondition(model.queueClearRefusal != nil,
                     "P0: the refusal must be surfaced so the UI can explain why")

        // 在途项结束后（POST 有了结果，delivery 回到 waiting），清空应当恢复可用。
        // 这验证了拒绝是「因为确实在途」而不是永久锁死。
        model.queuedTurns[0].delivery = .waiting
        model.setQueuedTurns([])
        precondition(model.queuedTurns.isEmpty,
                     "once nothing is in flight, clearing works (got \(model.queuedTurns.count) rows)")
        precondition(model.queueClearRefusal == nil, "the refusal clears on success")

        model.disconnect()
    }

    // P0：断线恢复时，没有 active stream 不等于「上一轮已完成」。
    //
    // 恢复路径手里没有 done/stream_end 帧，只能靠快照自证。旧实现在
    // `activeStreamID == nil` 时直接 idle 返回，绕过完成计数与队列 flush 判定：
    // 一旦误判，`canSend` 变真，排队的那条被自动发出，两个轮次并发。
    do {
        let service = RecoveryService()
        service.throwsOnDisconnect = true
        // 断线时服务端把 run 摘掉（active 归 nil），但历史里没有 assistant 消息：
        // 既没有 active stream，也无法证实上一轮已结束。
        service.dropsActiveOnDisconnect = true
        service.historyWithoutAnswer = true
        let model = NativeChatModel(sessionID: "recover-unproven", api: service)
        await model.load()
        model.sendMode = .queue
        model.draft = "first"; _ = await model.send()
        model.draft = "queued-follow-up"; _ = await model.send()
        precondition(model.queuedTurns.count == 1, "the follow-up is queued behind the active turn")

        // 等恢复耗尽（3 次退避）。
        try await ModelTests.eventually { service.historyCalls >= 2 && !model.running }

        precondition(model.uncertain,
                     "P0: an unproven finish must lock sending instead of pretending the turn ended")
        precondition(model.queuedTurns.count == 1,
                     "P0: the queued turn must NOT be auto-dispatched on an unproven finish")
        precondition(service.startCalls == 1,
                     "P0: no second POST was issued — got \(service.startCalls) start calls")
        precondition(model.notice?.contains("无法确认") == true,
                     "the user is told why sending is paused, not left guessing")
        model.disconnect()
    }

    // build159: manual and queued sends MUST share identical attribution
    // semantics even if one new message matches among other writers.
    do {
        let base: [[String: Any]] = [
            ["id": "old", "role": "user", "content": "earlier"]
        ]
        let one = base + [["id": "ours?", "role": "user", "content": "canonical"]]
        let many = one + [["id": "other", "role": "user", "content": "different"]]
        let queue = ChatQueuedTurn(text: "canonical", attachments: [],
            composerText: "canonical", origin: .userInput,
            automaticAfterStreamID: nil, delivery: .uncertain,
            historyEnd: 1, knownIDs: ["old"], submittedAt: 1_700_000_000)
        let manual = NativeChatModel.PendingSend(
            id: "manual", text: "canonical", attachments: [],
            composerText: "canonical", historyEnd: 1, knownIDs: ["old"],
            createdAt: 1_700_000_000, origin: .userInput)
        func snap(_ rows: [[String: Any]], readOnly: Bool = false) throws -> ChatSnapshot {
            try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
                "session_id": "queue-evidence", "messages": rows, "read_only": readOnly
            ]))
        }
        let unique = try snap(one), collision = try snap(many)
        let absent = try snap(base), stale = try snap(one, readOnly: true)
        precondition(manual.resolution(in: unique) == .delivered
                     && queue.resolution(in: unique) == .delivered)
        precondition(manual.resolution(in: collision) == .failed
                     && queue.resolution(in: collision) == .failed,
                     "another new writer makes the only matching row ambiguous")
        precondition(manual.resolution(in: absent) == .absent
                     && queue.resolution(in: absent) == .absent)
        precondition(manual.resolution(in: stale) == .failed
                     && queue.resolution(in: stale) == .failed,
                     "read-only history is not authoritative delivery evidence")
    }

    // Q205-01/02 and build206: refusing an in-flight clear must preserve
    // recovery evidence; the warning expires on a successful mutation.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-clear-feedback", api: service)
        await model.load()
        let pending = ChatQueuedTurn(id: "submitting-queue", text: "keep",
            attachments: [image], composerText: "keep", origin: .userInput,
            automaticAfterStreamID: nil)
        model.setQueuedTurns([pending])
        model.queuedTurns[0].delivery = .submitting
        model.setQueuedTurns([])
        precondition(model.queuedTurns.count == 1
                     && model.queuedTurns[0].id == pending.id
                     && model.queuedTurns[0].attachments == [image])
        precondition(model.queueClearRefusal?.contains("正在发送") == true,
                     "in-flight refusal must be visible to queue UI")
        model.queuedTurns[0].delivery = .waiting
        model.setQueuedTurns([])
        precondition(model.queuedTurns.isEmpty && model.queueClearRefusal == nil,
                     "a successful clear retires stale refusal feedback")
        model.setQueueAutomaticDispatchPaused(true)
        model.uncertain = true // An unresolved POST is the reason for recovery lock.
        model.pauseQueueForRecovery()
        model.setQueueAutomaticDispatchPaused(false)
        precondition(model.queueRecoveryPaused && model.queueAutomaticDispatchPaused
                     && !model.queueUserPaused,
                     "recovery lock cannot be overridden by user-resume intent")
        model.disconnect()
    }
    precondition(!QueueEditorExitPolicy.needsDiscardConfirmation(
        editingID: nil, original: "a", current: "b"))
    precondition(!QueueEditorExitPolicy.needsDiscardConfirmation(
        editingID: "turn", original: "same", current: "same"))
    precondition(QueueEditorExitPolicy.needsDiscardConfirmation(
        editingID: "turn", original: "original", current: "edited"))

    print("SEND_SAFETY_PASS complete queue payload, no overwrite, persistence, steer lock, interrupt verification, cancellation, approval identity and clarify reply contract")
}
