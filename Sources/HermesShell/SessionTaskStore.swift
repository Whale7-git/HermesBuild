import Foundation

/// Persists only opaque session IDs and task categories for the active
/// instance/account scope. Message text, titles, paths and credentials never
/// enter this store.
enum SessionTaskStore {
    private static let prefix = "HermesSessions.tasks.v1."

    static func key(instanceID: String, accountScope: String) -> String {
        let parts = [instanceID, accountScope]
        let digest = (try? JSONEncoder().encode(parts))?.base64EncodedString() ?? ""
        return prefix + digest
    }

    static func load(instanceID: String, accountScope: String,
                     defaults: UserDefaults = .standard) -> [String: SessionTaskObservation] {
        let key = key(instanceID: instanceID, accountScope: accountScope)
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: SessionTaskObservation].self, from: data) else {
            return [:]
        }
        return decoded.mapValues { value in
            SessionTaskObservation(
                signals: SessionTaskCenter.persistable(value.signals),
                observedAt: Date(timeIntervalSince1970: value.observedAt))
        }
    }

    @discardableResult
    static func save(_ values: [String: SessionTaskObservation],
                     instanceID: String, accountScope: String,
                     defaults: UserDefaults = .standard) -> Bool {
        let key = key(instanceID: instanceID, accountScope: accountScope)
        let cleaned = values.filter { !$0.value.signals.isEmpty }.mapValues { value in
            SessionTaskObservation(
                signals: SessionTaskCenter.persistable(value.signals),
                observedAt: Date(timeIntervalSince1970: value.observedAt))
        }
        if cleaned.isEmpty {
            defaults.removeObject(forKey: key)
            return defaults.data(forKey: key) == nil
        }
        guard let data = try? JSONEncoder().encode(cleaned) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    static func remove(instanceID: String, accountScope: String,
                       defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(instanceID: instanceID, accountScope: accountScope))
    }
}
