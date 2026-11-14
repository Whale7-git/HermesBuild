import Foundation

@MainActor final class PendingRecoveryService: NativeChatService {
    var rows: [[String: Any]] = [["id": "old", "role": "user", "content": "same"]]
    var offset = 0
    var active: String?
    var readOnly = false
    var failHistory = false
    var failStart = true
    var historyWait: CheckedContinuation<ChatSnapshot, Error>?
    var holdHistory = false
    var startCalls = 0
    var sent: [(String, [ChatAttachmentPayload])] = []

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        if failHistory { throw URLError(.notConnectedToInternet) }
        let snapshot = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: [
            "session_id": sessionID, "messages": rows, "_messages_offset": offset,
            "read_only": readOnly, "active_stream_id": active as Any? ?? NSNull()
        ]))
        if holdHistory { return try await withCheckedThrowingContinuation { historyWait = $0 } }
        return snapshot
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        try await startNativeTurn(sessionID: sessionID, text: text, attachments: [])
    }
    func startNativeTurn(sessionID: String, text: String, attachments: [ChatAttachmentPayload]) async throws -> String {
        startCalls += 1
        sent.append((text, attachments))
        if failStart { throw URLError(.networkConnectionLost) }
        active = "accepted"
        return "accepted"
    }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
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

        let busyService = PendingRecoveryService()
        let busy = NativeChatModel(sessionID: "test", api: busyService)
        await busy.load()
        busy.draft = "same"
        await busy.send()
        busyService.holdHistory = true
        let checking = Task { await busy.reconcilePending() }
        try await eventually { busyService.historyWait != nil }
        precondition(!busy.canResendPending && !busy.canSend)
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
