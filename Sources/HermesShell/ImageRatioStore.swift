import Dispatch
import Foundation

/// 图片行盒的布局规则：只由宽度约束与真实纵横比决定，绝不估算。
///
/// `aspect` 是宽高比（SwiftUI `aspectRatio` 的口径），`isLong` 只看纵横比，
/// 与「按宽度算出来的高度」无关：普通方图在窄屏上算出的高度也可能超过上限，
/// 但它的纵横比仍然是 1:1，不能因此被标成长图。
enum InlineImageLayout {
    /// 未知比例时的固定占位：4:3（宽/高）。
    static let placeholderAspect: CGFloat = 4.0 / 3.0
    /// 高/宽 ≥ 2 视为长图（截图、长文图片）。
    static let longRatio: CGFloat = 2.0
    /// 长图折叠后的高度。
    static let longHeight: CGFloat = 320
    /// 非长图的最大高度，超过时按比例收窄而不是拉伸。
    static let maxHeight: CGFloat = 360
    /// 合理性区间：小于 1:50 或大于 50:1 的比例视为不可信。
    static let ratioRange: ClosedRange<CGFloat> = 0.02...50

    /// 只接受有限、落在合理区间的比例。
    static func normalized(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratioRange.contains(ratio) else { return nil }
        return ratio
    }

    /// 纵横比（高/宽）是否属于长图。没有任何高度计算参与。
    static func isLong(ratio: CGFloat?) -> Bool {
        guard let ratio = normalized(ratio) else { return false }
        return ratio >= longRatio
    }

    /// SwiftUI `aspectRatio` 使用的宽高比；未知比例退回固定 4:3 占位。
    static func aspect(ratio: CGFloat?) -> CGFloat {
        guard let ratio = normalized(ratio) else { return placeholderAspect }
        return 1 / ratio
    }

    static func maxHeight(ratio: CGFloat?) -> CGFloat {
        isLong(ratio: ratio) ? longHeight : maxHeight
    }
}

/// 进入会话时取一次的只读比例快照。
///
/// 整个会话生命周期内都用这一份：图片加载完成后只写缓存，不改变当前行高；
/// 宿主单元格销毁重建时拿到的还是同一份值，所以不会因为缓存刚更新就突然变高。
/// 旋转、宽度变化由现有锚点机制处理，行高按同一比例重新计算。
struct ImageRatioSnapshot: Equatable, Sendable {
    private let values: [String: CGFloat]

    static let empty = ImageRatioSnapshot(values: [:])

    init(values: [String: CGFloat]) {
        self.values = values
    }

    func ratio(for path: String) -> CGFloat? { values[path] }
    var count: Int { values.count }
}

/// 按「实例 + 账号」作用域、会话与附件路径隔离的比例缓存。
///
/// 读写分离：UI 只读内存快照，磁盘读取在后台预载，写入合并后由后台队列落盘。
/// 每次删除作用域/清空都会推进代数，排队中的旧写入会被丢弃，避免退出账号或
/// 清缓存之后又被迟到的下载回调写回来。
final class ImageRatioStore {
    static let shared = ImageRatioStore()

    struct WriteToken: Equatable, Sendable {
        fileprivate let scope: String
        fileprivate let epoch: UInt64
        fileprivate let revision: UInt64
    }

    struct Limits {
        var entries = 300
        var maxAge: TimeInterval = 90 * 24 * 60 * 60
    }

    private struct Record: Codable {
        let session: String
        let path: String
        let ratio: Double
        let at: Double
    }

    private let directory: URL
    private let limits: Limits
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.hermes.image-ratio.io", qos: .utility)
    private var cache: [String: [String: Record]] = [:]
    private var loadedScopes: Set<String> = []
    private var loadingScopes: [String: WriteToken] = [:]
    /// 同一会话的快照会被视图构造反复读取，缓存一份避免重复建字典。
    private var snapshots: [String: ImageRatioSnapshot] = [:]
    private var dirtyScopes: Set<String> = []
    private var writeScheduled = false
    /// 删除作用域/清空时递增；旧代数排队中的写入直接丢弃。
    private var generation: UInt64 = 0
    private var scopeRevisions: [String: UInt64] = [:]

