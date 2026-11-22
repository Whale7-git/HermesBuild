import Foundation

/// Only opaque run/session IDs are retained; credentials and message text never enter this store.
@MainActor
final class GatewayRunStore {
    private let defaults: UserDefaults?
    private let key: String
    private let unresolvedKey: String
    private let generationKey: String
    private let generation: String
    private var values: [String: String]
    private var unresolvedValues: [String: String]
    private var activePersistenceFailed = false
    private var unresolvedPersistenceFailed = false

    var persistenceFailed: Bool { activePersistenceFailed || unresolvedPersistenceFailed }
    private var didDiagnoseRetired = false

    init(scope: String?, defaults: UserDefaults = .standard) {
        self.defaults = scope == nil ? nil : defaults
        key = "HermesNative.gatewayRuns.v1." + (scope ?? "ephemeral")
        unresolvedKey = "HermesNative.gatewayUnresolvedRuns.v1." + (scope ?? "ephemeral")
        generationKey = "HermesNative.gatewayRunGeneration.v1." + (scope ?? "ephemeral")
        generation = defaults.string(forKey: generationKey) ?? UUID().uuidString
        if scope != nil { defaults.set(generation, forKey: generationKey) }
        values = scope == nil ? [:] : (defaults.dictionary(forKey: key) as? [String: String] ?? [:])
        unresolvedValues = scope == nil ? [:]
            : (defaults.dictionary(forKey: unresolvedKey) as? [String: String] ?? [:])
    }

    private var isValid: Bool {
        defaults == nil || defaults?.string(forKey: generationKey) == generation
    }

    private func current() -> [String: String] {
        guard isValid else { noteRetired(); return [:] }
        if activePersistenceFailed { return values }
        if let defaults { return defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        return values
    }

    private func currentUnresolved() -> [String: String] {
        guard isValid else { noteRetired(); return [:] }
        if unresolvedPersistenceFailed { return unresolvedValues }
        if let defaults {
            return defaults.dictionary(forKey: unresolvedKey) as? [String: String] ?? [:]
        }
        return unresolvedValues
    }

    private func noteRetired() {
        guard !didDiagnoseRetired else { return }
        didDiagnoseRetired = true
        Self.diagnose("run records unavailable: generation rotated, this scope instance is retired")
    }

    private func persist(_ values: [String: String]) -> Bool {
        guard let defaults else { return true }
        defaults.set(values, forKey: key)
        _ = defaults.synchronize()
        let readBack = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return readBack == values
    }

    private func persistUnresolved(_ values: [String: String]) -> Bool {
        guard let defaults else { return true }
        defaults.set(values, forKey: unresolvedKey)
        _ = defaults.synchronize()
        let readBack = defaults.dictionary(forKey: unresolvedKey) as? [String: String] ?? [:]
        return readBack == values
    }

    /// Only verified active runs are returned to the session-list running indicator.
    /// An unresolved record is retained separately so a later probe can re-arm it.
    func runID(for sessionID: String) -> String? {
        let active = current()[sessionID]
        return active == currentUnresolved()[sessionID] ? nil : active
    }

    func unresolvedRunID(for sessionID: String) -> String? {
        currentUnresolved()[sessionID]
    }

    func runIDs(for sessionIDs: [String]) -> [String: String] {
        let active = current()
        let unresolved = currentUnresolved()
        var found: [String: String] = [:]
        for sessionID in sessionIDs {
            if let runID = active[sessionID], unresolved[sessionID] != runID {
                found[sessionID] = runID
            }
        }
        return found
    }

    func unresolvedRunIDs(for sessionIDs: [String]) -> [String: String] {
        let unresolved = currentUnresolved()
        return Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { id in
            unresolved[id].map { (id, $0) }
        })
    }

    func remember(runID: String, sessionID: String) {
        guard isValid else { noteRetired(); return }
        unresolvedValues = currentUnresolved()
        unresolvedValues.removeValue(forKey: sessionID)
        unresolvedPersistenceFailed = !persistUnresolved(unresolvedValues)
        values = current()
        values[sessionID] = runID
        activePersistenceFailed = !persist(values)
    }

    func markUnresolved(runID: String, sessionID: String) {
        guard isValid else { noteRetired(); return }
        // Persist unresolved first so a crash cannot leave a stale active indicator.
        unresolvedValues = currentUnresolved()
        unresolvedValues[sessionID] = runID
        unresolvedPersistenceFailed = !persistUnresolved(unresolvedValues)
        values = current()
        if values[sessionID] == runID { values.removeValue(forKey: sessionID) }
        activePersistenceFailed = !persist(values)
    }

    func finish(runID: String) {
        guard isValid else { noteRetired(); return }
        values = current().filter { $0.value != runID }
        activePersistenceFailed = !persist(values)
        unresolvedValues = currentUnresolved().filter { $0.value != runID }
        unresolvedPersistenceFailed = !persistUnresolved(unresolvedValues)
    }

    private static func diagnose(_ message: String) {
        _ = try? FileHandle.standardError.write(contentsOf: Data(("[HermesNative][gateway-run] " + message + "\n").utf8))
    }

    static func removeAll(instanceID: String, accountScope: String? = nil,
                          defaults: UserDefaults = .standard) {
        let prefix = "HermesNative.gatewayRuns.v1." + instanceID + "|"
        let unresolvedPrefix = "HermesNative.gatewayUnresolvedRuns.v1." + instanceID + "|"
        let generationPrefix = "HermesNative.gatewayRunGeneration.v1." + instanceID + "|"
        if let accountScope {
            defaults.removeObject(forKey: prefix + accountScope)
            defaults.removeObject(forKey: unresolvedPrefix + accountScope)
            defaults.set(UUID().uuidString, forKey: generationPrefix + accountScope)
        } else {
            let keys = defaults.dictionaryRepresentation().keys
            let accounts = Set(keys.compactMap { key -> String? in
                if key.hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
                if key.hasPrefix(unresolvedPrefix) { return String(key.dropFirst(unresolvedPrefix.count)) }
                if key.hasPrefix(generationPrefix) { return String(key.dropFirst(generationPrefix.count)) }
                return nil
            })
            for account in accounts {
                defaults.removeObject(forKey: prefix + account)
                defaults.removeObject(forKey: unresolvedPrefix + account)
                defaults.set(UUID().uuidString, forKey: generationPrefix + account)
            }
        }
    }
}
