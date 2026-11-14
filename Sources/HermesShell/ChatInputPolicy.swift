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

    static func showsStop(running: Bool) -> Bool { running }
}