    /// Capture before the asynchronous image request, never on completion.
    func token(scope: String) -> WriteToken {
        lock.lock()
        defer { lock.unlock() }
        return tokenLocked(scope: scope)
    }

    private func tokenLocked(scope: String) -> WriteToken {
        WriteToken(scope: scope, epoch: generation, revision: scopeRevisions[scope] ?? 0)
    }

    private func acceptsLocked(_ token: WriteToken) -> Bool {
        token == tokenLocked(scope: token.scope)
    }

    init(directory: URL? = nil, limits: Limits = Limits()) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directory = base.appendingPathComponent("HermesImageRatios", isDirectory: true)
        }
        self.limits = limits
    }

    private static func key(session: String, path: String) -> String {
        session + "\u{1f}" + path
    }

    private static func digest(_ value: String) -> String {
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 7809847782465536322
        for byte in Data(value.utf8) {
            first = (first ^ UInt64(byte)) &* 1099511628211
            second = (second ^ UInt64(byte)) &* 14029467366897019727
        }
        return String(format: "%016llx%016llx", first, second)
    }

    private func fileURL(scope: String) -> URL {
        directory.appendingPathComponent(Self.digest(scope) + ".json")
    }

    // MARK: - 读

    /// UI 只读内存：不做任何同步磁盘 I/O。
    func snapshot(scope: String, sessionID: String) -> ImageRatioSnapshot {
        lock.lock()
        let cacheKey = scope + "\u{1e}" + sessionID
        if let hit = snapshots[cacheKey] {
            lock.unlock()
            return hit
        }
        let table = cache[scope] ?? [:]
        var values: [String: CGFloat] = [:]
        for record in table.values where record.session == sessionID {
            values[record.path] = CGFloat(record.ratio)
        }
        let snapshot = ImageRatioSnapshot(values: values)
        snapshots[cacheKey] = snapshot
        lock.unlock()
        preload(scope: scope)
        return snapshot
    }

    /// 后台把作用域文件读进内存；同一个作用域只尝试一次。内存里已有的记录优先，
    /// 不会被磁盘上的旧副本覆盖（预载期间可能刚写到新的比例）。
    func preload(scope: String) {
        guard !scope.isEmpty else { return }
        lock.lock()
        let done = loadedScopes.contains(scope) || loadingScopes[scope] != nil
        let token = tokenLocked(scope: scope)
        if !done { loadingScopes[scope] = token }
        lock.unlock()
        guard !done else { return }

        ioQueue.async { [weak self] in
            self?.loadFromDisk(scope: scope, token: token)
        }
    }

    /// 测试用：同步预载，避免用例依赖调度时序。生产路径只用 `preload`。
    func preloadSynchronously(scope: String) {
        lock.lock()
        let token = tokenLocked(scope: scope)
        loadingScopes[scope] = token
        lock.unlock()
        ioQueue.sync { loadFromDisk(scope: scope, token: token) }
    }

    private func loadFromDisk(scope: String, token: WriteToken) {
        var table: [String: Record] = [:]
        // 可忽略：比例缓存失败只会导致图片先按默认比例渲染一次
        if let data = try? Data(contentsOf: fileURL(scope: scope)),
           // 可忽略：比例缓存失败只会导致图片先按默认比例渲染一次
           let records = try? JSONDecoder().decode([Record].self, from: data) {
            for record in records {
                table[Self.key(session: record.session, path: record.path)] = record
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard acceptsLocked(token) else { return }
        if loadingScopes[scope] == token { loadingScopes.removeValue(forKey: scope) }
        guard !loadedScopes.contains(scope) else { return }
        loadedScopes.insert(scope)
        // 预载期间写入的记录更新，保留它们。
        let existing = cache[scope] ?? [:]
        table.merge(existing) { _, new in new }
        pruneLocked(&table)
        cache[scope] = table
        snapshots.removeAll()
    }

    // MARK: - 写

    func remember(token: WriteToken, sessionID: String, path: String, ratio: CGFloat) {
        let scope = token.scope
        guard !scope.isEmpty, !sessionID.isEmpty, !path.isEmpty,
              let normalized = InlineImageLayout.normalized(ratio) else { return }
        lock.lock()
        guard acceptsLocked(token) else { lock.unlock(); return }
        var table = cache[scope] ?? [:]
        let key = Self.key(session: sessionID, path: path)
        if let previous = table[key], abs(CGFloat(previous.ratio) - normalized) < 0.0001 {
            lock.unlock()
            return
        }
        table[key] = Record(session: sessionID, path: path,
                            ratio: Double(normalized), at: Date().timeIntervalSince1970)
        pruneLocked(&table)
        cache[scope] = table
        // A measurement does not mean that the existing file has been loaded.
        // Merge old records first, preserving the new in-memory measurement.
        snapshots.removeAll()
        dirtyScopes.insert(scope)
        let schedule = !writeScheduled
        if schedule { writeScheduled = true }
        lock.unlock()
        preload(scope: scope)
        if schedule { scheduleWrite() }
    }

    /// 合并写盘：0.4 秒内的多次测量只落一次盘，且不在调用线程上做 I/O。
    private func scheduleWrite() {
        ioQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.writeDirty()
        }
    }

    private func writeDirty() {
        lock.lock()
        let scopes = dirtyScopes
        dirtyScopes.removeAll()
        writeScheduled = false
        var payloads: [(WriteToken, [String: Record])] = []
        for scope in scopes {
            if let table = cache[scope] { payloads.append((tokenLocked(scope: scope), table)) }
        }
        lock.unlock()

        for (token, table) in payloads {
            // 期间被清空/移除作用域：丢弃这次写盘。
            guard accepts(token) else { continue }
            persist(table, scope: token.scope)
        }
    }

    /// 测试用：等待排队中的写入完成。生产路径不调用。
    func flushPendingWrites() {
        // Earlier preloads/deletions must complete before taking the payload.
        ioQueue.sync { writeDirty() }
    }

    private func accepts(_ token: WriteToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsLocked(token)
    }

    // MARK: - 作用域

    /// 切换账号、删除实例时按作用域清理。
    func remove(scope: String) {
        lock.lock()
        scopeRevisions[scope, default: 0] &+= 1
        cache[scope] = [:]
        loadedScopes.insert(scope)
        loadingScopes.removeValue(forKey: scope)
        dirtyScopes.remove(scope)
        snapshots.removeAll()
        ioQueue.async { [weak self] in
            guard let self else { return }
            // 可忽略：比例缓存失败只会导致图片先按默认比例渲染一次
            try? FileManager.default.removeItem(at: self.fileURL(scope: scope))
        }
        lock.unlock()
    }

    /// 清空全部缓存（清缓存 / 退出登录）。
    func clearAll() {
        lock.lock()
        generation &+= 1
        cache = [:]
        loadedScopes = []
        loadingScopes = [:]
        scopeRevisions = [:]
        snapshots.removeAll()
        dirtyScopes = []
        ioQueue.async { [weak self] in
            guard let self else { return }
            // 可忽略：比例缓存失败只会导致图片先按默认比例渲染一次
            try? FileManager.default.removeItem(at: self.directory)
        }
        lock.unlock()
    }

    // MARK: - 落盘

    private func pruneLocked(_ table: inout [String: Record]) {
        let cutoff = Date().timeIntervalSince1970 - limits.maxAge
        table = table.filter { $0.value.at >= cutoff }
        guard table.count > limits.entries else { return }
        let newest = table.sorted { $0.value.at > $1.value.at }.prefix(limits.entries)
        table = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    private func persist(_ table: [String: Record], scope: String) {
        let records = table.values.sorted { $0.at > $1.at }
        guard !records.isEmpty else {
            // 可忽略：比例缓存失败只会导致图片先按默认比例渲染一次
            try? FileManager.default.removeItem(at: fileURL(scope: scope))
            return
        }
        // 可忽略：比例缓存失败只会导致图片先按默认比例渲染一次
        guard let data = try? JSONEncoder().encode(records) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(scope: scope), options: .atomic)
        } catch {
            // 缓存写失败只影响下次首帧比例，不影响本次显示；不抛错、不阻塞。
        }
    }
}
