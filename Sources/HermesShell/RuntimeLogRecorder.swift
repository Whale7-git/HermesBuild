import Foundation

/// Immutable identity for one log scope session. Asynchronous work captures the
/// token when it starts and records against it later; an expired token is
/// dropped instead of being redirected into whatever scope happens to be active.
struct RuntimeLogToken: Hashable, Sendable {
    let scope: RuntimeLogScope
    let generation: UInt64
}

/// 运行时诊断日志：应用级 + 会话级双轨，按 account/session 分区，默认不上传。
///
/// - `record` 只在主线程做 O(1) 内存追加，零 IO、零网络；没有有效 token 时不写入任何分区。
/// - 异步回调必须携带开始操作时捕获的 token；过期 token 直接丢弃。
/// - `endScope` 只注销 activeToken，**不删缓冲**：排查的典型路径是「出问题 →
///   退出会话 → 去设置导出」，日志必须在作用域结束后仍然可读。
/// - 应用级分区（sessionID 为空）承载登录、网络、缓存、启动等不归属会话的事件，
///   因此在会话列表页打开设置也有内容可看。
/// - 日志只留状态/耗时/错误类别，路径只保留叶子名，URL 去 query，敏感键值脱敏。
/// - 内存分区有数量上限；磁盘留底由 RuntimeLogStorage 控制 8 份 / 2MiB。
@MainActor
final class RuntimeLogRecorder {
    static let shared = RuntimeLogRecorder()

    /// 级别只用于「导出时把问题排在前面」和阅读过滤，不参与容量与去重。
    enum Level: String, Codable, CaseIterable {
        case debug, info, warning, error

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }

