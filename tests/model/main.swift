import Foundation

// Linux only: UI observation has no bearing on the state machine under test.
#if !canImport(SwiftUI)
protocol ObservableObject: AnyObject {}
var transcriptPublications = 0
@propertyWrapper struct Published<Value> {
    var wrappedValue:Value {
        didSet { if wrappedValue is ChatTranscript { transcriptPublications += 1 } }
    }
}
#endif

@MainActor final class FakeChatService:NativeChatService {
    var startCalls = 0
    var historyCalls = 0
    var stopCalls = 0
    var failStart = false
    var delayStart = false
    var emitDone = false
    var acceptedText = ""
    var terminalHistoryEntered = false
    var deferTerminalHistory = false
    var active:String?
    var lastAttachmentPaths:[String] = []
    var failTerminalHistory = false
    var historyRows: [[String: Any]] = []
    var probeResult: ActiveRunProbe = .unknown
    var probeCalls = 0
    func probeActiveRun(sessionID:String,runID:String) async throws -> ActiveRunProbe {
        probeCalls += 1
        return probeResult
    }
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload]) async throws -> String {
        lastAttachmentPaths = attachments.map(\.path)
        return try await startNativeTurn(sessionID:sessionID,text:text)
    }
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        if deferTerminalHistory {
            terminalHistoryEntered = true
            try await Task.sleep(nanoseconds:100_000_000)
            if failTerminalHistory { throw URLError(.timedOut) }
        }
        var s:[String:Any] = ["session_id":sessionID,"messages":historyRows,"read_only":false,"_messages_offset":0]
        if let active { s["active_stream_id"] = active }
        return try ChatSnapshot(data:JSONSerialization.data(withJSONObject:["session":s]))
    }
    func startNativeTurn(sessionID:String,text:String) async throws -> String {
        startCalls += 1
        if delayStart { try await Task.sleep(nanoseconds:100_000_000) }
        if failStart { throw URLError(.timedOut) }
        acceptedText = text
        active = "test-stream"
        return active!
    }
    func stopNativeTurn(streamID:String) async throws { stopCalls += 1; active = nil }
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws {
        if emitDone {
            active = nil
            // A completed turn must be visible in the authoritative GET.
            historyRows.append(["id": "accepted-user-\(startCalls)", "role": "user", "content": acceptedText])
            historyRows.append(["id": "accepted-answer-\(startCalls)", "role": "assistant", "content": "completed"])
            deferTerminalHistory = true
            _ = try await onFrame(SSEFrame(event:"done",data:"{\"session\":{\"session_id\":\"test\",\"messages\":[]}}",id:"test:1"))
            return
        }
        try await Task.sleep(nanoseconds:30_000_000_000)
    }
}

