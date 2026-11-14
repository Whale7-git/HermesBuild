import SwiftUI

// MARK: - Overview
//
// HighlightedTextFragment displays syntax-highlighted code using a two-phase approach.
// Tokenization runs asynchronously and is keyed by content, while highlighting runs
// synchronously on token or environment changes (theme, color scheme, dynamic type).
//
// The presentationIntent is preserved after highlighting so pasteboard formatters can
// reconstruct the block structure when copying code.

struct HighlightedTextFragment: View {
  @Environment(\.textEnvironment) private var textEnvironment
  @Environment(\.textualCodeTokenizationDuration) private var tokenizationDuration

  @State private var model = Model()

  private let content: AttributedSubstring
  private let languageHint: String?
  private let theme: StructuredText.HighlighterTheme

  init(
    _ content: AttributedSubstring,
    languageHint: String?,
    theme: StructuredText.HighlighterTheme
  ) {
    self.content = content
    self.languageHint = languageHint
    self.theme = theme
  }

  var body: some View {
    let input = Input(content: content, languageHint: languageHint)
    let appearance = Appearance(theme: theme, environment: textEnvironment)
    TextFragment(model.code(for: input, appearance: appearance) ?? AttributedString(content))
      .foregroundStyle(theme.foregroundColor)
      .task(id: input) {
        await model.tokenize(
          input: input, duration: tokenizationDuration
        )
      }
      .onChange(of: Tuple(model.tokenRevision, input, appearance), initial: true) { _, _ in
        model.highlight(input: input, appearance: appearance)
      }
      .onDisappear { model.cancel() }
  }
}

extension HighlightedTextFragment {
  struct Input: Equatable {
    let content: AttributedSubstring
    let languageHint: String?
  }

  struct Appearance: Equatable {
    let theme: StructuredText.HighlighterTheme
    let environment: TextEnvironmentValues
  }

  @MainActor @Observable final class Model {
    private(set) var tokenRevision: UInt64 = 0
    private var tokens: [CodeToken] = []
    private var tokenInput: Input?
    private var highlightedInput: Input?
    private var highlightedAppearance: Appearance?
    private var highlightedCode: AttributedString?
    private let work: TextualTokenizationWork<Input, CodeToken>

    init() {
      work = TextualTokenizationWork<Input, CodeToken>(
        sharedCache: TextualCodeTokenCache.shared
      )
    }

    func code(for input: Input, appearance: Appearance) -> AttributedString? {
      guard highlightedInput == input, highlightedAppearance == appearance else { return nil }
      return highlightedCode
    }

    func cancel() { work.cancel() }

    func tokenize(input: Input, duration: (@Sendable (Double) -> Void)?) async {
      let code = String(input.content.characters[...])
      let plain = [CodeToken(content: code, type: .plain)]
      // Exact (language, source) key for the process-wide completed-result
      // cache. The unit separator keeps the prefix unambiguous; source text
      // may contain any character after it.
      let cacheKey = input.languageHint.map { $0 + "\u{1F}" + code }
      let operation: (@Sendable () async -> [CodeToken])?
      if let language = input.languageHint {
        operation = {
          guard !Task.isCancelled, let tokenizer = CodeTokenizer.shared else { return plain }
          return await tokenizer.tokenize(code: code, language: language, duration: duration)
        }
      } else { operation = nil }
      await work.run(input: input, plain: plain, cacheKey: cacheKey, operation: operation) { [weak self] result in
        guard let self else { return }
        // Reattaching an unchanged, fully tokenized fragment can retain its
        // current appearance. Theme/environment changes independently restyle
        // these same tokens through onChange above.
        if self.tokenInput == input, self.tokens == result, self.highlightedInput == input { return }
        self.tokenInput = input
        self.tokens = result
        self.highlightedInput = nil
        self.highlightedAppearance = nil
        self.highlightedCode = nil
        self.tokenRevision &+= 1
      }
    }

    func highlight(input: Input, appearance: Appearance) {
      guard tokenInput == input else { return }
      let theme = appearance.theme
      let environment = appearance.environment
      var baseAttributes = AttributeContainer()
      // Re-apply the presentation intent for pasteboard formatters
      baseAttributes.presentationIntent = input.content.presentationIntent
      ForegroundColorProperty(theme.foregroundColor)
        .apply(in: &baseAttributes, environment: environment)

      // Resolve each token type once. The previous loop copied and restyled
      // the base container for every token, including repeated keywords and
      // punctuation.
      var containers: [StructuredText.HighlighterTheme.TokenType: AttributeContainer] = [:]
      containers.reserveCapacity(theme.tokenProperties.count)
      for (type, properties) in theme.tokenProperties {
        var container = baseAttributes
        properties.apply(in: &container, environment: environment)
        containers[type] = container
      }

      // Build one attributed string for the whole block and style token ranges
      // in place. Token contents concatenate to the code in order, so ranges
      // are exact; this keeps the previous colors and fonts while avoiding one
      // intermediate AttributedString per token.
      let code = tokens.map(\.content).joined()
      // Preserve search backgrounds and occurrence metadata while applying
      // syntax colors. Tokenization must not erase the active Find range.
      var highlightedCode = String(input.content.characters) == code
        ? AttributedString(input.content) : AttributedString(code)
      highlightedCode.mergeAttributes(baseAttributes)
      var start = highlightedCode.startIndex
      for token in tokens {
        let end = highlightedCode.index(start, offsetByCharacters: token.content.count)
        if let container = containers[token.type] {
          highlightedCode[start..<end].mergeAttributes(container, mergePolicy: .keepNew)
        }
        start = end
      }

      self.highlightedCode = highlightedCode
      self.highlightedInput = input
      self.highlightedAppearance = appearance
    }
  }
}

private struct TextualCodeTokenizationDurationKey: EnvironmentKey {
  static let defaultValue: (@Sendable (Double) -> Void)? = nil
}

/// Process-wide, bounded reuse of completed Prism output for identical
/// (language, source) pairs. Main-actor isolated and memory-only; the
/// tokenizer actor remains the sole serial owner of the JavaScript context.
@MainActor
private enum TextualCodeTokenCache {
  static let shared = TextualTokenCache<CodeToken>(
    estimatedBytes: { $0.content.utf8.count + 48 }
  )
}

extension EnvironmentValues {
  /// Optional numeric-only diagnostic. Measures synchronous tokenizer work;
  /// excludes actor queueing, theme application and layout. Nil avoids clocks.
  public var textualCodeTokenizationDuration: (@Sendable (Double) -> Void)? {
    get { self[TextualCodeTokenizationDurationKey.self] }
    set { self[TextualCodeTokenizationDurationKey.self] = newValue }
  }
}
