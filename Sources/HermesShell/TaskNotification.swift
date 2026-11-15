import Foundation

/// 一条待投递的本地通知。
///
/// 纯值类型，不依赖 `UserNotifications`——这样 Linux 离线套件也能编译并断言
/// 决策逻辑，系统投递单独放在 `SystemNotificationDeliverer` 里。
struct TaskNotification: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// 服务端在等用户投票，run 挂起。
        case approvalPending
        /// 服务端在等用户补充自由文本或选项，run 同样挂起。
        case clarifyPending
        /// 后台那一轮跑完了。
        case runFinished
        /// 后台恢复遇到需要人看的问题。
        case recoveryIssue
    }

    let kind: Kind
    /// The source account is part of notification identity and routing.
    let instanceID: String
    let accountScope: String
    let sessionID: String
    /// 会话显示名。空标题由 Planner 降级成占位文案，不在这里补。
    let sessionTitle: String
    /// 交给系统的通知标识，用于替换去重。
    ///
    /// 必须是稳定且可推导的：同一个事实重复到达要得到同一个值，系统才会
    /// 替换而不是堆叠。绝不使用 `UUID()`。
    let stableID: String
}
