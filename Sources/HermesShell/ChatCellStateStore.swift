import Foundation

/// 本地「折叠」状态存储，按 实例 / 账号 / 会话 三元组隔离，键布局与
/// ChatReadingPositionStore、ChatDraftStore(v2) 保持一致。
///
/// 只持久化「折叠」这一个布尔维度：不持久化「展开」的工具组。
/// 工具组与流式行的 id 可能随会话重建而重用/消失，记住「已展开」会与
/// 流式行 `streaming:<uuid>` 以及本地乐观行 `local-<uuid>` 冲突；
/// 而默认是展开的，所以只需记住用户主动折叠过的行 id。
struct ChatCellStateStore {
    private let defaults: UserDefaults
    private let key: String

    init(instanceID: String, accountScope: String, sessionID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Encode the tuple, not a delimiter-joined string (which can collide).
        let tuple = Self.encodedTuple([instanceID, accountScope, sessionID])
        self.key = "HermesNative.cellState.v1." + tuple
    }

    /// 身份三元组的键片段。
    ///
    /// 正常路径仍是 `JSONEncoder` 编码 `[String]`，与历史键逐字节一致（不迁移旧数据）。
    /// `[String]` 编码在实践中不会失败，但这里不用 `try!`：万一失败退回长度前缀编码，
    /// 仍然是单射（不同元组不会碰撞），只是那一条读到空值。
    private static func encodedTuple(_ values: [String]) -> String {
        if let data = try? JSONEncoder().encode(values) { return data.base64EncodedString() }
        let fallback = values.map { "\($0.utf8.count):\($0)" }.joined()
        return "len:" + Data(fallback.utf8).base64EncodedString()
    }

    /// 已折叠的行 id。丢弃空串、本地乐观行与流式行，防止旧脏数据
    /// 命中将来某条临时行。
    func loadCollapsed() -> Set<String> {
        guard let stored = defaults.stringArray(forKey: key) else { return [] }
        return Set(stored.compactMap(Self.sanitized))
    }

    /// 空集合时删除键，避免 UserDefaults 里残留空数组。
    func saveCollapsed(_ ids: Set<String>) {
        let cleaned = Set(ids.compactMap(Self.sanitized))
        if cleaned.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            // Stable order keeps the stored blob identical for equal sets.
            defaults.set(cleaned.sorted(), forKey: key)
        }
    }

    /// 删除这一条的折叠状态。会话删除后行 id 不再存在。
    func remove() {
        defaults.removeObject(forKey: key)
    }

    /// 删除某实例 + 账号下的全部折叠状态（清空缓存、切换账号）。
    static func removeAll(instanceID: String, accountScope: String,
                          defaults: UserDefaults = .standard) {
        for name in defaults.dictionaryRepresentation().keys {
            guard name.hasPrefix(prefix) else { continue }
            let encoded = String(name.dropFirst(prefix.count))
            // 可忽略：解析不出来的键本来就不属于本模块的格式，跳过即可。
            guard let data = Data(base64Encoded: encoded),
                  let tuple = try? JSONDecoder().decode([String].self, from: data),
                  tuple.count >= 2, tuple[0] == instanceID, tuple[1] == accountScope else { continue }
            defaults.removeObject(forKey: name)
        }
    }

    private static let prefix = "HermesNative.cellState.v1."

    /// 只接受稳定、可跨会话复用的服务端消息 id。
    /// 视图层的行 id 形如 `m-<messageID>`，临时行因此是 `m-local-…` /
    /// `m-streaming:…`；带前缀和不带前缀的两种形态都拒绝。
    private static func sanitized(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        let bare = id.hasPrefix("m-") ? String(id.dropFirst(2)) : id
        guard !bare.hasPrefix("local-"), !bare.hasPrefix("streaming:") else { return nil }
        return id
    }
}
