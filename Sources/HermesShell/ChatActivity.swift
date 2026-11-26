import Foundation

/// Presentation of client knowledge, not a claim about server execution.
enum ChatActivity: Equatable {
    case ready, loading, syncing, sending, connecting, replying, stopping
    case reconnecting, verifying, suspended, needsVerification, needsLogin, readOnly
    case waitingForApproval, waitingForClarify
    case cached(syncing: Bool)
    case tool(String)
    case failed

    var title: String {
        switch self {
        case .ready: return "就绪"
        case .loading: return "正在同步…"
        case .syncing: return "正在同步…"
        case .sending: return "正在发送…"
        case .connecting: return "正在连接回复…"
        case .replying: return "Hermes 正在回复…"
        case .stopping: return "正在停止…"
        case .reconnecting: return "连接中断，正在恢复…"
        case .verifying: return "正在同步…"
        case .suspended: return "连接已暂停"
        case .needsVerification: return "回复状态尚未确认"
        case .needsLogin: return "登录已失效 · 请重新登录"
        case .readOnly: return "只读会话"
        case .waitingForApproval: return "等待你确认"
        case .waitingForClarify: return "等待你补充信息"
        case .cached(let syncing): return syncing ? "正在同步…" : "离线历史"
        case .tool(let name): return "正在执行 \(name)…"
        case .failed: return "暂时无法完成"
        }
    }

    var showsProgress: Bool {
        switch self {
        case .loading, .syncing, .sending, .connecting, .replying, .stopping,
             .reconnecting, .verifying, .tool: return true
        case .cached(let syncing): return syncing
        default: return false
        }
    }

    /// Old unfinished tools must never become active again just because a new
    /// user turn starts. Nil/unloaded anchors remain unknown, never fabricated.
    static func activeToolIDs(messages: [ChatMessage], tools: [ChatTool]) -> Set<String> {
        let start = messages.lastIndex(where: { $0.role == "user" }) ?? messages.startIndex
        let anchors = Set(messages[start...].map(\.id))
        return Set(tools.compactMap { tool in
            guard !tool.done, !tool.isError, let anchor = tool.afterMessageID,
                  anchors.contains(anchor) else { return nil }
            return tool.id
        })
    }
}


/// A warning action and its label share one policy. An unresolved run takes
/// precedence over a degraded recovery record without hiding real I/O errors.
enum ChatNoticeAction: Equatable {
    case details, reconcilePending, verifyStatus, retry

    static func choose(hasPendingSend: Bool, uncertain: Bool,
                       persistenceIssue: Bool, recoveryDegraded: Bool) -> ChatNoticeAction {
        if persistenceIssue { return .details }
        if hasPendingSend { return .reconcilePending }
        if uncertain { return .verifyStatus }
        if recoveryDegraded { return .details }
        return .retry
    }

    var title: String {
        switch self {
        case .details: return "详情"
        case .reconcilePending, .verifyStatus: return "同步状态"
        case .retry: return "重试"
        }
    }
}


/// One product-facing projection for chrome, notices and task panels.
/// It must never be used as authority to send, stop, or retire a receipt.
struct SessionPresentationState: Equatable {
    let title: String
    let showsProgress: Bool
    let showsWarning: Bool
    let showsNotice: Bool
    let needsVerification: Bool
    let hasError: Bool
    let notice: String?

    init(activity: ChatActivity, transcriptAvailable: Bool,
         routineRecovery: Bool, requiresAction: Bool,
         verificationPending: Bool, errorPresent: Bool,
         warningPresent: Bool, notice: String?) {
        let compactRecovery = transcriptAvailable && routineRecovery && !requiresAction
            && activity != .stopping && activity != .needsLogin
            && activity != .waitingForApproval && activity != .waitingForClarify
            && activity != .suspended && activity != .sending
        if compactRecovery {
            title = "正在同步…"
            showsProgress = true
            showsWarning = false
            showsNotice = false
            needsVerification = false
            hasError = false
            self.notice = nil
        } else {
            title = activity.title
            showsProgress = activity.showsProgress
            showsWarning = warningPresent && !showsProgress
            showsNotice = warningPresent
            needsVerification = verificationPending
            hasError = errorPresent
            self.notice = notice
        }
    }
}