        /// 单字符标记，让一行日志在等宽字体下仍能一眼扫出严重程度。
        var marker: String {
            switch self {
            case .debug: return "D"
            case .info: return "I"
            case .warning: return "W"
            case .error: return "E"
            }
        }
    }

    struct Entry: Codable {
        let time: String
        let level: String
        let tag: String
        let message: String
    }

    /// 诊断页可选的一个分区。`label` 在 beginScope 时写入，用于下拉列表。
    struct ScopeSummary: Identifiable, Hashable {
        let key: String
        let label: String
        let isApp: Bool
        let entryCount: Int
        let lastUsed: UInt64
        var id: String { key }
    }

    private static let capacity = 512
    /// Bounded number of in-memory scopes; the least recently used one is dropped.
    /// The app-level scope is never dropped.
    private static let maxScopes = 12
    private static let maxMessageBytes = 2048
    /// 导出时置顶的问题条目上限，避免摘要本身变成另一份全量日志。
    private static let summaryLimit = 20

    private var buffers: [String: RuntimeLogBuffer<Entry>] = [:]
    private var generations: [String: UInt64] = [:]
    private var scopes: [String: RuntimeLogScope] = [:]
    /// Never reuse an evicted scope's generation: otherwise a delayed callback
    /// carrying its first token becomes valid when that scope is reopened.
    private var nextGeneration: UInt64 = 0
    private var lastUsed: [String: UInt64] = [:]
    private var labels: [String: String] = [:]
    private var clock: UInt64 = 0
    private var activeToken: RuntimeLogToken?
    private var appScopeKey: String?
    private let localFile: URL

    init(localDirectory: URL? = nil) {
        localFile = localDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRuntimeLog", isDirectory: true)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - 作用域生命周期

    /// 进入某个账号/会话作用域，返回该作用域的不可变 token。
    ///
    /// 重复进入同一会话（返回列表再点回来、视图重建）**不能清空已有条目**：
    /// 排查路径是「出问题 → 来回切几次 → 去设置导出」，每次重建都清零会让
    /// 诊断页永远显示「暂无日志」。这里只递增 generation 让旧 token 失效
    /// （旧视图不得再写），缓冲区本身沿用。
    @discardableResult
    func beginScope(instanceID: String, accountScope: String, sessionID: String,
                    label: String = "") -> RuntimeLogToken {
        let scope = RuntimeLogScope(instanceID: instanceID, accountScope: accountScope, sessionID: sessionID)
        let key = scope.key
        nextGeneration &+= 1
        let next = nextGeneration
        generations[key] = next
        scopes[key] = scope
        if buffers[key] == nil {
            buffers[key] = RuntimeLogBuffer<Entry>(capacity: Self.capacity)
        }
        // 标题可能随重命名变化；已有条目时也更新，诊断页才显示当前名字。
        labels[key] = label.isEmpty ? Self.fallbackLabel(scope) : label
        touch(key)
        let token = RuntimeLogToken(scope: scope, generation: next)
        activeToken = token
        pruneScopes()
        return token
    }

    /// 应用级分区：登录、网络、缓存等不归属任何会话的事件写这里。
    /// 重复调用是幂等的（同一实例+账号复用同一分区）。
    @discardableResult
    func configureAppScope(instanceID: String, accountScope: String) -> RuntimeLogToken {
        let scope = RuntimeLogScope(instanceID: instanceID, accountScope: accountScope, sessionID: "")
        let key = scope.key
        if buffers[key] == nil {
            buffers[key] = RuntimeLogBuffer<Entry>(capacity: Self.capacity)
            nextGeneration &+= 1
            generations[key] = nextGeneration
            labels[key] = "应用"
        }
        scopes[key] = scope
        appScopeKey = key
        if let activeToken, !sameAccount(activeToken.scope, scope) { self.activeToken = nil }
        touch(key)
        pruneScopes()
        return RuntimeLogToken(scope: scope, generation: generations[key] ?? 1)
    }

    /// 应用级记录。没有配置过应用作用域时静默丢弃（不猜账号归属）。
    func recordApp(_ level: Level, _ tag: String, _ message: String) {
        guard let key = appScopeKey else { return }
        append(level: level, tag: tag, message: message, key: key)
    }

    /// Only the owner of the active scope may close it; a stale view must not
    /// retire a newer view's logging scope.
    ///
    /// The buffer stays alive on purpose: the user reproduces a problem inside a
    /// session, leaves it, and only then opens Settings to export. Dropping the
    /// buffer here is exactly why the export used to come back empty.
    func endScope(_ token: RuntimeLogToken? = nil) {
        if let token, let active = activeToken, token != active { return }
        activeToken = nil
    }

    /// Token for work that is about to start (e.g. an attachment upload).
    func currentToken() -> RuntimeLogToken? { activeToken }

    // MARK: - 记录 / 快照

    /// 主线程 O(1) 追加。`token` 为 nil 时使用当前作用域；显式传入的过期 token 会被丢弃。
    func record(_ level: Level = .info, _ tag: String, _ message: String,
                token: RuntimeLogToken? = nil) {
        guard let target = token ?? activeToken, isValid(target) else { return }
        append(level: level, tag: tag, message: message, key: target.scope.key)
    }

    private func append(level: Level, tag: String, message: String, key: String) {
        let entry = Entry(time: Self.formatter.string(from: Date()),
            level: level.rawValue,
            tag: Self.sanitize(tag, limit: 64),
            message: Self.sanitize(message, limit: Self.maxMessageBytes))
        var buffer = buffers[key] ?? RuntimeLogBuffer<Entry>(capacity: Self.capacity)
        buffer.append(entry)
        buffers[key] = buffer
        touch(key)
    }

    /// 当前（或指定）作用域的日志快照，按行拼接。
    func snapshot(token: RuntimeLogToken? = nil) -> String {
        guard let target = token ?? activeToken, isValid(target) else { return "" }
        return lines(forKey: target.scope.key)
    }

    /// 按分区键读取；用于诊断页选择「上一个会话」这类已经结束的作用域。
    func snapshot(scopeKey: String) -> String {
        guard buffers[scopeKey] != nil, canRead(scopeKey) else { return "" }
        return lines(forKey: scopeKey)
    }

    /// 诊断页的分区列表：应用级固定置顶，其余按最近使用排序。
    func recentScopes() -> [ScopeSummary] {
        buffers.compactMap { key, buffer -> ScopeSummary? in
            guard !buffer.elements.isEmpty, canRead(key) else { return nil }
            let isApp = key == appScopeKey
            return ScopeSummary(key: key,
                                label: labels[key] ?? "未命名",
                                isApp: isApp,
                                entryCount: buffer.elements.count,
                                lastUsed: lastUsed[key] ?? 0)
        }
        .sorted { lhs, rhs in
            if lhs.isApp != rhs.isApp { return lhs.isApp }
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
            return lhs.label < rhs.label
        }
    }

    /// 导出文件名与内容；作用域无效或没有条目时返回 nil。
    func export(token: RuntimeLogToken? = nil) -> (filename: String, text: String)? {
        guard let target = token ?? activeToken, isValid(target) else { return nil }
        return export(scopeKey: target.scope.key)
    }

    /// 按分区键导出。问题条目在文件开头的摘要里先列一遍，正文仍保持时间顺序——
    /// 排查时先看到失败，需要上下文时再往下读。
    func export(scopeKey: String) -> (filename: String, text: String)? {
        guard buffers[scopeKey] != nil, canRead(scopeKey) else { return nil }
        let body = lines(forKey: scopeKey)
        guard !body.isEmpty else { return nil }
        let summary = problemSummary(forKey: scopeKey)
        let text = summary.isEmpty ? body : summary + "\n\n" + body
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "runtime-log-\(Self.safeKey(scopeKey))-\(stamp).txt"
        return (name, text)
    }

    private func problemSummary(forKey key: String) -> String {
        let problems = (buffers[key]?.elements ?? [])
            .filter { ($0.level == Level.warning.rawValue || $0.level == Level.error.rawValue) }
        guard !problems.isEmpty else { return "" }
        let recent = problems.suffix(Self.summaryLimit).reversed()
        var out = "== 问题摘要（\(problems.count) 条，最近 \(recent.count) 条）=="
        for entry in recent {
            let level = Level(rawValue: entry.level) ?? .info
            out += "\n[\(entry.time)] \(level.marker) \(entry.tag) \(entry.message)"
        }
        return out
    }

    /// Bounded problem summary for the opt-in experience report. Unlike the
    /// detailed per-scope export, this only includes severity, module, count and
    /// the newest timestamp. It never includes messages, scope labels, session
    /// identifiers, URLs or credentials.
    func diagnosticProblemSummary(maximumCategories: Int = 12) -> String {
        struct Bucket {
            var count = 0
            var latest = ""
        }
        var buckets: [String: Bucket] = [:]
        for (key, buffer) in buffers where canRead(key) {
            for entry in buffer.elements {
                guard entry.level == Level.warning.rawValue || entry.level == Level.error.rawValue else {
                    continue
                }
                let tag = Self.sanitize(entry.tag, limit: 64)
                let bucketKey = "\(entry.level)|\(tag)"
                var bucket = buckets[bucketKey] ?? Bucket()
                bucket.count += 1
                bucket.latest = max(bucket.latest, entry.time)
                buckets[bucketKey] = bucket
            }
        }
        guard !buckets.isEmpty else {
            return "运行时问题摘要：暂无警告或错误（只统计当前账号的本机内存日志）。"
        }
        let selected = buckets.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            return lhs.key < rhs.key
        }.prefix(max(1, maximumCategories))
        var lines = [
            "运行时问题摘要：\(buckets.values.reduce(0) { $0 + $1.count }) 条；"
                + "只含级别、模块、次数和最近时间，不含正文、标识、地址或凭据。"
        ]
        for (key, bucket) in selected {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let level = Level(rawValue: parts.first ?? "") ?? .warning
            let tag = parts.count > 1 ? parts[1] : "unknown"
            lines.append("[\(bucket.latest)] \(level.marker) \(tag) ×\(bucket.count)")
        }
        if buckets.count > selected.count {
            lines.append("另有 \(buckets.count - selected.count) 个模块未展开。")
        }
        return lines.joined(separator: "\n")
    }

    private func lines(forKey key: String) -> String {
        (buffers[key]?.elements ?? [])
            .map { entry in
                let level = Level(rawValue: entry.level) ?? .info
                return "[\(entry.time)] \(level.marker) \(entry.tag) \(entry.message)"
            }
            .joined(separator: "\n")
    }

    // MARK: - 本地留底（无自动上报）

    /// 附件失败等调用点：只校验作用域并做本地留底，绝不自动上报。
    func flush(sessionID: String, baseURL: URL?, token: RuntimeLogToken? = nil) {
        guard let target = token ?? activeToken, isValid(target),
              target.scope.sessionID == sessionID, !sessionID.isEmpty else { return }
        // baseURL 仅用于一致性校验：给出地址时必须是带主机的合法绝对 URL。
        if let baseURL = baseURL, baseURL.host == nil { return }
        let text = lines(forKey: target.scope.key)
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        let stamp = Int(Date().timeIntervalSince1970)
        let filename = "runtime-log-v2-\(target.scope.accountFileKey)-\(target.scope.scopeFileKey)-\(stamp)-\(UUID().uuidString).txt"
        let localFile = self.localFile
        DispatchQueue.global(qos: .utility).async {
            try? RuntimeLogStorage.save(data, in: localFile, filename: filename)
        }
    }

    /// 本地留底目录（供「失败留底」读取）。
    func localDirectory() -> URL { localFile }

    /// 留底文件列表，最新在前。
    func localSnapshots() -> [URL] {
        guard let appScopeKey, let account = scopes[appScopeKey] else { return [] }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let items = (try? manager.contentsOfDirectory(at: localFile, includingPropertiesForKeys: Array(keys))) ?? []
        // Legacy filenames did not retain a complete account identity. They
        // cannot safely be offered to a different signed-in account.
        let prefix = "runtime-log-v2-\(account.accountFileKey)-"
        return items.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix("runtime-log-"), url.pathExtension == "txt",
                  url.lastPathComponent.hasPrefix(prefix),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    // MARK: - 显式导出

    // MARK: - 辅助

    /// Number of retained in-memory scopes (bounded by `maxScopes`).
    var scopeCount: Int { buffers.count }

    private func isValid(_ token: RuntimeLogToken) -> Bool {
        buffers[token.scope.key] != nil && generations[token.scope.key] == token.generation
    }

    private func sameAccount(_ lhs: RuntimeLogScope, _ rhs: RuntimeLogScope) -> Bool {
        lhs.instanceID == rhs.instanceID && lhs.accountScope == rhs.accountScope
    }

    /// F-77：默认 fail-closed。
    ///
    /// 旧实现在 `appScope` 未配置时返回 `true`，也就是「还没确定当前账号，就先允许读
    /// 任何分区」，启动早期存在一个极短的跨账号可读窗口。现在改为：没有当前账号
    /// 归属就一律不可读。
    ///
    /// 这要求调用方在**任何读取之前**先 `configureAppScope`。本类型里没有「首次
    /// 访问自动登记为当前 scope」的兜底 —— 那等于换个地方继续放行。
    private func canRead(_ key: String) -> Bool {
        guard let appScopeKey, let account = scopes[appScopeKey] else { return false }
        guard let scope = scopes[key] else { return false }
        return sameAccount(account, scope)
    }

    private func touch(_ key: String) {
        clock &+= 1
        lastUsed[key] = clock
    }

    /// Keeps the active scope plus the most recently used ones, and never drops
    /// the app-level scope (it is the only partition available with no session).
    private func pruneScopes() {
        while buffers.count > Self.maxScopes {
            var protected: Set<String> = []
            if let active = activeToken?.scope.key { protected.insert(active) }
            if let app = appScopeKey { protected.insert(app) }
            let candidates = lastUsed.filter { !protected.contains($0.key) && buffers[$0.key] != nil }
            guard let oldest = candidates.min(by: { $0.value < $1.value })?.key else { break }
            buffers.removeValue(forKey: oldest)
            lastUsed.removeValue(forKey: oldest)
            generations.removeValue(forKey: oldest)
            scopes.removeValue(forKey: oldest)
            labels.removeValue(forKey: oldest)
        }
    }

    private static func fallbackLabel(_ scope: RuntimeLogScope) -> String {
        if scope.sessionID.isEmpty { return "应用" }
        return "会话 " + String(scope.sessionID.prefix(8))
    }

    /// One-line, de-identified text. Truncation alone is not sanitization.
    private static func sanitize(_ raw: String, limit: Int) -> String {
        // Redact before flattening newlines, while HTTP header boundaries are
        // still available. Header, JSON and key=value forms all occur in errors.
        var text = replace(#"(?im)\b(?:set-cookie|cookie)\s*:\s*[^\r\n]*"#, in: raw, template: "cookie=<redacted>")
        text = replace(#"(?i)\b(?:authorization|proxy-authorization)\s*[:=]\s*(?:(?:bearer|basic)\s+)?[^\s,;\r\n]+"#,
                       in: text, template: "authorization=<redacted>")
        text = replace(#"(?i)([\"']?\b(?:cookie|(?:access[_-]?|refresh[_-]?)?token|(?:api[_-]?)?key|authorization|password|secret)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s&,;\}\]]+)"#,
                       in: text, template: "$1<redacted>")
        // URL userinfo and fragments can carry credentials too, not only query.
        text = replace(#"(?i)(https?://)(?:[^/\s@]+@)([^\s]+)"#, in: text, template: "$1$2")
        text = replace(#"(?i)(https?://[^\s?#]+)[?#][^\s]*"#, in: text, template: "$1")
        text = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32) : $0
        }))
        // Absolute paths: keep only the leaf name (uploads live under a session inbox).
        text = replace(#"(?:/[^\s:："]+)+/([^/\s:："]+)"#, in: text, template: "$1")
        return String(decoding: text.utf8.prefix(limit), as: UTF8.self)
    }

    private static func replace(_ pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Encode the complete tuple: prefix bytes are shared by unrelated sessions.
    private static func safeKey(_ key: String) -> String {
        guard let data = Data(base64Encoded: key),
              let tuple = try? JSONDecoder().decode([String].self, from: data), tuple.count == 3 else { return UUID().uuidString }
        return RuntimeLogScope(instanceID: tuple[0], accountScope: tuple[1], sessionID: tuple[2]).scopeFileKey
    }
}
