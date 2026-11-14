import Foundation

/// Last successful home-list refresh, scoped by instance and account. The value
/// is explanatory UI state only; it never participates in session ordering.
final class SessionRefreshClock {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSuccess(scope: String) -> Date? {
        guard !scope.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[scope] { return cached }
        let interval = defaults.double(forKey: key(scope))
        guard interval > 0 else { return nil }
        let date = Date(timeIntervalSince1970: interval)
        cache[scope] = date
        return date
    }

    func recordSuccess(scope: String, at date: Date = Date()) {
        guard !scope.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        cache[scope] = date
        defaults.set(date.timeIntervalSince1970, forKey: key(scope))
    }

    func remove(scope: String) {
        guard !scope.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: scope)
        defaults.removeObject(forKey: key(scope))
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        for scope in cache.keys { defaults.removeObject(forKey: key(scope)) }
        cache = [:]
    }

    private func key(_ scope: String) -> String {
        "Hermes.sessionRefresh.lastSuccess." + Data(scope.utf8).base64EncodedString()
    }
}
