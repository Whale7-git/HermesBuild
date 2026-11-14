import Foundation
#if canImport(Security)
import Security
#endif

/// An injectable Keychain boundary. Linux tests must provide an explicit mock;
/// the production implementation never falls back to plaintext preferences.
protocol InstanceCredentialStorage: AnyObject {
    func read(reference: String) throws -> String?
    func write(_ value: String, reference: String) throws
    func remove(reference: String) throws
}

enum InstanceCredentialError: LocalizedError {
    case unavailable, operation(Int32), invalidConfiguration
    var errorDescription: String? {
        switch self {
        case .unavailable: return "此环境不支持系统钥匙串，无法安全保存网关密钥。"
        case .operation(let status): return "系统钥匙串操作失败（\(status)），请解锁设备后重试。"
        case .invalidConfiguration: return "实例配置无效，原配置未更改。"
        }
    }
}

final class InstanceCredentialStore: InstanceCredentialStorage {
    #if canImport(Security)
    private let service = "com.whale7.hermes.gateway-api-key.v1"
    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: reference,
         kSecAttrSynchronizable as String: false]
    }
    #endif

    func read(reference: String) throws -> String? {
        #if canImport(Security)
        var request = query(reference)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw InstanceCredentialError.operation(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw InstanceCredentialError.invalidConfiguration
        }
        return value
        #else
        throw InstanceCredentialError.unavailable
        #endif
    }

    func write(_ value: String, reference: String) throws {
        #if canImport(Security)
        var request = query(reference)
        request[kSecValueData as String] = Data(value.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        // Save creates a fresh immutable reference for every changed credential.
        // Updating an old slot would make a later transaction failure destructive.
        guard status == errSecSuccess else { throw InstanceCredentialError.operation(status) }
        #else
        throw InstanceCredentialError.unavailable
        #endif
    }

    func remove(reference: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InstanceCredentialError.operation(status)
        }
        #else
        throw InstanceCredentialError.unavailable
        #endif
    }
}

/// Preferences contain instance metadata and opaque Keychain references only.
/// New secrets are staged in independent slots before the JSON commit. A failed
/// write can leave an unreferenced slot, but cannot damage any existing secret.
struct InstanceStore {
    private static let key = "hermes.instances"
    private static let activeKey = "hermes.activeInstance"
    private static let cleanupKey = "hermes.credentials.pendingCleanup.v1"

    /// Inert setup record keeps the instance model nonempty without a preset host.
    /// AppState rejects the blank address before issuing any network request.
    static let defaultInstanceName = "尚未配置"
    static let defaultInstanceBaseURL = ""
    static let defaultInstanceWebUIBaseURL = ""
    static let defaultInstanceGatewayDataPath = "/opt/data"
    static let defaultInstanceAPIKey = ""

    struct LoadResult {
        let instances: [HermesInstance]
        let warning: String?
    }

