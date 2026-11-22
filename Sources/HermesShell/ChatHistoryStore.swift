import Foundation

/// A display-only copy of history confirmed by a GET. Runtime stream state,
/// cursors, credentials, drafts and optimistic messages never enter this DTO.
struct ChatHistoryRecord {
    let sessionID: String
    var messages: [ChatMessage]
    var tools: [ChatTool]
    var olderOffset: Int
    var model: String?
    var usage: ChatUsage?
    var savedAt: Date
    /// Count of tools which could not fit even as identity-only cache entries.
    var uncachedToolCount: Int = 0

    init(snapshot: ChatSnapshot, savedAt: Date = Date()) {
        sessionID = snapshot.sessionID
        messages = snapshot.messages
        tools = snapshot.tools
        olderOffset = snapshot.olderOffset
        model = snapshot.model
        usage = snapshot.usage
        self.savedAt = savedAt
    }

    mutating func prepend(_ snapshot: ChatSnapshot) {
        let messageIDs = Set(messages.map(\.id))
        messages.insert(contentsOf: snapshot.messages.filter { !messageIDs.contains($0.id) }, at: 0)
        let toolIDs = Set(tools.map(\.id))
        tools.insert(contentsOf: snapshot.tools.filter { !toolIDs.contains($0.id) }, at: 0)
        olderOffset = snapshot.olderOffset
        savedAt = Date()
    }
}

/// Files live in the application's purgeable sandbox cache, never shared
/// preferences or the document picker. All I/O and JSON coding use one utility
/// queue; a burst of updates replaces a pending write instead of blocking UI.
final class ChatHistoryStore: Sendable {
    enum WriteFailure: String, Hashable, Sendable {
        case serialization
        case sizeBudget
        case diskWrite
        case backupProtection
    }

    struct WriteReport: Sendable, Equatable {
        let failure: WriteFailure?
        var succeeded: Bool { failure == nil }
        /// `nil` means the write was superseded, retired, or had nothing
        /// pending. Those are lifecycle outcomes, not storage failures.
        static let ok = WriteReport(failure: nil)
        static func failed(_ failure: WriteFailure) -> WriteReport {
            WriteReport(failure: failure)
        }
    }

    /// Called on the history-cache utility queue after a confirmed snapshot is
    /// persisted. The store never reads the runtime log itself: it is compiled
    /// into standalone offline suites and logging must not become an I/O
    /// dependency of cache persistence. The callback carries only a category.
    private let report: (@Sendable (WriteReport) -> Void)?
    /// Failure classes already reported by this page. A failing disk should not
    /// add one identical warning for every streamed snapshot.
    private let reportedFailures = ReportedFailures()

    private final class ReportedFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var values = Set<WriteFailure>()

