import Foundation

/// 纯图消息的占位文本。
///
/// 发送协议不变：正文仍然写「（仅附件）」；是否隐藏这段文字只发生在展示层。
/// 判定只看**具体消息身份**：正文相同但未被本机标记过的消息一律显示。
/// 时间戳窗口已被移除——它会把稍后一条同样文字的用户消息误判成系统占位。
/// 一条用户消息的正文来源。发送时判定一次，重发沿用，展示只看消息身份。
enum ChatSendOrigin: String, Equatable, Codable {
    case userInput
    case systemPlaceholder
}

enum ChatAttachmentPlaceholder {
    /// 与发送端共用的占位文本，两处必须保持同一份定义。
    static let systemText = "（仅附件）"

    static func hidesBody(messageID: String, content: String, role: String,
                          attachmentCount: Int, markedIDs: Set<String>) -> Bool {
        guard role == "user", attachmentCount > 0, content == systemText,
              !messageID.isEmpty else { return false }
        return markedIDs.contains(messageID)
    }
}

/// 本机「空正文 + 附件」发送的消息身份。
///
/// 键包含实例与账号作用域，值按会话分桶；切换账号、删除实例、清缓存时必须
/// 调用 `removeScope` / `clearAll`。
///
/// 两类身份：
/// - `local`：本地乐观气泡的临时 ID，只存在内存里，进程结束即失效；
/// - `confirmed`：服务端回写那一行的真实 ID，持久化，跨启动有效。
final class ChatAttachmentPlaceholderStore {
    static let shared = ChatAttachmentPlaceholderStore()

    struct Limits {
        var perSession = 80
        var perScope = 60
    }

    /// 一个会话桶：ID 列表 + 最近一次写入时间。
    /// 时间只用于容量裁剪，不参与任何判定（判定只看 ID 集合）。
    struct Bucket: Equatable {
        var ids: [String]
        var writtenAt: Double

        init(ids: [String], writtenAt: Double) {
            self.ids = ids
            self.writtenAt = writtenAt
        }
    }

    private let defaults: UserDefaults
    private let limits: Limits
    private let lock = NSLock()
    /// scope -> session -> 已确认消息 ID（持久化）
    private var confirmed: [String: [String: Bucket]] = [:]
    /// scope -> session -> 本地乐观消息 ID（仅内存）
    private var locals: [String: [String: Bucket]] = [:]
    private var loadedScopes: Set<String> = []
    /// 合并后的查询缓存，写入时清空。
    private var marks: [String: Set<String>] = [:]

    init(defaults: UserDefaults = .standard, limits: Limits = Limits()) {
        self.defaults = defaults
        self.limits = limits
        purgeLegacyTimestampRecords()
    }

    private static func storageKey(_ scope: String) -> String {
        "HermesChat.attachmentPlaceholder.v3." + Data(scope.utf8).base64EncodedString()
    }

    /// v1 记录存的是时间戳，已经不能作为隐藏依据；升级时直接清掉。
    private func purgeLegacyTimestampRecords() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("HermesChat.attachmentPlaceholder.v1.") || key.hasPrefix("HermesChat.attachmentPlaceholder.v2.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func cacheKey(_ scope: String, _ sessionID: String) -> String {
        scope + "\u{1e}" + sessionID
    }

    func rememberLocal(scope: String, sessionID: String, id: String) {
        guard !scope.isEmpty, !sessionID.isEmpty, !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var table = locals[scope] ?? [:]
        var list = table[sessionID]?.ids ?? []
        if !list.contains(id) { list.append(id) }
        table[sessionID] = Bucket(ids: Array(list.suffix(limits.perSession)), writtenAt: now())
        pruneLocked(&table)
        locals[scope] = table
        marks.removeAll()
    }

    func forgetLocal(scope: String, sessionID: String, id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var table = locals[scope], let bucket = table[sessionID] else { return }
        let list = bucket.ids.filter { $0 != id }
        if list.isEmpty { table.removeValue(forKey: sessionID) }
        else { table[sessionID] = Bucket(ids: list, writtenAt: bucket.writtenAt) }
        locals[scope] = table
        marks.removeValue(forKey: cacheKey(scope, sessionID))
    }

