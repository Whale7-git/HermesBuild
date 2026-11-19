import Foundation

/// A discoverable reader shortcut without adding buttons to every short reply.
/// The source message, not a collapsed preview, is the input: folding a long
/// answer must not make its reader shortcut disappear. There is no text parsing
/// or layout work on scrolling frames.
enum ChatReadingShortcutPolicy {
    static let minimumUTF16Length = 1000

    static func showInline(text: String, isStreaming: Bool,
                           showsCopy: Bool) -> Bool {
        !isStreaming && showsCopy && text.utf16.count >= minimumUTF16Length
    }
}