@main struct ModelTests {
    @MainActor static func eventually(_ condition:() -> Bool,
                                      file: StaticString = #fileID, line: UInt = #line) async throws {
        for _ in 0..<4000 {
            if condition() { return }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        preconditionFailure("automatic GET recovery did not reach expected state", file: file, line: line)
    }
    @MainActor static func finalHistoryGateTests() throws {
        let initial: [[String: Any]] = [
            ["id": "old-user", "role": "user", "content": "Earlier question"],
            ["id": "old-answer", "role": "assistant", "content": "Earlier answer"]
        ]
        let sent: [String: Any] = ["id": "new-user", "role": "user", "content": "new turn"]
        let answer: [String: Any] = ["id": "new-answer", "role": "assistant", "content": "final streamed answer"]
        func snapshot(_ rows: [[String: Any]], active: String? = nil) throws -> ChatSnapshot {
            var obj: [String: Any] = [
                "session_id": "test", "messages": rows, "_messages_offset": 0,
                "read_only": false
            ]
            if let active { obj["active_stream_id"] = active }
            return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": obj]))
        }
        let receipt = ActiveTurnRecovery(runID: "run-1", historyEnd: 2,
            knownIDs: ["old-user", "old-answer"], text: "new turn", attachmentPaths: [])
        let stale = try snapshot(initial + [sent])
        let alive = try snapshot(initial + [sent, answer], active: "run-1")
        let final = try snapshot(initial + [sent, answer])
        let unknownStatus = try ChatSnapshot(
            data: JSONSerialization.data(withJSONObject: [
                "session_id": "test", "messages": initial + [sent, answer]
            ]), runStatusUnknown: true)
        // A stale history payload may still include an active_stream_id from another
        // Run while the independent status probe fails. Neither its presence nor
        // its mismatch is proof that our accepted POST has finished.
        let contradictoryUnknown = try ChatSnapshot(
            data: JSONSerialization.data(withJSONObject: [
                "session_id": "test", "active_stream_id": "different-run",
                "messages": initial + [sent, answer]
            ]), runStatusUnknown: true)
        precondition(contradictoryUnknown.activeRunEvidence == .unknown
                     && !ChatFinalHistoryGate.canReplace(
                         contradictoryUnknown, sessionID: "test", receipt: receipt,
                         streamedAssistantPresent: true, expectedRunID: "run-1"),
                     "failed Run probe cannot authorize a cross-Run history replacement")
        precondition(unknownStatus.activeRunEvidence == .unknown
                     && !ChatFinalHistoryGate.canReplace(
                         unknownStatus, sessionID: "test",
                         receipt: receipt, streamedAssistantPresent: true),
                     "unknown run status must not replace streamed reply")
        precondition(!ChatFinalHistoryGate.canReplace(
            unknownStatus, sessionID: "test", receipt: receipt,
            streamedAssistantPresent: false),
            "unknown status cannot authorize history replacement even without a streamed reply")
        precondition(!ChatFinalHistoryGate.canReplace(stale, sessionID: "test",
            receipt: receipt, streamedAssistantPresent: true))
        precondition(!ChatFinalHistoryGate.canReplace(alive, sessionID: "test",
            receipt: receipt, streamedAssistantPresent: true))
        precondition(!ChatFinalHistoryGate.canReplace(final, sessionID: "different",
            receipt: receipt, streamedAssistantPresent: true))
        precondition(!ChatFinalHistoryGate.canReplace(final, sessionID: "test",
            receipt: nil, streamedAssistantPresent: true))
        precondition(ChatFinalHistoryGate.canReplace(final, sessionID: "test",
            receipt: receipt, streamedAssistantPresent: true))
        precondition(ChatFinalHistoryGate.canReplace(stale, sessionID: "test",
            receipt: receipt, streamedAssistantPresent: false))
        precondition(!ChatFinalHistoryGate.canReplace(final, sessionID: "test",
            receipt: receipt, streamedAssistantPresent: true, expectedRunID: "another-run"),
            "same-session final history of a different accepted Run is not authorization")
        precondition(ChatFinalHistoryGate.canReplace(final, sessionID: "test",
            receipt: receipt, streamedAssistantPresent: true, expectedRunID: "run-1"),
            "matching Run and receipt can finalize the streamed reply")
        let model = NativeChatModel(sessionID: "test", api: FakeChatService())
        model.streamID = "run-1"
        model.activeTurnRecovery = receipt
        model.buffer.messages = [ChatMessage(id: "streaming:run-1", role: "assistant",
                                            content: "visible streamed reply")]
        model.buffer.terminal = true
        do {
            try model.applySnapshot(stale)
            preconditionFailure("stale refresh must not clear streamed reply")
        } catch {
            precondition(model.buffer.messages.first?.content == "visible streamed reply",
                         "stale GET must leave visible streamed text intact")
            precondition(model.activeTurnRecovery?.runID == "run-1",
                         "stale GET must preserve original POST receipt")
        }
        try model.applySnapshot(final)
        precondition(model.buffer.messages.contains { $0.id == "new-answer" },
                     "matching final history replaces the temporary streamed row")
        print("MODEL_PASS never replace streamed text with stale or cross-Run history")
    }

    @MainActor static func unresolvedProbeSafetyTests() async throws {
        let service = FakeChatService()
        service.historyRows = [[
            "id": "retained-user", "role": "user", "content": "retain this transcript"
        ]]
        let model = NativeChatModel(sessionID: "test", api: service)
        await model.load()
        let receipt = ActiveTurnRecovery(
            runID: "test-stream", historyEnd: 1,
            knownIDs: ["retained-user"], text: "accepted POST",
            attachmentPaths: [])
        model.activeTurnRecovery = receipt
        model.streamID = receipt.runID
        model.lastEventID = "sse-event-12"
        model.transition(to: .reconnecting)
        let renderedIDs = model.transcript.messages.map(\.id)
        let unknown = try ChatSnapshot(
            data: JSONSerialization.data(withJSONObject: [
                "session_id": "test", "messages": service.historyRows
            ]), runStatusUnknown: true)
        service.probeResult = .unknown
        try model.applySnapshot(unknown, preserveLoadedOlder: true)
        precondition(model.lastEventID == "sse-event-12"
                     && model.streamID == receipt.runID
                     && model.transcript.messages.map(\.id) == renderedIDs,
                     "unknown status cannot discard SSE cursor, stream, or transcript")
        try await eventually { service.probeCalls == 1 && model.activeRunProbeTask == nil }
        precondition(model.phase == .reconnecting && model.uncertain && !model.canSend,
                     "unconfirmed status must keep the original run locked")
        service.probeResult = .unresolved
        model.probeAcceptedRun(receipt)
        try await eventually { service.probeCalls == 2 && model.activeRunProbeTask == nil }
        precondition(model.phase == .idle && !model.running && model.streamID == nil,
                     "bounded 404 must retire the live UI phase, not remain reconnecting")
        precondition(model.activeTurnRecovery == receipt && model.uncertain && !model.canSend,
                     "unresolved 404 preserves accepted POST receipt and send lock")
        precondition(model.transcript.messages.map(\.id) == renderedIDs
                     && service.startCalls == 0,
                     "unresolved recovery must preserve history and never replay POST")
        model.disconnect()
        print("MODEL_PASS unknown repeated probe converges without replay or transcript loss")
    }

    @MainActor static func main() async throws {
        try finalHistoryGateTests()
        try await unresolvedProbeSafetyTests()
        try await placeholderOriginTests()
        try await cacheTests()
        try await placeholderBindingTests()
        try await runWindowTrimTests()
        try await pendingRecoveryTests()
        try await activityRecoveryTests()
        historyClassificationTests()
        try runSettlementTests()
        sendGateTests()
        turnStateTests()
        turnReducerTests()
        try await automaticReconciliationTests()
        try await runPagingBudgetTests()
        runQueuePresentationTests()
        await runSendModeTests()
        try await runSendSafetyTests()
        try await testRetiredPostCompletions()
        try await phaseTransitionTests()
        let foregroundService = FakeChatService()
        let foregroundModel = NativeChatModel(sessionID:"foreground",api:foregroundService)
        await foregroundModel.load()
        foregroundModel.transcript.messages = [ChatMessage(id:"shown",role:"assistant",content:"Keep visible")]
        foregroundService.deferTerminalHistory = true
        let foregroundTask = Task { await foregroundModel.resumeForeground() }
        while !foregroundService.terminalHistoryEntered { await Task.yield() }
        precondition(!foregroundModel.loading && foregroundModel.transcript.messages.first?.content == "Keep visible","foreground sync must keep conversation visible")
        precondition(!foregroundModel.canSend, "silent refresh still locks send until canonical history arrives")
        await foregroundTask.value
        foregroundModel.disconnect()
        print("MODEL_PASS foreground resumes without blocking existing conversation")
        let service = FakeChatService()
        let model = NativeChatModel(sessionID:"test",api:service)
        await model.load()
        precondition(!model.readOnly && service.historyCalls == 1)
        model.draft = "must not resend uncertain POST"
        service.failStart = true
        await model.send()
        precondition(model.error != nil && model.draft == "must not resend uncertain POST")
        await model.send()
        precondition(service.startCalls == 1,"Uncertain POST must block automatic/second send until explicit status refresh")
        print("MODEL_PASS uncertain POST not resent")
        service.failStart = false
        await model.refresh()
        precondition(model.canResendPending && !model.canSend, "refresh retains the explicit retry/discard decision")
        model.discardPending()
        precondition(!model.uncertain && model.canSend)
        service.delayStart = true
        model.draft = "first message"
        let sendTask = Task { await model.send() }
        while service.startCalls < 2 { await Task.yield() }
        let countBefore = service.historyCalls
        await model.refresh()
        precondition(service.historyCalls == countBefore,"refresh cannot unlock an outstanding POST")
        model.draft = "new draft typed while waiting"
        _ = await sendTask.value
        precondition(model.draft == "new draft typed while waiting","start completion must not erase a newer draft")
        precondition(model.running && !model.canSend)
        model.disconnect()
        precondition(service.stopCalls == 0,"leaving screen must not stop backend")
        print("MODEL_PASS refresh during submit, preserved draft, disconnect does not stop")
        let settlingService = FakeChatService()
        let settlingModel = NativeChatModel(sessionID:"test",api:settlingService)
        await settlingModel.load()
        settlingService.emitDone = true
        settlingModel.draft = "A"
        await settlingModel.send()
        while !settlingService.terminalHistoryEntered { await Task.yield() }
        settlingModel.draft = "B"
        await settlingModel.send()
        precondition(settlingService.startCalls == 1 && !settlingModel.canSend,"terminal history must settle before permitting next send")
        while settlingModel.reconciling { await Task.yield() }
        precondition(settlingModel.canSend && settlingModel.draft == "B")
        settlingModel.disconnect()
        print("MODEL_PASS terminal/history reconciliation holds send lock")
        let resumeService = FakeChatService()
        let resumeModel = NativeChatModel(sessionID:"test",api:resumeService)
        await resumeModel.load()
        resumeService.delayStart = true
        resumeModel.draft = "pending"
        let pending = Task { await resumeModel.send() }
        while resumeService.startCalls < 1 { await Task.yield() }
        resumeModel.disconnect()
        await resumeModel.load()
        _ = await pending.value
        precondition(resumeService.historyCalls == 2,"reopening during POST must resume once submission resolves")
        precondition(resumeModel.draft.isEmpty && resumeModel.running && resumeModel.streamID != nil)
        resumeModel.disconnect()
        print("MODEL_PASS reopen during pending submission resumes safely")
        let failedService = FakeChatService()
        let failedModel = NativeChatModel(sessionID:"test",api:failedService)
        await failedModel.load()
        failedService.emitDone = true
        failedService.failTerminalHistory = true
        failedModel.draft = "pending"
        await failedModel.send()
        while !failedService.terminalHistoryEntered || failedModel.reconciling { await Task.yield() }
        precondition(!failedModel.canSend && failedModel.uncertain,"terminal history failure must keep send locked")
        failedModel.draft = "retry"
        await failedModel.send()
        precondition(failedService.startCalls == 1)
        failedService.failTerminalHistory = false
        failedService.historyRows = [
            ["id": "recovered-user", "role": "user", "content": "pending"],
            ["id": "recovered-answer", "role": "assistant", "content": "completed"]
        ]
        await failedModel.refresh()
        try await eventually { failedModel.canSend && !failedModel.uncertain }
        failedModel.disconnect()
        print("MODEL_PASS failed terminal history locks until verified refresh")
        for throwsOnDisconnect in [false,true] {
            let recovery = RecoveryService()
            recovery.throwsOnDisconnect = throwsOnDisconnect
            let recovering = NativeChatModel(sessionID:"test",api:recovery)
            recovery.inspect = {
                precondition(!recovering.reconnecting,"receiving frames must clear reconnecting indicator")
                return recovering.transcript
            }
            await recovering.load()
            recovering.draft = "one POST"
            await recovering.send()
            try await eventually { recovery.streamCalls >= 2 && recovering.canSend }
            precondition(recovery.startCalls == 1 && recovery.cursors[1] == "s:1")
            precondition(recovering.transcript.messages.last?.content == "AB","same stream must retain cursor and deduplication")
            precondition(recovering.canSend && recovery.historyCalls >= 2)
            recovery.inspect = nil
            recovering.disconnect()
        }
        print("MODEL_PASS EOF and URL error GET recovery preserves cursor, no repeated POST")
        let suite = "HermesModelDraftTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = ChatDraftStore(instanceID:"instance",sessionID:"test",defaults:defaults)
        store.save("restored")
        let draftService = FakeChatService()
        let draftModel = NativeChatModel(sessionID:"test",api:draftService,draftStore:store)
        precondition(draftModel.draft == "restored")
        await draftModel.load()
        draftModel.draft = "pending"
        precondition(store.load() == "pending")
        draftService.failStart = true
        await draftModel.send()
        precondition(store.load() == "pending")
        draftService.failStart = false
        await draftModel.refresh()
        precondition(draftModel.canResendPending && !draftModel.canSend)
        draftModel.discardPending()
        draftService.delayStart = true
        let saving = Task { await draftModel.send() }
        while draftService.startCalls < 2 { await Task.yield() }
        draftModel.draft = "newer"
        _ = await saving.value
        precondition(store.load() == "newer")
        draftModel.disconnect()
        draftService.active = nil
        draftService.historyRows = [
            ["id": "saved-user", "role": "user", "content": "pending"],
            ["id": "saved-answer", "role": "assistant", "content": "completed"]
        ]
        await draftModel.load()
        await draftModel.send()
        precondition(store.load().isEmpty)
        draftModel.disconnect()
        print("MODEL_PASS draft restore, edits, uncertain preservation, conditional success clear")
        let burst = BurstService()
        let batched = NativeChatModel(sessionID:"test",api:burst)
        burst.inspect = { batched.transcript }
        await batched.load()
        batched.draft = "burst"
        await batched.send()
        try await eventually { batched.uncertain }
        precondition(burst.checked && batched.transcript.terminal)
        burst.inspect = nil
        batched.disconnect()
        print("MODEL_PASS burst batched, 40ms live publication, terminal immediate flush")
        let capped = RecoveryService()
        capped.neverFinishes = true
        let bounded = NativeChatModel(sessionID:"test",api:capped)
        await bounded.load()
        bounded.draft = "bounded"
        await bounded.send()
        try await eventually { bounded.uncertain && !bounded.reconnecting }
        precondition(capped.streamCalls == 4 && capped.historyCalls == 4 && capped.startCalls == 1)
        bounded.disconnect()
        let cancelled = RecoveryService()
        cancelled.neverFinishes = true
        let detached = NativeChatModel(sessionID:"test",api:cancelled)
        await detached.load()
        detached.draft = "cancel recovery"
        await detached.send()
        try await eventually { detached.reconnecting }
        detached.disconnect()
        try await Task.sleep(nanoseconds:400_000_000)
        precondition(cancelled.streamCalls == 1 && cancelled.historyCalls == 1 && !detached.reconnecting)
        print("MODEL_PASS three GET retry bound; disconnect cancels reconnect")
        let stale = RecoveryService()
        let revised = NativeChatModel(sessionID:"test",api:stale)
        await revised.load()
        stale.holdHistory = true
        revised.draft = "stale GET"
        await revised.send()
        precondition(revised.transcript.messages.first?.timestamp != nil,"optimistic user message must have local timestamp")
        try await eventually { stale.pendingHistory != nil }
        revised.disconnect()
        stale.holdHistory = false
        stale.active = nil
        // The global admission scheduler intentionally retains the physical
        // GET slot until a non-cooperative transport actually returns.
        // Start the new load concurrently, then release the old mock GET;
        // awaiting the new load first creates a circular wait in this fixture.
        let previousCalls = stale.historyCalls
        let freshLoad = Task { await revised.load() }
        try await eventually { revised.loading || revised.syncing }
        precondition(stale.historyCalls == previousCalls,
                     "same-session GET must wait for the physical old request")
        stale.pendingHistory?.resume(returning:try ChatSnapshot(data:Data("{\"session_id\":\"test\",\"messages\":[],\"active_stream_id\":\"obsolete\",\"read_only\":true}".utf8)))
        stale.pendingHistory = nil
        await freshLoad.value
        precondition(stale.historyCalls == previousCalls + 1,
                     "waiting GET must acquire the released physical slot")
        try await Task.sleep(nanoseconds:80_000_000)
        precondition(revised.streamID == nil && !revised.running && !revised.readOnly && revised.transcript.messages.last?.content == "AB")
        revised.disconnect()
        print("MODEL_PASS stale GET cannot overwrite newer revision; optimistic message timestamp")
        let resumedService = RecoveryService()
        let resumed = NativeChatModel(sessionID:"test",api:resumedService)
        resumedService.inspect = { resumed.transcript }
        await resumed.load()
        resumed.draft = "resume stream"
        await resumed.send()
        try await eventually { resumedService.streamCalls == 1 }
        resumed.disconnect()
        await resumed.load()
        try await eventually { resumed.canSend }
        precondition(resumedService.cursors[1] == "s:1" && resumedService.startCalls == 1)
        resumedService.inspect = nil
        resumed.disconnect()
        print("MODEL_PASS disconnect/load same stream keeps cursor and text deduplication")
        // Two presentations of one Session must share a runtime. A late
        // disappear from the previous view cannot retire the replacement.
        let registry = ConversationRuntimeRegistry()
        let key = ConversationRuntimeRegistry.Key(instanceID: "a", accountScope: "b", sessionID: "test")
        let firstLease = UUID(), secondLease = UUID()
        let runtimeService = AcceptedPendingService()
        let runtime = registry.claim(key, presentation: firstLease) {
            NativeChatModel(sessionID: "test", api: runtimeService)
        }
        await runtime.load()
        runtime.draft = "accepted"
        let runtimePost = Task { await runtime.send() }
        try await eventually { runtimeService.pending != nil }
        registry.detach(key, presentation: firstLease)
        let reopened = registry.claim(key, presentation: secondLease) {
            fatalError("in-flight runtime must not be reconstructed")
        }
        precondition(reopened === runtime && reopened.submitting)
        registry.detach(key, presentation: firstLease)
        precondition(registry.owns(key, presentation: secondLease))
        precondition(!registry.mayWriteDraft(key, presentation: firstLease))
        precondition(registry.mayWriteDraft(key, presentation: secondLease))
        precondition(!registry.reattach(key, presentation: firstLease, model: runtime))
        registry.detach(key, presentation: secondLease)
        registry.pruneDetached(excluding: nil, limit: 0)
        precondition(registry.contains(key), "in-flight POST may not be evicted")
        precondition(registry.reattach(key, presentation: secondLease, model: runtime))
        let otherKey = ConversationRuntimeRegistry.Key(instanceID: "other", accountScope: "b", sessionID: "test")
        let otherLease = UUID()
        let other = registry.claim(otherKey, presentation: otherLease) {
            NativeChatModel(sessionID: "test", api: FakeChatService())
        }
        registry.detachScope(instanceID: "a", accountScope: "b")
        precondition(registry.contains(key) && !runtime.runtimeRetired)
        precondition(registry.owns(otherKey, presentation: otherLease))
        registry.retireScope(instanceID: "a", accountScope: "b")
        precondition(registry.contains(otherKey) && !other.runtimeRetired)
        runtimeService.accepted = true
        runtimeService.pending?.resume(returning: "accepted-stream")
        runtimeService.pending = nil
        _ = await runtimePost.value
        precondition(runtime.runtimeRetired && runtime.activeTurnRecovery == nil &&
            !registry.contains(key), "late POST cannot mutate a retired runtime")
        let recoveryKey = ConversationRuntimeRegistry.Key(instanceID: "cold", accountScope: "b", sessionID: "test")
        let recoveryService = FakeChatService()
        let cold = registry.restoreForRecovery(recoveryKey) {
            NativeChatModel(sessionID: "test", api: recoveryService)
        }!
        await cold.load()
        cold.draft = "never submit from recovery"
        let coldSent = await cold.send()
        precondition(!coldSent && recoveryService.startCalls == 0 && !cold.canSend)
        cold.resumeQueueAfterRecovery()
        precondition(cold.queueAutomaticDispatchPaused)
        let coldClaim = registry.claim(recoveryKey, presentation: UUID()) {
            fatalError("cold owner should be reused")
        }
        precondition(coldClaim === cold && !cold.recoveryOnly && cold.queueAutomaticDispatchPaused)
        registry.retireAll()
        print("MODEL_PASS runtime lease handoff, scope isolation, cold recovery no POST and retired POST fencing")

        let acceptedService = AcceptedPendingService()
        let acceptedModel = NativeChatModel(sessionID:"test",api:acceptedService)
        await acceptedModel.load()
        acceptedModel.draft = "accepted"
        let acceptedPost = Task { await acceptedModel.send() }
        try await eventually { acceptedService.pending != nil }
        acceptedModel.disconnect()
        await acceptedModel.load()
        acceptedService.accepted = true
        acceptedService.pending?.resume(returning:"accepted-stream")
        acceptedService.pending = nil
        _ = await acceptedPost.value
        precondition(acceptedModel.transcript.messages.contains { $0.id == "accepted-user" },"reentry before first event must restore accepted user message from history")
        acceptedModel.disconnect()
        print("MODEL_PASS late POST acceptance restores history before first event")
        let cursorlessService = CursorlessRecoveryService()
        let cursorless = NativeChatModel(sessionID:"test",api:cursorlessService)
        cursorlessService.inspect = { cursorless.transcript }
        await cursorless.load()
        cursorless.draft = "accepted"
        await cursorless.send()
        try await eventually { cursorlessService.secondStreamVerified }
        precondition(cursorlessService.startCalls == 1 && cursorlessService.cursors == [nil,nil])
        cursorless.disconnect()
        cursorlessService.inspect = nil
        print("MODEL_PASS EOF before first cursor recovers canonical accepted history without POST replay")
        for failStop in [false,true] {
            let staleStopService = DeferredStopService()
            let stopped = NativeChatModel(sessionID:"test",api:staleStopService)
            await stopped.load()
            let stopTask = Task { await stopped.stop() }
            try await eventually { staleStopService.pending != nil }
            stopped.disconnect()
            staleStopService.active = "new-stream"
            await stopped.load()
            precondition(stopped.stopping && stopped.streamID == "old-stream" && !stopped.canSend,
                         "a different active history alone cannot supersede an unconfirmed STOP")
            staleStopService.confirmsOldTerminal = true
            await stopped.load()
            if failStop { staleStopService.pending?.resume(throwing:URLError(.networkConnectionLost)) }
            else { staleStopService.pending?.resume(returning:()) }
            staleStopService.pending = nil
            await stopTask.value
            precondition(stopped.streamID == "new-stream" && stopped.running && !stopped.stopping)
            precondition(stopped.error == nil && staleStopService.historyCalls == 2)
            stopped.disconnect()
        }
        print("MODEL_PASS old stop success/error cannot overwrite a newer loaded stream")
        // ---- A09: AttachmentResetPolicy 四种组合 ----
        precondition(AttachmentResetPolicy.shouldReset(accepted:true, hasError:false, uncertain:false), "accepted and clean send resets attachments")
        precondition(!AttachmentResetPolicy.shouldReset(accepted:false, hasError:false, uncertain:false), "guard-rejected send keeps attachments")
        precondition(!AttachmentResetPolicy.shouldReset(accepted:true, hasError:true, uncertain:false), "failed send keeps attachments")
        precondition(!AttachmentResetPolicy.shouldReset(accepted:true, hasError:false, uncertain:true), "uncertain send keeps attachments")
        // ---- A09: send 返回 Bool ----
        let rejectedService = FakeChatService()
        let rejectedModel = NativeChatModel(sessionID:"test", api:rejectedService)
        await rejectedModel.load()
        let emptyAccepted = await rejectedModel.send()
        precondition(emptyAccepted == false && rejectedService.startCalls == 0, "empty draft without attachments is rejected and returns false")
        rejectedService.delayStart = true
        rejectedModel.draft = "in flight"
        let inflight = Task { await rejectedModel.send() }
        while rejectedService.startCalls < 1 { await Task.yield() }
        let busyAccepted = await rejectedModel.send()
        precondition(busyAccepted == false && rejectedService.startCalls == 1, "a send while a POST is in flight returns false")
        _ = await inflight.value
        rejectedService.delayStart = false
        rejectedService.active = nil
        rejectedService.historyRows = [
            ["id": "sent-user", "role": "user", "content": "in flight"],
            ["id": "sent-answer", "role": "assistant", "content": "completed"]
        ]
        await rejectedModel.refresh()
        precondition(rejectedModel.canSend && !rejectedModel.uncertain)
        rejectedModel.draft = "normal"
        let normalAccepted = await rejectedModel.send()
        precondition(normalAccepted == true, "an accepted send returns true")
        rejectedModel.disconnect()
        let unknownService = FakeChatService()
        unknownService.failStart = true
        let unknownModel = NativeChatModel(sessionID:"test", api:unknownService)
        await unknownModel.load()
        unknownModel.draft = "uncertain"
        let unknownAccepted = await unknownModel.send()
        precondition(unknownAccepted == true && unknownModel.uncertain, "a dispatched POST whose outcome is unknown still reports accepted")
        await unknownModel.refresh()
        precondition(unknownModel.canResendPending && !unknownModel.canSend && !unknownModel.uncertain,
                     "refresh settles absence but preserves the explicit retry/discard decision")
        unknownModel.disconnect()
        print("MODEL_PASS send reports accepted/rejected; attachment reset policy holds")
        // ---- A08: loadOlder 分页后 resumeForeground(preserveLoadedOlder) 不丢更早消息 ----
        let pageService = CachedHistoryService()
        pageService.deferHistory = false
        let pagedModel = NativeChatModel(sessionID:"cache", api:pageService)
        await pagedModel.load()
        precondition(pagedModel.olderOffset == 2 && pagedModel.transcript.messages.map(\.id) == ["fresh"])
        await pagedModel.loadOlder()
        precondition(pagedModel.transcript.messages.map(\.id) == ["older-0", "older-1", "fresh"], "loadOlder pages earlier rows in")
        pageService.deferHistory = true
        let foreground = Task { await pagedModel.resumeForeground() }
        try await eventually { pageService.pending != nil }
        pageService.pending?.resume(returning: try ChatSnapshot(data: Data(#"{"session_id":"cache","read_only":false,"_messages_offset":2,"messages":[{"id":"fresh","role":"assistant","content":"network history"}]}"#.utf8)))
        pageService.pending = nil
        await foreground.value
        precondition(pagedModel.transcript.messages.map(\.id) == ["older-0", "older-1", "fresh"], "resumeForeground must not discard older paged messages")
        // The foreground GET above consumed the deferred continuation; the
        // default-path refresh must not park on another one nobody resumes.
        pageService.deferHistory = false
        await pagedModel.refresh()
        precondition(pagedModel.transcript.messages.map(\.id) == ["fresh"], "default refresh path without preserveLoadedOlder is unchanged")
        pagedModel.disconnect()
        print("MODEL_PASS resumeForeground preserves loaded older pages")
    }

    @MainActor static func cacheTests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hermes-model-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(instanceID: UUID().uuidString, sessionID: "cache", accountScope: "test-account", rootDirectory: directory)
        let stale = try ChatSnapshot(data: Data("{\"session_id\":\"cache\",\"messages\":[{\"id\":\"cached\",\"role\":\"assistant\",\"content\":\"cached history\"}],\"active_stream_id\":\"old-stream\",\"model\":\"old-model\",\"_messages_offset\":2,\"output_tokens\":999,\"read_only\":false}".utf8))
        store.schedule(ChatHistoryRecord(snapshot: stale))
        await store.flush()
        let service = CachedHistoryService()
        let model = NativeChatModel(sessionID: "cache", api: service, historyStore: store)
        let loading = Task { await model.load() }
        try await eventually { service.pending != nil }
        precondition(model.cachedHistoryDate != nil && model.transcript.messages.first?.content == "cached history")
        precondition(!model.loading && model.syncing && model.readOnly && !model.canSend)
        precondition(model.streamID == nil && !model.running && service.cursors.isEmpty,
                     "a cached active stream must never be attached or unlock actions")
        model.draft = "do not send while offline"
        await model.send()
        await model.loadOlder()
        precondition(service.startCalls == 0 && service.historyCalls == 1)
        service.pending?.resume(throwing: URLError(.notConnectedToInternet))
        service.pending = nil
        await loading.value
        precondition(model.cachedHistoryDate != nil && model.error != nil && model.notice != nil && !model.canSend)
        precondition(model.transcript.messages.first?.content == "cached history", "offline errors must preserve readable cache")
        print("MODEL_PASS cached history appears before GET, stays read-only after offline failure")

        // build185: a freshly opened chat reads the confirmed local window
        // before network history starts. The same one-shot warmup is reused
        // by load(), without replaying an old run or granting send permission.
        let earlyService = CachedHistoryService()
        let earlyModel = NativeChatModel(sessionID: "cache", api: earlyService, historyStore: store)
        await earlyModel.warmupCachedHistory()
        precondition(earlyModel.cachedHistoryDate != nil &&
                     earlyModel.transcript.messages.map(\.id) == ["cached"] &&
                     earlyModel.readOnly && !earlyModel.canSend,
                     "prewarm paints only read-only confirmed history")
        precondition(earlyService.historyCalls == 0 && earlyService.startCalls == 0 &&
                     earlyModel.streamID == nil && earlyService.cursors.isEmpty,
                     "prewarm never issues GET/POST/stream or restores stale run identity")
        await earlyModel.warmupCachedHistory()
        precondition(earlyService.historyCalls == 0, "prewarm does not repeat remote I/O")
        let earlyLoad = Task { await earlyModel.load() }
        try await eventually { earlyService.pending != nil }
        precondition(earlyService.historyCalls == 1 &&
                     earlyModel.cachedHistoryDate != nil && earlyModel.syncing &&
                     earlyModel.transcript.messages.first?.id == "cached",
                     "remote GET preserves the painted cache until authority arrives")
        earlyService.pending?.resume(throwing: URLError(.notConnectedToInternet))
        earlyService.pending = nil
        await earlyLoad.value
        precondition(earlyModel.cachedHistoryDate != nil && !earlyModel.canSend,
                     "offline error keeps local content visible but send remains locked")
        earlyService.deferHistory = false
        await earlyModel.refresh()
        precondition(earlyModel.cachedHistoryDate == nil && earlyModel.canSend &&
                     earlyModel.transcript.messages.map(\.id) == ["fresh"],
                     "authoritative recovery replaces cached history and restores permission")
        earlyModel.disconnect()
        print("MODEL_PASS build185 early history paint, cached-only safety, authoritative replacement")

        service.deferHistory = false
        await model.refresh()
        precondition(model.cachedHistoryDate == nil && model.canSend && !model.readOnly)
        precondition(model.transcript.messages.map(\.id) == ["fresh"] && model.olderOffset == 2)
        precondition(model.sessionModel == nil && model.transcript.usage?.outputTokens == nil,
                     "network metadata must replace cached model/usage rather than retain stale values")
        await model.loadOlder()
        await store.flush()
        let paged = await store.load()
        precondition(paged?.messages.map(\.id) == ["older-0", "older-1", "fresh"] && paged?.olderOffset == 0)
        model.draft = "an optimistic row must remain memory-only"
        await model.send()
        await store.flush()
        let confirmedOnly = await store.load()
        precondition(model.transcript.messages.contains { $0.id.hasPrefix("local-") })
        precondition(confirmedOnly?.messages.contains { $0.id.hasPrefix("local-") } == false)
        model.disconnect()
        print("MODEL_PASS authoritative GET replaces cache, confirmed pagination persists, optimistic rows stay memory-only")

        let streamService = CachedHistoryService()
        streamService.deferHistory = false
        streamService.activeStream = "live-new"
        let resumed = NativeChatModel(sessionID: "cache", api: streamService, historyStore: store)
        await resumed.load()
        try await eventually { !streamService.cursors.isEmpty }
        precondition(streamService.cursors.count == 1 && streamService.cursors[0] == nil,
                     "cold restore must begin an authoritative active stream without a cached event cursor")
        precondition(resumed.running && resumed.streamID == "live-new" && resumed.cachedHistoryDate == nil && !resumed.canSend)
        resumed.disconnect()
        print("MODEL_PASS only current GET can attach a stream and its first SSE cursor is nil")

        let longStore = ChatHistoryStore(instanceID: UUID().uuidString, sessionID: "long-cache", accountScope: "test-account", rootDirectory: directory)
        let longMessages = (0..<100).map { ["id": "long-\($0)", "role": "assistant", "content": "message \($0)"] }
        let longSnapshot = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session_id": "long-cache", "_messages_offset": 20, "messages": longMessages]))
        var longRecord = ChatHistoryRecord(snapshot: longSnapshot)
        longRecord.tools = [ChatTool(id: "hidden", name: "search", args: "", result: "old", done: true, isError: false, afterMessageID: "long-0"),
                            ChatTool(id: "visible", name: "search", args: "", result: "recent", done: true, isError: false, afterMessageID: "long-99")]
        longStore.schedule(longRecord)
        await longStore.flush()
        let longService = CachedHistoryService()
        let longModel = NativeChatModel(sessionID: "long-cache", api: longService, historyStore: longStore)
        let longLoading = Task { await longModel.load() }
        try await eventually { longService.pending != nil }
        precondition(longModel.transcript.messages.count == 60 && longModel.transcript.messages.first?.id == "long-40")
        precondition(longModel.transcript.tools.map(\.id) == ["visible"] && longModel.olderOffset == 60)
        let fullDiskRecord = await longStore.load()
        precondition(fullDiskRecord?.messages.count == 100, "bounded first display must not discard the larger disk snapshot")
        longService.pending?.resume(throwing: URLError(.notConnectedToInternet))
        longService.pending = nil
        await longLoading.value
        longModel.disconnect()
        print("MODEL_PASS cold-cache display work is capped at 60 rows with safe raw pagination indices")

        let authService = CachedHistoryService()
        let protected = NativeChatModel(sessionID: "cache", api: authService, historyStore: store)
        var authenticationCalls = 0
        protected.onAuthenticationRequired = { authenticationCalls += 1 }
        let authLoading = Task { await protected.load() }
        try await eventually { authService.pending != nil }
        precondition(protected.cachedHistoryDate != nil)
        authService.pending?.resume(throwing: CacheTestError.unauthorized)
        authService.pending = nil
        await authLoading.value
        precondition(authenticationCalls == 1 && protected.transcript.messages.isEmpty && protected.cachedHistoryDate == nil)
        precondition(protected.readOnly && !protected.canSend && protected.streamID == nil)
        protected.disconnect()
        let streamAuth = CachedHistoryService()
        streamAuth.deferHistory = false
        streamAuth.activeStream = "auth-expired"
        streamAuth.failStreamWithAuthentication = true
        let streamProtected = NativeChatModel(sessionID: "cache", api: streamAuth)
        streamProtected.onAuthenticationRequired = { authenticationCalls += 1 }
        await streamProtected.load()
        try await eventually { authenticationCalls == 2 }
        precondition(streamAuth.historyCalls == 1 && streamAuth.cursors.count == 1,
                     "a 401 stream response must terminate without GET reconnect retries")
        precondition(streamProtected.transcript.messages.isEmpty && !streamProtected.canSend && !streamProtected.reconnecting)
        streamProtected.disconnect()
        print("MODEL_PASS authentication expiry clears displayed cache, reports once and stops stream recovery")
    }
}

enum CacheTestError: Error { case unauthorized }

@MainActor final class CachedHistoryService: NativeChatService {
    var deferHistory = true
    var pending: CheckedContinuation<ChatSnapshot, Error>?
    var historyCalls = 0
    var startCalls = 0
    var activeStream: String?
    var cursors: [String?] = []
    var failStreamWithAuthentication = false
    func requiresAuthentication(after error: Error) -> Bool { error is CacheTestError }
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        if deferHistory { return try await withCheckedThrowingContinuation { pending = $0 } }
        var fields: [String: Any] = ["session_id": sessionID, "read_only": false,
            "_messages_offset": before == nil ? 2 : 0,
            "messages": before == nil ? [["id": "fresh", "role": "assistant", "content": "network history"]]
                : [["id": "older-0", "role": "user", "content": "older question"],
                   ["id": "older-1", "role": "assistant", "content": "older answer"]]]
        if let activeStream { fields["active_stream_id"] = activeStream }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: fields))
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        startCalls += 1
        activeStream = "accepted"
        return "accepted"
    }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
        cursors.append(lastEventID)
        if failStreamWithAuthentication { throw CacheTestError.unauthorized }
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
    func stopNativeTurn(streamID: String) async throws { activeStream = nil }
}

