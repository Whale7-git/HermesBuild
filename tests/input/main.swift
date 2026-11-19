import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
typealias Policy = ChatInputPolicy

expect(Policy.action(replacement: "\n", isReturnAction: true, composing: false,
                     returnSends: true, canSubmit: true) == .submit,
       "a native Return action in send mode submits")
expect(Policy.action(replacement: "\n", isReturnAction: false, composing: false,
                     returnSends: true, canSubmit: true) == .edit,
       "an explicit newline document insertion does not submit")
expect(Policy.action(replacement: "\n", isReturnAction: true, composing: true,
                     returnSends: true, canSubmit: true) == .edit,
       "Return while an IME has marked text remains an IME edit")
expect(Policy.action(replacement: "\n", isReturnAction: true, composing: false,
                     returnSends: false, canSubmit: true) == .edit,
       "the user can restore Return-to-newline")
expect(Policy.action(replacement: "\n", isReturnAction: true, composing: false,
                     returnSends: true, canSubmit: false) == .consume,
       "empty, locked or running submissions do not submit or insert Return")

for value in ["你好", "nihao", "🙂", "👩🏽‍💻", "第一行\n第二行", "\n\n", "", " "] {
    expect(Policy.action(replacement: value, isReturnAction: true, composing: false,
                         returnSends: true, canSubmit: true) == .edit,
           "text edits and multiline pastes never become a Return action")
}
for value in ["\r", "\r\n", "\u{2028}", "\u{2029}"] {
    expect(Policy.action(replacement: value, isReturnAction: true, composing: false,
                         returnSends: true, canSubmit: true) == .submit,
           "IME Return variants submit through the same keyboard action")
}
for value in ["\r", "\r\n", "\u{2028}", "\u{2029}"] {
    expect(Policy.action(replacement: value, isReturnAction: false, composing: false,
                         returnSends: true, canSubmit: true) == .edit,
           "pasted or explicit IME line separators remain document content")
}
for enabled in [true, false] {
    for composing in [true, false] {
        expect(Policy.action(replacement: "\n", isReturnAction: false, composing: composing,
                             returnSends: enabled, canSubmit: true) == .edit,
               "explicit newline editing remains an edit under all settings")
    }
}

expect(ChatComposerActionPolicy.showsSend(running: false, sendEnabled: false,
                                          hasReadyAttachments: false),
       "idle composer keeps a visible (disabled) send affordance")
expect(!ChatComposerActionPolicy.showsStop(running: false),
       "idle composer does not offer stop")
expect(!ChatComposerActionPolicy.showsSend(running: true, sendEnabled: false,
                                           hasReadyAttachments: false),
       "empty running composer hides send")
expect(ChatComposerActionPolicy.showsStop(running: true),
       "empty running composer always exposes stop, even before a stream id")
expect(ChatComposerActionPolicy.showsSend(running: true, sendEnabled: true,
                                          hasReadyAttachments: false)
       && ChatComposerActionPolicy.showsStop(running: true),
       "typed running composer offers both send and stop")
expect(ChatComposerActionPolicy.reservesSendSlot(running: true, sendEnabled: false,
                                                hasReadyAttachments: false),
       "empty running draft reserves inert send slot to keep Stop fixed")
expect(!ChatComposerActionPolicy.reservesSendSlot(running: true, sendEnabled: true,
                                                 hasReadyAttachments: false),
       "first typed character replaces reserved slot without adding control width")
expect(!ChatComposerActionPolicy.reservesSendSlot(running: true, sendEnabled: false,
                                                 hasReadyAttachments: true),
       "ready attachments replace reserved slot with disabled send affordance")
expect(!ChatComposerActionPolicy.reservesSendSlot(running: false, sendEnabled: false,
                                                 hasReadyAttachments: false),
       "idle composer never shows an extra blank slot")
expect(ChatReadingShortcutPolicy.showInline(
           text: String(repeating: "长", count: 1000), isStreaming: false, showsCopy: true),
       "long completed answer exposes direct reader shortcut")
expect(!ChatReadingShortcutPolicy.showInline(
           text: String(repeating: "短", count: 999), isStreaming: false, showsCopy: true),
       "short answer keeps compact copy quote more toolbar")
expect(!ChatReadingShortcutPolicy.showInline(
           text: String(repeating: "x", count: 1000), isStreaming: true, showsCopy: true),
       "streaming output does not gain a reader button while expanding")
expect(!ChatReadingShortcutPolicy.showInline(
           text: String(repeating: "x", count: 1000), isStreaming: false, showsCopy: false),
       "tool-only or restricted row does not gain a reader button")
expect(ChatReadingShortcutPolicy.showInline(
           text: String(repeating: "👩🏽‍💻", count: 170), isStreaming: false, showsCopy: true),
       "UTF-16 threshold handles emoji clusters without treating graphemes as code units")
expect(ChatComposerActionPolicy.showsSend(running: true, sendEnabled: false,
                                          hasReadyAttachments: true)
       && ChatComposerActionPolicy.showsStop(running: true),
       "attachments do not obscure stop while running")
for (readOnly, loading, stopping, composing, canSend, hasContent, token) in [
    (true, false, false, false, true, true, "只读"),
    (false, false, true, false, true, true, "停止"),
    (false, true, false, false, true, true, "读取"),
    (false, false, false, true, true, true, "输入法"),
    (false, false, false, false, false, true, "核对状态"),
    (false, false, false, false, true, false, "附件"),
    (false, false, false, false, true, true, "发送当前")
] {
    let hint = ChatComposerFeedbackPolicy.sendHint(
        readOnly: readOnly, loading: loading, stopping: stopping,
        composing: composing, canSend: canSend, hasContent: hasContent)
    expect(hint.contains(token), "composer hint respects \(token) condition")
}
expect(ChatComposerFeedbackPolicy.stopHint(stopping: true, canStop: false).contains("确认终态"),
       "stop acknowledgement must not be described as completed")
expect(ChatComposerFeedbackPolicy.stopHint(stopping: false, canStop: false).contains("连接"),
       "unavailable stop explains connection gating")
expect(ChatComposerFeedbackPolicy.stopHint(stopping: false, canStop: true).contains("请求停止"),
       "available stop describes a request, not guaranteed terminal")
print("CHAT_INPUT_POLICY_PASS \(checks) assertions (UIKit/IME routing requires device testing)")
