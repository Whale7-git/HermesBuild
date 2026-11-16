import Foundation

/// Known remote Session IDs from a partially completed create operation.
/// Only opaque IDs are persisted, never message text, model options or keys.
/// A timed-out create with NO returned ID cannot be recovered here; the caller
/// must ask the user to compare the authoritative remote Session list.
enum CreatedSessionRecoveryStore {
    private static let prefix = "HermesSessions.createdRecovery.v1."
    private static let limit = 32

    static func key(instanceID: String, accountScope: String) -> String {
        let encoded = (try? JSONEncoder().encode([instanceID, accountScope]))?.base64EncodedString() ?? ""
        return prefix + encoded
    }

    static func known(instanceID: String, accountScope: String,
                      defaults: UserDefaults = .standard) -> [String] {
        let key = key(instanceID: instanceID, accountScope: accountScope)
        return Array(Set(defaults.stringArray(forKey: key) ?? []).filter { !$0.isEmpty }).sorted()
    }

    @discardableResult
    static func remember(_ sessionID: String, instanceID: String, accountScope: String,
                         defaults: UserDefaults = .standard) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let key = key(instanceID: instanceID, accountScope: accountScope)
        var ids = known(instanceID: instanceID, accountScope: accountScope, defaults: defaults)
        ids.removeAll { $0 == sessionID }
        ids.append(sessionID)
        defaults.set(Array(ids.suffix(limit)), forKey: key)
        return defaults.stringArray(forKey: key)?.contains(sessionID) == true
    }

    static func reconcile(authoritative: Set<String>, instanceID: String,
                          accountScope: String, defaults: UserDefaults = .standard) -> [String] {
        let key = key(instanceID: instanceID, accountScope: accountScope)
        let missing = known(instanceID: instanceID, accountScope: accountScope,
                            defaults: defaults).filter { !authoritative.contains($0) }
        if missing.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(missing, forKey: key) }
        return missing
    }
}