@MainActor final class BurstService:NativeChatService {
    var inspect:(() -> ChatTranscript)?
    var streaming = false
    var checked = false
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot {
        if streaming { throw URLError(.timedOut) }
        return try ChatSnapshot(data:Data("{\"session_id\":\"test\",\"messages\":[],\"read_only\":false}".utf8))
    }
    func startNativeTurn(sessionID:String,text:String) async throws -> String { "burst" }
    func stopNativeTurn(streamID:String) async throws {}
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws {
        streaming = true
        let before = transcriptPublications
        for index in 0..<1000 {
            _ = try await onFrame(SSEFrame(event:"token",data:"{\"text\":\"x\"}",id:"b:\(index)"))
        }
        precondition(transcriptPublications - before < 10,"burst must not publish once per token")
        try await Task.sleep(nanoseconds:70_000_000)
        precondition(inspect?().messages.last?.content.count == 1000,"live buffer must publish within 50ms")
        _ = try await onFrame(SSEFrame(event:"token",data:"{\"text\":\"x\"}",id:"b:1000"))
        _ = try await onFrame(SSEFrame(event:"stream_end",data:"{}",id:"b:1001"))
        precondition(inspect?().terminal == true && inspect?().messages.last?.content.count == 1001,"terminal must flush immediately")
        checked = true
    }
}

