import Foundation

/// Plain-text local drafts, scoped to the exact server instance, account and session.
/// No credentials or cookies are stored here.
struct ChatDraftStore {
    private let defaults: UserDefaults
    private let fileStore: LocalDataFileStore?
    private let key: String
    /// v1 key to clear on save when migrating away from the account-less layout.
    private let legacyKey: String?

    /// Legacy two-parameter initializer (v1). Kept for the drafts/model test
    /// groups: no account dimension, v1 key, identical UserDefaults semantics.
    init(instanceID: String, sessionID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fileStore = nil
        self.key = "HermesNative.chatDraft.v1." + Self.encodedTuple([instanceID, sessionID])
        self.legacyKey = nil
    }

    /// Account-scoped UserDefaults initializer. Offline suites pass an isolated
    /// suite here; production uses the verified file-backed initializer below.
    init(instanceID: String, accountScope: String, sessionID: String,
         legacyBaseURL: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fileStore = nil
        self.key = "HermesNative.chatDraft.v2." + Self.encodedTuple([instanceID, accountScope, sessionID])
        if let legacy = legacyBaseURL {
            self.legacyKey = "HermesNative.chatDraft.v1." + Self.encodedTuple([legacy, sessionID])
        } else {
            self.legacyKey = nil
        }
    }

    /// Production storage. The protected file is authoritative. The existing
    /// account-scoped UserDefaults value remains a migration source until a
    /// verified file write and read-back both succeed.
    init(instanceID: String, accountScope: String, sessionID: String,
         legacyBaseURL: String? = nil, defaults: UserDefaults = .standard,
         fileStore: LocalDataFileStore) {
        self.defaults = defaults
        self.fileStore = fileStore
        self.key = "HermesNative.chatDraft.v2." + Self.encodedTuple([instanceID, accountScope, sessionID])
        if let legacy = legacyBaseURL {
            self.legacyKey = "HermesNative.chatDraft.v1." + Self.encodedTuple([legacy, sessionID])
        } else {
            self.legacyKey = nil
        }
    }

    /// Keys use the JSON encoding of the tuple, not a delimiter-joined string,
    /// so `["a:b", "c"]` and `["a", "b:c"]` cannot collide.
    private static func encodedTuple(_ values: [String]) -> String {
        if let data = try? JSONEncoder().encode(values) { return data.base64EncodedString() }
        let fallback = values.map { "\($0.utf8.count):\($0)" }.joined()
        return "len:" + Data(fallback.utf8).base64EncodedString()
    }

    func loadPending() -> (value: Data?, result: LocalStoreWriteResult) {
        if let fileStore { return fileStore.loadPending() }
        return (defaults.data(forKey: key + ".pending"), .ok)
    }

    @discardableResult
    func savePending(_ value: Data?) -> LocalStoreWriteResult {
        if let fileStore { return fileStore.savePending(value) }
        if let value { defaults.set(value, forKey: key + ".pending") }
        else { defaults.removeObject(forKey: key + ".pending") }
        return defaults.data(forKey: key + ".pending") == value ? .ok : .failed(.diskWrite)
    }

    /// Accepted run receipt: independent from pre-POST PendingSend.
    func loadActiveRun() -> (value: Data?, result: LocalStoreWriteResult) {
        if let fileStore { return fileStore.loadActiveRun() }
        return (defaults.data(forKey: key + ".activeRun"), .ok)
    }

    @discardableResult
    func saveActiveRun(_ value: Data?) -> LocalStoreWriteResult {
        if let fileStore { return fileStore.saveActiveRun(value) }
        if let value { defaults.set(value, forKey: key + ".activeRun") }
        else { defaults.removeObject(forKey: key + ".activeRun") }
        return defaults.data(forKey: key + ".activeRun") == value
            ? .ok : .failed(.diskWrite)
    }

    func loadAttachmentDraft() -> (value: Data?, result: LocalStoreWriteResult) {
        if let fileStore { return fileStore.loadAttachmentDraft() }
        return (defaults.data(forKey: key + ".attachments"), .ok)
    }

    @discardableResult
    func saveAttachmentDraft(_ value: Data?) -> LocalStoreWriteResult {
        if let fileStore { return fileStore.saveAttachmentDraft(value) }
        if let value { defaults.set(value, forKey: key + ".attachments") }
        else { defaults.removeObject(forKey: key + ".attachments") }
        return defaults.data(forKey: key + ".attachments") == value
            ? .ok : .failed(.diskWrite)
    }

    func load() -> String { loadDraftResult().value }