    private struct StoredInstance: Codable {
        var instance: HermesInstance
        var reference: String?
        private enum CodingKeys: String, CodingKey { case reference = "credential_ref" }
        init(instance: HermesInstance, reference: String?) {
            self.instance = instance
            self.reference = reference
        }
        init(from decoder: Decoder) throws {
            instance = try HermesInstance(from: decoder)
            reference = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .reference)
        }
        func encode(to encoder: Encoder) throws {
            var metadata = instance
            metadata.apiKey = ""
            try metadata.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(reference, forKey: .reference)
        }
    }

    static func load(defaults: UserDefaults = .standard,
                     credentials: any InstanceCredentialStorage = InstanceCredentialStore()) -> [HermesInstance] {
        loadResult(defaults: defaults, credentials: credentials).instances
    }

    static func loadResult(defaults: UserDefaults = .standard,
                           credentials: any InstanceCredentialStorage = InstanceCredentialStore()) -> LoadResult {
        // A missing preference is a normal first launch. Invalid stored metadata
        // requires an explicit repair warning; both paths return an inert record.
        let rawData = defaults.data(forKey: key)
        let neverConfigured = (rawData == nil)
        let decoded: [StoredInstance]? = rawData.flatMap { try? JSONDecoder().decode([StoredInstance].self, from: $0) }
        let stored = decoded ?? []
        let corrupt = !neverConfigured
            && (decoded == nil || stored.isEmpty || Set(stored.map { $0.instance.id }).count != stored.count)
        guard !corrupt, !stored.isEmpty else {
            // Missing or corrupt configuration produces an inert setup record.
            // Existing valid instances and their Keychain references are unchanged.
            return LoadResult(
                instances: [HermesInstance(name: Self.defaultInstanceName,
                                           baseURL: Self.defaultInstanceBaseURL,
                                           backend: .gateway,
                                           apiKey: Self.defaultInstanceAPIKey,
                                           webuiBaseURL: Self.defaultInstanceWebUIBaseURL,
                                           gatewayDataPath: Self.defaultInstanceGatewayDataPath)],
                // 只有数据损坏才提示。首次启动是正常状态，提示会制造不必要的恐慌。
                warning: corrupt
                    ? "实例配置读取失败，请重新配置网关地址与密钥。"
                    : nil)
        }
        var instances: [HermesInstance] = []
        var failedRead = false
        var needsMigration = false
        for row in stored {
            var instance = row.instance
            if !instance.apiKey.isEmpty {
                needsMigration = true
            } else if let reference = row.reference {
                do {
                    guard valid(reference: reference, owner: instance.id),
                          let secret = try credentials.read(reference: reference), !secret.isEmpty else {
                        throw InstanceCredentialError.invalidConfiguration
                    }
                    instance.apiKey = secret
                } catch { failedRead = true }
            } else if instance.backend == .gateway {
                // Restoring metadata without this-device-only Keychain items
                // must lead to an explicit credential repair, never silent loss.
                failedRead = true
            }
            instances.append(instance)
        }
        if failedRead {
            return LoadResult(instances: instances, warning: "部分网关密钥暂时无法读取，请解锁设备后重新打开，或在实例设置中更新密钥。原配置已保留。")
        }
        if needsMigration {
            do {
                let warning = try save(instances, defaults: defaults, credentials: credentials)
                return LoadResult(instances: instances, warning: warning)
            } catch {
                // A failed secure write must never leave plaintext in preferences.
                // Encode, persist and verify each step instead of treating set()
                // as proof that the scrubbed metadata reached disk.
                let scrubbed = scrubbedInstances(instances)
                let warning = scrubLegacyPlaintext(
                    instances,
                    encode: { try encodeScrubbedMetadata(scrubbedInstances($0)) },
                    write: { defaults.set($0, forKey: key) },
                    read: { defaults.data(forKey: key) })
                return LoadResult(
                    instances: scrubbed,
                    warning: warning)
            }
        }
        let warning = cleanPending(defaults: defaults, credentials: credentials)
        return LoadResult(instances: instances, warning: warning)
    }

    @discardableResult
    static func save(_ list: [HermesInstance], defaults: UserDefaults = .standard,
                     credentials: any InstanceCredentialStorage = InstanceCredentialStore()) throws -> String? {
        guard !list.isEmpty, Set(list.map(\.id)).count == list.count else {
            throw InstanceCredentialError.invalidConfiguration
        }
        let previous = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([StoredInstance].self, from: $0) } ?? []
        let previousByID = Dictionary(previous.map { ($0.instance.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [StoredInstance] = []
        var staged: [String] = []
        do {
            for instance in list {
                let old = previousByID[instance.id]?.reference.flatMap { valid(reference: $0, owner: instance.id) ? $0 : nil }
                var reference = old
                if !instance.apiKey.isEmpty {
                    // F-80：必须区分「Keychain 读取抛错」和「读到了不同的值」。
                    // 旧写法 `try?` 把两者压成 nil，设备刚重启未解锁时每个实例都会被
                    // 判定为「密钥已变更」→ 批量 re-stage 新 slot、旧 slot 入清理队列，
                    // 随后一旦 save 失败，用户原本可用的密钥就被静默丢弃。
                    // 读抛错时整个事务中止并保留原配置：这次保存无法判断真伪，不该动盘。
                    let existing: String?
                    if let old {
                        // 读抛错直接冒泡到外层 catch：那里会回收已 staged 的槽并抛出，
                        // 从而保证 metadata 与旧 slot 都不被改动。
                        existing = try credentials.read(reference: old)
                    } else {
                        existing = nil
                    }
                    if existing != instance.apiKey {
                        let created = instance.id.uuidString + "/" + UUID().uuidString
                        // Register before touching Keychain. An interrupted
                        // transaction can reclaim its unreferenced slot on load.
                        enqueueCleanup([created], defaults: defaults)
                        staged.append(created)
                        try credentials.write(instance.apiKey, reference: created)
                        reference = created
                    }
                }
                next.append(StoredInstance(instance: instance, reference: reference))
            }
            let data = try JSONEncoder().encode(next)
            // No existing metadata or credential slot changes before this point.
            defaults.set(data, forKey: key)
            guard defaults.synchronize(), defaults.data(forKey: key) == data else {
                throw InstanceCredentialError.invalidConfiguration
            }
        } catch {
            enqueueCleanup(staged, defaults: defaults)
            _ = cleanPending(defaults: defaults, credentials: credentials)
            throw error
        }
        let retained = Set(next.compactMap(\.reference))
        let obsolete = previous.compactMap(\.reference).filter { !retained.contains($0) }
        enqueueCleanup(obsolete, defaults: defaults)
        return cleanPending(defaults: defaults, credentials: credentials)
    }

    /// 引用格式 `<instanceUUID>/<slotUUID>` 的第一段就是 owner。
    /// 格式不合法时返回一个不会匹配任何实例的哨兵 UUID。
    private static func ownerOf(_ reference: String) -> UUID {
        let head = reference.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return UUID(uuidString: head) ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    }

    private static func valid(reference: String, owner: UUID) -> Bool {
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) == owner
            && UUID(uuidString: String(parts[1])) != nil
    }

    private static func scrubbedInstances(_ instances: [HermesInstance]) -> [HermesInstance] {
        instances.map { instance in
            var copy = instance
            copy.apiKey = ""
            return copy
        }
    }

    private static func encodeScrubbedMetadata(_ instances: [HermesInstance]) throws -> Data {
        try JSONEncoder().encode(
            instances.map { StoredInstance(instance: $0, reference: nil) })
    }

    /// Persists metadata without secrets and verifies the exact bytes that can be
    /// read back. The closures keep the failure paths testable without touching
    /// production preferences or credentials.
    static func scrubLegacyPlaintext(
        _ instances: [HermesInstance],
        encode: ([HermesInstance]) throws -> Data,
        write: (Data) -> Void,
        read: () -> Data?
    ) -> String {
        let scrubbed = scrubbedInstances(instances)
        do {
            let data = try encode(scrubbed)
            write(data)
            guard let persisted = read(), persisted == data else {
                return "网关密钥迁移失败，且无法确认明文副本已清除；设备上可能仍保留明文，请立即重试或重新录入密钥。"
            }
            // StoredInstance intentionally encodes a blank apiKey without a
            // key. Decode to reject malformed metadata; the exact-byte check
            // above rejects any extra or legacy field.
            _ = try JSONDecoder().decode([StoredInstance].self, from: persisted)
            return "网关密钥迁移失败，已确认应用内的明文副本被清除；设备上其他位置可能仍保留明文，请立即重试或重新录入密钥。"
        } catch {
            return "网关密钥迁移失败，且脱敏配置未能保存；设备上可能仍保留明文，请立即重试或重新录入密钥。"
        }
    }

    private static func enqueueCleanup(_ references: [String], defaults: UserDefaults) {
        let pending = Set(defaults.stringArray(forKey: cleanupKey) ?? []).union(references)
        if !pending.isEmpty { defaults.set(Array(pending), forKey: cleanupKey) }
    }

    private static func cleanPending(defaults: UserDefaults, credentials: any InstanceCredentialStorage) -> String? {
        // A partially completed cleanup can be retried after unlock or restart.
        let live = Set((defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([StoredInstance].self, from: $0) } ?? []).compactMap(\.reference))
        var pending: [String] = []
        for reference in defaults.stringArray(forKey: cleanupKey) ?? [] where !live.contains(reference) {
            // 只删自己能认领的引用：格式非法或 owner 不匹配的条目一律不动，
            // 避免清理队列被污染后误删其它实例/账号的 Keychain 项。
            guard valid(reference: reference, owner: ownerOf(reference)) else { continue }
            do { try credentials.remove(reference: reference) }
            catch { pending.append(reference) }
        }
        if pending.isEmpty { defaults.removeObject(forKey: cleanupKey) }
        else { defaults.set(pending, forKey: cleanupKey) }
        return pending.isEmpty ? nil : "实例配置已保存；部分旧密钥暂未能从钥匙串清理，将在解锁后重试。"
    }

    static var activeID: UUID? {
        get { UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: activeKey) }
    }
}