@MainActor final class RecoveryService:NativeChatService {
    var startCalls = 0
    var streamCalls = 0
    var historyCalls = 0
    var cursors:[String?] = []
    var active:String?
    var lastSubmittedText: String?
    var throwsOnDisconnect = false
    var neverFinishes = false
    var holdHistory = false
    var pendingHistory:CheckedContinuation<ChatSnapshot,Error>?
    var inspect:(() -> ChatTranscript)?
    /// P0：恢复 GET 返回「无 active stream 且历史里没有任何 assistant 消息」。
    /// 模拟服务端仍在跑、只是这次 GET 没给出活跃 id 的瞬时不一致。
    var historyWithoutAnswer = false
    /// P0：断线时服务端把 run 摘掉（`active` 归 nil），但历史里还没有终态。
    /// 这是「无 active stream 也无法证实已结束」的真实场景。
    var dropsActiveOnDisconnect = false
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        let includeAnswer = active == nil && streamCalls > 0 && !historyWithoutAnswer
        // Final history must contain the accepted user row as well as its
        // reply. A mock that returns only "AB" cannot prove which POST
        // produced it and must not unlock a real recovered Run.
        let completedRows: [[String: Any]] = [
            ["id": "sent-user", "role": "user", "content": lastSubmittedText ?? ""],
            ["id": "answer", "role": "assistant", "content": "AB"]
        ]
        var s:[String:Any] = ["session_id":sessionID,
                              "messages":includeAnswer ? completedRows : [],
                              "read_only":false]
        if let active { s["active_stream_id"] = active }
        let snapshot = try ChatSnapshot(data:JSONSerialization.data(withJSONObject:["session":s]))
        if holdHistory {
            return try await withCheckedThrowingContinuation { pendingHistory = $0 }
        }
        return snapshot
    }
    func startNativeTurn(sessionID:String,text:String) async throws -> String {
        startCalls += 1
        lastSubmittedText = text
        active = "s"
        return "s"
    }
    func stopNativeTurn(streamID:String) async throws { active = nil }
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws {
        streamCalls += 1
        cursors.append(lastEventID)
        if neverFinishes { return }
        _ = try await onFrame(SSEFrame(event:"token",data:"{\"text\":\"A\"}",id:"s:1"))
        if streamCalls == 1 {
            if throwsOnDisconnect {
                // 服务端此刻已经把这个 run 摘掉，但历史里没有终态记录。
                if dropsActiveOnDisconnect { active = nil }
                throw URLError(.networkConnectionLost)
            }
            return
        }
        _ = try await onFrame(SSEFrame(event:"token",data:"{\"text\":\"B\"}",id:"s:2"))
        try await Task.sleep(nanoseconds:70_000_000)
        if let inspect {
            precondition(inspect().messages.last?.content == "AB","replayed frames must not duplicate in-memory text before history reconciliation")
        }
        active = nil
        _ = try await onFrame(SSEFrame(event:"stream_end",data:"{\"status\":\"completed\"}",id:"s:3"))
    }
}

