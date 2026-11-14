import SwiftUI

extension StructuredText {
  struct CodeBlock: View {
    @Environment(\.highlighterTheme) private var highlighterTheme
    @Environment(\.codeBlockStyle) private var codeBlockStyle
    @Environment(\.deferredHighlightingAfter) private var deferredHighlightingAfter

    private let content: AttributedSubstring
    private let languageHint: String?

    init(_ content: AttributedSubstring, languageHint: String?) {
      if let last = content.characters.indices.last, content.characters[last] == "\n" {
        self.content = content[..<last]
      } else {
        self.content = content
      }
      self.languageHint = languageHint
    }

    var body: some View {
      let configuration = CodeBlockStyleConfiguration(
        label: .init(
          codeLabel
        ),
        indentationLevel: indentationLevel,
        languageHint: languageHint,
        codeBlock: .init(content),
        highlighterTheme: highlighterTheme
      )
      let resolvedStyle = codeBlockStyle.resolve(configuration: configuration)

      AnyView(resolvedStyle)
    }

    private var indentationLevel: Int {
      content.presentationIntent?.indentationLevel ?? 0
    }

    @ViewBuilder private var codeLabel: some View {
      if let limit = deferredHighlightingAfter,
         (content.presentationIntent?.components.last?.identity ?? Int.max) > limit {
        TextFragment(AttributedString(content)).foregroundStyle(highlighterTheme.foregroundColor)
      } else {
        HighlightedTextFragment(content, languageHint: languageHint, theme: highlighterTheme)
      }
    }
  }
}

extension EnvironmentValues {
  @Entry var deferredHighlightingAfter: Int? = nil
}
