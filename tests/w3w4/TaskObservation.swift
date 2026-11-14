// Compiled with existing AppState test fixtures and the exact production
// recordTaskSignals() method extracted into a headless view harness by run.py.
// This checks the record/clear path, NOT SwiftUI onChange scheduling.
@main struct ObservationTests {
    @MainActor static func main() async throws {
        let instance = HermesInstance(name: "Offline W3", baseURL: "https://w3-offline.invalid")
        let credentials = MemoryInstanceCredentials()
        try InstanceStore.save([instance], credentials: credentials)
        InstanceStore.activeID = instance.id
        let app = AppState(credentials: credentials)
        let sessionID = "offline-w3-observation"
        app.sessions = [.placeholder(id: sessionID)]
        let instanceID = app.historyInstanceID, account = app.historyAccountScope
        defer { SessionTaskStore.remove(instanceID: instanceID, accountScope: account) }
        let api = RaceService()
        api.active = nil
        let old = NativeChatModel(sessionID: sessionID, api: api)
        defer { old.disconnect() }
        await old.resumeForeground()
        api.recoveryUnavailable = true
        old.noteRunRecoveryState()
        let view = ObservationHarness(model: old, app: app, sessionID: sessionID)
        view.observe()
        precondition(app.sessionTaskObservations[sessionID]?.signals == [.recoveryIssue])
        api.recoveryUnavailable = false
        old.noteRunRecoveryState()
        await old.resumeForeground()
        view.observe()
        precondition(app.sessionTaskObservations[sessionID]?.signals == [.recoveryIssue],
                     "same-model page sticky warning must remain an attention record")
        let fresh = NativeChatModel(sessionID: sessionID, api: api)
        defer { fresh.disconnect() }
        await fresh.resumeForeground()
        ObservationHarness(model: fresh, app: app, sessionID: sessionID).observe()
        precondition(app.sessionTaskObservations[sessionID] == nil,
                     "healthy new model's actual view observer clears old attention state")
        precondition(app.sessionTaskSummaries.isEmpty)
        precondition(SessionTaskStore.load(instanceID: instanceID, accountScope: account)[sessionID] == nil,
                     "clear must reach persisted task store")
        app.setSessionTaskSignals([.waitingForApproval, .needsVerification, .stopping], for: sessionID)
        ObservationHarness(model: fresh, app: app, sessionID: sessionID).observe()
        precondition(app.sessionTaskObservations[sessionID] == nil,
                     "fresh canonical idle observation clears old approval/verification/stopping facts")
        precondition(api.startCalls == 0 && api.stopCalls == 0 && api.approvalCalls == 0,
                     "observing/clearing task state never sends a command")
        print("W3_OBSERVATION_PASS same-model stickiness; new-model observation clears memory and store; no mark-handled action; no POST")
    }
}
