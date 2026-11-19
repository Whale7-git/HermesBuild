import Foundation

/// Classifies UITextViewDelegate edits. A keyboard Return may surface as LF,
/// CR, CRLF or the Unicode line separators depending on the active IME. Marked
/// text, paste, explicit newline insertion and ordinary edits stay edits.
enum ChatInputPolicy {
    enum Action: Equatable { case edit, submit, consume }

    static func action(replacement: String, isReturnAction: Bool, composing: Bool,
                       returnSends: Bool, canSubmit: Bool) -> Action {
        guard isReturnAction, isReturnReplacement(replacement), !composing, returnSends else {
            return .edit
        }
        return canSubmit ? .submit : .consume
    }

    static func isReturnReplacement(_ value: String) -> Bool {
        ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"].contains(value)
    }
}

/// Which primary actions are visible in the chat composer.
///
/// Visibility is distinct from enabled state. When a turn is running and the
/// draft is empty, Stop must replace Send; the user must never be left with
/// neither action. This stays Foundation-only so it is regression-testable.
enum ChatComposerActionPolicy {
    static func showsSend(running: Bool, sendEnabled: Bool, hasReadyAttachments: Bool) -> Bool {
        !running || sendEnabled || hasReadyAttachments
    }

    /// Keep the Send slot's geometry alive while a running assistant has no
    /// draft to send. Typing the first character must not shift the Stop button.
    /// This is visual only: no hidden control can dispatch a request.
    static func reservesSendSlot(running: Bool, sendEnabled: Bool,
                                 hasReadyAttachments: Bool) -> Bool {
        running && !showsSend(running: running, sendEnabled: sendEnabled,
                              hasReadyAttachments: hasReadyAttachments)
    }

    static func showsStop(running: Bool) -> Bool { running }
}

/// Accessibility feedback for disabled composer actions. This does not
/// interpret server status or authorize sending: the existing canSend gate
/// and draft/IME policy remain authoritative.
enum ChatComposerFeedbackPolicy {
    static func sendHint(readOnly: Bool, loading: Bool, stopping: Bool,
                         composing: Bool, canSend: Bool, hasContent: Bool) -> String {
        if readOnly { return "当前会话只读，无法发送消息" }
        if stopping { return "正在等待服务端确认停止，暂不能发送" }
        if loading { return "正在读取会话，请稍后发送" }
        if composing { return "输入法正在组合文字，请先完成输入" }
        if !canSend { return "当前连接或运行状态暂不允许发送，请先核对状态" }
        if !hasContent { return "请输入文字或添加附件" }
        return "发送当前消息"
    }

    static func stopHint(stopping: Bool, canStop: Bool) -> String {
        if stopping { return "已请求停止，等待服务端确认终态" }
        if !canStop { return "当前连接未就绪，暂不能请求停止" }
        return "请求停止当前回复；需等待服务端确认"
    }
}
