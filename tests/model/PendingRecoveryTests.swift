import Foundation

private final class AtomicReadBackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor final class PendingRecoveryService: NativeChatService {
    var rows: [[String: Any]] = [["id": "old", "role": "user", "content": "same"]]
    var offset = 0
    /// Simulate the backend's 60-raw-record history window.
    var historyPageLimit: Int?
    var historyPageCalls = 0
    var historyCalls = 0
    var appendHeadOnOlderPage = false
    var failOlderPageOnce = false
    var active: String?
    var statusUnknown = false
    var unavailableRunID: String?
    var allowUserRelease = false
    var userReleaseCalls = 0
    var readOnly = false
    var failHistory = false
    var failHistoryAfterProbe = false
    var rowsAfterProbe: [[String: Any]]?
    var failStart = true
    var carriesRunSubmissionIdentity = false
    var receivedKeys: [String?] = []
    var beforeStart: (() -> Void)?
    var historyWait: CheckedContinuation<ChatSnapshot, Error>?
    var holdHistory = false
    var startCalls = 0
    var sent: [(String, [ChatAttachmentPayload])] = []
    var probeResults: [ActiveRunProbe] = [.unknown]
    var probeCalls = 0
    var streamCursors: [String?] = []

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        if failHistory { throw URLError(.notConnectedToInternet) }
        var visibleRows = rows
        var pageOffset = offset
        if let limit = historyPageLimit {
            let upper = min(before ?? (offset + rows.count), offset + rows.count)
            let lower = max(offset, upper - limit)
            visibleRows = Array(rows[(lower - offset)..<(upper - offset)])
            pageOffset = lower
            if before != nil {
                historyPageCalls += 1
                if failOlderPageOnce {
                    failOlderPageOnce = false
                    throw URLError(.networkConnectionLost)
                }
                // Simulates a concurrent append during history lookback.
                if appendHeadOnOlderPage {
                    appendHeadOnOlderPage = false
                    rows.append(["id": "concurrent", "role": "assistant", "content": "other reply"])
                }
            }
        }
        let snapshot = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
            "session_id": sessionID, "messages": visibleRows, "_messages_offset": pageOffset,
            "read_only": readOnly, "active_stream_id": active as Any? ?? NSNull()
        ]), runStatusUnknown: statusUnknown, unavailableRunID: unavailableRunID)
        if holdHistory { return try await withCheckedThrowingContinuation { historyWait = $0 } }
        return snapshot
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        try await startNativeTurn(sessionID: sessionID, text: text, attachments: [])
    }
    func releaseMissingRunAfterUserConfirmation(sessionID: String, runID: String) async throws -> Bool {
        userReleaseCalls += 1
        guard allowUserRelease, sessionID == "test", runID == unavailableRunID,
              active == nil else { return false }
        statusUnknown = false
        unavailableRunID = nil
        return true
    }
    func probeActiveRun(sessionID: String, runID: String) async throws -> ActiveRunProbe {
        probeCalls += 1
        if failHistoryAfterProbe { failHistory = true }
        if let rowsAfterProbe { rows = rowsAfterProbe }
        return probeResults.count > 1 ? probeResults.removeFirst() : (probeResults.first ?? .unknown)
    }
    func startNativeTurn(sessionID: String, text: String, attachments: [ChatAttachmentPayload]) async throws -> String {
        startCalls += 1
        sent.append((text, attachments))
        if failStart { throw URLError(.networkConnectionLost) }
        active = "accepted"
        return "accepted"
    }
    func startNativeTurn(sessionID: String, text: String, attachments: [ChatAttachmentPayload],
                         reasoningEffort: String?, submissionKey: String?) async throws -> String {
        receivedKeys.append(submissionKey)
        beforeStart?()
        return try await startNativeTurn(sessionID: sessionID, text: text, attachments: attachments)
    }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
        streamCursors.append(lastEventID)
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
    func stopNativeTurn(streamID: String) async throws { active = nil }
}

