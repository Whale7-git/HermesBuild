import Foundation

/// The app, not the user, owns bounded GET-only status reconciliation.
/// Test the actual NativeChatModel task against a deterministic fake gateway.
extension ModelTests {
    @MainActor static func automaticReconciliationTests() async throws {
        let service = ActivityRecoveryService()
        let model = NativeChatModel(sessionID: "activity", api: service)
        precondition(model.automaticReconciliationDelay(attempt: 0, failures: 0) == 1_000_000_000)
        precondition(model.automaticReconciliationDelay(attempt: 10_000, failures: 0) == 3_000_000_000,
                     "healthy long-running recovery must stay responsive")
        precondition(model.automaticReconciliationDelay(attempt: 10, failures: 99) == 60_000_000_000)
        model.setRecoveryPresentationVisible(false)
        precondition(model.automaticReconciliationDelay(attempt: 10, failures: 0) == 10_000_000_000)
        model.unavailableRunStatusID = "missing"
        precondition(model.automaticReconciliationDelay(attempt: 10, failures: 0) == 20_000_000_000)
        model.unavailableRunStatusID = nil
        model.setRecoveryPresentationVisible(true)
        model.automaticReconciliationSteadyNanoseconds = 4_000_000
        model.automaticReconciliationDelaysNanoseconds = [
            1_000_000, 2_000_000, 4_000_000
        ]

        // Failure during the initial history GET is not permission to POST.
        service.failHistory = true
        await model.load()
        precondition(model.uncertain && !model.canSend)
        let firstCalls = service.historyCalls
        service.failHistory = false
        model.scheduleAutomaticReconciliation()
        let recovery = model.automaticReconciliationTask
        precondition(recovery != nil, "visible uncertain chat schedules its own GET")
        await recovery?.value
        precondition(service.historyCalls > firstCalls,
                     "automatic reconciliation must actually read history")
        precondition(!model.uncertain && model.canSend && service.postCalls == 0,
                     "canonical GET clears transient error without submitting a POST")
        precondition(model.automaticReconciliationTask == nil,
                     "completed reconciliation releases its single-flight owner")
        model.disconnect()

        // A persistent outage continues beyond the fast retry window and
        // never unlocks or replays. A later successful GET recovers it.
        let outage = ActivityRecoveryService()
        outage.failHistory = true
        let locked = NativeChatModel(sessionID: "activity", api: outage)
        locked.automaticReconciliationDelaysNanoseconds = [
            1_000_000, 2_000_000, 4_000_000
        ]
        locked.automaticReconciliationSteadyNanoseconds = 4_000_000
         await locked.load()
        locked.scheduleAutomaticReconciliation()
        try await eventually { outage.historyCalls >= 5 }
        precondition(outage.postCalls == 0 && locked.uncertain && !locked.canSend,
                     "after the fast window, keep the lock and continue read-only recovery")
        outage.failHistory = false
        try await eventually { !locked.uncertain && locked.canSend }
        precondition(outage.postCalls == 0, "steady retry resolves without POST")
        locked.disconnect()

        let cancelService = ActivityRecoveryService()
        cancelService.failHistory = true
        let cancelled = NativeChatModel(sessionID: "activity", api: cancelService)
        cancelled.automaticReconciliationDelaysNanoseconds = [2_000_000_000]
        await cancelled.load()
        cancelled.scheduleAutomaticReconciliation()
        let initialCalls = cancelService.historyCalls
        cancelled.disconnect()
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(cancelService.historyCalls == initialCalls &&
                     cancelled.automaticReconciliationTask == nil,
                     "leaving chat cancels retries without cross-session GETs")

        // A known missing POST is a user-choice boundary. The app must not
        // re-submit it merely because a timer or foreground refresh fired.
        let absent = FakeChatService()
        let noResend = NativeChatModel(sessionID: "test", api: absent)
        await noResend.load()
        noResend.draft = "please answer"
        absent.failStart = true
        _ = await noResend.send()
        precondition(absent.startCalls == 1 && noResend.pendingSend != nil)
        await noResend.refresh()
        precondition(noResend.pendingAbsent && noResend.canResendPending,
                     "authoritative absence leaves resend as an explicit choice")
        noResend.scheduleAutomaticReconciliation()
        precondition(noResend.automaticReconciliationTask == nil &&
                     absent.startCalls == 1,
                     "automatic worker must not resend a proven absent POST")
        noResend.disconnect()
        print("MODEL_PASS automatic read-only recovery, steady outage recovery and cancellation")
    }
}
