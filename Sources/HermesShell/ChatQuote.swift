import Foundation

/// Formats the visible text inserted by "Quote". This is a composer-only
/// projection: it never changes the message stored in history or the wire
/// protocol, and the user can edit every inserted line before sending.
enum ChatQuote {
    static let maximumCharacters = 1_600
    static let maximumLines = 24

    static func insertion(for message: ChatMessage) -> String? {
        let source = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChatRenderableText.hasVisibleContent(source) else { return nil }

        let lines = source.components(separatedBy: .newlines)
        var selected: [String] = []
        var used = 0
        var truncated = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if !selected.isEmpty { selected.append("") }
                continue
            }
            if selected.filter({ !$0.isEmpty }).count >= maximumLines {
                truncated = true
                break
            }
            let separator = selected.isEmpty ? 0 : 1
            let available = maximumCharacters - used - separator
            guard available > 0 else { truncated = true; break }
            if line.count > available {
                selected.append(String(line.prefix(available)) + "…")
                truncated = true
                break
            }
            selected.append(line)
            used += separator + line.count
        }
        while selected.last?.isEmpty == true { selected.removeLast() }
        guard !selected.isEmpty else { return nil }
        let body = selected.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        let author = message.role == "user" ? "你" : "Hermes"
        let suffix = truncated ? "\n\n（引用已截断）\n\n" : "\n\n"
        return "> **引用 \(author)**\n\(body)\(suffix)"
    }
}
