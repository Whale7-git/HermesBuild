import Foundation

/// 模型「最近使用」的本地记录。
///
/// 只记**服务端确认成功**的切换，键用 `ModelOption.id`（`provider/model`），
/// 与选择器判定当前项的身份一致，因此同名不同 provider 的模型不会互相顶替。
/// 按「实例 + 账号」隔离：切账号、删除实例、清缓存都要同步清理，
/// 否则另一个账号会看到上一个账号的最近模型。
final class RecentModelStore {
    static let shared = RecentModelStore()

    /// 每个作用域最多保留几条。
    static let limit = 3

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// scope -> [id]，最近使用的在前。
    private var cache: [String: [String]] = [:]
    private var loadedScopes: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 读写

    /// 记录一次成功切换。重复选择同一模型会把它移到最前，不产生重复项。
    func remember(scope: String, id: String) {
        guard !scope.isEmpty, !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var list = loadLocked(scope)
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        cache[scope] = list
        persistLocked(list, scope: scope)
    }

    /// 最近使用的模型 id，最近的在前。
    func ids(scope: String) -> [String] {
        guard !scope.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(scope)
    }

    /// 把记录过滤成目录里仍然存在的模型，保持原有顺序。
    /// 目录换过 provider 之后，旧 id 会自然消失，不需要额外迁移。
    func availableIds(scope: String, in options: [ModelOption]) -> [String] {
        let known = Set(options.map(\.id))
        return ids(scope: scope).filter { known.contains($0) }
    }

    func remove(scope: String) {
        guard !scope.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: scope)
        loadedScopes.insert(scope)
        defaults.removeObject(forKey: Self.storageKey(scope))
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        for scope in cache.keys { defaults.removeObject(forKey: Self.storageKey(scope)) }
        for scope in loadedScopes { defaults.removeObject(forKey: Self.storageKey(scope)) }
        cache = [:]
        loadedScopes = []
    }

    // MARK: - 内部

    private func loadLocked(_ scope: String) -> [String] {
        if let hit = cache[scope] { return hit }
        loadedScopes.insert(scope)
        var list: [String] = []
        if let data = defaults.data(forKey: Self.storageKey(scope)),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            // 磁盘内容可能是旧版本写的：去重 + 截断，保证顺序与上限。
            var seen: Set<String> = []
            for id in decoded where !id.isEmpty && !seen.contains(id) {
                seen.insert(id)
                list.append(id)
            }
            list = Array(list.prefix(Self.limit))
        }
        cache[scope] = list
        return list
    }

    private func persistLocked(_ list: [String], scope: String) {
        let key = Self.storageKey(scope)
        guard !list.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }

    private static func storageKey(_ scope: String) -> String {
        "hermes.recentModels." + scope
    }
}