    func loadDraftResult() -> (value: String, result: LocalStoreWriteResult) {
        guard let fileStore else {
            return (defaults.string(forKey: key) ?? "", .ok)
        }
        let loaded = fileStore.loadDraft()
        if let value = loaded.value { return (value, loaded.result) }
        return migrateDraftIfAvailable(loaded)
    }

    @discardableResult
    func save(_ value: String) -> LocalStoreWriteResult {
        guard let fileStore else {
            if let legacy = legacyKey { defaults.removeObject(forKey: legacy) }
            if value.isEmpty { defaults.removeObject(forKey: key) }
            else { defaults.set(value, forKey: key) }
            return .ok
        }
        let result = value.isEmpty ? fileStore.removeDraft() : fileStore.saveDraft(value)
        guard result.succeeded else { return result }
        if let legacy = legacyKey { defaults.removeObject(forKey: legacy) }
        defaults.removeObject(forKey: key)
        return result
    }

    func validateStoredData() -> LocalStoreWriteResult {
        guard fileStore != nil else { return .ok }
        let draft = loadDraftResult()
        if !draft.result.succeeded { return draft.result }
        let queue = loadQueuedResult()
        if !queue.result.succeeded { return queue.result }
        let pending = loadPending().result
        if !pending.succeeded { return pending }
        let active = loadActiveRun().result
        return active.succeeded ? loadAttachmentDraft().result : active
    }

    /// The attachment editor owns bytes that can be large enough to exceed the
    /// 48 MB attachment envelope only after JSON/base64 expansion. Probe the
    /// exact encoded payload without replacing a previously good snapshot.
    func attachmentDraftFits(_ value: Data?) -> Bool {
        guard let value else { return true }
        guard let encoded = try? JSONEncoder().encode(value) else { return false }
        return encoded.count <= 47 * 1024 * 1024
    }

    /// An unsent queued turn shares this exact account/session namespace. It
    /// contains text and uploaded references only; restoring it never submits.
    func loadQueued() -> Data? { loadQueuedResult().value }

    func loadQueuedResult() -> (value: Data?, result: LocalStoreWriteResult) {
        guard let fileStore else {
            return (defaults.data(forKey: key + Self.queuedSuffix), .ok)
        }
        let loaded = fileStore.loadQueue()
        if let value = loaded.value { return (value, loaded.result) }
        return migrateQueueIfAvailable(loaded)
    }

    /// Retry a failed migration without touching the legacy copy until the new
    /// file has passed its own read-back validation.
    func retryMigration() -> (draft: LocalStoreWriteResult, queue: LocalStoreWriteResult) {
        guard let fileStore else { return (.ok, .ok) }
        let draftLoaded = fileStore.loadDraft()
        let queueLoaded = fileStore.loadQueue()
        let draft = migrateDraftIfAvailable(draftLoaded)
        let queue = migrateQueueIfAvailable(queueLoaded)
        return (draft.result, queue.result)
    }

    /// Passing nil explicitly clears the queue. Empty bytes are rejected and
    /// never replace a previously readable queue with an unreadable blob.
    @discardableResult
    func saveQueued(_ value: Data?) -> LocalStoreWriteResult {
        if let value, value.isEmpty { return .failed(.encoding) }
        guard let fileStore else {
            if let value { defaults.set(value, forKey: key + Self.queuedSuffix) }
            else { defaults.removeObject(forKey: key + Self.queuedSuffix) }
            return .ok
        }
        let result = fileStore.saveQueue(value)
        if result.succeeded { defaults.removeObject(forKey: key + Self.queuedSuffix) }
        return result
    }

    /// The explicit user pause is a preference, NOT a recovery error. Store
    /// only a scoped Boolean, never message text or credentials, and keep it
    /// independent from the queued-turn data so an empty queue retains intent.
    func loadQueueUserPaused() -> Bool {
        defaults.bool(forKey: key + ".queueUserPaused")
    }

    @discardableResult
    func saveQueueUserPaused(_ paused: Bool) -> LocalStoreWriteResult {
        let name = key + ".queueUserPaused"
        if paused { defaults.set(true, forKey: name) }
        else { defaults.removeObject(forKey: name) }
        return defaults.bool(forKey: name) == paused ? .ok : .failed(.diskWrite)
    }

