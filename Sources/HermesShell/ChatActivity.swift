import Foundation

/// Presentation of client knowledge, not a claim about server execution.
enum ChatActivity: Equatable {
    case ready, loading, syncing, sending, connecting, replying, stopping
    case reconnecting, verifying, suspended, needsVerification, needsLogin, readOnly
    case cached(syncing: Bool)
    case tool(String)
    case failed

    var title: String {
        switch self {
        case .ready: return "就绪"
        case .loading: return "正在读取会话…"
        case .syncing: return "正在同步历史…"
        case .sending: return "正在发送…"
        case .connecting: return "正在连接回复…"
        case .replying: return "Hermes 正在回复…"
        case .stopping: return "正在停止…"
        case .reconnecting: return "连接中断，正在恢复…"
        case .verifying: return "正在核对后台状态…"
        case .suspended: return "连接已暂停 · 返回后核对"
        case .needsVerification: return "后台状态待核对"
        case .needsLogin: return "登录已失效 · 请重新登录"
        case .readOnly: return "只读会话"
        case .cached(let syncing): return syncing ? "本地历史 · 正在联网核对…" : "本地历史 · 待联网核对"
        case .tool(let name): return "正在执行 \(name)…"
        case .failed: return "操作未完成 · 请查看提示"
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
