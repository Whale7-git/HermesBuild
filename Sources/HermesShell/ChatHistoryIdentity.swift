import Foundation

/// Cache namespaces use app-owned identities, never cookies or passwords.
enum ChatHistoryIdentity {
    static func instanceID(id: UUID, baseURL: String) -> String {
        // `[String]` 编码实际不会失败；这里不用 `try!`，失败时退回长度前缀编码。
        // 两种编码都是单射，所以不同 (id, baseURL) 仍不可能落到同一个缓存命名空间。
        if let data = try? JSONEncoder().encode([id.uuidString, baseURL]) {
            return data.base64EncodedString()
        }
        let fallback = [id.uuidString, baseURL].map { "\($0.utf8.count):\($0)" }.joined()
        return "len:" + Data(fallback.utf8).base64EncodedString()
    }

    static func accountScope(instanceID: String, defaults: UserDefaults = .standard) -> String {
        let key = "HermesNative.historyAccount.v1." + instanceID
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    @discardableResult
    static func rotate(instanceID: String, defaults: UserDefaults = .standard) -> String {
        let previous = accountScope(instanceID: instanceID, defaults: defaults)
        defaults.set(UUID().uuidString, forKey: "HermesNative.historyAccount.v1." + instanceID)
        return previous
    }
}
