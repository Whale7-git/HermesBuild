import Foundation
#if canImport(Darwin)
import Textual
#endif

/// A reader-only outline of *rendered* Markdown headings. Search ordinals are
/// derived from the same visible attributed text used by NativeMarkdownView,
/// never from raw Markdown byte offsets or estimated scroll percentages.
enum ChatReaderOutline {
    struct Section: Identifiable, Equatable, Sendable {
        let id: Int
        let level: Int
        let title: String
        let ordinal: Int
    }

    static func sections(in markdown: String, limit: Int = 48) -> [Section] {
        guard !markdown.isEmpty, markdown.utf8.count <= 512 * 1024, limit > 0 else { return [] }
        #if canImport(Darwin)
        guard let attributed = try? AttributedString(
            markdown: markdown, including: \.textual, options: .init(), baseURL: nil
        ) else { return [] }
        let plain = String(attributed.characters)
        var sections: [Section] = []
        var activeLevel: Int?
        var activeText = ""
        var activeOffset = 0

        func finish() {
            guard let level = activeLevel, sections.count < limit else {
                activeLevel = nil
                activeText = ""
                return
            }
            let title = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                activeLevel = nil
                activeText = ""
            }
            guard !title.isEmpty, title.utf16.count <= 256 else { return }
            // Count the *real* occurrence preceding this heading, including
            // same-title mentions and repeated headings. A text mismatch makes
            // the item non-navigable rather than jumping to a guessed location.
            let ranges = ChatFindHighlight.utf16Ranges(of: title, in: plain, limit: 301)
            guard let ordinal = ranges.firstIndex(where: { $0.location == activeOffset }),
                  ordinal < 300 else { return }
            sections.append(Section(id: sections.count, level: level,
                                    title: title, ordinal: ordinal))
        }

        for run in attributed.runs {
            if Task.isCancelled { return [] }
            let level = run.presentationIntent?.components.compactMap { component -> Int? in
                if case .header(let value) = component.kind { return value }
                return nil
            }.last
            let part = String(attributed.characters[run.range])
            guard let level, (1...6).contains(level) else {
                finish()
                continue
            }
            if activeLevel != nil && (activeLevel != level || activeText.hasSuffix("\n")) {
                finish()
            }
            if activeLevel == nil {
                activeLevel = level
                let leading = String(part.prefix(while: { $0.isWhitespace }))
                let prefix = String(attributed.characters[..<run.range.lowerBound])
                activeOffset = prefix.utf16.count + leading.utf16.count
            }
            activeText += part
            if part.contains("\n") { finish() }
        }
        finish()
        return sections
        #else
        // Linux standalone tests cannot parse Apple's Markdown presentation
        // intents. Never manufacture approximate chapter coordinates.
        return []
        #endif
    }
}
