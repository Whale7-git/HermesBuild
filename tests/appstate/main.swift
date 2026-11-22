import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if !canImport(SwiftUI)
protocol ObservableObject:AnyObject {}
enum PublicationProbe { static var assignments = 0 }
@propertyWrapper struct Published<Value> {
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { value }
        set { PublicationProbe.assignments += 1; value = newValue }
    }
}
extension Array { mutating func remove(atOffsets indexes:IndexSet) { for i in indexes.sorted(by:>) { remove(at:i) } } }
#endif
enum APIError:Error { case http(Int,String) }
final class MemoryInstanceCredentials: InstanceCredentialStorage {
    var values: [String: String] = [:]
    var failWrites = false
    var failReads = false
    func read(reference: String) throws -> String? {
        if failReads { throw URLError(.userAuthenticationRequired) }
        return values[reference]
    }
    func write(_ value: String, reference: String) throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        values[reference] = value
    }
    func remove(reference: String) throws { values.removeValue(forKey: reference) }
}
func expectUnified(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
@MainActor final class RecordingTaskNotifier: TaskNotificationDelivering {
    private(set) var delivered: [TaskNotification] = []
    private(set) var removed: [String] = []
    private(set) var authorizationRequests = 0
    var status: TaskNotificationAuthorization = .authorized
    func deliver(_ notification: TaskNotification, sound: Bool) async {
        delivered.append(notification)
    }
    func authorizationStatus() async -> TaskNotificationAuthorization { status }
    func requestAuthorization() async -> TaskNotificationAuthorization {
        authorizationRequests += 1
        status = .authorized
        return status
    }
    func remove(identifier: String) async { removed.append(identifier) }
}
@MainActor final class HermesAPI {
    static var createEntered = false
    static var holdCreates = false
    static var pendingCreate: CheckedContinuation<String, Error>?
    static var nextCreateID = "created-fixture"
    static var confirmedModelHistory = false
    static var modelHistoryOverride: [String: Any]? = nil
    static var modelHistoryError: Error? = nil
    static var holdModelHistory = false
    static var pendingModelHistory: CheckedContinuation<ChatSnapshot, Error>? = nil
    static var modelHistoryCalls = 0
    static var listEntered = false
    static var capabilitiesOverride: BackendCapabilities?
    static var authCalls = 0
    static var authLoggedIn = true
    static var authError: Error?
    static var heldLists = Set<String>()
    static var listCalls: [String: Int] = [:]
    static var pendingLists: [String: CheckedContinuation<[SessionSummary], Error>] = [:]
    static var listDelayNanoseconds: UInt64 = 0
    static var listError: Error?
    let baseURL:String
    init(baseURL:String) { self.baseURL = baseURL }
    func syncCookiesFromWebKit() async {}
    /// AppState 在账号退役时按域清 cookie；测试替身只需可调用。
    func clearCookies() {}
    func authStatus() async throws -> AuthStatus {
        Self.authCalls += 1
        if let error = Self.authError { throw error }
        return AuthStatus(authEnabled:true,loggedIn:Self.authLoggedIn,passwordAuthEnabled:true)
    }
    func sessions() async throws -> [SessionSummary] {
        Self.listCalls[baseURL, default: 0] += 1
        if Self.heldLists.contains(baseURL) {
            return try await withCheckedThrowingContinuation { Self.pendingLists[baseURL] = $0 }
        }
        if let error = Self.listError { throw error }
        if Self.listDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: Self.listDelayNanoseconds)
        }
        if baseURL.contains("a.example") {
            Self.listEntered = true
            try await Task.sleep(nanoseconds:120_000_000)
        }
        return [try JSONDecoder().decode(SessionSummary.self,from:Data("{\"session_id\":\"\(baseURL.contains("a.example") ? "A" : "B")\",\"title\":\"test\"}".utf8))]
    }
    func login(password:String) async throws {}
    func createNativeSession() async throws -> String {
        Self.createEntered = true
        if Self.holdCreates {
            return try await withCheckedThrowingContinuation { Self.pendingCreate = $0 }
        }
        try await Task.sleep(nanoseconds:100_000_000)
        return baseURL.contains("a.example") ? "A-created" : "B-created"
    }
    // 会话与模型管理：本测试只验证 AppState 的本地状态迁移，网络层用最小替身。
    static var lastModelSet:(String,String?,String)? = nil
    static var lastRename:(String,String)? = nil
    static var lastPin:(String,Bool)? = nil
    static var lastArchive:String? = nil
    static var lastDelete:String? = nil
    static var holdDeletes = false
    static var pendingDelete: CheckedContinuation<Void, Error>?
    static var deleteCalls: [(String, String)] = []
    // A01: rename 在途挂起，沿用 pendingLists 的 continuation 模式，验证切实例后旧写回被拒绝。
    static var holdRenames = false
    static var pendingRename: CheckedContinuation<Void, Error>? = nil
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        Self.modelHistoryCalls += 1
        if Self.holdModelHistory {
            return try await withCheckedThrowingContinuation {
                Self.pendingModelHistory = $0
            }
        }
        if let error = Self.modelHistoryError { throw error }
        if let response = Self.modelHistoryOverride {
            return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: response))
        }
        if Self.confirmedModelHistory, let selected = Self.lastModelSet {
            let payload: [String: Any] = ["session_id": sessionID, "messages": [],
                "model": selected.2, "model_provider": selected.1 ?? NSNull()]
            return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: payload))
        }
        return try ChatSnapshot(data: Data("{\"session_id\":\"test\",\"messages\":[]}".utf8))
    }
    func availableModels() async throws -> ModelCatalog {
        try ModelCatalog(data: Data(#"{"groups":[{"provider":"p","provider_id":"custom:p","models":[{"id":"m1","label":"M1"}]}]}"#.utf8))
    }
    func setSessionModel(sessionID:String, model:String, provider:String?) async throws {
        Self.lastModelSet = (sessionID, provider, model)
    }
    func renameSession(sessionID:String, title:String) async throws {
        if Self.holdRenames { try await withCheckedThrowingContinuation { Self.pendingRename = $0 } }
        Self.lastRename = (sessionID, title)
    }
    func setSessionPinned(sessionID:String, pinned:Bool) async throws { Self.lastPin = (sessionID, pinned) }
    func setSessionArchived(sessionID:String, archived:Bool) async throws { Self.lastArchive = sessionID }
    func deleteSession(sessionID:String) async throws {
        Self.deleteCalls.append((baseURL, sessionID))
        if Self.holdDeletes { try await withCheckedThrowingContinuation { Self.pendingDelete = $0 } }
        Self.lastDelete = sessionID
    }
    func branchSession(sessionID:String, keepCount:Int?, title:String?) async throws -> String { "branched" }
}
@main struct AppStateTests {
    static let credentials = MemoryInstanceCredentials()
    @MainActor static func firstLaunchSetupTests() async throws {
        let defaults = UserDefaults.standard
        let keys = ["hermes.instances", "hermes.activeInstance", "hermes.credentials.pendingCleanup.v1"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        let storage = MemoryInstanceCredentials()
        let model = AppState(credentials: storage)
        let placeholderID = model.active.id
        let calls = HermesAPI.authCalls
        let lists = HermesAPI.listCalls
        await model.refresh()
        precondition(model.needsInstanceSetup && model.active.baseURL.isEmpty,
                     "first launch must not select any preset host")
        precondition(HermesAPI.authCalls == calls && HermesAPI.listCalls == lists,
                     "setup state must not attempt authentication or session requests")
        precondition(model.errorText == AppState.unconfiguredInstanceMessage && !model.needsLogin,
                     "setup prompts for configuration rather than a login or DNS failure")

        storage.failWrites = true
        let failed = model.addInstance(name: "Mine", url: "https://setup.example",
                                       backend: .gateway, apiKey: "setup-fixture")
        guard case .failure = failed else { preconditionFailure("secure write failure must reject setup") }
        precondition(model.active.id == placeholderID && model.needsInstanceSetup,
                     "failed setup preserves the inert record for retry")
        storage.failWrites = false
        let added = model.addInstance(name: "Mine", url: "https://setup.example",
                                      backend: .gateway, apiKey: "setup-fixture")
        guard case .success = added else { preconditionFailure("valid setup must save") }
        precondition(model.instances.count == 1 && model.active.id != placeholderID,
                     "first configured instance replaces the placeholder")
        precondition(!model.needsInstanceSetup && model.active.name == "Mine",
                     "successful setup activates the user's own instance")
        let restored = AppState(credentials: storage)
        precondition(restored.active.id == model.active.id && restored.active.apiKey == "setup-fixture",
                     "relaunch preserves the configured instance and its Keychain reference")
        await model.refresh()

        defaults.set(Data("broken metadata".utf8), forKey: "hermes.instances")
        let damaged = AppState(credentials: storage)
        let damagedCalls = HermesAPI.authCalls
        let damagedLists = HermesAPI.listCalls
        await damaged.refresh()
        precondition(damaged.needsInstanceSetup && damaged.errorText != nil,
                     "corrupt metadata requires explicit repair without choosing a host")
        precondition(HermesAPI.authCalls == damagedCalls && HermesAPI.listCalls == damagedLists,
                     "corrupt metadata never triggers a network fallback")
        print("FIRST_LAUNCH_SETUP_PASS no preset host, retry, persistence and corrupt recovery")
    }
    @MainActor static func spin(_ predicate: () -> Bool, file: StaticString = #fileID, line: UInt = #line) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard clock.now < deadline else {
                preconditionFailure("controlled request did not reach expected state within 3s", file: file, line: line)
            }
            // A count of Task.yield calls is not an elapsed-time budget and
            // can expire before a different executor gets scheduled.
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { preconditionFailure("controlled request wait cancelled", file: file, line: line) }
        }
    }

    @MainActor static func homeCreateNavigationTests() async throws {
        let old = HermesInstance(name: "Create A", baseURL: "https://create-a.example")
        let other = HermesInstance(name: "Create B", baseURL: "https://create-b.example")
        try InstanceStore.save([old, other], credentials: credentials)
        InstanceStore.activeID = old.id

        let app = AppState(credentials: credentials)
        HermesAPI.holdCreates = true
        defer { HermesAPI.holdCreates = false; HermesAPI.pendingCreate = nil }

        // User navigates into an existing Session during a remote create.
        let request = Task { await app.createSessionForHomeTurn("old turn", model: nil) }
        await spin { HermesAPI.pendingCreate != nil }
        app.openSession(.placeholder(id: "existing"))
        HermesAPI.pendingCreate?.resume(returning: "late-known-session")
        HermesAPI.pendingCreate = nil
        let requestAccepted = await request.value
        precondition(!requestAccepted, "stale home create cannot own navigation")
        precondition(app.currentSessionID == "existing",
                     "explicit openSession outranks late create response")
        precondition(CreatedSessionRecoveryStore.known(
            instanceID: app.historyInstanceID, accountScope: app.historyAccountScope)
            .contains("late-known-session"), "known late SID retained for recovery")
        precondition(app.sessions.contains { $0.sessionId == "late-known-session" },
                     "known orphan remains visible without switching current page")

        // User navigates back to the empty home while creation is pending.
        let closeRequest = Task { await app.createSessionForHomeTurn("second turn", model: nil) }
        await spin { HermesAPI.pendingCreate != nil }
        app.closeSession()
        HermesAPI.pendingCreate?.resume(returning: "late-after-close")
        HermesAPI.pendingCreate = nil
        let closeAccepted = await closeRequest.value
        precondition(!closeAccepted && app.currentSessionID == nil,
                     "closeSession invalidates pending create navigation")

        // Switching account scope/instance must not insert an old host's SID
        // into the newly active host's view.
        let scopeAID = app.historyInstanceID, scopeAAccount = app.historyAccountScope
        let switchRequest = Task { await app.createSessionForHomeTurn("third turn", model: nil) }
        await spin { HermesAPI.pendingCreate != nil }
        app.switchTo(1)
        HermesAPI.pendingCreate?.resume(returning: "old-host-only")
        HermesAPI.pendingCreate = nil
        let switchAccepted = await switchRequest.value
        precondition(!switchAccepted,
                     "scope change invalidates stale response")
        precondition(app.currentSessionID != "old-host-only"
                     && !app.sessions.contains(where: { $0.sessionId == "old-host-only" }),
                     "old instance SID never appears in current instance")
        precondition(CreatedSessionRecoveryStore.known(
            instanceID: scopeAID, accountScope: scopeAAccount).contains("old-host-only"),
            "old instance SID remains recorded only under its originating scope")
        print("HOME_NAVIGATION_PASS open, close and cross-instance late-response ownership")
    }

    @MainActor static func webUIHomeModelTests() async throws {
        let host = HermesInstance(name: "WebUI model test", baseURL: "https://model-home.example")
        try InstanceStore.save([host], credentials: credentials)
        InstanceStore.activeID = host.id
        let app = AppState(credentials: credentials)
        await app.loadModels()
        guard let option = app.modelCatalog?.options.first else {
            preconditionFailure("fixture model catalog unavailable")
        }
        HermesAPI.lastModelSet = nil
        HermesAPI.confirmedModelHistory = true
        let ok = await app.createSessionForHomeTurn("model first", model: option)
        precondition(ok, "WebUI selected model should create verified session")
        precondition(HermesAPI.lastModelSet?.1 == option.providerID
            && HermesAPI.lastModelSet?.2 == option.model,
            "model and provider must reach WebUI session-update request")
        precondition(app.consumeHomeTurn(for: app.currentSessionID!) == "model first",
                     "only verified model transition arms automatic first POST")
        let sid = app.currentSessionID!
        app.closeSession()
        HermesAPI.modelHistoryOverride = [
            "session_id": sid, "messages": [], "model": option.model,
            "model_provider": "other-provider"]
        let rejected = await app.createSessionForHomeTurn("do not send", model: option)
        precondition(!rejected && app.homeSendError?.contains("消息未发送") == true,
                     "WebUI first turn cannot arm a POST when Provider read-back disagrees")
        precondition(app.consumeHomeTurn(for: sid) == nil,
                     "rejected model activation never authorizes first-turn replay")
        HermesAPI.modelHistoryOverride = nil
        HermesAPI.confirmedModelHistory = false
        HermesAPI.lastModelSet = nil
        print("WEBUI_MODEL_HOME_PASS verified model and provider before first POST; mismatches blocked")
    }

    @MainActor static func modelSwitchReadbackTests() async throws {
        let a = HermesInstance(name: "Model A", baseURL: "https://model-switch-a.test")
        let b = HermesInstance(name: "Model B", baseURL: "https://model-switch-b.test")
        try InstanceStore.save([a, b], credentials: credentials)
        InstanceStore.activeID = a.id
        let app = AppState(credentials: credentials)
        await app.loadModels()
        let selected = app.modelCatalog!.options[0]
        var old = SessionSummary.placeholder(id: "existing")
        old.model = "earlier"
        app.sessions = [old]
        app.openSession(old)
        HermesAPI.confirmedModelHistory = true
        HermesAPI.lastModelSet = nil
        defer {
            HermesAPI.confirmedModelHistory = false
            HermesAPI.modelHistoryOverride = nil
            HermesAPI.modelHistoryError = nil
            HermesAPI.holdModelHistory = false
            HermesAPI.pendingModelHistory = nil
        }

        let initialReads = HermesAPI.modelHistoryCalls
        let accepted = await app.setModel(selected, for: "existing")
        precondition(accepted && app.currentSession?.model == selected.model
                     && app.sessions[0].model == selected.model,
                     "model update becomes visible only after exact history confirmation")
        precondition(HermesAPI.modelHistoryCalls == initialReads + 1
                     && HermesAPI.lastModelSet?.1 == selected.providerID,
                     "model switch calls server history once and sends the intended provider")

        var prior = app.sessions[0]
        prior.model = "unchanged"
        app.sessions = [prior]
        app.openSession(prior)
        HermesAPI.modelHistoryOverride = [
            "session_id": "existing", "messages": [],
            "model": selected.model, "model_provider": "unrelated-provider"]
        let wrongProvider = await app.setModel(selected, for: "existing")
        precondition(!wrongProvider && app.sessions[0].model == "unchanged"
                     && app.currentSession?.model == "unchanged"
                     && app.sessionActionError?.contains("Provider") == true,
                     "HTTP success with wrong provider cannot publish selected model")

        HermesAPI.modelHistoryOverride = [
            "session_id": "existing", "messages": [], "model": selected.model]
        let missingProvider = await app.setModel(selected, for: "existing")
        precondition(!missingProvider && app.sessions[0].model == "unchanged"
                     && app.sessionActionError?.contains("Provider") == true,
                     "legacy backend omitting provider remains unverified, not guessed")

        HermesAPI.modelHistoryOverride = [
            "session_id": "existing", "messages": [],
            "model": "different", "model_provider": selected.providerID!]
        let differentModel = await app.setModel(selected, for: "existing")
        precondition(!differentModel && app.sessions[0].model == "unchanged",
                     "different actual model cannot be confirmed just by 200 response")
        HermesAPI.modelHistoryOverride = [
            "session_id": "someone-else", "messages": [],
            "model": selected.model, "model_provider": selected.providerID!]
        let otherSession = await app.setModel(selected, for: "existing")
        precondition(!otherSession && app.sessions[0].model == "unchanged",
                     "cross-session history cannot authorize a model switch")

        HermesAPI.modelHistoryOverride = nil
        HermesAPI.modelHistoryError = URLError(.notConnectedToInternet)
        let failedHistory = await app.setModel(selected, for: "existing")
        precondition(!failedHistory && app.sessions[0].model == "unchanged"
                     && app.sessionActionError != nil,
                     "failed history read must preserve previous local model identity")
        HermesAPI.modelHistoryError = nil

        // Independent scope checks survive an old server completion after
        // switching instances. No result or error from A may mutate host B.
        HermesAPI.holdModelHistory = true
        let oldSwitch = Task { await app.setModel(selected, for: "existing") }
        await spin { HermesAPI.pendingModelHistory != nil }
        app.switchTo(1)
        let oldResult = try ChatSnapshot(data: Data(
            "{\"session_id\":\"existing\",\"messages\":[],\"model\":\"m1\",\"model_provider\":\"custom:p\"}".utf8))
        HermesAPI.pendingModelHistory?.resume(returning: oldResult)
        HermesAPI.pendingModelHistory = nil
        let oldAccepted = await oldSwitch.value
        precondition(!oldAccepted && app.active.id == b.id
                     && !app.sessionActionBusy && app.sessionActionError == nil,
                     "late model confirmation cannot mutate an unrelated instance")
        print("MODEL_SWITCH_READBACK_PASS success, mismatch, missing provider, network failure and scope race")
    }

    @MainActor static func pendingRequestRestartTests() throws {
        let host = HermesInstance(name: "Task recovery", baseURL: "https://task-restart.test")
        try InstanceStore.save([host], credentials: credentials)
        InstanceStore.activeID = host.id
        let notifier = RecordingTaskNotifier()
        let app = AppState(credentials: credentials, notifier: notifier)
        let instanceScope = app.historyInstanceID
        let accountScope = app.historyAccountScope
        defer {
            SessionTaskStore.remove(instanceID: instanceScope, accountScope: accountScope)
        }
        app.sessions = [.placeholder(id: "pending-long")]
        app.approvalArrived(sessionID: "pending-long", requestID: "approval-1")
        app.clarifyArrived(sessionID: "pending-long", requestID: "clarify-1")
        app.setSessionTaskSignals(
            (app.sessionTaskObservations["pending-long"]?.signals ?? []).union([.stopping]),
            for: "pending-long")
        let before = app.sessionTaskObservations["pending-long"]?.signals ?? []
        precondition(before.isSuperset(of: [.waitingForApproval, .waitingForClarify, .stopping]),
                     "different requests and STOP persist as separate local facts")

        let reopened = AppState(credentials: credentials, notifier: notifier)
        let restored = reopened.sessionTaskObservations["pending-long"]?.signals ?? []
        precondition(restored == before && reopened.historyInstanceID == instanceScope
                     && reopened.historyAccountScope == accountScope,
                     "relaunch preserves waiting signals but not opaque message content")
        // Request identities intentionally are NOT persisted. Resolving a
        // post-restart request with no reconstructed request ledger cannot
        // prove the whole run is done.
        reopened.approvalResolved(sessionID: "pending-long", requestID: "approval-1")
        let after = reopened.sessionTaskObservations["pending-long"]?.signals ?? []
        precondition(after.isSuperset(of: [.waitingForApproval, .waitingForClarify,
                                         .stopping, .needsVerification]),
                     "late resolution after relaunch must keep other tasks and require verification")
        let anotherHost = HermesInstance(name: "Unrelated", baseURL: "https://task-other.test")
        if case .missing = reopened.unifiedTaskObservations(for: anotherHost) {
            // Expected: an unconfigured host cannot access this account's facts.
        } else {
            preconditionFailure("task observations cannot be read from an unconfigured host")
        }
        print("TASK_RESTART_PASS persistent scoped facts; stale request resolution stays fail-closed")
    }

    @MainActor static func instanceEditingTests() async throws {
        let gateway = HermesInstance(name: "Old", baseURL: "https://edit-gw.test",
                                     backend: .gateway, apiKey: "old-secret",
                                     gatewayDataPath: "/opt/data")
        let secondary = HermesInstance(name: "Other", baseURL: "https://other-edit.test")
        try InstanceStore.save([gateway, secondary], credentials: credentials)
        InstanceStore.activeID = gateway.id
        let model = AppState(credentials: credentials)
        model.openSession(.placeholder(id: "draft-in-progress"))
        let beforeID = model.historyInstanceID
        let beforeAccount = model.historyAccountScope
        let token = model.activeChangeToken
        let rename = await model.editInstance(
            id: gateway.id, name: "Renamed", url: gateway.baseURL,
            gatewayDataPath: gateway.gatewayDataPath)
        guard case .success = rename else { preconditionFailure("rename-only edit must succeed") }
        precondition(model.active.id == gateway.id && model.active.name == "Renamed",
                     "renaming preserves original UUID")
        precondition(model.currentSessionID == "draft-in-progress" &&
                     model.activeChangeToken == token && model.historyAccountScope == beforeAccount,
                     "renaming must not reset active chat, account or scope token")
        precondition(model.historyInstanceID == beforeID, "renaming preserves history namespace")
        precondition(InstanceStore.load(credentials: credentials)[0].name == "Renamed",
                     "renaming persists across reload")

        let bad = await model.editInstance(id: gateway.id, name: "Bad",
                                          url: "https://edit-gw.test/?q=1")
        guard case .failure = bad else { preconditionFailure("invalid URL must fail") }
        precondition(model.active.name == "Renamed", "invalid editing input cannot change config")
        let missingFreshKey = await model.editInstance(
            id: gateway.id, name: "Unsafe", url: "https://new-edit.test",
            gatewayDataPath: "/opt/data")
        guard case .failure = missingFreshKey else { preconditionFailure("new gateway host requires key") }
        precondition(model.active.baseURL == gateway.baseURL && model.active.apiKey == "old-secret",
                     "original Bearer token is not sent to a new gateway implicitly")

        HermesAPI.listError = URLError(.notConnectedToInternet)
        let rejected = await model.editInstance(
            id: gateway.id, name: "Unreachable", url: "https://new-edit.test",
            replacementAPIKey: "fresh-secret", gatewayDataPath: "/opt/data")
        guard case .failure = rejected else { preconditionFailure("unreachable gateway cannot replace original") }
        HermesAPI.listError = nil
        precondition(model.active.baseURL == gateway.baseURL && model.currentSessionID == "draft-in-progress",
                     "failed connection probe leaves active chat and old credentials intact")
        credentials.failWrites = true
        let diskFailure = await model.editInstance(
            id: gateway.id, name: "NoSave", url: "https://new-edit.test",
            replacementAPIKey: "fresh-secret", gatewayDataPath: "/opt/data")
        guard case .failure = diskFailure else { preconditionFailure("Keychain write must fail closed") }
        credentials.failWrites = false
        precondition(model.active.baseURL == gateway.baseURL && model.active.apiKey == "old-secret",
                     "failed credential transaction must not mutate instance")

        let changed = await model.editInstance(
            id: gateway.id, name: "Moved", url: "https://new-edit.test",
            replacementAPIKey: "fresh-secret", gatewayDataPath: "/data/new")
        guard case .success = changed else { preconditionFailure("verified endpoint edit must save") }
        precondition(model.active.id == gateway.id &&
                     model.active.baseURL == "https://new-edit.test" &&
                     model.active.apiKey == "fresh-secret" &&
                     model.active.gatewayDataPath == "/data/new",
                     "edit keeps UUID while changing validated endpoint and secret")
        precondition(model.historyInstanceID != beforeID && model.currentSessionID == nil,
                     "endpoint edit must reset visible session and isolate old namespace")
        let persisted = InstanceStore.load(credentials: credentials)
        precondition(persisted[0].id == gateway.id && persisted[0].baseURL == "https://new-edit.test",
                     "verified endpoint survives secure metadata reload")

        // A changed key on the same endpoint retires account-scoped data.
        let currentAccount = model.historyAccountScope
        let keyEdit = await model.editInstance(
            id: gateway.id, name: "Moved", url: "https://new-edit.test",
            replacementAPIKey: "third-secret", gatewayDataPath: "/data/new")
        guard case .success = keyEdit else { preconditionFailure("valid key update must succeed") }
        precondition(model.active.apiKey == "third-secret" &&
                     model.historyAccountScope != currentAccount,
                     "replacing key rotates history account namespace")
        let otherEdit = await model.editInstance(
            id: secondary.id, name: "Other Renamed", url: secondary.baseURL)
        guard case .success = otherEdit else { preconditionFailure("inactive rename must succeed") }
        precondition(model.active.id == gateway.id && model.instances[1].id == secondary.id &&
                     model.instances[1].name == "Other Renamed",
                     "editing an inactive instance must not switch active host")
        // A delayed connection probe cannot write to a removed/switched scope.
        HermesAPI.heldLists = ["https://edit-race.test"]
        let staleProbe = Task { await model.editInstance(
            id: gateway.id, name: "Must Not Save", url: "https://edit-race.test",
            replacementAPIKey: "race-secret", gatewayDataPath: "/data/new") }
        await spin { HermesAPI.pendingLists["https://edit-race.test"] != nil }
        model.switchTo(1)
        HermesAPI.pendingLists.removeValue(forKey: "https://edit-race.test")!
            .resume(returning: [])
        let staleResult = await staleProbe.value
        guard case .failure = staleResult else {
            preconditionFailure("switched instance must invalidate outstanding edit")
        }
        precondition(model.instances[0].name == "Moved" &&
                     model.instances[0].baseURL == "https://new-edit.test" &&
                     model.active.id == secondary.id,
                     "in-flight edit cannot overwrite state after switching instances")
        HermesAPI.heldLists = []
        print("INSTANCE_EDIT_PASS rename preserve, strict URL/key validation, failed probes, secure rollback, endpoint isolation, account rotation and switched-scope race")
    }

    @MainActor static func unifiedSessionNavigationTests() async throws {
        let a = HermesInstance(name: "Unified A", baseURL: "https://unified-a.test")
        let b = HermesInstance(name: "Unified B", baseURL: "https://unified-b.test")
        try InstanceStore.save([a, b], credentials: credentials)
        InstanceStore.activeID = a.id
        let model = AppState(credentials: credentials)
        await model.refresh()
        let shared = SessionSummary.placeholder(id: "same-session-id")
        model.sessions = [shared]
        let endpointA = model.historyInstanceID
        let accountA = model.historyAccountScope
        model.switchTo(1)
        await spin { model.hasLoadedSessions }
        let endpointB = model.historyInstanceID
        let accountB = model.historyAccountScope
        expectUnified(model.unifiedCachedSessions(for: a)?.first?.sessionId == shared.sessionId,
                      "inactive host's scoped confirmed list remains available")
        expectUnified(!model.openSessionFromInstance(instanceID: a.id,
            endpointIdentity: endpointA, accountScope: "wrong-account", session: shared)
            && model.active.id == b.id,
            "mismatched account cannot navigate or switch hosts")
        expectUnified(!model.openSessionFromInstance(instanceID: a.id,
            endpointIdentity: endpointB, accountScope: accountA, session: shared)
            && model.active.id == b.id,
            "matching session ID with mismatched endpoint cannot switch")
        expectUnified(model.openSessionFromInstance(instanceID: a.id,
            endpointIdentity: endpointA, accountScope: accountA, session: shared)
            && model.active.id == a.id && model.currentSessionID == shared.sessionId,
            "explicit scoped tap switches to the correct host and opens its native Session")
        expectUnified(model.unifiedCachedSessions(for: b) != nil,
                      "other host's known list remains in its own scope")
        let unknown = HermesInstance(name: "Not configured", baseURL: "https://unified-c.test")
        expectUnified(model.unifiedCachedSessions(for: unknown) == nil,
                      "unknown host cannot inspect any scoped cached list")
        expectUnified(accountA != accountB || endpointA != endpointB,
                      "test hosts use independent identity tuples")
        print("UNIFIED_NAV_PASS exact host/account/session routing and isolated snapshots")
    }

    @MainActor static func foregroundListPolicyTests() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let old = base.addingTimeInterval(-120)
        let fresh = base.addingTimeInterval(-2)
        var policy = ForegroundListRefreshPolicy()
        precondition(!policy.shouldRefresh(
            wasActive: true, isActive: true, scope: "account-A",
            lastSuccess: old, now: base),
            "active-to-active redraw does not refresh")
        precondition(!policy.shouldRefresh(
            wasActive: true, isActive: false, scope: "account-A",
            lastSuccess: old, now: base),
            "background transition itself never starts network work")
        precondition(!policy.shouldRefresh(
            wasActive: false, isActive: true, scope: "account-A",
            lastSuccess: fresh, now: base),
            "rapid app bounce reuses a fresh authoritative list")
        precondition(policy.shouldRefresh(
            wasActive: false, isActive: true, scope: "account-A",
            lastSuccess: old, now: base),
            "return from background after stale list schedules one refresh")
        precondition(!policy.shouldRefresh(
            wasActive: false, isActive: true, scope: "account-A",
            lastSuccess: nil, now: base.addingTimeInterval(3)),
            "failed or in-flight foreground attempt has cooldown")
        precondition(policy.shouldRefresh(
            wasActive: false, isActive: true, scope: "account-B",
            lastSuccess: nil, now: base.addingTimeInterval(3)),
            "another instance/account scope is never suppressed by A's cooldown")
        precondition(policy.shouldRefresh(
            wasActive: false, isActive: true, scope: "account-A",
            lastSuccess: nil, now: base.addingTimeInterval(16)),
            "a failed attempt remains retryable after cooldown")
        precondition(!policy.shouldRefresh(
            wasActive: false, isActive: true, scope: "",
            lastSuccess: nil, now: base.addingTimeInterval(50)),
            "invalid/retired scope never starts a list request")
        print("FOREGROUND_POLICY_PASS scope, stale state, app bounce, failure cooldown")
    }

    @MainActor static func completionRefreshTests() async throws {
        let host = HermesInstance(name: "Completion", baseURL: "https://completion-212.test")
        try InstanceStore.save([host], credentials: credentials)
        InstanceStore.activeID = host.id
        HermesAPI.heldLists = [host.baseURL]
        defer { HermesAPI.heldLists = [] }
        let model = AppState(credentials: credentials)
        let decoder = JSONDecoder()
        func row(_ sid: String, running: Bool) throws -> SessionSummary {
            let data = Data("{\"session_id\":\"\(sid)\",\"title\":\"Test\",\"is_streaming\":\(running)}".utf8)
            return try decoder.decode(SessionSummary.self, from: data)
        }
        // First successful list is the evidence baseline; a session that is
        // already idle cannot be manufactured into a completion notification.
        let first = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[host.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: host.baseURL)!
            .resume(returning: [try row("observed-running", running: true),
                                try row("idle-no-evidence", running: false)])
        await first.value
        precondition(model.completedSessionIDs.isEmpty,
                     "first snapshot alone cannot infer any new completion")
        let second = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[host.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: host.baseURL)!
            .resume(returning: [try row("observed-running", running: false),
                                try row("idle-no-evidence", running: false)])
        await second.value
        precondition(model.completedSessionIDs == Set(["observed-running"]),
                     "only a recorded streaming->not-streaming transition earns the blue dot")
        let third = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[host.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: host.baseURL)!
            .resume(returning: [try row("observed-running", running: false),
                                try row("idle-no-evidence", running: false)])
        await third.value
        precondition(model.completedSessionIDs == Set(["observed-running"]),
                     "repeated authoritative idle snapshots cannot manufacture new completion")
        print("FOREGROUND_COMPLETION_PASS known transition, unknown state, idempotent refresh")
    }

    @MainActor static func refreshTests() async throws {
        let a = HermesInstance(name: "Refresh A", baseURL: "https://refresh-a.test")
        let b = HermesInstance(name: "Refresh B", baseURL: "https://refresh-b.test")
        try InstanceStore.save([a, b], credentials: credentials); InstanceStore.activeID = a.id
        HermesAPI.heldLists = [a.baseURL, b.baseURL]
        let model = AppState(credentials: credentials)
        var firstDone = false, secondDone = false
        let first = Task { await model.refresh(); firstDone = true }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        let second = Task { await model.refresh(); secondDone = true }
        for _ in 0..<20 { await Task.yield() }
        precondition(HermesAPI.listCalls[a.baseURL] == 1 && model.loadingSessions && !firstDone && !secondDone,
                     "overlapping pull/footer callers await one actual list request")
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: [.placeholder(id: "kept")])
        await first.value; await second.value
        precondition(firstDone && secondDone && !model.loadingSessions && model.sessions.first?.id == "kept")

        let failure = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(throwing: URLError(.notConnectedToInternet))
        await failure.value
        precondition(model.errorText != nil && model.sessions.first?.id == "kept" && !model.loadingSessions,
                     "a failed refresh preserves visible rows and publishes feedback")
        let retry = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        precondition(model.errorText == nil && model.loadingSessions, "retry clears old failure while awaiting GET")
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: [])
        await retry.value
        precondition(model.sessions.isEmpty && model.errorText == nil && !model.loadingSessions,
                     "a successful empty result replaces old rows")

        model.sessions = [.placeholder(id: "deleted-during-refresh")]
        let beforeDelete = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        await model.delete(sessionID: "deleted-during-refresh")
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: [.placeholder(id: "deleted-during-refresh")])
        await beforeDelete.value
        precondition(model.sessions.isEmpty && !model.loadingSessions, "a pre-delete GET cannot resurrect the deleted row")
        let afterDelete = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: [.placeholder(id: "after-delete")])
        await afterDelete.value
        precondition(model.sessions.map(\.id) == ["after-delete"], "deletion invalidation releases the old shared refresh task")

        model.sessions = [.placeholder(id: "archived-during-refresh")]
        let beforeArchive = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        await model.archive(sessionID: "archived-during-refresh")
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: [.placeholder(id: "archived-during-refresh")])
        await beforeArchive.value
        precondition(model.sessions.isEmpty && !model.loadingSessions,
                     "a pre-archive GET cannot resurrect an archived row")

        let stale = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        model.switchTo(1)
        await spin { HermesAPI.pendingLists[b.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(throwing: URLError(.timedOut))
        await stale.value
        precondition(model.loadingSessions && model.errorText == nil && model.active.id == b.id,
                     "late cancelled-instance failure cannot clear new busy state or publish an error")
        HermesAPI.pendingLists.removeValue(forKey: b.baseURL)!.resume(returning: [.placeholder(id: "only-new-instance")])
        await model.refresh()
        precondition(model.sessions.map(\.id) == ["only-new-instance"] && !model.loadingSessions,
                     "new instance refresh remains owned until its actual request finishes")

        // build157: returning to a previously loaded host immediately restores
        // its own confirmed snapshot. The in-flight GET must not blank the list.
        model.switchTo(0)
        precondition(model.hasLoadedSessions && model.sessions.isEmpty,
                     "confirmed empty A scope is known, not an uninitialized spinner")
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        model.switchTo(1)
        precondition(model.hasLoadedSessions &&
                     model.sessions.map(\.id) == ["only-new-instance"],
                     "B sessions are restored synchronously without showing A's rows or empty flash")
        await spin { HermesAPI.pendingLists[b.baseURL] != nil }
        // Flush both held requests; old A generation must not write onto B.
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)?.resume(returning: [.placeholder(id: "late-a")])
        HermesAPI.pendingLists.removeValue(forKey: b.baseURL)!.resume(returning: [.placeholder(id: "only-new-instance")])
        await model.refresh()
        precondition(model.sessions.map(\.id) == ["only-new-instance"],
                     "stale A responses cannot replace cached B results")

        let scope = model.historyAccountScope
        let unauthorized = Task { await model.refresh() }
        await spin { HermesAPI.pendingLists[b.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: b.baseURL)!.resume(throwing: APIError.http(401, "expired"))
        await unauthorized.value
        // P0-12：401 只置 needsLogin 提示，不再销毁账号命名空间与列表缓存。
        // 远程可注入的 401 不能成为清空本地数据的手段。
        precondition(model.needsLogin && model.historyAccountScope == scope && !model.loadingSessions,
                     "a 401 only raises the login prompt and preserves local data")
        HermesAPI.heldLists = []
    }

    // build158: deleting the active host or an earlier indexed host must not
    // transfer the old list into another instance's scoped cache.
    @MainActor static func instanceDeletionCacheTests() async throws {
        let a = HermesInstance(name: "Delete A", baseURL: "https://delete-a.example")
        let b = HermesInstance(name: "Delete B", baseURL: "https://delete-b.example")
        let c = HermesInstance(name: "Delete C", baseURL: "https://delete-c.example")
        HermesAPI.heldLists = []
        try InstanceStore.save([a, b, c], credentials: credentials)
        InstanceStore.activeID = a.id
        let first = AppState(credentials: credentials)
        await first.refresh()
        first.sessions = [.placeholder(id: "owned-by-A")]
        first.switchTo(1)
        await spin { first.hasLoadedSessions && first.sessions.first?.id == "B" }
        first.sessions = [.placeholder(id: "owned-by-B")]
        first.switchTo(0)
        precondition(first.sessions.map(\.id) == ["owned-by-A"])
        first.deleteInstance(at: IndexSet(integer: 0))
        precondition(first.active.id == b.id
                     && first.sessions.map(\.id) == ["owned-by-B"],
                     "deleting active A must restore B, never cache A under B")

        // The current host survives but its numeric index shifts left.
        try InstanceStore.save([a, b, c], credentials: credentials)
        InstanceStore.activeID = b.id
        let second = AppState(credentials: credentials)
        await second.refresh()
        second.sessions = [.placeholder(id: "B-after-shift")]
        second.deleteInstance(at: IndexSet(integer: 0))
        precondition(second.active.id == b.id
                     && second.sessions.map(\.id) == ["B-after-shift"],
                     "deleting an earlier host keeps the surviving current host's list")
    }

    @MainActor static func sessionRefreshPolicyTests() async throws {
        let api = HermesAPI(baseURL: "https://refresh-policy.test")
        HermesAPI.capabilitiesOverride = .gateway
        HermesAPI.authCalls = 0
        HermesAPI.listCalls = [:]
        HermesAPI.listDelayNanoseconds = 200_000_000
        do {
            _ = try await SessionRefreshLoader.load(
                api: api, policy: SessionRefreshPolicy(totalTimeout: 0.02))
            preconditionFailure("a stalled gateway refresh must hit its total deadline")
        } catch is SessionRefreshTimeout {
            // expected
        }
        precondition(HermesAPI.authCalls == 0,
                     "gateway refresh must not issue a duplicate authentication request")
        precondition(HermesAPI.listCalls[api.baseURL] == 1,
                     "gateway refresh spends its request budget on the list itself")

        HermesAPI.capabilitiesOverride = .webUI
        HermesAPI.authCalls = 0
        HermesAPI.listCalls = [:]
        do {
            _ = try await SessionRefreshLoader.load(
                api: api, policy: SessionRefreshPolicy(totalTimeout: 0.02))
            preconditionFailure("a stalled WebUI refresh must hit its total deadline")
        } catch is SessionRefreshTimeout {
            // expected
        }
        precondition(HermesAPI.authCalls == 1,
                     "WebUI still checks its dedicated authentication endpoint")
        precondition(HermesAPI.listCalls[api.baseURL] == 1,
                     "WebUI proceeds to the real list only after authentication succeeds")

        HermesAPI.authLoggedIn = false
        HermesAPI.authCalls = 0
        HermesAPI.listCalls = [:]
        do {
            _ = try await SessionRefreshLoader.load(
                api: api, policy: SessionRefreshPolicy(totalTimeout: 1))
            preconditionFailure("a logged-out WebUI must stop before requesting sessions")
        } catch let error as APIError {
            guard case .http(401, _) = error else {
                preconditionFailure("logged-out WebUI must surface an authentication error")
            }
        }
        precondition(HermesAPI.authCalls == 1 && HermesAPI.listCalls[api.baseURL] == nil,
                     "logged-out WebUI must not fetch or expose a session list")

        HermesAPI.authLoggedIn = true
        HermesAPI.capabilitiesOverride = .gateway
        HermesAPI.authCalls = 0
        HermesAPI.listDelayNanoseconds = 0
        HermesAPI.listError = APIError.http(403, "forbidden")
        do {
            _ = try await SessionRefreshLoader.load(
                api: api, policy: SessionRefreshPolicy(totalTimeout: 1))
            preconditionFailure("gateway list 403 must surface")
        } catch let error as APIError {
            guard case .http(403, _) = error else {
                preconditionFailure("gateway list 403 must retain its status")
            }
        }
        precondition(HermesAPI.authCalls == 0,
                     "gateway list failures remain authoritative for authentication")
        HermesAPI.capabilitiesOverride = nil
        HermesAPI.listError = nil
        HermesAPI.listCalls = [:]
    }

    @MainActor static func sessionRefreshFeedbackTests() async throws {
        let suite = "HermesSessionRefreshClock-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SessionRefreshClock(defaults: defaults)
        let refreshDate = Date(timeIntervalSince1970: 1_800_000_000)
        clock.recordSuccess(scope: "instance-a|account-a", at: refreshDate)
        precondition(clock.lastSuccess(scope: "instance-a|account-a") == refreshDate,
                     "successful refresh timestamps survive within the scope")
        precondition(clock.lastSuccess(scope: "instance-b|account-a") == nil,
                     "refresh timestamps are isolated by instance")
        let restartedClock = SessionRefreshClock(defaults: defaults)
        precondition(restartedClock.lastSuccess(scope: "instance-a|account-a") == refreshDate,
                     "refresh timestamp persists across app launch")
        restartedClock.remove(scope: "instance-a|account-a")
        precondition(restartedClock.lastSuccess(scope: "instance-a|account-a") == nil,
                     "retiring an account removes its refresh timestamp")

        let instance = HermesInstance(name: "Refresh feedback", baseURL: "https://refresh-feedback.test")
        try InstanceStore.save([instance], credentials: credentials)
        InstanceStore.activeID = instance.id
        let model = AppState(
            credentials: credentials,
            sessionRefreshPolicy: SessionRefreshPolicy(totalTimeout: 0.02),
            sessionRefreshClock: SessionRefreshClock(defaults: defaults))
        model.sessions = [.placeholder(id: "last-known-good")]
        precondition(model.lastSessionRefresh == nil)
        HermesAPI.listDelayNanoseconds = 200_000_000
        await model.refresh()
        precondition(model.sessions.map(\.id) == ["last-known-good"],
                     "a timed-out list refresh must preserve the last known good rows")
        precondition(model.errorText?.contains("上次成功刷新") == true && !model.loadingSessions,
                     "a timeout with cached rows must explain that stale data remains visible")

        model.sessions = []
        await model.refresh()
        precondition(model.sessions.isEmpty &&
                     model.errorText?.contains("没有可保留") == true,
                     "a timeout without cached rows must give a concise retry message")

        HermesAPI.listDelayNanoseconds = 0
        HermesAPI.listError = nil
        await model.refresh()
        let successfulRefresh = model.lastSessionRefresh
        precondition(successfulRefresh != nil,
                     "a successful list request records its visible refresh time")
        precondition(SessionRefreshClock(defaults: defaults).lastSuccess(
            scope: model.historyInstanceID + "|" + model.historyAccountScope) != nil,
            "a successful refresh timestamp is stored in the active account scope")

        model.sessions = [.placeholder(id: "kept-after-403")]
        HermesAPI.listDelayNanoseconds = 0
        HermesAPI.listError = APIError.http(403, "forbidden")
        let accountScope = model.historyAccountScope
        await model.refresh()
        precondition(model.needsLogin && model.sessions.map(\.id) == ["kept-after-403"],
                     "a 403 must raise login while preserving local rows")
        precondition(model.historyAccountScope == accountScope,
                     "a 403 must not rotate or destroy the local account namespace")
        HermesAPI.listError = nil
    }

    @MainActor static func deletionScopeTests() async throws {
        for batch in [false, true] {
            let a = HermesInstance(name: "Delete A", baseURL: "https://delete-a.test")
            let b = HermesInstance(name: "Delete B", baseURL: "https://delete-b.test")
            try InstanceStore.save([a, b], credentials: credentials); InstanceStore.activeID = a.id
            let model = AppState(credentials: credentials)
            let instanceA = model.historyInstanceID
            let accountA = model.historyAccountScope
            let draftA = ChatDraftStore(instanceID: instanceA, accountScope: accountA, sessionID: "same-id")
            draftA.save("old account")
            HermesAPI.holdDeletes = true
            let initialCalls = HermesAPI.deleteCalls.count
            let task = Task {
                if batch { _ = await model.deleteSessions(ids: ["same-id", "second-id"]) }
                else { await model.delete(sessionID: "same-id") }
            }
            await spin { HermesAPI.pendingDelete != nil }
            model.switchTo(1)
            let draftB = ChatDraftStore(instanceID: model.historyInstanceID, accountScope: model.historyAccountScope,
                                         sessionID: "same-id")
            draftB.save("new account's unsent text")
            HermesAPI.pendingDelete!.resume(); HermesAPI.pendingDelete = nil
            await task.value
            precondition(draftA.load().isEmpty, "delete cleans the dispatching account's local state")
            precondition(draftB.load() == "new account's unsent text", "late delete cannot erase the new account's same-ID draft")
            precondition(HermesAPI.deleteCalls.count == initialCalls + 1, "scope change stops the remaining batch requests")
            HermesAPI.holdDeletes = false
            draftB.remove()
        }
    }

    @MainActor static func gatewayCredentialTests() async throws {
        let gateway = HermesInstance(name: "Credential fixture", baseURL: "https://gateway-auth.test",
            backend: .gateway, apiKey: "old-fixture-key")
        try InstanceStore.save([gateway], credentials: credentials)
        InstanceStore.activeID = gateway.id
        let model = AppState(credentials: credentials)
        model.needsLogin = true
        let oldAccount = model.historyAccountScope
        await model.updateGatewayAPIKey("invalid\nheader")
        precondition(model.active.apiKey == "old-fixture-key" && model.historyAccountScope == oldAccount)
        credentials.failWrites = true
        await model.updateGatewayAPIKey("new-fixture-key")
        precondition(model.active.apiKey == "old-fixture-key" && model.historyAccountScope == oldAccount,
                     "credential failure must not replace a live config or rotate its account")
        let previousCount = model.instances.count
        model.addInstance(name: "Fail", url: "https://another-gateway.test", backend: .gateway, apiKey: "other-fixture-key")
        precondition(model.instances.count == previousCount, "failed secure persistence cannot append an unsaved instance")
        credentials.failWrites = false
        await model.updateGatewayAPIKey("new-fixture-key")
        precondition(model.active.id == gateway.id && model.active.apiKey == "new-fixture-key")
        precondition(model.historyAccountScope != oldAccount && !model.needsLogin,
                     "a successfully saved replacement gets a fresh backend/account before authentication")
        let persisted = UserDefaults.standard.data(forKey: "hermes.instances") ?? Data()
        let text = String(decoding: persisted, as: UTF8.self)
        precondition(!text.contains("new-fixture-key") && !text.contains("old-fixture-key"),
                     "instance preferences never contain the gateway credential")
        credentials.failReads = true
        let unavailable = AppState(credentials: credentials)
        let preservedAccount = unavailable.historyAccountScope
        let priorListCalls = HermesAPI.listCalls[gateway.baseURL, default: 0]
        await unavailable.refresh()
        precondition(unavailable.credentialWarning != nil && !unavailable.needsLogin)
        precondition(unavailable.historyAccountScope == preservedAccount
            && HermesAPI.listCalls[gateway.baseURL, default: 0] == priorListCalls,
            "unavailable Keychain must not send an empty key or retire the valid account")
        credentials.failReads = false
        await unavailable.refresh()
        precondition(unavailable.active.apiKey == "new-fixture-key" && unavailable.credentialWarning == nil
            && unavailable.historyAccountScope == preservedAccount,
            "unlock and refresh restores the credential without losing the existing account scope")
    }

    // A credential probe can outlive its originating host. Its successful
    // response must never save into the host now occupying activeIndex.
    @MainActor static func gatewayKeyScopeRaceTests() async throws {
        let a = HermesInstance(name: "Gateway race A",
            baseURL: "https://gateway-key-race-a.test", backend: .gateway,
            apiKey: "old-a")
        let b = HermesInstance(name: "Gateway race B",
            baseURL: "https://gateway-key-race-b.test", backend: .gateway,
            apiKey: "old-b")
        try InstanceStore.save([a, b], credentials: credentials)
        InstanceStore.activeID = a.id
        let app = AppState(credentials: credentials)
        HermesAPI.heldLists.insert(a.baseURL)
        let probe = Task { await app.updateGatewayAPIKey("new-a") }
        await spin { HermesAPI.pendingLists[a.baseURL] != nil }
        app.switchTo(1)
        HermesAPI.pendingLists.removeValue(forKey: a.baseURL)!.resume(returning: [])
        await probe.value
        HermesAPI.heldLists.remove(a.baseURL)
        precondition(app.active.id == b.id && app.instances[0].apiKey == "old-a"
                     && app.instances[1].apiKey == "old-b",
                     "a successful A probe cannot write its key to B after a switch")

        // Use a fresh AppState for deletion; switching back to A would also
        // start a background list refresh and could overwrite the mock's
        // one-continuation-per-URL slot, invalidating the test itself.
        let deletingA = HermesInstance(name: "Delete-probe A",
            baseURL: "https://gateway-key-delete-a.test", backend: .gateway,
            apiKey: "delete-old-a")
        let deletingB = HermesInstance(name: "Delete-probe B",
            baseURL: "https://gateway-key-delete-b.test", backend: .gateway,
            apiKey: "delete-old-b")
        try InstanceStore.save([deletingA, deletingB], credentials: credentials)
        InstanceStore.activeID = deletingA.id
        let deleting = AppState(credentials: credentials)
        HermesAPI.heldLists.insert(deletingA.baseURL)
        let stale = Task { await deleting.updateGatewayAPIKey("never-save") }
        await spin { HermesAPI.pendingLists[deletingA.baseURL] != nil }
        deleting.deleteInstance(at: IndexSet(integer: 0))
        HermesAPI.pendingLists.removeValue(forKey: deletingA.baseURL)!.resume(returning: [])
        await stale.value
        HermesAPI.heldLists.remove(deletingA.baseURL)
        precondition(deleting.instances.count == 1 && deleting.active.id == deletingB.id
                     && deleting.active.apiKey == "delete-old-b",
                     "a probe for a deleted host cannot overwrite the shifted B index")
    }

    @MainActor static func taskSignalDedupTests() throws {
        let instance = HermesInstance(name: "Task dedup", baseURL: "https://task-dedup.test")
        try InstanceStore.save([instance], credentials: credentials)
        InstanceStore.activeID = instance.id
        let model = AppState(credentials: credentials)
        #if !canImport(SwiftUI)
        let initial = PublicationProbe.assignments
        model.setSessionTaskSignals([], for: "empty")
        precondition(PublicationProbe.assignments == initial,
                     "empty signals on absent record must not assign Published storage")
        model.setSessionTaskSignals([.running], for: "empty")
        precondition(PublicationProbe.assignments == initial,
                     "server-only running normalizes to absent without publishing")
        #endif
        model.setSessionTaskSignals([.needsVerification], for: "task")
        let first = model.sessionTaskObservations["task"]!
        #if !canImport(SwiftUI)
        let afterFirst = PublicationProbe.assignments
        #endif
        model.setSessionTaskSignals([.needsVerification, .running], for: "task")
        precondition(model.sessionTaskObservations["task"] == first,
                     "identical persistable signals preserve observedAt")
        #if !canImport(SwiftUI)
        precondition(PublicationProbe.assignments == afterFirst,
                     "identical signals must not assign Published storage")
        #endif
        precondition(SessionTaskStore.load(instanceID: model.historyInstanceID,
                     accountScope: model.historyAccountScope)["task"] == first)
        model.setSessionTaskSignals([.waitingForApproval], for: "task")
        precondition(model.sessionTaskObservations["task"]?.signals == [.waitingForApproval])
        model.setSessionTaskSignals([], for: "task")
        precondition(model.sessionTaskObservations["task"] == nil)
        precondition(SessionTaskStore.load(instanceID: model.historyInstanceID,
                     accountScope: model.historyAccountScope)["task"] == nil)
        print("TASK_SIGNAL_DEDUP_PASS empty and repeated signals publish zero assignments")
    }

    @MainActor static func notificationRoutingTests() async throws {
        let instance = HermesInstance(name: "Notify", baseURL: "https://notify-tasks.test")
        try InstanceStore.save([instance], credentials: credentials)
        InstanceStore.activeID = instance.id
        let notifier = RecordingTaskNotifier()
        let model = AppState(credentials: credentials, notifier: notifier)
        model.sessions = [.placeholder(id: "visible"), .placeholder(id: "other")]

        model.setPresentationVisibility(appActive: true, conversationVisible: true)
        model.currentSessionID = "visible"
        model.approvalArrived(sessionID: "visible", requestID: "a1")
        await spin { notifier.delivered.isEmpty }
        precondition(notifier.delivered.isEmpty, "active visible conversation suppresses its own approval")
        precondition(model.sessionTaskObservations["visible"]?.signals
                     == [.waitingForApproval],
                     "notification suppression still records the task-center signal")

        model.setPresentationVisibility(appActive: false, conversationVisible: false)
        model.clarifyArrived(sessionID: "visible", requestID: "c1")
        await spin { notifier.delivered.count == 1 }
        precondition(notifier.delivered.first?.kind == .clarifyPending,
                     "clarify uses a distinct notification kind")
        let deliveredID = notifier.delivered[0].stableID
        model.clarifyResolved(sessionID: "visible", requestID: "c1")
        await spin { notifier.removed.contains(deliveredID) }
        precondition(notifier.removed.contains(deliveredID),
                     "resolved clarify removes the exact delivered identifier")
        precondition(model.sessionTaskObservations["visible"]?.signals
                     == [.waitingForApproval],
                     "resolving clarify preserves the suppressed approval")

        model.approvalArrived(sessionID: "other", requestID: "other-a")
        await spin { notifier.delivered.count >= 2 }
        model.approvalResolved(sessionID: "visible", requestID: "a1")
        precondition(model.sessionTaskObservations["visible"] == nil,
                     "resolving the last request in one session clears it")
        precondition(model.sessionTaskObservations["other"]?.signals
                     == [.waitingForApproval],
                     "resolving one session does not clear another session's request")
        model.approvalResolved(sessionID: "other", requestID: "other-a")

        model.setPresentationVisibility(appActive: true, conversationVisible: false)
        model.approvalArrived(sessionID: "visible", requestID: "a2")
        model.clarifyArrived(sessionID: "visible", requestID: "c2")
        await spin { notifier.delivered.count >= 4 }
        precondition(Set(notifier.delivered.suffix(2).map(\.kind))
                     == [.approvalPending, .clarifyPending],
                     "active but obscured conversation delivers both sibling requests")
        precondition(model.sessionTaskObservations["visible"]?.signals
                     == [.waitingForApproval, .waitingForClarify],
                     "sibling approval and clarify signals coexist")
        model.approvalResolved(sessionID: "visible", requestID: "a2")
        precondition(model.sessionTaskObservations["visible"]?.signals == [.waitingForClarify],
                     "resolving approval preserves clarify task signal")
        model.clarifyResolved(sessionID: "visible", requestID: "c2")
        precondition(model.sessionTaskObservations["visible"] == nil,
                     "resolving last blocking request clears task signal")
        print("NOTIFICATION_ROUTING_PASS visibility, clarify identity and exact removal")
    }

    @MainActor static func main() async throws {
        try await firstLaunchSetupTests()
        try taskSignalDedupTests()
        try await notificationRoutingTests()
        try await taskCacheTests()
        let a = HermesInstance(name:"A",baseURL:"https://a.example")
        let b = HermesInstance(name:"B",baseURL:"https://b.example")
        try InstanceStore.save([a,b], credentials: credentials); InstanceStore.activeID = a.id
        let model = AppState(credentials: credentials)
        let historyA = model.historyAccountScope
        let historyInstanceA = model.historyInstanceID
        let oldRefresh = Task { await model.refresh() }
        await spin { HermesAPI.listEntered }
        model.switchTo(1)
        precondition(model.historyInstanceID != historyInstanceA && model.historyAccountScope != historyA,
                     "history cache namespaces are isolated between instances")
        await oldRefresh.value
        await spin { model.sessions.first?.id == "B" }
        precondition(model.active.id == b.id && model.sessions.first?.id == "B","stale A list must not overwrite B")
        model.switchTo(0)
        precondition(model.historyAccountScope == historyA, "returning to an instance retains its cache account namespace")
        let creating = Task { await model.createSession() }
        await spin { HermesAPI.createEntered }
        model.switchTo(1)
        await creating.value
        precondition(model.active.id == b.id && model.currentSessionID == nil,"A-created session must not navigate on B API")
        let prior = model.instances.count
        model.addInstance(name:"invalid",url:"not-a-url")
        precondition(model.instances.count == prior && model.errorText != nil)
        model.deleteInstance(at:IndexSet(integer:0))
        precondition(model.active.id == b.id,"deleting earlier row must preserve selected identity")
        model.switchTo(0)
        let opening = Task { await model.createSession() }
        await spin { HermesAPI.createEntered }
        await opening.value
        precondition(model.currentSessionID != nil,"successful create must open the new session")
        let createdID = model.currentSessionID
        model.openSession(SessionSummary.placeholder(id:"opened"))
        precondition(model.currentSessionID == "opened","opening a session must be remembered")
        model.addInstance(name:"C",url:"https://c.example")
        precondition(model.instances.count == 2,"valid instance must be added")
        model.switchTo(model.instances.count - 1)
        precondition(model.currentSessionID == nil,"switching instance must leave the chat")
        model.switchTo(0)
        precondition(model.currentSessionID == nil && createdID != nil,"instance switch must not restore a stale session")
        let searchHit = SessionSummary.placeholder(id: "from-search")
        model.sessions = []
        model.openSession(searchHit)
        precondition(model.currentSession?.title == searchHit.title && model.currentSession?.sessionId == "from-search",
                     "a search hit opened from outside the normal list keeps its real title")
        await model.rename(sessionID: searchHit.id, title: "搜索页改名")
        precondition(model.currentSession?.title == "搜索页改名", "rename updates an opened search-only session")
        model.closeSession()
        precondition(model.currentSession == nil, "closing clears the remembered search hit")
        let forkPlan = MessageForkPlan(keepCount: 1, text: "edit", sourceMessageID: "m", sendImmediately: false)
        model.pendingFork = ("fork", forkPlan)
        precondition(model.consumeFork(for: "wrong") == nil, "a different session cannot consume fork draft")
        precondition(model.consumeFork(for: "fork") == forkPlan, "new branch receives its draft")
        precondition(model.consumeFork(for: "fork") == nil, "regenerate plan can only be consumed once")
        model.pendingFork = ("fork", forkPlan)
        model.switchTo(model.activeIndex)
        precondition(model.pendingFork == nil, "switching instance cancels pending auto-send")
        // ---- 模型目录与会话操作的本地状态迁移 ----
        await model.refresh()
        await model.loadModels()
        let catalog = model.modelCatalog
        precondition(catalog?.options.count == 1,"model catalog must load once")
        // 已有目录时普通调用不应重复请求（force 才刷新）。
        await model.loadModels()
        precondition(model.modelCatalog == catalog,"cached catalog is reused without force")
        let first = catalog!.options[0]
        model.sessions = [SessionSummary.placeholder(id:"opened")]
        model.currentSessionID = "opened"
        HermesAPI.confirmedModelHistory = true
        let switched = await model.setModel(first, for: "opened")
        precondition(switched && HermesAPI.lastModelSet?.0 == "opened","set model hits the session route")
        precondition(HermesAPI.lastModelSet?.1 == "custom:p","set model forwards the catalog provider id")
        precondition(model.sessions[0].model == "m1","confirmed model switch updates the local row")
        await model.rename(sessionID:"opened", title:"  改过的标题  ")
        precondition(HermesAPI.lastRename?.1 == "改过的标题","rename trims whitespace before sending")
        precondition(model.sessions[0].title == "改过的标题","confirmed rename updates the local row")
        let emptyTitleBefore = model.sessions[0].title
        await model.rename(sessionID:"opened", title:"   ")
        precondition(model.sessions[0].title == emptyTitleBefore,"blank rename is rejected locally, not sent")
        precondition(!model.sessionActionBusy,"busy flag must be released after every action")
        await model.togglePin(sessionID:"opened")
        precondition(HermesAPI.lastPin?.1 == true && model.sessions[0].pinned == true,"pin toggles from current state")
        await model.togglePin(sessionID:"opened")
        precondition(HermesAPI.lastPin?.1 == false && model.sessions[0].pinned == false,"second toggle unpins")
        await model.archive(sessionID:"opened")
        precondition(HermesAPI.lastArchive == "opened","archive hits the route")
        precondition(model.currentSessionID == nil && model.sessions.isEmpty,"archived session leaves both the list and the chat")
        model.sessions = [SessionSummary.placeholder(id:"doomed")]
        await model.delete(sessionID:"doomed")
        precondition(HermesAPI.lastDelete == "doomed" && model.sessions.isEmpty,"delete removes the row")
        let scope = model.historyAccountScope
        let backendBeforeRetirement = model.api
        model.openSession(SessionSummary.placeholder(id: "cached-open"))
        // P0-12：401/403 只提示登录，**绝不**销毁本地数据。远程可注入的 401
        // 不能成为远程清空草稿/历史的手段；真正的退役只发生在凭证校验成功后。
        model.needsLogin = true
        precondition(model.api === backendBeforeRetirement,
                     "login-required must not recreate the backend (no remote data destruction)")
        precondition(model.historyAccountScope == scope,
                     "login-required must keep the account namespace so drafts survive")
        precondition(model.currentSessionID == "cached-open",
                     "login-required keeps the open conversation readable")
        model.needsLogin = false
        precondition(model.historyAccountScope == scope, "repeated login-state publications do not churn namespaces")
        model.openSession(SessionSummary.placeholder(id: "still-open"))
        precondition(model.currentSessionID == "still-open", "login-required state does not close conversations")
        // ---- A05: 搜索/归档行打开的会话（openedSession）setModel 后本地同步 ----
        model.needsLogin = false
        model.sessions = []
        model.openSession(SessionSummary.placeholder(id:"search-model"))
        let searchSwitched = await model.setModel(catalog!.options[0], for:"search-model")
        precondition(searchSwitched && HermesAPI.lastModelSet?.0 == "search-model","set model hits the session route for an opened search hit")
        precondition(model.currentSession?.model == "m1","setModel on an opened non-list session updates the visible row")
        model.closeSession()
        HermesAPI.confirmedModelHistory = false
        // ---- A01: 切实例必须重置目录与会话操作状态 ----
        // The login-loss retirement above now also clears the catalog (part of
        // the A01 fix), so load it again to set up the reset check.
        await model.loadModels()
        precondition(model.modelCatalog != nil,"catalog loaded for the reset check")
        model.catalogLoading = true
        model.sessionActionBusy = true
        model.sessionActionError = "stale"
        model.switchTo(model.activeIndex)
        precondition(model.modelCatalog == nil && !model.catalogLoading,"switching instances must drop the old instance's model catalog")
        precondition(!model.sessionActionBusy && model.sessionActionError == nil,"switching instances must reset session action state")
        // ---- A02: 实例地址校验 ----
        let urlBaseline = model.instances.count
        model.addInstance(name:"坏查询",url:"https://host.example/?view=chat")
        precondition(model.instances.count == urlBaseline && model.errorText != nil,"query strings must be rejected")
        model.addInstance(name:"坏锚点",url:"https://host.example/#frag")
        precondition(model.instances.count == urlBaseline,"fragments must be rejected")
        model.addInstance(name:"坏路径",url:"https://host.example/a/../b")
        precondition(model.instances.count == urlBaseline,"dot-dot paths must be rejected")
        model.addInstance(name:"公网明文",url:"http://host.example/base")
        precondition(model.instances.count == urlBaseline && model.errorText != nil,
                     "public cleartext HTTP cannot be saved as an instance")
        precondition(AppState.validatedInstanceURL("http://192.168.1.10:8642") != nil,
                     "LAN HTTP is accepted by both input and transport policy")
        model.addInstance(name:"正规",url:"https://host.example/base")
        precondition(model.instances.count == urlBaseline + 1 && model.instances.last?.baseURL == "https://host.example/base","plain base URLs are accepted verbatim")
        // ---- A02: normalizedBaseURL ----
        precondition(AppState.normalizedBaseURL("https://host.example/base/") == "https://host.example/base","trailing slash is trimmed")
        precondition(AppState.normalizedBaseURL("https://host.example/base?view=chat") == "https://host.example/base","legacy query is stripped for the attachment policy")
        precondition(AppState.normalizedBaseURL("https://host.example/base#frag") == "https://host.example/base","legacy fragment is stripped for the attachment policy")
        precondition(AppState.normalizedBaseURL("https://host.example/a/../b") == nil,"dot-dot paths are rejected")
        precondition(AppState.normalizedBaseURL("http://host.example/base") == nil,"public plaintext http is rejected")
        precondition(AppState.normalizedBaseURL("http://192.168.1.10:8642") == "http://192.168.1.10:8642","LAN plaintext http is allowed")
        precondition(AppState.normalizedBaseURL("http://localhost:8642") == "http://localhost:8642","loopback plaintext http is allowed")
        precondition(AppState.normalizedBaseURL("http://10.0.0.5:8642") == "http://10.0.0.5:8642","10/8 plaintext http is allowed")
        precondition(AppState.normalizedBaseURL("http://172.16.3.4:8642") == "http://172.16.3.4:8642","172.16/12 plaintext http is allowed")
        precondition(AppState.normalizedBaseURL("https://host.example/base") == "https://host.example/base","public https is allowed")
        // ---- A02: 模型目录解析边界 ----
        do {
            _ = try ModelCatalog(data: Data(#"{"groups":{"unexpected":true}}"#.utf8))
            precondition(false,"non-array groups must throw malformed")
        } catch let error as ModelCatalogError {
            if case .malformed = error {} else { precondition(false,"non-array groups must throw ModelCatalogError.malformed") }
        } catch {
            precondition(false,"non-array groups must throw ModelCatalogError.malformed")
        }
        let emptyCatalog = try ModelCatalog(data: Data(#"{"groups":[]}"#.utf8))
        precondition(emptyCatalog.options.isEmpty,"empty groups remains a legal empty catalog")
        do {
            _ = try ModelCatalog(data: Data(#"{"error":"x"}"#.utf8))
            precondition(false,"error payload must still throw")
        } catch {
            precondition("\(error)".contains("x"),"server error text preserved")
        }
        // ---- A01: rename 在途时切实例，旧结果不得写回新实例的列表 ----
        HermesAPI.holdRenames = true
        let raceA = HermesInstance(name:"Race A",baseURL:"https://race-a.example")
        let raceB = HermesInstance(name:"Race B",baseURL:"https://race-b.example")
        try InstanceStore.save([raceA,raceB], credentials: credentials); InstanceStore.activeID = raceA.id
        HermesAPI.heldLists = [raceA.baseURL,raceB.baseURL]
        let raceModel = AppState(credentials: credentials)
        raceModel.sessions = [SessionSummary.placeholder(id:"r1")]
        let renameTask = Task { await raceModel.rename(sessionID:"r1",title:"旧实例改名") }
        await spin { HermesAPI.pendingRename != nil }
        raceModel.switchTo(1)
        await spin { HermesAPI.pendingLists[raceB.baseURL] != nil }
        HermesAPI.pendingLists.removeValue(forKey: raceB.baseURL)!.resume(returning:[SessionSummary.placeholder(id:"r1")])
        await spin { raceModel.sessions.first?.id == "r1" }
        HermesAPI.pendingRename?.resume()
        HermesAPI.pendingRename = nil
        await renameTask.value
        precondition(HermesAPI.lastRename?.1 == "旧实例改名","the in-flight rename reached the old instance's API")
        precondition(raceModel.sessions.count == 1 && raceModel.sessions[0].sessionId == "r1" && raceModel.sessions[0].title == "新会话","a rename dispatched on instance A must not pollute instance B's list")
        precondition(!raceModel.sessionActionBusy && raceModel.sessionActionError == nil,"rejected write-back leaves no busy flag and no leaked error")
        HermesAPI.holdRenames = false
        HermesAPI.heldLists = []
        // build182: creation is not a POST receipt. Verify the independent
        // one-shot handoff, persisted draft and attachment-only navigation.
        let homeApp = AppState(credentials: credentials)
        let homeInstance = homeApp.historyInstanceID
        let homeAccount = homeApp.historyAccountScope
        let created = await homeApp.createSessionForHomeTurn("first safe message", model: nil)
        precondition(created && homeApp.currentSessionID != nil,
                     "home send first creates a session, not a chat POST")
        let homeSID = homeApp.currentSessionID!
        precondition(homeApp.sessions.contains(where: { $0.sessionId == homeSID }),
                     "created Session is visible in drawer without an extra GET")
        let persisted = ChatDraftStore(instanceID: homeInstance, accountScope: homeAccount,
                                       sessionID: homeSID, fileStore: LocalDataFileStore(
                instanceID: homeInstance, accountScope: homeAccount, sessionID: homeSID))
        precondition(persisted.load() == "first safe message",
                     "native Session draft must be persisted before handoff")
        precondition(homeApp.consumeHomeTurn(for: homeSID) == "first safe message",
                     "only the matching Session may claim first-turn text")
        precondition(homeApp.consumeHomeTurn(for: homeSID) == nil,
                     "chat page remount never submits the same first turn twice")
        homeApp.closeSession()
        let staged = await homeApp.createSessionForHomeTurn("text with image", model: nil,
                                                            sendImmediately: false)
        precondition(staged && homeApp.currentSessionID != nil,
                     "home Plus creates attachment-capable Session")
        let attachmentSID = homeApp.currentSessionID!
        precondition(homeApp.consumeHomeTurn(for: attachmentSID) == nil,
                     "attachment staging never issues a first-turn POST")
        precondition(homeApp.consumeHomeAttachmentRequest(for: attachmentSID)
                     && !homeApp.consumeHomeAttachmentRequest(for: attachmentSID),
                     "native attachment chooser request is also consumed once")
        precondition(ChatDraftStore(instanceID: homeInstance, accountScope: homeAccount,
                                   sessionID: attachmentSID, fileStore: LocalDataFileStore(
                    instanceID: homeInstance, accountScope: homeAccount,
                    sessionID: attachmentSID)).load() == "text with image",
                     "attachment transfer preserves typed text for manual send")
        homeApp.closeSession()
        precondition(!homeApp.consumeHomeAttachmentRequest(for: attachmentSID),
                     "closing Session cancels any staged attachment chooser")
        print("HOME_DELIVERY_PASS one-shot, draft, drawer and attachment staging")

        try await homeCreateNavigationTests()
        try await webUIHomeModelTests()
        try await modelSwitchReadbackTests()
        try pendingRequestRestartTests()
        try await unifiedSessionNavigationTests()
        foregroundListPolicyTests()
        try await refreshTests()
        try await completionRefreshTests()
        try await instanceDeletionCacheTests()
        try await sessionRefreshPolicyTests()
        try await sessionRefreshFeedbackTests()
        try await deletionScopeTests()
        try await gatewayCredentialTests()
        try await gatewayKeyScopeRaceTests()
        try await instanceEditingTests()
        // #89: a delayed cross-session GET cannot retire a newer accepted Run
        // or a pending POST written while the read was in flight.
        let originalReceipt = Data("run-1".utf8)
        let replacementReceipt = Data("run-2".utf8)
        precondition(SessionRecoveryCoordinator.mayRetireStoredReceipt(
            expected: originalReceipt, current: originalReceipt, pendingIsEmpty: true),
            "unchanged receipt may retire after authoritative terminal proof")
        precondition(!SessionRecoveryCoordinator.mayRetireStoredReceipt(
            expected: originalReceipt, current: replacementReceipt, pendingIsEmpty: true),
            "stale GET cannot erase a newer accepted Run")
        precondition(!SessionRecoveryCoordinator.mayRetireStoredReceipt(
            expected: originalReceipt, current: originalReceipt, pendingIsEmpty: false),
            "stale GET cannot erase accepted receipt while a new POST is pending")
        precondition(!SessionRecoveryCoordinator.mayRetireStoredReceipt(
            expected: originalReceipt, current: nil, pendingIsEmpty: true),
            "already-cleared receipt cannot be retired again")
        print("RECOVERY_RECEIPT_RACE_PASS same-run, replacement, pending and cleared")
        print("APPSTATE_PASS stale list/create isolation, session actions, account isolation, authentication retirement and awaited coalesced refresh")
    }
}

// 直连网关改造后 AppState 面对的是 HermesBackend 协议；本测试只验证本地状态迁移，
// 所以给替身补齐协议要求的最小实现，网络行为仍在各自场景里桩控。
extension HermesAPI: HermesBackend {
    /// 替身模拟本地 WebUI：能力表给完整能力，测试不关心网关分支。
    var capabilities: BackendCapabilities { Self.capabilitiesOverride ?? .webUI }
    var attachmentBaseURL: URL { URL(string: "https://a.example")! }
    var webConsoleBaseURL: URL { URL(string: "https://a.example")! }
    func performNative(_ request: URLRequest) async throws -> Data { Data() }
    func uploadAttachment(_ request: URLRequest,
                          onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> Data { Data() }
    func syncCookiesToWebKit() async {}
    func requiresAuthentication(after error: Error) -> Bool { false }
    func createSession(title: String?, model: String?) async throws -> String {
        try await createNativeSession()
    }
    func forkSession(sessionID: String, keepCount: Int?) async throws -> String { "forked" }
    func startNativeTurn(sessionID: String, text: String) async throws -> String { "stream" }
    func startNativeTurn(sessionID: String, text: String,
                         attachments: [ChatAttachmentPayload]) async throws -> String { "stream" }
    func stopNativeTurn(streamID: String) async throws {}
    func steerNativeTurn(sessionID: String, text: String) async throws -> String? { nil }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {}
}