    /// 本地气泡与服务端行对上号：把临时 ID 换成真实 ID 并持久化。
    func bind(scope: String, sessionID: String, localID: String, confirmedID: String) {
        guard !scope.isEmpty, !sessionID.isEmpty, !confirmedID.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if !localID.isEmpty, var table = locals[scope], let bucket = table[sessionID] {
            let list = bucket.ids.filter { $0 != localID }
            if list.isEmpty { table.removeValue(forKey: sessionID) }
            else { table[sessionID] = Bucket(ids: list, writtenAt: bucket.writtenAt) }
            locals[scope] = table
        }
        var table = loadConfirmedLocked(scope)
        var list = table[sessionID]?.ids ?? []
        if !list.contains(confirmedID) { list.append(confirmedID) }
        table[sessionID] = Bucket(ids: Array(list.suffix(limits.perSession)), writtenAt: now())
        pruneLocked(&table)
        confirmed[scope] = table
        persistLocked(table, scope: scope)
        marks.removeValue(forKey: cacheKey(scope, sessionID))
    }

    func markedIDs(scope: String, sessionID: String) -> Set<String> {
        guard !scope.isEmpty, !sessionID.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let key = cacheKey(scope, sessionID)
        if let hit = marks[key] { return hit }
        var result = Set(loadConfirmedLocked(scope)[sessionID]?.ids ?? [])
        result.formUnion(locals[scope]?[sessionID]?.ids ?? [])
        marks[key] = result
        return result
    }

    func removeScope(_ scope: String) {
        lock.lock()
        defer { lock.unlock() }
        confirmed[scope] = [:]
        locals[scope] = [:]
        loadedScopes.insert(scope)
        marks.removeAll()
        defaults.removeObject(forKey: Self.storageKey(scope))
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        let scopes = Set(confirmed.keys).union(loadedScopes).union(locals.keys)
        confirmed = [:]
        locals = [:]
        loadedScopes = []
        marks.removeAll()
        for scope in scopes {
            defaults.removeObject(forKey: Self.storageKey(scope))
        }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("HermesChat.attachmentPlaceholder.v3.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func loadConfirmedLocked(_ scope: String) -> [String: Bucket] {
        if let hit = confirmed[scope] { return hit }
        var table: [String: Bucket] = [:]
        if !loadedScopes.contains(scope),
           let data = defaults.data(forKey: Self.storageKey(scope)) {
            // v3 的旧格式是 [String: [String]]，没有写入时间：按最旧处理，
            // 这样新写入的会话一定优先保留，不需要升版本号。
            // 可忽略：旧格式解析失败只是丢掉「纯图消息隐藏占位文字」的标记，
            // 最坏结果是用户重新看到一行「（仅附件）」，不会误隐藏任何正文。
            if let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
                for (session, ids) in decoded {
                    table[session] = Bucket(ids: ids, writtenAt: 0)
                }
            }
        }
        loadedScopes.insert(scope)
        pruneLocked(&table)
        confirmed[scope] = table
        return table
    }

    private func pruneLocked(_ table: inout [String: Bucket]) {
        for (session, bucket) in table {
            let kept = Array(bucket.ids.suffix(limits.perSession))
            if kept.isEmpty { table.removeValue(forKey: session) }
            else { table[session] = Bucket(ids: kept, writtenAt: bucket.writtenAt) }
        }
        guard table.count > limits.perScope else { return }
        // 按**写入时间**升序丢弃最旧的会话桶。
        // 不能用 session ID 排序：那样会丢掉刚写入的会话，导致这条纯图消息
        // 的文字重新出现（与「回写后占位失效」同症状）。
        let survivors = table
            .sorted { $0.value.writtenAt > $1.value.writtenAt }
            .prefix(limits.perScope)
        table = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func persistLocked(_ table: [String: Bucket], scope: String) {
        let key = Self.storageKey(scope)
        // 磁盘格式保持 v3 的 [String: [String]]：写入时间只是进程内的裁剪依据，
        // 重启后缺失时间按最旧处理，不影响任何判定。
        let cleaned = table
            .filter { !$0.value.ids.isEmpty }
            .mapValues(\.ids)
        guard !cleaned.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        // 可忽略：编码失败只会让这条「已确认纯图消息」重启后重新显示占位文字，
        // 判定集合是展示层标记，不影响消息内容与发送。
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        defaults.set(data, forKey: key)
    }
}
