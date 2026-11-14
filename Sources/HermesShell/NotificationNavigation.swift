import Foundation

/// 通知点击后的导航意图。
///
/// 通知投递发生在系统回调里，那一刻没有视图上下文，也不能直接拿 `AppState`。
/// 这里只记录「用户点了哪个会话的通知」，由界面层在下一次出现时消费。
///
/// 刻意做成**零框架依赖、非 actor 隔离**的纯类型：
/// - `UserNotifications` 只在 `#if canImport` 块里可用，离线套件跑在 Linux 上；
/// - 加 `@MainActor` 会把它所在编译单元的顶层代码一并变成 MainActor 隔离，
///   让使用它的测试文件报 `main actor-isolated var can not be mutated from
///   a nonisolated context`。用 `NSLock` 保证线程安全即可，不必占用全局 actor。
final class NotificationNavigation {
    /// 单例。用 `nonisolated(unsafe)` 而不是 `@MainActor`：
    /// 内部全部访问都走 `NSLock`，线程安全由锁保证；若标 `@MainActor`，
    /// 会把使用它的编译单元顶层代码一并变成 MainActor 隔离，让纯逻辑测试
    /// 报 `main actor-isolated var can not be mutated from a nonisolated context`。
    nonisolated(unsafe) static let shared = NotificationNavigation()

    static let changed = Notification.Name("Hermes.notificationNavigation.changed")

    struct Target: Equatable, Sendable {
        let instanceID: String
        let accountScope: String
        let sessionID: String

        var isScoped: Bool { !instanceID.isEmpty && !accountScope.isEmpty }
    }

    @discardableResult
    func consume(target: Target) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending == target else { return false }
        pending = nil
        return true
    }

    /// Compatibility for legacy unscoped intents (used by older tests).
    /// Production routing must use consume(target:) to match all three keys.
    @discardableResult
    func consume(sessionID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending?.sessionID == sessionID else { return false }
        pending = nil
        return true
    }

    private let lock = NSLock()
    private var pending: Target?

    init() {}

    var pendingTarget: Target? {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    var pendingSessionID: String? { pendingTarget?.sessionID }

    /// Legacy notifications have no verified owner and must not be routed
    /// into an arbitrary active instance by the UI.
    func open(sessionID: String) {
        open(sessionID: sessionID, instanceID: "", accountScope: "")
    }

    func open(sessionID: String, instanceID: String, accountScope: String) {
        guard !sessionID.isEmpty else { return }
        lock.lock()
        pending = Target(instanceID: instanceID, accountScope: accountScope, sessionID: sessionID)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = pending?.sessionID
        pending = nil
        return value
    }
}
