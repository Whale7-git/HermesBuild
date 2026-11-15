import Foundation

/// Formats the visible text inserted by "Quote". This is a composer-only
/// projection: it never changes the message stored in history or the wire
/// protocol, and the user can edit every inserted line before sending.
enum ChatQuote {
    /// UI-only preview plus the original editable Markdown wire content.
    /// Keeping the wire in the Session's draft store preserves crash recovery
    /// and the backend protocol without showing syntax in the UITextView.
    struct Reference: Equatable {
        let author: String
        let preview: String
        let wire: String
    }

    static func reference(for message: ChatMessage) -> Reference? {
        guard let wire = insertion(for: message) else { return nil }
        return splitDraft(wire).reference
    }

    static func assemble(_ reference: Reference?, reply: String) -> String {
        (reference?.wire ?? "") + reply
    }

    static func splitDraft(_ raw: String) -> (reference: Reference?, reply: String) {
        guard raw.hasPrefix("> **引用 "),
              let separator = raw.range(of: "\n\n") else {
            return (nil, raw)
        }
        var wire = String(raw[..<separator.upperBound])
        var reply = String(raw[separator.upperBound...])
        if reply.hasPrefix("（引用已截断）\n\n") {
            let suffix = "（引用已截断）\n\n"
            wire += suffix
            reply.removeFirst(suffix.count)
        }
        let lines = String(wire[..<separator.lowerBound]).components(separatedBy: "\n")
        guard let header = lines.first, header.hasSuffix("**"),
              lines.count > 1,
              lines.dropFirst().allSatisfy({ $0.hasPrefix(">") }) else {
            return (nil, raw)
        }
        let author = String(header.dropFirst("> **引用 ".count).dropLast(2))
        guard author == "你" || author == "Hermes" else { return (nil, raw) }
        let preview = lines.dropFirst().map {
            $0.hasPrefix("> ") ? String($0.dropFirst(2)) : String($0.dropFirst())
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (Reference(author: author, preview: preview, wire: wire), reply)
    }

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