extension ModelTests {
    @MainActor static func pendingRecoveryTests() async throws {
        // A failed POST must not lose the durable snapshot during a second
        // atomic write. Linux Foundation's replaceItemAt used to unlink it.
        let probeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-atomic-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: probeRoot) }
        let probe = LocalDataFileStore(instanceID: "probe", accountScope: "account",
                                       sessionID: "session", rootDirectory: probeRoot)
        let first = Data("first-pending".utf8)
        let second = Data("replaced-pending".utf8)
        precondition(probe.savePending(first).succeeded)
        precondition(probe.loadPending().value == first)
        precondition(probe.savePending(second).succeeded)
        precondition(probe.loadPending().value == second,
                     "repeat pending writes must remain durable and readable")
        print("LOCAL_STORE_REPLACE_PASS")

        // Force the post-replacement read-back to fail. The previous committed
        // envelope must be restored, not deleted together with the new value.
        let rollbackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-atomic-rollback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rollbackRoot) }
        let readBackCounter = AtomicReadBackCounter()
        let rollbackStore = LocalDataFileStore(
            instanceID: "rollback", accountScope: "account", sessionID: "session",
            rootDirectory: rollbackRoot,
            destinationReadBackVerifier: { url, _ in
                !url.lastPathComponent.hasPrefix("pending-") || readBackCounter.next() != 2
            })
        precondition(rollbackStore.savePending(first).succeeded)
        precondition(rollbackStore.savePending(second).failure
            == LocalStoreWriteFailure.diskWrite)
        precondition(rollbackStore.loadPending().value == first,
                     "failed post-replacement read-back must roll back the old durable value")
        print("LOCAL_STORE_ROLLBACK_PASS")

        // Cold-process recovery must restore a cursor AND its matching
        // accumulator, then attach the same Run without creating another POST.
        let checkpointFiles = LocalDataFileStore(instanceID: "checkpoint", accountScope: "account",
            sessionID: "test", rootDirectory: probeRoot)
        let checkpointStore = ChatDraftStore(instanceID: "checkpoint", accountScope: "account",
            sessionID: "test", fileStore: checkpointFiles)
        let checkpointReceipt = ActiveTurnRecovery(runID: "checkpoint-run", historyEnd: 0,
            knownIDs: [], text: "accepted question", attachmentPaths: [])
        var checkpointProjection = ChatTranscript()
        checkpointProjection.messages = [ChatMessage(id: "local-user", role: "user",
            content: checkpointReceipt.text, delivery: .accepted)]
        try checkpointProjection.apply(SSEFrame(event: "token", data: #"{"text":"partial answer"}"#, id: "cursor-1"))
        let checkpoint = RunRecoveryCheckpoint(version: 1, scope: "checkpoint|account",
            sessionID: "test", receipt: checkpointReceipt, historyEnd: 0, olderOffset: 0,
            cursor: "cursor-1", projection: checkpointProjection, approvals: [], clarifies: [])
        precondition(!checkpointProjection.exceedsCheckpointPayloadBudget(LocalDataFileStore.maxCheckpointBytes))
        var oversizedProjection = checkpointProjection
        oversizedProjection.reasoning = String(repeating: "a", count: LocalDataFileStore.maxCheckpointBytes + 1)
        precondition(oversizedProjection.exceedsCheckpointPayloadBudget(LocalDataFileStore.maxCheckpointBytes))
        let checkpointData = try JSONEncoder().encode(checkpoint)
        let checkpointReceiptData = try JSONEncoder().encode(checkpointReceipt)
        precondition(checkpointStore.saveActiveRun(checkpointReceiptData).succeeded)
        precondition(checkpointStore.saveCheckpoint(checkpointData).succeeded)
        precondition(checkpointStore.saveCheckpoint(Data(repeating: 1,
            count: LocalDataFileStore.maxCheckpointBytes + 1)).failure == .payloadTooLarge)
        precondition(checkpointStore.loadCheckpoint().value == checkpointData,
            "an oversized update cannot destroy the previous complete replay point")
        let checkpointService = PendingRecoveryService()
        checkpointService.rows = [["id": "canonical-user", "role": "user", "content": checkpointReceipt.text]]
        checkpointService.active = checkpointReceipt.runID
        let checkpointModel = NativeChatModel(sessionID: "test", api: checkpointService,
            draftStore: checkpointStore, displayScope: "checkpoint|account")
        await checkpointModel.load()
        try await eventually { !checkpointService.streamCursors.isEmpty }
        precondition(checkpointService.streamCursors == ["cursor-1"] && checkpointService.startCalls == 0)
        precondition(checkpointModel.buffer.messages.map(\.id).first == "canonical-user")
        precondition(checkpointModel.buffer.messages.last?.content == "partial answer")
        precondition(!checkpointModel.canSend)
        // Replayed event is ignored; a fresh event extends exactly one bubble.
        try checkpointModel.buffer.apply(SSEFrame(event: "token", data: #"{"text":"partial answer"}"#, id: "cursor-1"))
        try checkpointModel.buffer.apply(SSEFrame(event: "token", data: #"{"text":" continued"}"#, id: "cursor-2"))
        precondition(checkpointModel.buffer.messages.last?.content == "partial answer continued")
        checkpointModel.lastEventID = "cursor-2"
        checkpointModel.recoveryCheckpointRead = false
        let currentSnapshot = try await checkpointService.history(sessionID: "test", before: nil)
        checkpointModel.restoreRecoveryCheckpoint(from: currentSnapshot)
        precondition(checkpointModel.lastEventID == "cursor-2" &&
            checkpointModel.buffer.messages.last?.content == "partial answer continued",
            "disk restore must not regress a live in-memory cursor")
        precondition(checkpoint.resumeProjection(scope: "other|account", sessionID: "test",
            receipt: checkpointReceipt, snapshot: currentSnapshot) == nil)
        precondition(checkpoint.resumeProjection(scope: "checkpoint|account", sessionID: "test",
            receipt: ActiveTurnRecovery(runID: "other-run", historyEnd: 0, knownIDs: [],
                text: checkpointReceipt.text, attachmentPaths: []), snapshot: currentSnapshot) == nil)
        // Routine encoding commits a complete immutable projection. A forced
        // boundary then takes precedence over an older queued routine encode.
        checkpointModel.persistRecoveryCheckpoint()
        try await eventually {
            guard let data = checkpointStore.loadCheckpoint().value,
                  let saved = try? JSONDecoder().decode(RunRecoveryCheckpoint.self, from: data) else { return false }
            return saved.cursor == "cursor-2"
        }
        checkpointModel.lastCheckpointWrite = -.infinity
        checkpointModel.persistRecoveryCheckpoint()
        try checkpointModel.buffer.apply(SSEFrame(event: "token", data: #"{"text":" final"}"#, id: "cursor-3"))
        checkpointModel.lastEventID = "cursor-3"
        checkpointModel.persistRecoveryCheckpoint(force: true)
        guard let forcedData = checkpointStore.loadCheckpoint().value else {
            preconditionFailure("forced checkpoint missing")
        }
        let forced = try JSONDecoder().decode(RunRecoveryCheckpoint.self, from: forcedData)
        precondition(forced.cursor == "cursor-3" && forced.projection.canResume(at: "cursor-3"))
        await Task.yield()
        precondition(checkpointStore.loadCheckpoint().value == forcedData,
                     "an older asynchronous projection cannot overwrite a forced checkpoint")
        checkpointModel.disconnect()
        print("CHECKPOINT_PASS atomic scoped cold resume, replay deduplication, oversized fallback, live cursor and encoder fences")

        let attachment = ChatAttachmentPayload(name: "scan.pdf", path: "/attachments/new.pdf",
                                             mime: "application/pdf", size: 48, isImage: false)
        // A direct POST survives process loss with attachment refs and no automatic replay.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalDataFileStore(instanceID: "test", accountScope: "account", sessionID: "test", rootDirectory: root)
        let durable = ChatDraftStore(instanceID: "test", accountScope: "account", sessionID: "test", fileStore: files)
        let originalService = PendingRecoveryService()
        let original = NativeChatModel(sessionID: "test", api: originalService, draftStore: durable)
        await original.load()
        original.draft = "durable"
        await original.send(attachments: [attachment])
        precondition(durable.loadPending().value != nil)
        original.disconnect()
        let restoredService = PendingRecoveryService()
        let restored = NativeChatModel(sessionID: "test", api: restoredService, draftStore: durable)
        precondition(restored.hasPendingSend && !restored.canSend)
        precondition(restored.pendingSend?.attachments == [attachment])
        precondition(restoredService.startCalls == 0)
        let restoredResult = await restored.reconcilePending()
        precondition(restoredResult == .absent && restoredService.startCalls == 0)
        restoredService.rows.append(["id": "delivered", "role": "user", "content": "durable",
            "attachments": [["path": attachment.path]]])
        let resolvedResult = await restored.reconcilePending()
        precondition(resolvedResult == .delivered && durable.loadPending().value == nil)
        restored.disconnect()
        print("PENDING_PASS durable direct POST survives restart and resolves without replay")

        // Keyed admission can be accepted before a user row is written.
        // A lost response plus empty history is not authority to retry.
        do {
            let keyedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: keyedRoot) }
            let keyedFiles = LocalDataFileStore(instanceID: "keyed", accountScope: "account",
                sessionID: "test", rootDirectory: keyedRoot)
            let keyedStore = ChatDraftStore(instanceID: "keyed", accountScope: "account",
                sessionID: "test", fileStore: keyedFiles)
            let service = PendingRecoveryService()
            service.carriesRunSubmissionIdentity = true
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: keyedStore)
            await model.load()
            service.beforeStart = {
                let stored = try! JSONDecoder().decode(NativeChatModel.PendingSend.self,
                    from: keyedStore.loadPending().value!)
                precondition(stored.submissionKey == service.receivedKeys.last! &&
                             RunSubmissionIdentity.valid(stored.submissionKey!),
                             "the same key must be on disk before network transport")
            }
            model.draft = "keyed submission"
            _ = await model.send()
            precondition(service.startCalls == 1 && model.pendingSend?.submissionKey != nil)
            let key = model.pendingSend?.submissionKey
            model.disconnect()
            service.beforeStart = nil
            let restored = NativeChatModel(sessionID: "test", api: service, draftStore: keyedStore)
            precondition(restored.pendingSend?.submissionKey == key)
            let missing = await restored.reconcilePending()
            precondition(missing == .failed && !restored.canSend && !restored.canResendPending &&
                         service.startCalls == 1,
                         "missing history cannot authorize replay of a keyed admission")
            let retried = await restored.resendPending()
            precondition(!retried && service.startCalls == 1)
            restored.disconnect()
        }
        print("PENDING_PASS durable submission key before transport, restart, no replay on absence")

        // Targeted failure injection at both sides of the admission boundary.
        // Reject the protected file read-back, not the whole storage root.
        for failingPrefix in ["pending-", "active-run-"] {
            let faultRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: faultRoot) }
            let faultFiles = LocalDataFileStore(instanceID: "keyed-fault", accountScope: "account",
                sessionID: "test", rootDirectory: faultRoot,
                destinationReadBackVerifier: { url, data in
                    !url.lastPathComponent.hasPrefix(failingPrefix) &&
                        (try? Data(contentsOf: url)) == data
                })
            let faultStore = ChatDraftStore(instanceID: "keyed-fault", accountScope: "account",
                sessionID: "test", fileStore: faultFiles)
            let service = PendingRecoveryService()
            service.carriesRunSubmissionIdentity = true
            service.failStart = false
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: faultStore)
            await model.load()
            model.draft = "keep this draft"
            _ = await model.send()
            if failingPrefix == "pending-" {
                precondition(service.startCalls == 0 && model.pendingSend != nil &&
                             model.draft == "keep this draft" && !model.canSend,
                             "failed pre-POST commit cannot send")
            } else {
                precondition(service.startCalls == 1 && faultStore.loadPending().value != nil &&
                             model.activeTurnRecovery == nil && !model.canSend,
                             "failed post-acceptance receipt must preserve the original pending proof")
                let saved = try JSONDecoder().decode(NativeChatModel.PendingSend.self,
                    from: faultStore.loadPending().value!)
                precondition(saved.submissionKey == service.receivedKeys.last!)
                model.disconnect()
                let reopened = NativeChatModel(sessionID: "test", api: service, draftStore: faultStore)
                precondition(reopened.pendingSend?.submissionKey == saved.submissionKey && !reopened.canSend)
                precondition(service.startCalls == 1)
                reopened.disconnect()
            }
            model.disconnect()
        }
        print("PENDING_PASS pre-POST write and post-acceptance receipt fault injection")

        // Fail queue retirement after the accepted Run has committed.
        // The original durable queue and pending identities must survive.
        do {
            let queueRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: queueRoot) }
            let writes = AtomicReadBackCounter()
            let queueFiles = LocalDataFileStore(instanceID: "queue-fault", accountScope: "account",
                sessionID: "test", rootDirectory: queueRoot,
                destinationReadBackVerifier: { url, data in
                    if url.lastPathComponent.hasPrefix("queue-"), writes.next() >= 3 { return false }
                    return (try? Data(contentsOf: url)) == data
                })
            let queueStore = ChatDraftStore(instanceID: "queue-fault", accountScope: "account",
                sessionID: "test", fileStore: queueFiles)
            let service = PendingRecoveryService()
            service.carriesRunSubmissionIdentity = true
            service.failStart = false
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: queueStore)
            await model.load()
            // Keep a sibling so retirement requires an atomic replacement
            // instead of a deletion, which uses a different storage path.
            model.setQueuedTurns([
                ChatQueuedTurn(id: "first", text: "first", attachments: [], composerText: "first",
                    origin: .userInput, automaticAfterStreamID: nil),
                ChatQueuedTurn(id: "sibling", text: "sibling", attachments: [], composerText: "sibling",
                    origin: .userInput, automaticAfterStreamID: nil)
            ])
            _ = await model.flushQueuedIfNeeded()
            precondition(service.startCalls == 1 && model.queuedTurns.count == 2 &&
                         model.pendingSend != nil && model.activeTurnRecovery != nil &&
                         model.queueAutomaticDispatchPaused,
                         "failed queue retirement preserves all protected transaction evidence")
            let durableQueue = ChatSendQueueCodec.decode(queueStore.loadQueuedResult().value!)!
            let pending = try JSONDecoder().decode(NativeChatModel.PendingSend.self, from: queueStore.loadPending().value!)
            let receipt = try JSONDecoder().decode(ActiveTurnRecovery.self, from: queueStore.loadActiveRun().value!)
            precondition(durableQueue.first?.submissionKey == pending.submissionKey &&
                         receipt.submissionKey == pending.submissionKey)
            model.disconnect()
            let repairedFiles = LocalDataFileStore(instanceID: "queue-fault", accountScope: "account",
                sessionID: "test", rootDirectory: queueRoot)
            let repairedStore = ChatDraftStore(instanceID: "queue-fault", accountScope: "account",
                sessionID: "test", fileStore: repairedFiles)
            let restored = NativeChatModel(sessionID: "test", api: service, draftStore: repairedStore)
            await restored.load()
            precondition(restored.queuedTurns.map(\.id) == ["sibling"] &&
                         restored.pendingSend == nil && service.startCalls == 1,
                         "relaunch retires only the original accepted row, without sending the sibling")
            restored.disconnect()
        }
        print("PENDING_PASS queue retirement fault and restart settlement without replay")
        // Corrupt pending data must not become sendable after a successful history GET.
        _ = durable.savePending(Data("invalid pending".utf8))
        let corrupt = NativeChatModel(sessionID: "test", api: PendingRecoveryService(), draftStore: durable)
        await corrupt.load()
        precondition(corrupt.pendingRecoveryUnreadable && !corrupt.canSend)
        precondition(!corrupt.validateLocalData().succeeded)
        precondition(!corrupt.retryQueuePersistence().succeeded)
        corrupt.abandonUnreadablePending()
        await corrupt.load()
        precondition(!corrupt.pendingRecoveryUnreadable && corrupt.canSend)
        corrupt.disconnect()
        // An identical OLD user message is never proof that THIS POST arrived.
        let oldService = PendingRecoveryService()
        let old = NativeChatModel(sessionID: "test", api: oldService)
        await old.load()
        old.draft = "same"
        await old.send(attachments: [attachment])
        precondition(old.transcript.messages.last?.attachmentPaths == [attachment.path])
        old.draft = "new draft"
        let absent = await old.reconcilePending()
        precondition(absent == .absent && old.canResendPending && !old.canSend)
        precondition(old.transcript.messages.filter { $0.delivery == .unconfirmed }.count == 1)
        precondition(old.draft == "new draft" && oldService.startCalls == 1)
        oldService.failStart = false
        let resent = await old.resendPending()
        precondition(resent && oldService.startCalls == 2)
        precondition(oldService.sent.last?.0 == "same" && oldService.sent.last?.1 == [attachment])
        precondition(old.draft == "new draft" && old.settledAttachmentPaths == [attachment.path])
        old.disconnect()
        print("PENDING_PASS old identical text excluded; explicit retry preserves newer draft and original attachments")

        // Accepted POST, lost response, then a GET with the canonical new row.
        let acceptedService = PendingRecoveryService()
        let accepted = NativeChatModel(sessionID: "test", api: acceptedService)
        await accepted.load()
        accepted.draft = "same"
        await accepted.send(attachments: [attachment])
        acceptedService.rows.append(["id": "new", "role": "user", "content": "same",
                                    "attachments": [["path": attachment.path]]])
        let delivered = await accepted.reconcilePending()
        precondition(delivered == .delivered && acceptedService.startCalls == 1)
        precondition(accepted.transcript.messages.map(\.id) == ["old", "new"])
        precondition(accepted.canSend && !accepted.canResendPending && accepted.draft.isEmpty)
        precondition(accepted.settledAttachmentPaths == [attachment.path])
        accepted.disconnect()
        print("PENDING_PASS lost response reconciles new authoritative row with no POST replay or duplicate bubble")

        // build224: the accepted user row is hidden behind >145 tool rows.
        let deepService = PendingRecoveryService()
        deepService.historyPageLimit = 60
        let deep = NativeChatModel(sessionID: "test", api: deepService)
        await deep.load()
        deep.draft = "deep message"
        await deep.send()
        deepService.rows.append(["id": "deep-user", "role": "user",
                                 "content": "deep message"])
        deepService.rows += (0..<145).map { n in
            ["id": "deep-tool-\(n)", "role": "tool", "content": "done",
             "tool_call_id": "deep-tool-\(n)"]
        }
        deepService.rows.append(["id": "deep-reply", "role": "assistant",
                                 "content": "finished"])
        let deepResult = await deep.reconcilePending()
        precondition(deepResult == .delivered && deepService.historyPageCalls >= 2
                     && deepService.startCalls == 1 && deep.pendingSend == nil,
                     "long pending send needs contiguous read-only pages, never replay")
        deep.disconnect()
        print("PENDING_PASS pending message confirmed across 145 tool rows")

        let hiddenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesHiddenPending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: hiddenRoot) }
        let hiddenStore = ChatDraftStore(instanceID: "hidden", accountScope: "account",
            sessionID: "test", fileStore: LocalDataFileStore(
                instanceID: "hidden", accountScope: "account",
                sessionID: "test", rootDirectory: hiddenRoot))
        let hiddenService = PendingRecoveryService()
        let hidden = NativeChatModel(sessionID: "test", api: hiddenService,
                                     draftStore: hiddenStore)
        await hidden.load()
        hidden.draft = "hidden unresolved"
        await hidden.send()
        hidden.discardPending()
        precondition(hidden.pendingSend?.hiddenFromTranscript == true
                     && hidden.uncertain && !hidden.canSend
                     && hiddenService.startCalls == 1,
                     "discard must preserve unverified delivery evidence")
        hidden.disconnect()
        let hiddenRestart = NativeChatModel(sessionID: "test",
            api: PendingRecoveryService(), draftStore: hiddenStore)
        precondition(hiddenRestart.pendingSend?.hiddenFromTranscript == true
                     && hiddenRestart.buffer.messages.isEmpty && !hiddenRestart.canSend,
                     "cold restart preserves the hidden disposition and send lock")
        await hiddenRestart.refresh()
        precondition(hiddenRestart.pendingSend == nil && !hiddenRestart.uncertain,
                     "verified absence retires hidden record without resending")
        hiddenRestart.disconnect()

        // Two new identical user rows after the POST boundary may come from
        // concurrent clients. No receipt exists to attribute either one.
        let collidingService = PendingRecoveryService()
        let colliding = NativeChatModel(sessionID: "test", api: collidingService)
        await colliding.load()
        colliding.draft = "same"
        await colliding.send()
        collidingService.rows.append(["id": "other-client", "role": "user", "content": "same"])
        collidingService.rows.append(["id": "possible-echo", "role": "user", "content": "same"])
        let ambiguous = await colliding.reconcilePending()
        precondition(ambiguous == .failed && colliding.uncertain && !colliding.canSend,
                     "multiple identical new rows cannot prove which POST was accepted")
        colliding.disconnect()

        // Same attachment-only text is insufficient if the actual file differs.
        for mode in ["missing-ref", "active", "truncated", "history-failed", "read-only", "changed-history"] {
            let service = PendingRecoveryService()
            let model = NativeChatModel(sessionID: "test", api: service)
            await model.load()
            await model.send(attachments: [attachment])
            switch mode {
            case "missing-ref":
                service.rows.append(["id": "new", "role": "user", "content": "（仅附件）",
                                     "attachments": [["path": "/attachments/different.pdf"]]])
            case "active": service.active = "still-working"
            case "truncated": service.offset = 40
            case "history-failed": service.failHistory = true
            case "read-only": service.readOnly = true
            default: service.rows = []
            }
            let result = await model.reconcilePending()
            precondition(result == .failed && model.uncertain && !model.canSend && !model.canResendPending, mode)
            precondition(model.transcript.messages.contains { $0.delivery == .unconfirmed }, mode)
            let retry = await model.resendPending()
            precondition(!retry && service.startCalls == 1 && model.settledAttachmentPaths.isEmpty, mode)
            model.disconnect()
        }
        print("PENDING_PASS ambiguous attachment, active run, partial/changed history and failed GET keep retry locked")

        // A silent foreground refresh must retain the pending bubble, too.
        let foregroundService = PendingRecoveryService()
        let foreground = NativeChatModel(sessionID: "test", api: foregroundService)
        await foreground.load()
        foreground.draft = "same"
        await foreground.send()
        foreground.disconnect()
        await foreground.resumeForeground()
        precondition(foreground.canResendPending && !foreground.canSend)
        precondition(foreground.transcript.messages.last?.delivery == .unconfirmed)
        foreground.discardPending()
        precondition(foreground.canSend && foreground.draft == "same")
        foreground.disconnect()
        print("PENDING_PASS foreground resume retains pending controls; explicit discard preserves original draft")

        // Accepted POST -> durable active-run receipt -> cold restart -> GET
        // reconciliation; no extra POST and no premature queue release.
        do {
            let activeRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("Hermes166-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: activeRoot) }
            let activeFiles = LocalDataFileStore(
                instanceID: "accepted", accountScope: "account",
                sessionID: "test", rootDirectory: activeRoot)
            let activeStore = ChatDraftStore(
                instanceID: "accepted", accountScope: "account",
                sessionID: "test", fileStore: activeFiles)
            let service = PendingRecoveryService()
            service.failStart = false
            let model = NativeChatModel(sessionID: "test", api: service,
                                        draftStore: activeStore)
            await model.load()
            model.draft = "accepted with attachment"
            let submitted = await model.send(attachments: [attachment])
            precondition(submitted && service.startCalls == 1)
            precondition(activeStore.loadActiveRun().value != nil,
                         "accepted run must persist separately from PendingSend")
            precondition(activeStore.loadPending().value == nil,
                         "a stored accepted run allows clearing pre-POST pending data")
            model.disconnect()

            let recoveryService = PendingRecoveryService()
            recoveryService.active = "accepted"
            let resumed = NativeChatModel(sessionID: "test", api: recoveryService,
                                          draftStore: activeStore)
            precondition(resumed.activeTurnRecovery?.runID == "accepted")
            precondition(!resumed.canSend && recoveryService.startCalls == 0)
            await resumed.load()
            precondition(resumed.running && !resumed.canSend,
                         "relaunch must reconnect to known active run without POST")
            recoveryService.active = nil
            await resumed.refresh()
            precondition(resumed.activeTurnRecovery != nil && !resumed.canSend,
                         "missing active stream with no reply is still inconclusive")
            precondition(resumed.notice?.contains("无法确认") == true,
                         "history GET must retain unresolved accepted-run explanation")
            recoveryService.rows.append([
                "id": "fresh", "role": "user", "content": "accepted with attachment",
                "attachments": [["path": attachment.path]]
            ])
            recoveryService.rows.append([
                "id": "fresh-answer", "role": "assistant", "content": "completed"
            ])
            await resumed.refresh()
            precondition(resumed.activeTurnRecovery == nil
                         && activeStore.loadActiveRun().value == nil,
                         "verified reply should retire accepted-run receipt on disk")
            precondition(resumed.canSend && recoveryService.startCalls == 0,
                         "safe recovery must never replay the original POST")
            resumed.disconnect()
            print("PENDING_PASS accepted-run receipt survives restart, locks ambiguity and resolves without replay")

            _ = activeStore.saveActiveRun(Data("invalid accepted receipt".utf8))
            let damaged = NativeChatModel(sessionID: "test", api: PendingRecoveryService(),
                                          draftStore: activeStore)
            await damaged.load()
            precondition(damaged.activeRecoveryUnreadable && !damaged.canSend,
                         "corrupt accepted-run storage must fail closed")
            damaged.abandonUnreadableActiveRecovery()
            await damaged.refresh()
            precondition(!damaged.activeRecoveryUnreadable && damaged.canSend,
                         "explicit discard plus GET may unlock a corrupt local record")
            damaged.disconnect()
        }

        // Receipt exists, but the history snapshot temporarily omits
        // active_stream_id. A bounded run-status probe may attach only when the
        // exact run is alive; unknown status never unlocks a POST.
        for result in [ActiveRunProbe.alive, .terminal(.completed),
                       .terminal(.failed), .terminal(.cancelled),
                       .terminal(.interrupted), .unknown] {
            do {
                let probeRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HermesRunProbe-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: probeRoot) }
                let probeFiles = LocalDataFileStore(
                    instanceID: "probe", accountScope: "account",
                    sessionID: "test", rootDirectory: probeRoot)
                let probeStore = ChatDraftStore(
                    instanceID: "probe", accountScope: "account",
                    sessionID: "test", fileStore: probeFiles)
                let receipt = ActiveTurnRecovery(
                    runID: "receipt-run", historyEnd: 0, knownIDs: [],
                    text: "receipt text", attachmentPaths: [])
                let data = try JSONEncoder().encode(receipt)
                precondition(probeStore.saveActiveRun(data).succeeded)
                let service = PendingRecoveryService()
                service.probeResults = [result]
                if result == .terminal(.completed) {
                    service.rowsAfterProbe = [
                        ["id": "sent", "role": "user", "content": "receipt text"],
                        ["id": "reply", "role": "assistant", "content": "final"]
                    ]
                }
                let model = NativeChatModel(
                    sessionID: "test", api: service, draftStore: probeStore)
                await model.load()
                try await eventually { service.probeCalls == 1 }
                if result == .alive {
                    try await eventually { model.streamID == receipt.runID }
                    precondition(!model.canSend && model.uncertain == false,
                                 "a proven live receipt attaches without replaying the POST")
                } else if case .terminal(let outcome) = result {
                    try await eventually { model.activeTurnRecovery == nil }
                    precondition(!model.uncertain && model.canSend && model.streamID == nil
                                 && model.queueAutomaticDispatchPaused && probeStore.loadActiveRun().value == nil,
                                 "verified terminal run syncs history without replaying the POST")
                    precondition(model.notice == outcome.notice,
                                 "distinct terminal results retain their user-visible outcome")
                } else {
                    precondition(model.uncertain && !model.canSend
                                 && model.streamID == nil && probeStore.loadActiveRun().value != nil,
                                 "unknown status remains locked until history proves completion")
                }
                precondition(service.startCalls == 0,
                             "run-status probing must never replay the original POST")
                model.disconnect()
            }
        }
        print("PENDING_PASS receipt-only run probe attaches alive and fails closed otherwise")

        // A lost status record is not authority to send, but must not hide
        // the canonical transcript when opening an otherwise empty model.
        do {
            let service = PendingRecoveryService()
            service.statusUnknown = true
            service.unavailableRunID = "expired-run"
            service.rows = [
                ["id": "sent", "role": "user", "content": "original"],
                ["id": "reply", "role": "assistant", "content": "already stored"]
            ]
            let model = NativeChatModel(sessionID: "test", api: service)
            model.automaticReconciliationUnavailableNanoseconds = 5_000_000
            model.automaticReconciliationSteadyNanoseconds = 3_000_000
            await model.load()
            precondition(model.transcript.messages.map(\.id) == ["sent", "reply"])
            precondition(model.uncertain && !model.canSend && service.startCalls == 0)
            precondition(model.latestRecoverySnapshot == nil, "unknown status cannot authorize history proof")
            let originalBoundary = model.confirmedHistoryEnd
            model.scheduleAutomaticReconciliation()
            precondition(model.unavailableRunStatusID == "expired-run" &&
                         model.automaticReconciliationTask != nil &&
                         model.presentationState.showsNotice,
                         "a missing run keeps sparse read-only recovery and visible uncertainty")
            let firstCalls = service.historyCalls
            service.rows.append(["id": "later", "role": "assistant", "content": "newly stored reply"])
            try await eventually { service.historyCalls >= firstCalls + 2 &&
                model.transcript.messages.last?.id == "later" }
            precondition(model.confirmedHistoryEnd == originalBoundary && model.latestRecoverySnapshot == nil,
                         "display-only history must never authorize settlement")
            // A delayed older or conflicting window cannot erase the new reply.
            let newerRows = service.rows
            service.rows = [["id": "sent", "role": "user", "content": "original"]]
            let staleCalls = service.historyCalls
            try await eventually { service.historyCalls > staleCalls }
            precondition(model.transcript.messages.last?.id == "later")
            service.rows = newerRows
            precondition(model.uncertain && !model.canSend && service.startCalls == 0,
                         "repeated missing status is not permission to send")
            model.draft = "must not send"
            let sent = await model.send()
            precondition(!sent && service.startCalls == 0)
            service.statusUnknown = false
            service.unavailableRunID = nil
            try await eventually { model.unavailableRunStatusID == nil && model.canSend }
            precondition(service.startCalls == 0,
                         "a later authoritative GET can restore sending without replay or manual refresh")
            model.disconnect()
            let stoppedCalls = service.historyCalls
            try await Task.sleep(nanoseconds: 20_000_000)
            precondition(service.historyCalls == stoppedCalls && model.automaticReconciliationTask == nil,
                         "disconnect stops sparse recovery")
        }

        // Status uncertainty may disable sending, not reading an adjacent
        // canonical history page. Periodic recovery cannot interrupt it.
        do {
            let service = PendingRecoveryService()
            service.statusUnknown = true
            service.unavailableRunID = "expired-paged"
            service.historyPageLimit = 2
            service.rows = (0..<6).map { ["id": "m\($0)", "role": "user", "content": "row \($0)"] }
            let model = NativeChatModel(sessionID: "test", api: service)
            model.automaticReconciliationUnavailableNanoseconds = 5_000_000
            model.automaticReconciliationSteadyNanoseconds = 3_000_000
            await model.load()
            precondition(model.transcript.messages.map(\.id) == ["m4", "m5"])
            precondition(model.canLoadOlderHistory && !model.canSend)
            service.holdHistory = true
            let paging = Task { await model.loadOlder() }
            try await eventually { service.historyWait != nil }
            let calls = service.historyCalls
            try await Task.sleep(nanoseconds: 25_000_000)
            precondition(service.historyCalls == calls && model.loadingOlder,
                         "automatic reconciliation must yield to a reader-owned page")
            service.holdHistory = false
            let page = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
                "session_id": "test", "messages": Array(service.rows[2..<4]),
                "_messages_offset": 2, "read_only": false
            ]), runStatusUnknown: true, unavailableRunID: "expired-paged")
            service.historyWait?.resume(returning: page)
            service.historyWait = nil
            await paging.value
            precondition(model.transcript.messages.map(\.id) == ["m2", "m3", "m4", "m5"])
            precondition(model.olderOffset == 2 && model.confirmedHistoryEnd == nil &&
                         model.latestRecoverySnapshot == nil && model.uncertain && !model.canSend &&
                         service.startCalls == 0,
                         "unverified reading must not create sending or settlement authority")
            model.disconnect()
        }

        // A confirmed terminal status must survive an unreachable final GET,
        // relaunch, and status expiry. Old receipts decode with nil evidence.
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("HermesTerminalProof-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = LocalDataFileStore(instanceID: "terminal", accountScope: "account",
                sessionID: "test", rootDirectory: root)
            let store = ChatDraftStore(instanceID: "terminal", accountScope: "account",
                sessionID: "test", fileStore: files)
            let receipt = ActiveTurnRecovery(runID: "verified-run", historyEnd: 0,
                knownIDs: [], text: "request", attachmentPaths: [])
            let encoded = try JSONEncoder().encode(receipt)
            precondition(store.saveActiveRun(encoded).succeeded)
            let service = PendingRecoveryService()
            service.probeResults = [.terminal(.failed)]
            service.failHistoryAfterProbe = true
            let first = NativeChatModel(sessionID: "test", api: service, draftStore: store)
            await first.load()
            try await eventually { first.activeTurnRecovery?.terminalStatus == .failed }
            precondition(first.uncertain && !first.canSend)
            first.disconnect()
            let durable = try JSONDecoder().decode(ActiveTurnRecovery.self,
                from: store.loadActiveRun().value!)
            precondition(durable.terminalStatus == .failed)
            let resumedService = PendingRecoveryService()
            resumedService.probeResults = [.unknown]
            let resumed = NativeChatModel(sessionID: "test", api: resumedService, draftStore: store)
            await resumed.load()
            try await eventually { resumed.activeTurnRecovery == nil }
            precondition(resumed.notice == RunTerminalStatus.failed.notice)
            precondition(resumed.canSend && resumedService.probeCalls == 0
                && resumedService.startCalls == 0)
            resumed.disconnect()
        }
        print("PENDING_PASS exact terminal proof survives failed history and restart")

        do {
            let defaults = UserDefaults(suiteName: "HermesDraftRace-" + UUID().uuidString)!
            let store = ChatDraftStore(instanceID: "draft-race", sessionID: "test", defaults: defaults)
            store.save("original")
            let model = NativeChatModel(sessionID: "test", api: PendingRecoveryService(), draftStore: store)
            store.save("newer composer text")
            model.clearOriginalDraft("original")
            precondition(store.load() == "newer composer text")
            store.save("original")
            model.clearOriginalDraft("original")
            precondition(store.load().isEmpty)
        }
        print("PENDING_PASS receipt cannot erase a newer durable composer draft")

        do {
            let defaults = UserDefaults(suiteName: "HermesFinalLag-" + UUID().uuidString)!
            let store = ChatDraftStore(instanceID: "final-lag", sessionID: "test", defaults: defaults)
            let receipt = ActiveTurnRecovery(runID: "final-lag", historyEnd: 0,
                knownIDs: [], text: "original", attachmentPaths: [])
            let encoded = try JSONEncoder().encode(receipt)
            precondition(store.saveActiveRun(encoded).succeeded)
            let service = PendingRecoveryService()
            service.probeResults = [.terminal(.completed)]
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: store)
            await model.load()
            try await eventually { model.activeTurnRecovery?.terminalStatus == .completed }
            try await eventually { model.activeRunProbeTask == nil }
            precondition(model.uncertain && !model.canSend && store.loadActiveRun().value != nil)
            service.rows = [
                ["id": "sent", "role": "user", "content": "original"],
                ["id": "reply", "role": "assistant", "content": "final"]
            ]
            await model.refresh(silent: true)
            try await eventually { model.activeTurnRecovery == nil }
            precondition(model.canSend && service.startCalls == 0 && service.probeCalls == 1)
            model.disconnect()
        }
        print("PENDING_PASS completed receipt waits for matching final history")

        // Completed streamed reply with the user row beyond the newest page.
        // A transient older-page failure must not strand the original receipt.
        do {
            let service = PendingRecoveryService()
            service.historyPageLimit = 60
            service.rows = [["id": "sent", "role": "user", "content": "long task"]]
            service.rows += (0..<180).map { index in
                ["id": "tool-\(index)", "role": "tool",
                 "tool_call_id": "tool-\(index)", "content": "completed"]
            }
            service.rows.append(["id": "answer", "role": "assistant", "content": "complete streamed answer"])
            service.failOlderPageOnce = true
            let model = NativeChatModel(sessionID: "test", api: service)
            model.activeTurnRecovery = ActiveTurnRecovery(runID: "long-terminal", historyEnd: 0,
                knownIDs: [], text: "long task", attachmentPaths: [], terminalStatus: .completed)
            model.streamID = "long-terminal"
            model.buffer.messages = [ChatMessage(id: "streaming:long-terminal", role: "assistant",
                content: "complete streamed answer")]
            model.buffer.terminal = true
            model.uncertain = true
            model.automaticReconciliationDelaysNanoseconds = [2_000_000]
            model.automaticReconciliationSteadyNanoseconds = 4_000_000
            model.automaticDeepRecoveryRetryNanoseconds = 8_000_000
            await model.load(silent: true)
            precondition(model.error == nil && model.latestRecoverySnapshot?.olderOffset == 122 &&
                         model.buffer.messages.last?.id == "streaming:long-terminal" && !model.canSend,
                         "valid partial head must survive final-history gate without losing visible reply")
            try await eventually { model.activeTurnRecovery == nil && model.canSend &&
                model.automaticReconciliationTask == nil }
            precondition(model.buffer.messages.last?.id == "answer" &&
                         service.historyPageCalls >= 4 && service.startCalls == 0,
                         "same-head pagination recovers after transient failure and stops polling")
            let calls = service.historyCalls
            try await Task.sleep(nanoseconds: 20_000_000)
            precondition(service.historyCalls == calls && model.queueRecoveryPaused)
            model.disconnect()
        }
        print("PENDING_PASS completed streamed long reply converges after same-head pagination retry")

        // Force a one-page work budget: the next tick must continue at the
        // previous cursor, not restart at the newest page.
        do {
            let service = PendingRecoveryService()
            service.historyPageLimit = 3
            service.rows = [["id": "sent", "role": "user", "content": "long task"]]
            service.rows += (0..<16).map { ["id": "tool-\($0)", "role": "tool", "content": "done"] }
            service.rows.append(["id": "reply", "role": "assistant", "content": "complete"])
            // A second legitimate turn cannot erase exact terminal proof.
            service.rows += [["id": "other-user", "role": "user", "content": "other"],
                             ["id": "other-reply", "role": "assistant", "content": "other answer"]]
            let model = NativeChatModel(sessionID: "test", api: service)
            model.activeTurnRecovery = ActiveTurnRecovery(runID: "multi-page", historyEnd: 0,
                knownIDs: [], text: "long task", attachmentPaths: [], terminalStatus: .completed)
            model.recoveryPagesPerPass = 1
            model.automaticReconciliationDelaysNanoseconds = [2_000_000]
            model.automaticReconciliationSteadyNanoseconds = 4_000_000
            await model.load()
            try await eventually { model.canSend && model.activeTurnRecovery == nil &&
                model.automaticReconciliationTask == nil }
            precondition(service.historyPageCalls >= 6 && service.historyPageCalls <= 8 &&
                         service.startCalls == 0 && model.queueRecoveryPaused,
                         "resumable compact proof must converge, with exact terminal and no replay")
            model.disconnect()
        }
        print("PENDING_PASS multi-pass history budget and exact terminal with a later independent user turn")

        // Missing status is still not terminal. Explicit external confirmation
        // can retire a matching receipt, not a running or unrelated Run.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = LocalDataFileStore(instanceID: "manual", accountScope: "account",
                sessionID: "test", rootDirectory: root)
            let store = ChatDraftStore(instanceID: "manual", accountScope: "account",
                sessionID: "test", fileStore: files)
            let receipt = ActiveTurnRecovery(runID: "expired-manual", historyEnd: 0,
                knownIDs: [], text: "original", attachmentPaths: [])
            let encoded = try JSONEncoder().encode(receipt)
            precondition(store.saveActiveRun(encoded).succeeded)
            let service = PendingRecoveryService()
            service.statusUnknown = true
            service.unavailableRunID = receipt.runID
            service.probeResults = [.unresolved]
            service.rows = [["id": "sent", "role": "user", "content": "original"],
                            ["id": "reply", "role": "assistant", "content": "answer"]]
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: store)
            await model.load()
            if let probe = model.activeRunProbeTask { await probe.value }
            precondition(model.canConfirmEndedRunLocally && !model.canSend && service.userReleaseCalls == 0)
            let denied = await model.confirmEndedRunLocally()
            precondition(!denied && model.activeTurnRecovery == receipt && !model.canSend)
            service.allowUserRelease = true
            let confirmed = await model.confirmEndedRunLocally()
            precondition(confirmed && model.canSend && store.loadActiveRun().value == nil &&
                         model.queueUserPaused && model.automaticReconciliationTask == nil &&
                         service.startCalls == 0 && service.userReleaseCalls == 2)
            model.disconnect()
            let restored = NativeChatModel(sessionID: "test", api: service, draftStore: store)
            await restored.load()
            precondition(restored.canSend && restored.queueUserPaused && service.startCalls == 0)
            service.failStart = false
            service.carriesRunSubmissionIdentity = true
            restored.draft = "a new explicit message"
            _ = await restored.send()
            precondition(service.startCalls == 1 && service.sent.last?.0 == "a new explicit message",
                         "the original session can actually submit a new turn after recovery")
            restored.disconnect()
        }
        print("PENDING_PASS explicit same-session release of a missing Run, failure and restart")

        // The original keyed POST response was lost. A visible user row alone
        // is delivery proof, not permission to send another request.
        do {
            let service = PendingRecoveryService()
            service.carriesRunSubmissionIdentity = true
            let model = NativeChatModel(sessionID: "test", api: service)
            await model.load()
            model.draft = "lost response"
            _ = await model.send()
            service.rows += [["id": "sent", "role": "user", "content": "lost response"],
                             ["id": "reply", "role": "assistant", "content": "answer"]]
            let result = await model.reconcilePending()
            precondition(result == .failed && model.pendingDeliveryIsVerified &&
                         model.canConfirmPendingEndedLocally && !model.canSend && !model.canResendPending)
            let confirmed = await model.confirmDeliveredPendingEndedLocally()
            precondition(confirmed && model.canSend && model.pendingSend == nil &&
                         model.queueUserPaused && service.startCalls == 1)
            model.disconnect()
        }
        print("PENDING_PASS keyed delivery versus execution; user-confirmed original session continuation")

        // Restore a crash between queue and PendingSend commits. Recovery
        // reuses the original identity for read-only proof, never sends it.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = LocalDataFileStore(instanceID: "orphan-key", accountScope: "account",
                sessionID: "test", rootDirectory: root)
            let store = ChatDraftStore(instanceID: "orphan-key", accountScope: "account",
                sessionID: "test", fileStore: files)
            let key = RunSubmissionIdentity.make()
            let orphan = ChatQueuedTurn(id: "orphan", text: "queued", attachments: [],
                composerText: "queued", origin: .userInput, automaticAfterStreamID: nil,
                delivery: .submitting, historyEnd: 0, knownIDs: [], submittedAt: 1, submissionKey: key)
            let encoded = ChatSendQueueCodec.encode([orphan])!
            precondition(store.saveQueued(encoded).succeeded)
            let service = PendingRecoveryService()
            service.rows = [["id": "sent", "role": "user", "content": "queued"],
                            ["id": "answer", "role": "assistant", "content": "complete"]]
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: store)
            await model.load()
            precondition(model.pendingSend?.submissionKey == key &&
                         model.pendingSend?.queuedTurnID == orphan.id && !model.canSend &&
                         model.pendingDeliveryIsVerified && service.startCalls == 0)
            let confirmed = await model.confirmDeliveredPendingEndedLocally()
            precondition(confirmed && model.canSend && model.pendingSend == nil &&
                         model.queuedTurns.isEmpty && service.startCalls == 0 && model.queueUserPaused)
            model.disconnect()
        }
        print("PENDING_PASS orphaned keyed queue reconstructs exact pending proof and never resends")

        // Long-running agent: a single answer can be separated from its
        // accepted user message by >60 invisible tool rows. A normal GET must
        // remain fail-closed; manual read-only pagination may prove completion.
        for scenario in ["complete", "background-notice", "mislabelled-user",
                         "second-user", "changed-tail", "still-running", "other-run"] {
            let longRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("HermesLongRun-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: longRoot) }
            let longFiles = LocalDataFileStore(
                instanceID: "long", accountScope: "account",
                sessionID: "test", rootDirectory: longRoot)
            let longStore = ChatDraftStore(instanceID: "long", accountScope: "account",
                                           sessionID: "test", fileStore: longFiles)
            let receipt = ActiveTurnRecovery(runID: "long-run", historyEnd: 0,
                knownIDs: [], text: "long task", attachmentPaths: [])
            let encodedReceipt = try JSONEncoder().encode(receipt)
            precondition(longStore.saveActiveRun(encodedReceipt).succeeded)
            let service = PendingRecoveryService()
            service.historyPageLimit = 60
            service.rows = [["id": "new-user", "role": "user", "content": "long task"]]
            service.rows += (0..<145).map { index in
                ["id": "tool-\(index)", "role": "tool",
                 "tool_call_id": "tool-\(index)", "content": "completed"]
            }
            if scenario == "second-user" {
                service.rows.insert(["id": "extra-user", "role": "user", "content": "another submission"],
                                    at: 80)
            }
            if scenario == "mislabelled-user" {
                service.rows.insert(["id": "labelled-user", "role": "user",
                                     "content": "genuine user question",
                                     "display_kind": "internal_notification"], at: 80)
            }
            service.rows.append(["id": "last-answer", "role": "assistant", "content": "completed"])
            if scenario == "background-notice" {
                service.rows.append(["id": "background", "role": "user",
                                     "content": "[OUT-OF-BAND USER MESSAGE — notification]\nStatus update\n[/OUT-OF-BAND USER MESSAGE]",
                                     "display_kind": "internal_notification"])
            }
            service.appendHeadOnOlderPage = scenario == "changed-tail"
            if scenario == "still-running" { service.active = "long-run" }
            if scenario == "other-run" { service.active = "newer-run" }
            let model = NativeChatModel(sessionID: "test", api: service, draftStore: longStore)
            await model.load()
            if let probe = model.activeRunProbeTask { await probe.value }
            precondition(!model.canSend && service.startCalls == 0,
                         "60-row tail must not release the send lock or replay a POST")
            let verified = await model.reconcileLongAcceptedRun()
            if scenario == "complete" || scenario == "background-notice" {
                precondition(verified && model.canSend
                             && longStore.loadActiveRun().value == nil,
                             "contiguous long history and stable tail must settle receipt")
            } else {
                precondition(!verified && !model.canSend
                             && longStore.loadActiveRun().value != nil,
                             "ambiguous/changed long history must remain fail-closed")
            }
            if scenario == "still-running" || scenario == "other-run" {
                precondition(service.historyPageCalls == 0 && service.startCalls == 0,
                             "a live current or competing run prevents lookback")
            } else {
                precondition(service.historyPageCalls >= 2 && service.startCalls == 0,
                             "verification pages history without replaying a POST")
            }
            model.disconnect()
        }
        print("PENDING_PASS long-run history pagination, interleaved user and changed tail")

        let busyService = PendingRecoveryService()
        let busy = NativeChatModel(sessionID: "test", api: busyService)
        await busy.load()
        busy.draft = "same"
        await busy.send()
        busyService.holdHistory = true
        let checking = Task { await busy.reconcilePending() }
        try await eventually { busyService.historyWait != nil }
        precondition(!busy.canResendPending && !busy.canSend)
        let inFlightGeneration = busy.revision
        await busy.refresh(silent: true)
        precondition(busy.reconciling && busy.revision == inFlightGeneration,
                     "ordinary refresh cannot revoke the pending reconciliation owner")
        busy.discardPending()
        precondition(busy.transcript.messages.last?.delivery == .unconfirmed,
                     "discard must not race an in-flight reconciliation")
        let blockedRetry = await busy.resendPending()
        precondition(!blockedRetry && busyService.startCalls == 1)
        let snapshot = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
            "session_id": "test", "messages": busyService.rows, "read_only": false
        ]))
        busyService.historyWait?.resume(returning: snapshot)
        busyService.historyWait = nil
        let checked = await checking.value
        precondition(checked == .absent && busy.canResendPending)
        busy.disconnect()
        print("PENDING_PASS in-flight GET locks retry and discard until its authoritative result")
    }
}
