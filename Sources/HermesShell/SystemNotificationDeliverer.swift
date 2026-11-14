import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// 通知授权状态。与系统枚举解耦，方便设置页在 Linux 侧也能编译。
enum TaskNotificationAuthorization: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

/// 投递抽象。所有系统框架调用都收在这一层的实现里，其余代码只依赖协议，
/// 因此纯逻辑与视图部分在 Linux 离线套件中仍可编译。
protocol TaskNotificationDelivering: AnyObject {
    func deliver(_ notification: TaskNotification, sound: Bool) async
    func authorizationStatus() async -> TaskNotificationAuthorization
    /// 首次真正要投递时才申请，不在启动时弹权限框。
    func requestAuthorization() async -> TaskNotificationAuthorization
}

#if canImport(UserNotifications)

/// 系统实现。唯一 import `UserNotifications` 的地方。
final class SystemNotificationDeliverer: NSObject, TaskNotificationDelivering,
                                         UNUserNotificationCenterDelegate {

    static let shared = SystemNotificationDeliverer()

    /// 在 App 启动时注册自己为 delegate，前台策略由这里决定。
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func deliver(_ notification: TaskNotification, sound: Bool) async {
        // P1：投递前先看授权。原来这里直接 add，`try?` 吞掉错误——
        // 如果尚未授权，首次安装的用户
        // 需要从设置页显式申请，不能仅依靠默认开启的通知类型。
        //
        // 不在这里自动弹权限框：那会在用户没打开开关时突然弹窗。
        // 申请动作放在设置页开关被打开的那一刻（见 LoginSettings）。
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else {
            await RuntimeLogRecorder.shared.record(
                .info, "notify",
                "skip delivery kind=\(notification.kind) reason=not-authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = Self.title(for: notification.kind)
        content.body = Self.body(for: notification)
        // 声音默认关闭：静音不会让事实变少，只会让人错过；用户可单独打开。
        if sound { content.sound = .default }
        // P1：带上会话标识，点击通知才能导航到对应会话。
        // 只放 opaque id，不放标题/正文——通知内容会出现在锁屏上。
        content.userInfo = [
            Self.sessionIDKey: notification.sessionID,
            Self.instanceIDKey: notification.instanceID,
            Self.accountScopeKey: notification.accountScope
        ]

        // 不设 trigger：立即投递。
        let request = UNNotificationRequest(identifier: notification.stableID,
                                            content: content,
                                            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // P1：`try?` 吞错会让「通知没来」变成不可诊断。
            await RuntimeLogRecorder.shared.record(
                .error, "notify",
                "delivery failed kind=\(notification.kind) err=\(error.localizedDescription)")
        }
    }

    /// 通知携带的会话标识键。读取方在 `didReceive` 里取。
    static let sessionIDKey = "sessionID"
    static let instanceIDKey = "instanceID"
    static let accountScopeKey = "accountScope"

    func authorizationStatus() async -> TaskNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async -> TaskNotificationAuthorization {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        return await authorizationStatus()
    }

    // MARK: - 前台策略

    /// 前台一律不弹。
    ///
    /// 能走到这里说明 App 在前台；「用户正看着该会话」的情况已经由
    /// `TaskNotificationPlanner` 过滤掉了。剩下的是用户在 App 内但停在别处，
    /// 切到任务中心即可看到，弹横幅只会盖住输入框。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// P1：点击通知后导航到对应会话。
    ///
    /// 原来通知只带标题与正文，`userInfo` 为空，点击后无法知道该打开哪个会话——
    /// 通知只是「提示」，点进去停在列表页。这里把会话标识交给导航。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async -> Void {
        let info = response.notification.request.content.userInfo
        guard let sessionID = info[Self.sessionIDKey] as? String, !sessionID.isEmpty,
              let instanceID = info[Self.instanceIDKey] as? String, !instanceID.isEmpty,
              let accountScope = info[Self.accountScopeKey] as? String, !accountScope.isEmpty else { return }
        // Fail closed on old, unscoped notifications: a session ID alone
        // cannot identify its Hermes host or account.
        NotificationNavigation.shared.open(sessionID: sessionID,
            instanceID: instanceID, accountScope: accountScope)
    }

    // MARK: - 文案

    private static func title(for kind: TaskNotification.Kind) -> String {
        switch kind {
        case .approvalPending: return "需要你确认"
        case .runFinished: return "处理完成"
        case .recoveryIssue: return "后台恢复需处理"
        }
    }

    /// 只写会话名与状态，不写正文、工具输出或文件路径——通知会出现在锁屏上。
    private static func body(for notification: TaskNotification) -> String {
        switch notification.kind {
        case .approvalPending:
            return notification.sessionTitle + "：回复停在审批步骤"
        case .runFinished:
            return notification.sessionTitle + "：本轮已结束"
        case .recoveryIssue:
            return notification.sessionTitle + "：检查恢复记录后继续"
        }
    }
}

#else

/// Linux 侧的替身：只记录调用，不投递。用于离线套件编译通过。
final class SystemNotificationDeliverer: TaskNotificationDelivering {
    static let shared = SystemNotificationDeliverer()
    private(set) var delivered: [TaskNotification] = []

    func install() {}

    func deliver(_ notification: TaskNotification, sound: Bool) async {
        delivered.append(notification)
    }

    func authorizationStatus() async -> TaskNotificationAuthorization { .authorized }

    func requestAuthorization() async -> TaskNotificationAuthorization { .authorized }
}

#endif