@MainActor final class CursorlessRecoveryService: NativeChatService {
    var startCalls = 0
    var streamCalls = 0
    var active = false
    var cursors: [String?] = []
    var secondStreamVerified = false
    var inspect: (() -> ChatTranscript)?
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot {
        var s: [String:Any] = ["session_id":sessionID,"messages":[],"read_only":false]
        if active {
            s["active_stream_id"] = "cursorless"
            s["messages"] = [["id":"canonical-user","role":"user","content":"accepted"]]
        }
        return try ChatSnapshot(data:JSONSerialization.data(withJSONObject:["session":s]))
    }
    func startNativeTurn(sessionID:String,text:String) async throws -> String {
        startCalls += 1
        active = true
        return "cursorless"
    }
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws {
        streamCalls += 1
        cursors.append(lastEventID)
        if streamCalls == 1 { return }
        precondition(inspect?().messages.contains(where: { $0.id == "canonical-user" }) == true)
        secondStreamVerified = true
        try await Task.sleep(nanoseconds:30_000_000_000)
    }
    func stopNativeTurn(streamID:String) async throws {}
}

@MainActor final class DeferredStopService: NativeChatService {
    var active = "old-stream"
    var historyCalls = 0
    var pending: CheckedContinuation<Void,Error>?
    var confirmsOldTerminal = false
    func probeActiveRun(sessionID: String, runID: String) async throws -> ActiveRunProbe {
        if runID == "old-stream" && confirmsOldTerminal { return .terminal(.cancelled) }
        return .unknown
    }
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        let s: [String:Any] = ["session_id":sessionID,"messages":[],"read_only":false,"active_stream_id":active]
        return try ChatSnapshot(data:JSONSerialization.data(withJSONObject:["session":s]))
    }
    func startNativeTurn(sessionID:String,text:String) async throws -> String { active }
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws {
        try await Task.sleep(nanoseconds:30_000_000_000)
    }
    func stopNativeTurn(streamID:String) async throws {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
}


