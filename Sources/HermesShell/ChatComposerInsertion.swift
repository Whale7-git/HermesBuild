import Foundation

/// Inserts a quoted block after the existing draft. Slash commands still use
/// whole-document insertion; quoted messages preserve work already typed.
struct ChatComposerInsertion: Equatable {
    var token = 0
    var text = ""
}

enum ChatComposerInsertionPlan {
    static func append(_ insertion: String, to draft: String) -> String {
        guard !insertion.isEmpty else { return draft }
        let separator: String
        if draft.isEmpty || draft.hasSuffix("\n\n") {
            separator = ""
        } else if draft.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        return draft + separator + insertion
    }
}