    /// Remove both draft and queue for this session.
    func remove() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: key + Self.queuedSuffix)
        defaults.removeObject(forKey: key + ".pending")
        defaults.removeObject(forKey: key + ".activeRun")
        defaults.removeObject(forKey: key + ".attachments")
        defaults.removeObject(forKey: key + ".queueUserPaused")
        if let legacy = legacyKey { defaults.removeObject(forKey: legacy) }
        _ = fileStore?.remove()
    }

    /// Remove every draft and queue in one instance + account namespace.
    @discardableResult
    static func removeAll(instanceID: String, accountScope: String,
                          defaults: UserDefaults = .standard,
                          fileRootDirectory: URL = LocalDataFileStore.defaultRoot) -> LocalStoreWriteResult {
        // A v1 key stores the original base URL instead of a scoped identity.
        // Decode the exact stable instance identity, never sweep other hosts.
        let legacyBaseURL: String? = {
            guard let data = Data(base64Encoded: instanceID),
                  let tuple = try? JSONDecoder().decode([String].self, from: data),
                  tuple.count == 2, UUID(uuidString: tuple[0]) != nil else { return nil }
            return tuple[1]
        }()
        for name in defaults.dictionaryRepresentation().keys {
            let isLegacy = name.hasPrefix(legacyPrefix)
            guard name.hasPrefix(prefix) || isLegacy else { continue }
            guard let tuple = decodeTuple(name) else { continue }
            if isLegacy {
                // v1 is account-less but *not* host-less. If the host cannot
                // be identified safely, leave that legacy record untouched.
                guard let legacyBaseURL, tuple.count >= 2,
                      tuple[0] == legacyBaseURL else { continue }
                defaults.removeObject(forKey: name)
                continue
            }
            guard tuple.count >= 2, tuple[0] == instanceID, tuple[1] == accountScope else { continue }
            defaults.removeObject(forKey: name)
        }
        return LocalDataFileStore.removeAll(instanceID: instanceID, accountScope: accountScope,
                                            rootDirectory: fileRootDirectory)
    }

    /// Remove one session from both the migration source and the file store.
    @discardableResult
    static func removeSession(instanceID: String, accountScope: String, sessionID: String,
                              defaults: UserDefaults = .standard,
                              fileRootDirectory: URL = LocalDataFileStore.defaultRoot) -> LocalStoreWriteResult {
        let key = "HermesNative.chatDraft.v2." + encodedTuple([instanceID, accountScope, sessionID])
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: key + queuedSuffix)
        defaults.removeObject(forKey: key + ".pending")
        defaults.removeObject(forKey: key + ".activeRun")
        defaults.removeObject(forKey: key + ".attachments")
        defaults.removeObject(forKey: key + ".queueUserPaused")
        let fileStore = LocalDataFileStore(instanceID: instanceID, accountScope: accountScope,
                                           sessionID: sessionID, rootDirectory: fileRootDirectory)
        return fileStore.remove()
    }

    private static let prefix = "HermesNative.chatDraft.v2."
    private static let legacyPrefix = "HermesNative.chatDraft.v1."
    private static let queuedSuffix = ".queued"

    private func migrateDraftIfAvailable(
        _ loaded: (value: String?, result: LocalStoreWriteResult)
    ) -> (value: String, result: LocalStoreWriteResult) {
        guard loaded.value == nil,
              let legacy = defaults.string(forKey: key), !legacy.isEmpty else {
            return ("", loaded.result)
        }
        guard loaded.result.succeeded, let fileStore else { return (legacy, loaded.result) }
        let written = fileStore.saveDraft(legacy)
        guard written.succeeded else { return (legacy, written) }
        defaults.removeObject(forKey: key)
        return (legacy, .ok)
    }

    private func migrateQueueIfAvailable(
        _ loaded: (value: Data?, result: LocalStoreWriteResult)
    ) -> (value: Data?, result: LocalStoreWriteResult) {
        guard loaded.value == nil,
              let legacy = defaults.data(forKey: key + Self.queuedSuffix) else {
            return (nil, loaded.result)
        }
        guard loaded.result.succeeded, let fileStore else { return (legacy, loaded.result) }
        let written = fileStore.saveQueue(legacy)
        guard written.succeeded else { return (legacy, written) }
        defaults.removeObject(forKey: key + Self.queuedSuffix)
        return (legacy, .ok)
    }

    private static func decodeTuple(_ name: String) -> [String]? {
        let base = name.hasSuffix(".pending") ? String(name.dropLast(8))
            : (name.hasSuffix(".activeRun") ? String(name.dropLast(10)) : name)
        let name = base.hasSuffix(queuedSuffix) ? String(base.dropLast(queuedSuffix.count)) : base
        let encoded: String
        if name.hasPrefix(prefix) { encoded = String(name.dropFirst(prefix.count)) }
        else if name.hasPrefix(legacyPrefix) { encoded = String(name.dropFirst(legacyPrefix.count)) }
        else { return nil }
        guard let data = Data(base64Encoded: encoded),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return value
    }
}
