import Foundation

/// 通知偏好的读写入口。
///
/// 三类通知默认全开：它们都是「需要你知道」的事实，静音不会让事实变少，
/// 只会让人错过。声音默认关：横幅本身已经够，响铃在多数场景是打扰。
///
/// 用静态属性而不是 `@AppStorage`，因为读取方是 `AppState` 与投递层，不是
/// 视图。设置页仍通过 `@AppStorage` 绑定同名 key，两边读同一份存储。
enum NotificationPreference {
    static let approvalKey = "hermesNotifyApproval"
    static let finishedKey = "hermesNotifyFinished"
    static let recoveryKey = "hermesNotifyRecovery"
    static let soundKey = "hermesNotifySound"

    /// 读取时给默认值 true：首次启动 key 不存在也应是开启。
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    static var approval: Bool { flag(approvalKey, default: true) }
    static var finished: Bool { flag(finishedKey, default: true) }
    static var recovery: Bool { flag(recoveryKey, default: true) }
    static var sound: Bool { flag(soundKey, default: false) }

    /// Clarify is another blocking "reply needs you" event and shares the
    /// approval toggle. Resolve the value explicitly so a new install gets the
    /// promised default-on behavior even if another caller rewrites the store.
    static var clarify: Bool { approval }
}