// Q205-04: a non-cooperative transport may complete after disconnect,
// authentication expiry or a newer phase has taken ownership. No live server.
@MainActor final class RetiredPostTestService: NativeChatService {
    var pending: CheckedContinuation<String, Error>?
    var startCalls = 0
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        let session: [String: Any] = ["session_id": sessionID,
                                      "messages": [], "read_only": false]
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject:
            ["session": session]))
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        startCalls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func stopNativeTurn(streamID: String) async throws {}
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
}

@MainActor func testRetiredPostCompletions() async throws {
    for accepted in [true, false] {
        let service = RetiredPostTestService()
        let model = NativeChatModel(sessionID: "late-post-auth", api: service)
        await model.load()
        model.draft = "old request"
        let request = Task { await model.send() }
        try await ModelTests.eventually { service.pending != nil }
        let oldPendingID = model.pendingSend?.id
        model.disconnect()
        // The authenticated presentation has retired this generation.
        model.transition(to: .needsLogin)
        model.draft = "new unsent draft"
        let continuation = service.pending!
        service.pending = nil
        if accepted { continuation.resume(returning: "old-run") }
        else { continuation.resume(throwing: URLError(.networkConnectionLost)) }
        _ = await request.value
        precondition(model.phase == .needsLogin && model.streamID == nil,
                     "retired POST cannot clear a newer authentication phase")
        precondition(model.draft == "new unsent draft",
                     "retired POST cannot delete a newer draft")
        precondition(model.pendingSend?.id == oldPendingID && oldPendingID != nil,
                     "retired POST retains pre-POST evidence for GET reconciliation")
        precondition(service.startCalls == 1 && !model.canSend,
                     "retired callback must not unlock or replay POST")
        model.disconnect()
    }
    for accepted in [true, false] {
        let service = RetiredPostTestService()
        let model = NativeChatModel(sessionID: "late-post-new-run", api: service)
        await model.load()
        model.draft = "old request"
        let request = Task { await model.send() }
        try await ModelTests.eventually { service.pending != nil }
        model.disconnect()
        model.suspended = false
        // Inject the new generation/phase explicitly; callbacks arriving
        // late must not touch current stream identity even if uncancellable.
        model.streamID = "current-run"
        model.transition(to: .streaming(connected: true))
        model.draft = "new draft"
        let continuation = service.pending!
        service.pending = nil
        if accepted { continuation.resume(returning: "obsolete-run") }
        else { continuation.resume(throwing: URLError(.timedOut)) }
        _ = await request.value
        precondition(model.phase == .streaming(connected: true)
                     && model.streamID == "current-run",
                     "retired POST cannot detach an unrelated active run")
        precondition(model.draft == "new draft" && service.startCalls == 1,
                     "retired callback cannot reset current composer or resubmit")
        model.disconnect()
    }
    // Even a successfully accepted but retired queued POST must keep its
    // durable queue evidence and require read-only reconciliation.
    do {
        let service = RetiredPostTestService()
        let model = NativeChatModel(sessionID: "late-queued-post", api: service)
        await model.load()
        let queued = ChatQueuedTurn(id: "queued-late", text: "pending",
            attachments: [], composerText: "pending", origin: .userInput,
            automaticAfterStreamID: nil)
        model.setQueuedTurns([queued])
        let dispatch = Task { await model.flushQueuedIfNeeded() }
        try await ModelTests.eventually { service.pending != nil }
        model.disconnect()
        model.transition(to: .needsLogin)
        let continuation = service.pending!
        service.pending = nil
        continuation.resume(returning: "accepted-but-retired")
        _ = await dispatch.value
        precondition(model.queuedTurns.first?.id == queued.id
                     && model.queuedTurns.first?.delivery == .uncertain,
                     "late acceptance must not erase the queue's delivery evidence")
        precondition(service.startCalls == 1 && !model.canSend,
                     "retired queue must remain locked until explicit reconciliation")
        model.disconnect()
    }
    print("MODEL_PASS delayed POST success/failure cannot mutate new auth or run")
}