        func insert(_ failure: WriteFailure) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return values.insert(failure).inserted
        }
    }

    struct Policy: Sendable {
        var maxEntryBytes = 4 * 1024 * 1024
        var maxTotalBytes: Int64 = 64 * 1024 * 1024
        var maxAge: TimeInterval = 30 * 24 * 60 * 60
        var debounce: TimeInterval = 1
        var maxMessages = 1200
        var maxTools = 600
        var maxEntries = 512
    }

    struct CleanupReport: Sendable, Equatable {
        let attempted: Int
        let removed: Int
        let failed: Int
        var succeeded: Bool { failed == 0 }
        static let empty = CleanupReport(attempted: 0, removed: 0, failed: 0)
    }

    struct Statistics: Sendable {
        let entries: Int
        let bytes: Int64
    }

    private struct Scope: Codable, Equatable, Sendable {
        let instanceID: String
        let sessionID: String
        let accountScope: String
        var namespace: String { ChatHistoryStore.digest([instanceID, accountScope]) }
        var filename: String { ChatHistoryStore.digest([instanceID, accountScope, sessionID]) + ".json" }
    }

    private struct Message: Codable {
        var id: String
        var role: String
        var content: String
        var timestamp: Double?
        var sourceIndex: Int
        var attachmentPaths: [String]
        var displayKind: String?
        init?(_ value: ChatMessage) {
            guard let sourceIndex = value.sourceIndex, sourceIndex >= 0,
                  ["user", "assistant"].contains(value.role),
                  !value.id.hasPrefix("local-"), !value.id.hasPrefix("streaming:") else { return nil }
            id = value.id; role = value.role; content = value.content
            timestamp = value.timestamp.flatMap { $0.isFinite ? $0 : nil }
            self.sourceIndex = sourceIndex
            attachmentPaths = value.attachmentPaths
            displayKind = value.displayKind
        }
        var value: ChatMessage {
            ChatMessage(id: id, role: role, content: content, timestamp: timestamp,
                        sourceIndex: sourceIndex, attachmentPaths: attachmentPaths,
                        displayKind: displayKind)
        }
    }

    private struct Tool: Codable {
        let id: String
        let name: String
        let args: String
        let result: String
        let done: Bool
        let isError: Bool
        let afterMessageID: String?
        /// Optional keys decode build228's legacy cache envelopes unchanged.
        let omittedResultBytes: Int?
        let omittedArgsBytes: Int?
        init(_ value: ChatTool, omitResult: Bool = false, omitArgs: Bool = false) {
            id = value.id; name = value.name
            args = omitArgs ? "" : value.args
            result = omitResult ? "" : value.result
            done = value.done; isError = value.isError; afterMessageID = value.afterMessageID
            omittedResultBytes = value.uncachedResultBytes
                ?? (omitResult && !value.result.isEmpty ? value.result.utf8.count : nil)
            omittedArgsBytes = value.uncachedArgsBytes
                ?? (omitArgs && !value.args.isEmpty ? value.args.utf8.count : nil)
        }
        var value: ChatTool {
            ChatTool(id: id, name: name, args: args, result: result, done: done,
                     isError: isError, afterMessageID: afterMessageID,
                     uncachedResultBytes: omittedResultBytes, uncachedArgsBytes: omittedArgsBytes)
        }
    }

    private struct Usage: Codable {
        let inputTokens: Int?
        let outputTokens: Int?
        let promptTokens: Int?
        let contextLength: Int?
        let cost: Double?
        let estimated: Bool
        init(_ value: ChatUsage) {
            inputTokens = value.inputTokens; outputTokens = value.outputTokens
            promptTokens = value.promptTokens; contextLength = value.contextLength
            cost = value.cost; estimated = value.estimated
        }
        var value: ChatUsage {
            var fields: [String: Any] = ["last_prompt_tokens_estimated": estimated]
            fields["input_tokens"] = inputTokens
            fields["output_tokens"] = outputTokens
            fields["last_prompt_tokens"] = promptTokens
            fields["context_length"] = contextLength
            fields["estimated_cost"] = cost
            return ChatUsage(fields: fields)
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let scope: Scope
        let savedAt: Date
        var messages: [Message]
        var tools: [Tool]
        var olderOffset: Int
        /// Optional key for backwards-compatible reading of earlier envelopes.
        var omittedToolCount: Int?
        let model: String?
        let usage: Usage?
        var value: ChatHistoryRecord {
            // Build without passing an active-stream snapshot into the model.
            ChatHistoryRecord(sessionID: scope.sessionID, messages: messages.map(\.value), tools: tools.map(\.value),
                              olderOffset: olderOffset, model: model, usage: usage?.value, savedAt: savedAt,
                              uncachedToolCount: omittedToolCount ?? 0)
        }
    }

    private struct PendingWrite {
        let token: UUID
        let namespace: String
        let generation: UInt
        let sessionGeneration: UInt
        let root: URL
        let scope: Scope
        let record: ChatHistoryRecord
        let policy: Policy
        let task: DispatchWorkItem
    }

    private static let queue = DispatchQueue(label: "HermesNative.history-cache", qos: .utility)
    private static let generationLock = NSLock()
    private static var publishedGeneration: UInt = 0
    // Protected by generationLock, not the I/O queue: a new page captures
    // its scope generation immediately without blocking on disk writes.
    // Deletion advances this generation; only subsequently created stores
    // can write the same session ID. This replaces the permanent blacklist.
    private static var sessionGenerations: [String: UInt] = [:]
    // Queue-owned namespace retirement keeps old signed-out accounts inert.
    private static var retired = Set<String>()
    private static var generation: UInt = 0
    private static var pending: [String: PendingWrite] = [:]
    private let scope: Scope
    private let root: URL
    private let policy: Policy
    private let generation: UInt
    private let sessionGeneration: UInt

    init(instanceID: String, sessionID: String, accountScope: String,
         rootDirectory: URL? = nil, policy: Policy = Policy(),
         report: (@Sendable (WriteReport) -> Void)? = nil) {
        scope = Scope(instanceID: instanceID, sessionID: sessionID, accountScope: accountScope)
        root = rootDirectory ?? Self.defaultDirectory
        self.policy = policy
        self.report = report
        // This short lock never covers I/O; creating a page must not wait for
        // the utility queue to finish another session's JSON write.
        Self.generationLock.lock()
        generation = Self.publishedGeneration
        sessionGeneration = Self.sessionGenerations[scope.filename] ?? 0
        Self.generationLock.unlock()
    }

    func load() async -> ChatHistoryRecord? {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                guard self.valid else { continuation.resume(returning: nil); return }
                let url = self.root.appendingPathComponent(self.scope.filename)
                let result = Self.read(url: url, policy: self.policy)
                continuation.resume(returning: result?.scope == self.scope ? result?.value : nil)
                Self.queue.async { Self.clean(root: self.root, policy: self.policy) }
            }
        }
    }

    func schedule(_ record: ChatHistoryRecord) {
        Self.queue.async {
            guard self.valid else { return }
            let key = self.root.appendingPathComponent(self.scope.filename).path
            Self.pending.removeValue(forKey: key)?.task.cancel()
            let token = UUID()
            let task = DispatchWorkItem {
                let report = Self.writePending(key: key, token: token)
                self.publish(report)
            }
            Self.pending[key] = PendingWrite(token: token, namespace: self.scope.namespace, generation: self.generation,
                                             sessionGeneration: self.sessionGeneration,
                                             root: self.root, scope: self.scope, record: record,
                                             policy: self.policy, task: task)
            Self.queue.asyncAfter(deadline: .now() + max(0, self.policy.debounce), execute: task)
        }
    }

    /// Finish a debounced confirmed snapshot when the page closes. Encoding and
    /// disk writes still happen on the utility queue, never in the UI callback.
    func flush() async {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let key = self.root.appendingPathComponent(self.scope.filename).path
                // 关页时顺手把待写快照落盘；失败只意味着「这次没存上」，不影响关页。
                if self.valid {
                    let report = Self.writePending(key: key)
                    self.publish(report)
                }
                continuation.resume()
            }
        }
    }

    private func publish(_ report: WriteReport) {
        guard let failure = report.failure else { return }
        guard reportedFailures.insert(failure) else { return }
        self.report?(report)
    }

    /// Delete only the named account's cache. Do not mistake an unreadable
    /// directory or an undecodable envelope for a verified successful cleanup.
    @discardableResult
    static func remove(instanceID: String, accountScope: String,
                       rootDirectory: URL? = nil) async -> CleanupReport {
        await withCheckedContinuation { continuation in
            queue.async {
                let namespace = digest([instanceID, accountScope])
                retired.insert(namespace)
                for key in pending.keys.filter({ pending[$0]?.namespace == namespace }) {
                    pending.removeValue(forKey: key)?.task.cancel()
                }
                let directory = rootDirectory ?? defaultDirectory
                let manager = FileManager.default
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
                    continuation.resume(returning: .empty)
                    return
                }
                guard isDirectory.boolValue else {
                    continuation.resume(returning: CleanupReport(attempted: 0, removed: 0, failed: 1))
                    return
                }
                let urls: [URL]
                do {
                    urls = try manager.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "json" }
                } catch {
                    continuation.resume(returning: CleanupReport(attempted: 0, removed: 0, failed: 1))
                    return
                }
                var attempted = 0, removed = 0, failed = 0
                for url in urls {
                    // Check scope without calling read(): read() may itself
                    // delete invalid/expired cache files outside this account.
                    guard let data = try? Data(contentsOf: url),
                          let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                        failed += 1 // ownership could not be established
                        continue
                    }
                    guard envelope.scope.namespace == namespace else { continue }
                    attempted += 1
                    do {
                        try manager.removeItem(at: url)
                        if manager.fileExists(atPath: url.path) { failed += 1 }
                        else { removed += 1 }
                    } catch { failed += 1 }
                }
                continuation.resume(returning: CleanupReport(
                    attempted: attempted, removed: removed, failed: failed))
            }
        }
    }

    /// Global cache deletion is explicit and returns the actual on-disk result.
    /// Reset generations before deletion so stale writers cannot resurrect data.
    @discardableResult
    static func clearAll(rootDirectory: URL? = nil) async -> CleanupReport {
        await withCheckedContinuation { continuation in
            queue.async {
                generation &+= 1
                generationLock.lock()
                publishedGeneration = generation
                sessionGenerations.removeAll()
                generationLock.unlock()
                for value in pending.values { value.task.cancel() }
                pending.removeAll()
                retired.removeAll()
                let directory = rootDirectory ?? defaultDirectory
                let manager = FileManager.default
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
                    continuation.resume(returning: .empty)
                    return
                }
                guard isDirectory.boolValue else {
                    continuation.resume(returning: CleanupReport(attempted: 0, removed: 0, failed: 1))
                    return
                }
                let urls: [URL]
                do {
                    urls = try manager.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "json" }
                } catch {
                    continuation.resume(returning: CleanupReport(attempted: 0, removed: 0, failed: 1))
                    return
                }
                var removed = 0, failed = 0
                for url in urls {
                    do {
                        try manager.removeItem(at: url)
                        if manager.fileExists(atPath: url.path) { failed += 1 }
                        else { removed += 1 }
                    } catch { failed += 1 }
                }
                continuation.resume(returning: CleanupReport(
                    attempted: urls.count, removed: removed, failed: failed))
            }
        }
    }

    @discardableResult
    func remove() async -> CleanupReport {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                // A stale controller must never delete the cache of a new
                // controller that reused the session ID after removal.
                guard self.valid else {
                    continuation.resume(returning: .empty)
                    return
                }
                Self.generationLock.lock()
                Self.sessionGenerations[self.scope.filename] = self.sessionGeneration &+ 1
                Self.generationLock.unlock()
                let url = self.root.appendingPathComponent(self.scope.filename)
                Self.pending.removeValue(forKey: url.path)?.task.cancel()
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continuation.resume(returning: .empty)
                    return
                }
                do {
                    try FileManager.default.removeItem(at: url)
                    let gone = !FileManager.default.fileExists(atPath: url.path)
                    continuation.resume(returning: CleanupReport(
                        attempted: 1, removed: gone ? 1 : 0, failed: gone ? 0 : 1))
                } catch {
                    continuation.resume(returning: CleanupReport(attempted: 1, removed: 0, failed: 1))
                }
            }
        }
    }

    static func statistics(rootDirectory: URL? = nil) async -> Statistics {
        await withCheckedContinuation { continuation in
            queue.async {
                let root = rootDirectory ?? defaultDirectory
                clean(root: root, policy: Policy())
                let entries = files(in: root)
                continuation.resume(returning: Statistics(entries: entries.count, bytes: entries.reduce(0) { $0 + fileSize($1) }))
            }
        }
    }

    private var valid: Bool {
        guard generation == Self.generation && !Self.retired.contains(scope.namespace) else {
            return false
        }
        Self.generationLock.lock()
        defer { Self.generationLock.unlock() }
        return sessionGeneration == (Self.sessionGenerations[scope.filename] ?? 0)
    }

    private static var defaultDirectory: URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = cache.appendingPathComponent("HermesNativeHistory-v1", isDirectory: true)
        // 历史缓存含会话正文，不进设备备份：换机/恢复时不应把旧账号内容带到新设备。
        // 目录级失败可以容忍：真正决定「这份文件能不能被备份走」的是写盘时对
        // **文件本身**设的 `isExcludedFromBackup`（见 writePending，那一处失败会
        // 直接删文件并放弃这次缓存）。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    /// 返回失败类别，表示这次**没有**把缓存写成功（序列化失败 / 超预算 / 写盘失败 /
    /// 安全属性没设上）。缓存写失败不影响主流程，所以调用方可以忽略返回值，但签名
    /// 上必须体现「可能失败」，否则又变成一处静默降级（F-55a / F-71）。
    @discardableResult
    private static func writePending(key: String, token: UUID? = nil) -> WriteReport {
        if let token, pending[key]?.token != token { return .ok }
        guard let item = pending.removeValue(forKey: key) else { return .ok }
        item.task.cancel()
        generationLock.lock()
        let sessionIsCurrent = item.sessionGeneration == (sessionGenerations[item.scope.filename] ?? 0)
        generationLock.unlock()
        guard item.generation == generation, !retired.contains(item.namespace),
              sessionIsCurrent else {
            return .ok
        }
        guard item.record.sessionID == item.scope.sessionID else {
            return .ok
        }
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: item.root, withIntermediateDirectories: true)) != nil else {
            return .failed(.diskWrite)
        }
        let url = item.root.appendingPathComponent(item.scope.filename)
        var messages = Array(item.record.messages.compactMap(Message.init).suffix(max(1, item.policy.maxMessages)))
        // Bound the first encode too. Otherwise a thousand very long messages
        // could allocate hundreds of MB before the encoded-size check below.
        let budget = max(0, item.policy.maxEntryBytes - 1024)
        let messageCosts = messages.map { value in
            value.id.utf8.count + value.role.utf8.count + value.content.utf8.count
                + value.attachmentPaths.reduce(512) { $0 + $1.utf8.count }
        }
        var messageBytes = messageCosts.reduce(0, +)
        var removed = 0
        while messageBytes > budget && messages.count - removed > 1 {
            messageBytes -= messageCosts[removed]
            removed += 1
        }
        if removed > 0 { messages.removeFirst(removed) }
        guard messageBytes <= budget else {
            // 连一条消息都放不下：删掉旧缓存而不是留一份过期窗口冒充最新。
            try? manager.removeItem(at: url)
            clean(root: item.root, policy: item.policy)
            return .failed(.sizeBudget)
        }
        let visible = Set(messages.map(\.id))
        let eligible = item.record.tools.filter {
            !$0.id.hasPrefix("stream-tool:") && ($0.afterMessageID == nil || visible.contains($0.afterMessageID!))
        }
        let candidates = Array(eligible.suffix(max(0, item.policy.maxTools)))
        var tools: [Tool] = []
        var remaining = budget - messageBytes
        var omittedToolCount = max(0, eligible.count - candidates.count)
        // Preserve latest tool identity and completion state, even when the
        // full result is multi-megabyte. Missing payload != empty Gateway result.
        for tool in candidates.reversed() {
            let identity = tool.id.utf8.count + tool.name.utf8.count
                + (tool.afterMessageID?.utf8.count ?? 0) + 512
            let argsBytes = tool.args.utf8.count
            let resultBytes = tool.result.utf8.count
            let fullCost = identity + argsBytes + resultBytes
            if fullCost <= remaining {
                tools.append(Tool(tool))
                remaining -= fullCost
            } else if identity <= remaining {
                // Oversized *arguments* do not justify dropping a small result.
                let keepResult = resultBytes <= remaining - identity
                let keepArgs = argsBytes <= remaining - identity - (keepResult ? resultBytes : 0)
                tools.append(Tool(tool, omitResult: !keepResult, omitArgs: !keepArgs))
                remaining -= identity + (keepResult ? resultBytes : 0)
                    + (keepArgs ? argsBytes : 0)
            } else {
                omittedToolCount += 1
            }
        }
        tools.reverse()
        var envelope = Envelope(version: 1, scope: item.scope, savedAt: item.record.savedAt,
                                messages: messages, tools: tools,
                                olderOffset: max(item.record.olderOffset, messages.first?.sourceIndex ?? 0),
                                omittedToolCount: omittedToolCount > 0 ? omittedToolCount : nil,
                                model: item.record.model, usage: item.record.usage.map(Usage.init))
        let encoder = JSONEncoder()
        // F-55a：`try?` 会把「序列化失败」变成「什么都没发生」，用户看到的是
        // 「这次没存上」却毫无痕迹。改成显式 catch：删掉该条缓存文件（否则下次
        // 冷启动会读到更旧的窗口，界面上像是「最新历史丢了」），并返回失败。
        guard var encoded = encode(envelope, using: encoder) else {
            try? manager.removeItem(at: url)
            clean(root: item.root, policy: item.policy)
            return .failed(.serialization)
        }
        // Escaping JSON characters can exceed the conservative UTF-8 estimate.
        // Shed tool *payloads* before removing confirmed messages. Preserve
        // identity and a truthful omitted-byte marker on every re-encode.
        while encoded.count > item.policy.maxEntryBytes && !envelope.tools.isEmpty {
            let idx = envelope.tools.indices.max {
                let a = envelope.tools[$0], b = envelope.tools[$1]
                return a.result.utf8.count + a.args.utf8.count
                    < b.result.utf8.count + b.args.utf8.count
            }!
            let candidate = envelope.tools[idx]
            if !candidate.result.isEmpty {
                envelope.tools[idx] = Tool(candidate.value, omitResult: true)
            } else if !candidate.args.isEmpty {
                envelope.tools[idx] = Tool(candidate.value, omitArgs: true)
            } else {
                envelope.tools.remove(at: idx)
                envelope.omittedToolCount = (envelope.omittedToolCount ?? 0) + 1
            }
            guard let next = encode(envelope, using: encoder) else {
                try? manager.removeItem(at: url)
                clean(root: item.root, policy: item.policy)
                return .failed(.serialization)
            }
            encoded = next
        }
        // Keep complete messages. If a single newest message cannot fit, remove
        // the old cache rather than silently truncating its content.
        while encoded.count > item.policy.maxEntryBytes && messages.count > 1 {
            messages.removeFirst(max(1, messages.count / 4))
            envelope.messages = messages
            let remaining = Set(messages.map(\.id))
            envelope.tools.removeAll { $0.afterMessageID.map { !remaining.contains($0) } ?? false }
            envelope.olderOffset = max(item.record.olderOffset, messages.first?.sourceIndex ?? 0)
            guard let next = encode(envelope, using: encoder) else {
                try? manager.removeItem(at: url)
                clean(root: item.root, policy: item.policy)
                return .failed(.serialization)
            }
            encoded = next
        }
        guard encoded.count <= item.policy.maxEntryBytes else {
            try? manager.removeItem(at: url)
            clean(root: item.root, policy: item.policy)
            return .failed(.sizeBudget)
        }
        do {
            // Atomic replacement also prevents interrupted writes from exposing
            // half a JSON document. iOS data protection requires first unlock.
            #if os(iOS)
            try encoded.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try encoded.write(to: url, options: .atomic)
            #endif
        } catch {
            // A cache failure must not replace the network result, but it must
            // not leave a half-written or unprotected file behind either.
            try? manager.removeItem(at: url)
            diagnose("history cache write failed; entry dropped")
            clean(root: item.root, policy: item.policy)
            return .failed(.diskWrite)
        }
        // 修改时间只影响淘汰顺序与 maxAge 判断，失败可以容忍。
        try? manager.setAttributes([.modificationDate: item.record.savedAt], ofItemAtPath: url.path)
        // F-55b：`isExcludedFromBackup` 是安全语义，不是优化。目录级那道（见
        // defaultDirectory）失败可以放过，因为这里还有文件级的一道；文件级失败
        // 就必须放弃这份缓存 —— 宁可没有缓存，也不要一份能被备份走的明文。
        //
        // 只有 iOS 把它当硬失败：设备备份是 iOS 的行为，离线套件跑在 Linux 上，
        // 那里这条属性本来就只是尽力而为，若也删文件，缓存会在测试环境里写不进去。
        var excluded = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        #if os(iOS)
        do {
            try excluded.setResourceValues(resources)
        } catch {
            try? manager.removeItem(at: url)
            diagnose("history cache backup exclusion failed; entry dropped")
            clean(root: item.root, policy: item.policy)
            return .failed(.backupProtection)
        }
        #else
        try? excluded.setResourceValues(resources)
        #endif
        clean(root: item.root, policy: item.policy)
        return .ok
    }

    /// 序列化失败只在这里留一行 stderr 诊断。
    ///
    /// 不走运行时日志记录器：本文件被 `tests/historycache` 等离线套件单独编译，
    /// 那些套件没有链接日志模块；而且日志系统自身也可能因为磁盘问题失败，
    /// 递归写日志在这里没有意义。
    private static func encode(_ envelope: Envelope, using encoder: JSONEncoder) -> Data? {
        do {
            return try encoder.encode(envelope)
        } catch {
            diagnose("history cache encode failed; entry dropped")
            return nil
        }
    }

    /// 只写状态，不带会话/实例标识，避免诊断行本身泄漏作用域信息。
    private static func diagnose(_ message: String) {
        _ = try? FileHandle.standardError.write(contentsOf: Data(("[HermesNative][history-cache] " + message + "\n").utf8))
    }

    private static func read(url: URL, policy: Policy) -> Envelope? {
        guard fileSize(url) > 0, fileSize(url) <= policy.maxEntryBytes,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              -value.savedAt.timeIntervalSinceNow <= policy.maxAge,
              value.olderOffset >= 0,
              value.messages.count <= max(1, policy.maxMessages), value.tools.count <= max(0, policy.maxTools),
              Set(value.messages.map(\.id)).count == value.messages.count,
              value.messages.allSatisfy({ !$0.id.isEmpty && $0.sourceIndex >= 0 && ["user", "assistant"].contains($0.role)
                  && !$0.id.hasPrefix("local-") && !$0.id.hasPrefix("streaming:") }) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return value
    }

    private static func clean(root: URL, policy: Policy) {
        // Directory cleanup uses metadata, not a full JSON decode of every
        // conversation. Validation of content/version is local to load().
        let existing = files(in: root).compactMap { url -> (URL, Date, Int64)? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            guard size > 0, size <= policy.maxEntryBytes,
                  -modified.timeIntervalSinceNow <= policy.maxAge else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return (url, modified, size)
        }.sorted { $0.1 > $1.1 }
        var retained: Int64 = 0
        var count = 0
        for (url, _, size) in existing {
            if count >= policy.maxEntries || size > policy.maxTotalBytes - retained { try? FileManager.default.removeItem(at: url) }
            else { retained += size; count += 1 }
        }
    }

    private static func files(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Opaque filenames avoid putting instance/session names in directory lists.
    /// Scope equality inside the envelope is still checked on every read.
    private static func digest(_ components: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(components)) ?? Data()
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 7809847782465536322
        for byte in bytes {
            first = (first ^ UInt64(byte)) &* 1099511628211
            second = (second ^ UInt64(byte)) &* 14029467366897019727
        }
        return String(format: "%016llx%016llx", first, second)
    }
}

private extension ChatHistoryRecord {
    init(sessionID: String, messages: [ChatMessage], tools: [ChatTool], olderOffset: Int, model: String?, usage: ChatUsage?, savedAt: Date, uncachedToolCount: Int = 0) {
        self.sessionID = sessionID
        self.messages = messages; self.tools = tools; self.olderOffset = olderOffset
        self.model = model; self.usage = usage; self.savedAt = savedAt
        self.uncachedToolCount = uncachedToolCount
    }
}
