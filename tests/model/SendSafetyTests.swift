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
    var stopErrorCode: Int?
    var stopTimeout = false
    var stopCalls = 0
    var stopProbeCalls = 0
    var failStart = false
    var historyRows: [[String: Any]] = []
    var historyPageSize: Int?
    var holdSteer = false
    var pendingSteer: CheckedContinuation<String?, Error>?
    var pendingApproval: CheckedContinuation<String?, Error>?
    var holdApproval = true
    var approvalOutcome: String?
    var clarifyOutcome: String?
    var approvalCalls: [(String, Int, String)] = []
    var clarifyCalls: [(String, Int, String)] = []
    var frames: [SSEFrame] = []
    var pendingControlSnapshot: GatewayPendingControlSnapshot?
    var historyCalls = 0
    var recoveryUnavailable = false
    var runRecoveryUnavailable: Bool { recoveryUnavailable }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        if failHistory { throw URLError(.notConnectedToInternet) }
        let end = min(max(0, before ?? historyRows.count), historyRows.count)
        let offset = historyPageSize.map { max(0, end - $0) } ?? 0
        var object: [String: Any] = ["session_id": sessionID,
            "messages": historyPageSize == nil ? historyRows : Array(historyRows[offset..<end]),
            "_messages_offset": offset, "_messages_truncated": offset > 0, "read_only": false]
        if let active { object["active_stream_id"] = active }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: object),
                                gatewayPendingControls: pendingControlSnapshot)
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
        if let stopErrorCode { throw ChatStopHTTPError.rejected(stopErrorCode) }
        if stopTimeout { throw URLError(.timedOut) }
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
        stopProbeCalls += 1
        return active == runID ? .alive : .terminal(.cancelled)
    }
    func steerNativeTurn(sessionID: String, text: String) async throws -> String? {
        steerCalls += 1
        if holdSteer { return try await withCheckedThrowingContinuation { pendingSteer = $0 } }
        return nil
    }
    func approveNativeTurn(runID: String, choice: String, requestID: String,
                           executionGeneration: Int) async throws -> String? {
        approvalCalls.append((requestID, executionGeneration, choice))
        if !holdApproval { return approvalOutcome }
        return try await withCheckedThrowingContinuation { pendingApproval = $0 }
    }
    func clarifyNativeTurn(runID: String, answer: String, requestID: String,
                           executionGeneration: Int) async throws -> String? {
        clarifyCalls.append((requestID, executionGeneration, answer))
        return clarifyOutcome
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
    func completeCurrentTurn(id: String) {
        guard let (text, attachments) = sent.last else { preconditionFailure("no accepted turn") }
        historyRows.append(["id": "completed-user-" + id, "role": "user", "content": text,
                            "attachments": attachments.map { ["path": $0.path] }])
        historyRows.append(["id": "completed-answer-" + id, "role": "assistant", "content": "final answer"])
        active = nil
        frames.append(SSEFrame(event: "stream_end", data: #"{"status":"completed"}"#, id: id))
    }

    func approval(_ id: String) {
        let payload: [String: Any] = [
            "request_id": id, "execution_generation": 7,
            "message": "Review command", "choices": ["once", "deny"]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? "{}"
        frames.append(SSEFrame(event: "approval", data: data, id: id))
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
        try FileManager.default.createDirectory(at: failingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failingStore = ChatDraftStore(
            instanceID: "draft-failure", accountScope: "account", sessionID: "session",
            defaults: defaults,
            fileStore: LocalDataFileStore(instanceID: "draft-failure", accountScope: "account",
                                          sessionID: "session", rootDirectory: failingRoot))
        let failingModel = NativeChatModel(sessionID: "draft-failure", api: SendSafetyService(),
                                           draftStore: failingStore)
        // Isolate a runtime draft-write outage from a cold unreadable store.
        precondition(!failingModel.recoveryRecordsUnreadable && failingModel.localPersistenceIssues.isEmpty)
        try FileManager.default.removeItem(at: failingRoot)
        try Data("not-a-directory".utf8).write(to: failingRoot)
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
        failingModel.recordLocalWrite(.failed(.diskWrite), kind: .draft)
        failingModel.recordLocalWrite(.failed(.diskWrite), kind: .runRecovery)
        failingModel.recordLocalWrite(.failed(.diskWrite), kind: .queue)
        precondition(failingModel.localPersistenceIssues.count == 3 && failingModel.queuePersistenceFailed)
        failingModel.recordVerifiedLocalRetry(.ok, kind: .queue)
        precondition(failingModel.localPersistenceIssues.count == 2 &&
                     failingModel.localPersistenceIssue?.kind == .runRecovery)
        failingModel.recordSuccessfulLocalWrite(kind: .runRecovery)
        precondition(failingModel.localPersistenceIssue?.kind == .draft,
                     "one repaired category cannot hide another unsaved record")
        failingModel.recordSuccessfulLocalWrite(kind: .draft)
        precondition(failingModel.localPersistenceIssue == nil)

        // Two files in the same category cannot acknowledge each other.
        failingModel.recordLocalWrite(.failed(.diskWrite), record: .pendingSend)
        failingModel.recordLocalWrite(.failed(.diskWrite), record: .queuedTurns)
        failingModel.recordSuccessfulLocalWrite(record: .queuedTurns)
        precondition(failingModel.queuePersistenceFailed &&
                     failingModel.localRecordIssues[.pendingSend] != nil)
        failingModel.recordLocalWrite(.failed(.diskWrite), record: .queuePause)
        failingModel.resumeQueueAfterRecovery()
        precondition(failingModel.queueAutomaticDispatchPaused,
                     "automatic recovery cannot bypass an unsaved pause")
        failingModel.recordSuccessfulLocalWrite(record: .pendingSend)
        precondition(failingModel.queuePersistenceFailed)
        failingModel.recordSuccessfulLocalWrite(record: .queuePause)
        precondition(!failingModel.queuePersistenceFailed)
        failingModel.recordLocalWrite(.failed(.diskWrite), record: .attachmentDraft)
        failingModel.recordSuccessfulLocalWrite(kind: .draft)
        precondition(failingModel.localRecordIssues[.attachmentDraft] != nil)
        failingModel.recordSuccessfulLocalWrite(record: .attachmentDraft)
        precondition(failingModel.localPersistenceIssue == nil)
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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStore = LocalDataFileStore(instanceID: "queue-save-result",
                                           accountScope: "account", sessionID: "session",
                                           rootDirectory: root)
        let store = ChatDraftStore(instanceID: "queue-save-result", accountScope: "account",
                                   sessionID: "session", defaults: defaults, fileStore: fileStore)
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-save-result", api: service,
                                    draftStore: store)
        await model.load()
        precondition(model.canSend && !model.pendingRecoveryUnreadable && !model.activeRecoveryUnreadable)
        // Inject a write outage AFTER a healthy initialization. A cold unreadable
        // root is a different safety case and must never permit a new send.
        try FileManager.default.removeItem(at: root)
        try Data("not-a-directory".utf8).write(to: root)
        model.transition(to: .streaming(connected: true))
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
        precondition(model.validateLocalData().succeeded)
        precondition(model.queueSaveFailed && model.localPersistenceIssue?.kind == .queue,
                     "reading accessible old or absent files cannot acknowledge a failed newer write")
        precondition(model.retryLocalMigration().succeeded && model.queueSaveFailed,
                     "no-op migration cannot acknowledge the current queue")
        let repaired = model.retryQueuePersistence()
        model.recordVerifiedLocalRetry(repaired, kind: .queue)
        precondition(repaired.succeeded && !model.queueSaveFailed &&
                     !model.queuePersistenceFailed &&
                     model.localPersistenceIssue?.kind == .draft,
                     "queue retry must not erase the independent draft write failure")
        let draftRetry = store.save(model.draft)
        model.recordVerifiedLocalRetry(draftRetry, kind: .draft)
        precondition(draftRetry.succeeded && model.localPersistenceIssue == nil,
                     "each failed record clears only after its own verified repair")
        model.disconnect()
    }

    // An unavailable receipt directory at launch must fail closed even
    // after a successful read-only history GET; an unsuccessful delete
    // cannot be mistaken for the explicit retirement of a damaged receipt.
    do {
        let suite = "HermesColdUnreadableReceipts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesColdUnreadable-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-a-directory".utf8).write(to: root)
        let fileStore = LocalDataFileStore(instanceID: "cold", accountScope: "account",
            sessionID: "session", rootDirectory: root)
        let store = ChatDraftStore(instanceID: "cold", accountScope: "account",
            sessionID: "session", defaults: defaults, fileStore: fileStore)
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "session", api: service, draftStore: store)
        precondition(model.pendingRecoveryUnreadable && model.activeRecoveryUnreadable)
        await model.load()
        precondition(!model.canSend && model.presentationState.needsVerification)
        model.draft = "never replay"
        let sent = await model.send()
        precondition(!sent && service.startCalls == 0 && model.draft == "never replay")
        model.abandonUnreadablePending()
        model.abandonUnreadableActiveRecovery()
        precondition(model.pendingRecoveryUnreadable && model.activeRecoveryUnreadable && !model.canSend,
                     "failed local deletion cannot unlock an unreadable receipt")
        precondition(model.draftRecoveryUnreadable)
        // Storage becomes accessible, with the original draft still present.
        // A late composer/model publication must not replace it with empty text.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        precondition(store.save("original retained draft").succeeded)
        model.draft = ""
        precondition(store.load() == "original retained draft")
        precondition(model.restoreUnreadableDraft().succeeded)
        precondition(!model.draftRecoveryUnreadable && model.draft == "original retained draft")
        model.disconnect()
        print("COLD_STORAGE_LOCK_PASS unavailable receipts block POST and cannot be cleared by failed deletion")
    }

    // A corrupt queue must not be interpreted as an empty, writable queue.
    do {
        let suite = "HermesQueueReadRepair-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDraftStore(instanceID: "repair", accountScope: "account",
            sessionID: "repair", defaults: defaults)
        let invalid = Data("bad queue".utf8)
        precondition(store.saveQueued(invalid).succeeded)
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "repair", api: service, draftStore: store)
        await model.load()
        precondition(model.queueRecoveryUnreadable && !model.canSend)
        model.setQueuedTurns([])
        precondition(store.loadQueued() == invalid)
        precondition(!model.retryQueuePersistence().succeeded)
        let recovered = ChatQueuedTurn(id: "repair-original", text: "original", attachments: [],
            composerText: "original", origin: .userInput, automaticAfterStreamID: nil,
            delivery: .submitting, historyEnd: 0, knownIDs: [], submittedAt: 1)
        precondition(store.saveQueued(ChatSendQueueCodec.encode([recovered])).succeeded)
        precondition(model.restoreUnreadableRecoveryRecords())
        precondition(!model.queueRecoveryUnreadable && model.queuedTurns.first?.id == recovered.id)
        precondition(model.queuedTurns.first?.delivery == .uncertain && model.queueRecoveryPaused)
        precondition(!model.canSend && service.startCalls == 0)
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
        // Simulate reopening an offscreen STOP runtime after SSE disappeared.
        model.streamTask?.cancel()
        model.streamTask = nil
        let previousProbes = service.stopProbeCalls
        await model.load()
        precondition(model.stopping && !model.canSend &&
                     service.stopProbeCalls > previousProbes &&
                     service.stopCalls == 1 && service.startCalls == 1,
                     "reopening must verify the exact STOP instead of replacing its phase")
        service.active = nil
        try await ModelTests.eventually { !model.stopping }
        precondition(model.canSend && service.startCalls == 1 && service.stopCalls == 1,
                     "bounded GET-only polling resolves terminal without repeating either POST")
        model.disconnect()
    }

    // A 404/409 is a rejected STOP request, not a successful cancellation.
    // The exact Run remains active and the client verifies it with GET only.
    for code in [404, 409] {
        let service = SendSafetyService()
        service.stopErrorCode = code
        let model = NativeChatModel(sessionID: "stop-rejected-\(code)", api: service)
        model.stopStatusPollDelaysNanoseconds = [5_000_000_000]
        await model.load()
        model.draft = "work"; _ = await model.send()
        await model.stop()
        precondition(model.stopping && model.uncertain && !model.canSend
                     && !model.stopAcknowledged && model.stopRejectedStatusCode == code,
                     "HTTP \(code) must remain a rejected, locked STOP outcome")
        precondition(service.active == "run-1" && service.startCalls == 1
                     && service.stopCalls == 1,
                     "rejected STOP preserves the live Run and never repeats either POST")
        precondition(model.notice?.contains("停止请求未被接受") == true,
                     "rejected STOP status is shown distinctly from an accepted STOP")
        model.disconnect()
    }

    // A timeout is different from an HTTP rejection: the STOP result is unknown.
    do {
        let service = SendSafetyService()
        service.stopTimeout = true
        let model = NativeChatModel(sessionID: "stop-timeout-unknown", api: service)
        model.stopStatusPollDelaysNanoseconds = [5_000_000_000]
        await model.load()
        model.draft = "work"; _ = await model.send()
        await model.stop()
        precondition(model.stopping && model.uncertain && !model.canSend
                     && !model.stopAcknowledged && model.stopRejectedStatusCode == nil,
                     "STOP timeout remains unknown and locked")
        precondition(service.active == "run-1" && service.startCalls == 1
                     && service.stopCalls == 1,
                     "STOP timeout is reconciled by GET without repeating POST")
        precondition(model.notice?.contains("结果未知") == true,
                     "STOP timeout is not presented as an HTTP rejection or success")
        model.disconnect()
    }

    // A run that remains alive must continue polling beyond the initial
    // window and stay locked until exact terminal proof.
    do {
        let service = SendSafetyService()
        service.stopAcknowledgementOnly = true
        let model = NativeChatModel(sessionID: "stop-never-terminal", api: service)
        model.stopStatusPollDelaysNanoseconds = [10_000_000, 10_000_000]
        model.stopStatusPollSteadyNanoseconds = 10_000_000
        await model.load()
        model.draft = "still running"; _ = await model.send()
        await model.stop()
        try await ModelTests.eventually { service.stopProbeCalls >= 5 }
        precondition(model.stopping && !model.canSend && service.startCalls == 1
                     && service.stopCalls == 1 && model.stopStatusPollTask != nil,
                     "continuous STOP status polling must not unlock or repeat a POST")
        service.active = nil
        try await ModelTests.eventually { !model.stopping }
        precondition(model.canSend && service.stopCalls == 1 && service.startCalls == 1)
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
        service.completeCurrentTurn(id: "paused-end")
        try await ModelTests.eventually { !model.running && model.streamID == nil }
        precondition(model.queueAutomaticDispatchPaused && model.queuedTurns.count == 1
                     && service.startCalls == 1,
                     "terminal evidence cannot override an existing queue pause")
        model.disconnect()
    }

    // Unknown stream termination must not be counted as success or allow
    // automatic dispatch, even when the status endpoint is unavailable.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "unknown-terminal", api: service)
        await model.load(); model.draft = "first"; _ = await model.send()
        model.sendMode = .queue; model.draft = "next"; _ = await model.send()
        service.frames.append(SSEFrame(event: "stream_end", data: #"{"status":"unknown"}"#, id: "unknown"))
        try await ModelTests.eventually { model.uncertain && !model.running }
        precondition(model.completedReplies == 0 && service.startCalls == 1 &&
            model.queuedText == "next" && !model.canSend)
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
        service.completeCurrentTurn(id: "run-1-end")
        try await ModelTests.eventually { service.startCalls == 2 }
        precondition(model.queuedTurns.count == 1 && model.queuedTurns[0].text == "third")
        service.completeCurrentTurn(id: "run-2-end")
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
        uncertain[0].submissionKey = RunSubmissionIdentity.make()
        precondition(ChatSendQueueCodec.decode(ChatSendQueueCodec.encode(uncertain)!) == uncertain,
                     "keyed queue recovery preserves its exact submission key")
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

    // A delivered queue row can be older than the latest 60 raw records.
    do {
        let service = SendSafetyService()
        service.historyPageSize = 60
        service.historyRows = [["id": "older", "role": "user", "content": "previous"],
            ["id": "accepted-older-page", "role": "user", "content": "queued long task"]]
        service.historyRows += (0..<145).map { ["id": "assistant-\($0)", "role": "assistant", "content": "step \($0)"] }
        let model = NativeChatModel(sessionID: "queue-long-proof", api: service)
        let turn = ChatQueuedTurn(id: "long-queue", text: "queued long task", attachments: [],
            composerText: "queued long task", origin: .userInput, automaticAfterStreamID: nil,
            delivery: .uncertain, historyEnd: 1, knownIDs: ["older"], submittedAt: 1_700_000_000)
        model.setQueuedTurns([turn])
        let ready = await model.prepareQueuedTurnForRetry(id: turn.id)
        precondition(!ready && model.queuedTurns.isEmpty && service.startCalls == 0 && service.historyCalls == 4,
                     "three contiguous history pages plus head verification prove delivery without POST")
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
        service.completeCurrentTurn(id: "new-turn-end")
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

    // Explicit manual queue actions must never dispatch a stale row's sibling.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "queue-exact-selection", api: service)
        await model.load()
        let first = ChatQueuedTurn(id: "first", text: "first", attachments: [],
            composerText: "first", origin: .userInput, automaticAfterStreamID: nil)
        let second = ChatQueuedTurn(id: "second", text: "second", attachments: [],
            composerText: "second", origin: .userInput, automaticAfterStreamID: nil)
        model.setQueuedTurns([first, second])
        let stale = await model.dispatchSelectedQueuedTurn(id: "removed")
        let wrongFirst = await model.flushQueuedIfNeeded(expectedTurnID: "second")
        precondition(!stale && !wrongFirst && service.startCalls == 0)
        var unresolved = first
        unresolved.delivery = .uncertain
        model.setQueuedTurns([unresolved, second])
        let blocked = await model.dispatchSelectedQueuedTurn(id: "second")
        precondition(!blocked && model.queuedTurns.first?.id == "first" && service.startCalls == 0,
                     "a waiting row cannot leapfrog unresolved original delivery")
        model.setQueuedTurns([first, second])
        let dispatched = await model.dispatchSelectedQueuedTurn(id: "second")
        precondition(dispatched && service.sent.last?.0 == "second" &&
                     model.queuedTurns.map(\.id) == ["first"])
        model.disconnect()
    }

    // A rejection is not evidence that the prompt has been resolved.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "control-rejected", api: service)
        await model.load(); model.draft = "go"; _ = await model.send()
        service.holdApproval = false
        service.approvalOutcome = "rejected"
        service.approval("reject-approval")
        try await ModelTests.eventually { model.pendingApproval?.requestID == "reject-approval" }
        guard let approval = model.pendingApproval else { preconditionFailure("missing approval") }
        await model.respondToApproval("once", requestID: approval.id, expected: approval)
        precondition(model.pendingApprovals.contains(approval) && model.error != nil)
        model.removePendingApproval(requestID: "reject-approval", runID: approval.runID,
            generation: approval.executionGeneration - 1)
        precondition(model.pendingApprovals.contains(approval), "stale generation cannot resolve approval")
        service.clarifyOutcome = "rejected"
        service.clarify("reject-clarify", generation: 9, choices: ["one", "two"])
        try await ModelTests.eventually { model.pendingClarify?.requestID == "reject-clarify" }
        guard let clarify = model.pendingClarify else { preconditionFailure("missing clarify") }
        await model.respondToClarify("one", requestID: clarify.id, expected: clarify)
        precondition(model.pendingClarifies.contains(clarify) && model.error != nil)
        model.removePendingClarify(requestID: clarify.requestID, runID: clarify.runID, generation: 8)
        precondition(model.pendingClarifies.contains(clarify), "old generation cannot resolve current clarify")
        model.removePendingClarify(requestID: clarify.requestID, runID: "wrong-run", generation: 9)
        precondition(model.pendingClarifies.contains(clarify), "foreign Run cannot resolve clarify")
        model.disconnect()
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
        precondition(service.approvalCalls.count == 1
                     && service.approvalCalls[0].0 == "old"
                     && service.approvalCalls[0].1 == 7
                     && service.approvalCalls[0].2 == "once",
                     "approval POST carries the chosen prompt identity and generation")
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
        service.holdApproval = false
        await model.respondToApproval("once")
        precondition(service.approvalCalls.isEmpty,
                     "an implicit approval cannot pick between multiple requests")
        service.frames.append(SSEFrame(event: "approval_resolved",
                                       data: "{\"request_id\":\"a1\"}", id: "a1-resolved"))
        service.frames.append(SSEFrame(event: "token", data: "{\"text\":\"seen\"}", id: "a1-seen"))
        try await ModelTests.eventually { model.transcript.lastEventID == "a1-seen" }
        precondition(model.pendingApprovals.map(\.requestID) == ["a2"],
                     "resolving one approval must preserve sibling requests")
        precondition(!model.canRespondToApproval(requestID: "missing", choice: "once"),
                     "a missing request ID must never fall back to another approval")
        await model.respondToApproval("once", requestID: "a1")
        precondition(service.approvalCalls.isEmpty &&
                     model.pendingApprovals.map(\.id) == ["a2"],
                     "a stale card tap must not approve its surviving sibling")
        let staleApproval = model.pendingApprovals[0]
        let replacementApproval = ChatPendingApproval(id: staleApproval.id, runID: staleApproval.runID,
            requestID: staleApproval.requestID, executionGeneration: staleApproval.executionGeneration + 1,
            detail: staleApproval.detail, command: staleApproval.command, choices: staleApproval.choices)
        model.pendingApprovals = [replacementApproval]
        await model.respondToApproval("once", requestID: staleApproval.id, expected: staleApproval)
        precondition(service.approvalCalls.isEmpty && model.pendingApprovals == [replacementApproval],
                     "same-ID newer approval cannot receive an old card's decision")
        let old = ChatPendingApproval(id: "old", runID: "old-run", requestID: "old",
                                      executionGeneration: 3,
                                      detail: "", command: nil, choices: ["once"])
        let current = ChatPendingApproval(id: "current", runID: "current-run",
                                          requestID: "current", executionGeneration: 4, detail: "",
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
        let callsBeforeAmbiguousAnswer = service.clarifyCalls.count
        await model.respondToClarify("ambiguous")
        precondition(service.clarifyCalls.count == callsBeforeAmbiguousAnswer,
                     "an implicit clarification cannot pick between multiple requests")
        await model.respondToClarify("answer q1", requestID: "q1")
        precondition(service.clarifyCalls.last?.0 == "q1"
                     && model.pendingClarifies.map(\.requestID) == ["q2"],
                     "answering one clarify must remove only that request")
        precondition(!model.canRespondToClarify(requestID: "missing"),
                     "a missing request ID must never fall back to another clarify")
        let callsBeforeStaleAnswer = service.clarifyCalls.count
        await model.respondToClarify("stale answer", requestID: "q1")
        precondition(service.clarifyCalls.count == callsBeforeStaleAnswer &&
                     model.pendingClarifies.map(\.id) == ["q2"],
                     "a stale card tap must not answer the surviving question")
        let oldQuestion = model.pendingClarifies[0]
        let newQuestion = ChatPendingClarify(id: oldQuestion.id, runID: oldQuestion.runID,
            requestID: oldQuestion.requestID, executionGeneration: 13,
            question: oldQuestion.question, choices: oldQuestion.choices, multiSelect: oldQuestion.multiSelect)
        model.pendingClarifies = [newQuestion]
        await model.respondToClarify("stale answer", requestID: oldQuestion.id, expected: oldQuestion)
        precondition(service.clarifyCalls.count == callsBeforeStaleAnswer && model.pendingClarify?.executionGeneration == 13,
                     "same-ID newer clarification cannot receive an old card's answer")
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
        precondition(!model.canSend,
                     "P0: unresolved completion must keep direct sending disabled")
        precondition(model.queueRecoveryPaused && model.queueAutomaticDispatchPaused,
                     "the unresolved run must retain the actual queue pause, independent of notice ownership")
        precondition(model.activity == .needsVerification && (model.presentationState.showsNotice || model.presentationState.showsProgress),
                     "unresolved completion must remain visible even if the exact receipt probe replaces the notice")
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

    // Identical payloads do not imply identical local send transactions.
    do {
        let model = NativeChatModel(sessionID: "queue-transaction-id", api: SendSafetyService())
        let turn = ChatQueuedTurn(id: "queue-id", text: "same", attachments: [],
            composerText: "same", origin: .userInput, automaticAfterStreamID: nil,
            delivery: .uncertain, historyEnd: 1, knownIDs: ["old"], submittedAt: 1)
        model.setQueuedTurns([turn])
        var manual = NativeChatModel.PendingSend(id: "local-manual", text: "same",
            attachments: [], composerText: "same", historyEnd: 1, knownIDs: ["old"],
            createdAt: 1, origin: .userInput)
        precondition(model.acknowledgeDeliveredQueuedTurn(matching: manual))
        precondition(model.queuedTurns == [turn], "manual receipt cannot consume an identical queue row")
        manual.queuedTurnID = "another-queue"
        precondition(model.acknowledgeDeliveredQueuedTurn(matching: manual) && model.queuedTurns == [turn])
        manual.queuedTurnID = turn.id
        let decoded = try JSONDecoder().decode(NativeChatModel.PendingSend.self, from: JSONEncoder().encode(manual))
        precondition(decoded.queuedTurnID == turn.id)
        precondition(model.acknowledgeDeliveredQueuedTurn(matching: decoded) && model.queuedTurns.isEmpty)
        model.disconnect()
    }

    // An accepted Run only owns the pending and queue transaction named in
    // its persisted receipt, never another identical user message.
    do {
        let service = SendSafetyService()
        let model = NativeChatModel(sessionID: "receipt-ownership", api: service)
        let queued = ChatQueuedTurn(id: "receipt-queue", text: "same", attachments: [],
            composerText: "same", origin: .userInput, automaticAfterStreamID: nil,
            delivery: .uncertain, historyEnd: 0, knownIDs: [], submittedAt: 1)
        model.setQueuedTurns([queued])
        model.pendingSend = NativeChatModel.PendingSend(id: "unrelated", text: "same",
            attachments: [], composerText: "same", historyEnd: 0, knownIDs: [],
            createdAt: 1, origin: .userInput)
        let receipt = ActiveTurnRecovery(runID: "accepted", historyEnd: 0, knownIDs: [],
            text: "same", attachmentPaths: [], pendingSendID: "earlier", queuedTurnID: queued.id)
        model.activeTurnRecovery = receipt
        precondition(model.settleAcceptedReceipt(receipt))
        precondition(model.pendingSend?.id == "unrelated" && model.queuedTurns.isEmpty)
        precondition(model.clearPendingSend(expectedID: "earlier") == false)
        model.disconnect()
    }

    // A stale accepted receipt with the same queue identity but another
    // dispatch key must not remove a newer attempt or its pending record.
    do {
        let model = NativeChatModel(sessionID: "keyed-ownership", api: SendSafetyService())
        let key = RunSubmissionIdentity.make()
        let other = RunSubmissionIdentity.make()
        let queued = ChatQueuedTurn(id: "same-queue", text: "same", attachments: [],
            composerText: "same", origin: .userInput, automaticAfterStreamID: nil,
            delivery: .uncertain, historyEnd: 0, knownIDs: [], submittedAt: 1,
            submissionKey: key)
        model.setQueuedTurns([queued])
        model.pendingSend = NativeChatModel.PendingSend(id: "same-pending", text: "same",
            attachments: [], composerText: "same", historyEnd: 0, knownIDs: [],
            createdAt: 1, origin: .userInput, queuedTurnID: queued.id, submissionKey: key)
        var receipt = ActiveTurnRecovery(runID: "run", historyEnd: 0, knownIDs: [],
            text: "same", attachmentPaths: [], pendingSendID: "same-pending",
            queuedTurnID: queued.id, submissionKey: other)
        model.activeTurnRecovery = receipt
        precondition(!model.settleAcceptedReceipt(receipt) && model.queuedTurns == [queued] &&
                     model.pendingSend?.submissionKey == key)
        receipt.submissionKey = key
        model.activeTurnRecovery = receipt
        precondition(model.settleAcceptedReceipt(receipt) && model.queuedTurns.isEmpty && model.pendingSend == nil)
        model.disconnect()
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

    // Cold recovery rebuilds approval and clarification cards only from a
    // complete, exact-Run Gateway snapshot. Missing capability preserves known
    // cards; an explicit empty set removes them; malformed state keeps sending locked.
    do {
        let service = SendSafetyService()
        service.active = "run-1"
        service.pendingControlSnapshot = GatewayPendingControlSnapshot(
            frames: [
                SSEFrame(event: "approval", data:
                    #"{"request_id":"approval-1","execution_generation":7,"message":"Run command","choices":["once","deny"]}"#,
                    id: nil),
                SSEFrame(event: "clarify", data:
                    #"{"request_id":"clarify-1","execution_generation":7,"question":"Choose a target","choices":["A","B"],"multi_select":false}"#,
                    id: nil)
            ],
            hasIncompleteControl: false)
        let model = NativeChatModel(sessionID: "control-snapshot-restore", api: service)
        await model.load()
        precondition(model.pendingApprovals.count == 1
                     && model.pendingApprovals.first?.runID == "run-1"
                     && model.pendingApprovals.first?.requestID == "approval-1",
                     "cold snapshot restores the approval card for the exact Run")
        precondition(model.pendingClarifies.count == 1
                     && model.pendingClarifies.first?.runID == "run-1"
                     && model.pendingClarifies.first?.requestID == "clarify-1"
                     && model.pendingClarifies.first?.executionGeneration == 7,
                     "cold snapshot restores the clarification card with generation")

        func snapshot(_ controls: GatewayPendingControlSnapshot?) throws -> ChatSnapshot {
            let object: [String: Any] = [
                "session_id": "control-snapshot-restore",
                "active_stream_id": "run-1",
                "messages": [],
                "read_only": false
            ]
            return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: object),
                                    gatewayPendingControls: controls)
        }
        let unknownObject: [String: Any] = [
            "session_id": "control-snapshot-restore", "messages": [], "read_only": false
        ]
        let unknownSnapshot = try ChatSnapshot(
            data: JSONSerialization.data(withJSONObject: unknownObject), runStatusUnknown: true)
        try model.applySnapshot(unknownSnapshot)
        precondition(model.pendingApprovals.count == 1 && model.pendingClarifies.count == 1,
                     "unknown Run status preserves known approval and clarification cards")

        // Older Gateways omit the field; absence is not evidence that a known
        // approval/clarification has been resolved.
        try model.applySnapshot(try snapshot(nil))
        precondition(model.pendingApprovals.count == 1 && model.pendingClarifies.count == 1,
                     "missing Gateway capability preserves known pending cards")

        try model.applySnapshot(try snapshot(GatewayPendingControlSnapshot(
            frames: [], hasIncompleteControl: false)))
        precondition(model.pendingApprovals.isEmpty && model.pendingClarifies.isEmpty,
                     "an authoritative empty pending_controls list removes stale cards")

        let preserved = GatewayPendingControlSnapshot(
            frames: [SSEFrame(event: "clarify", data:
                #"{"request_id":"partial-new","execution_generation":8,"question":"Still waiting"}"#,
                id: nil)],
            hasIncompleteControl: true)
        // A new valid prompt in an incomplete status snapshot must not silently
        // revoke a previously known prompt.
        try model.applySnapshot(try snapshot(service.pendingControlSnapshot))
        precondition(model.pendingApprovals.count == 1 && model.pendingClarifies.count == 1,
                     "complete control projection re-establishes canonical cards")
        try model.applySnapshot(try snapshot(preserved))
        precondition(model.pendingApprovals.count == 1
                     && model.pendingClarifies.count == 2
                     && model.uncertain && model.queueRecoveryPaused,
                     "partial projection preserves existing prompts and locks sending")

        try model.applySnapshot(try snapshot(GatewayPendingControlSnapshot(
            frames: [], hasIncompleteControl: true)))
        precondition(model.uncertain && model.queueRecoveryPaused
                     && model.notice?.contains("暂时未能完整加载") == true,
                     "incomplete control data fails closed and preserves the send lock")
        model.disconnect()
    }

    print("SEND_SAFETY_PASS complete queue payload, no overwrite, persistence, steer lock, interrupt verification, cancellation, approval identity and clarify reply contract")
}
