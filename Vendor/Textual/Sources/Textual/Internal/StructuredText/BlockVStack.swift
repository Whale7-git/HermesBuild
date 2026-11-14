import SwiftUI

// MARK: - Overview
//
// BlockVStack arranges blocks vertically with CSS-style margin collapsing behavior. Adjacent
// blocks' top and bottom spacing collapses by taking the maximum value rather than summing,
// matching how CSS margins work.
//
// List items can override block spacing with environment-driven list item spacing for consistent
// spacing within lists regardless of individual block preferences.

extension StructuredText {
  struct BlockVStack<Content: View>: View {
    @Environment(\.multilineTextAlignment) private var textAlignment
    @Environment(\.textEnvironment) private var textEnvironment
    @Environment(\.inlineStyle) private var inlineStyle
    @Environment(\.highlighterTheme) private var highlighterTheme
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale
    @Environment(\.overflowMode) private var overflowMode
    @Environment(\.deferredHighlightingAfter) private var deferredHighlightingAfter
    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.paragraphStyle) private var paragraphStyle
    @Environment(\.codeBlockStyle) private var codeBlockStyle
    @Environment(\.listItemStyle) private var listItemStyle

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    var body: some View {
      Group(subviews: content) { children in
        BlockVStackLayout(context: .init(
          textEnvironment: textEnvironment, inlineStyle: inlineStyle,
          highlighterTheme: highlighterTheme, locale: locale,
          layoutDirection: layoutDirection, displayScale: displayScale,
          textAlignment: textAlignment, overflowMode: overflowMode,
          deferredHighlightingAfter: deferredHighlightingAfter,
          lineSpacing: lineSpacing,
          paragraphStyle: BlockStyleSignature(paragraphStyle),
          codeBlockStyle: BlockStyleSignature(codeBlockStyle),
          listItemStyle: BlockStyleSignature(listItemStyle)
        )) {
          ForEach(children) {
            BlockLayoutView($0)
          }
        }
      }
    }
  }
}

extension StructuredText {
  struct BlockAlignmentKey: LayoutValueKey {
    static let defaultValue: TextAlignment? = nil
  }

  fileprivate struct BlockLayoutView<Content: View>: View {
    @Environment(\.listItemSpacingEnabled) private var listItemSpacingEnabled
    @Environment(\.resolvedListItemSpacing) private var resolvedListItemSpacing

    @State private var blockSpacing = BlockSpacing()

    private let content: Content

    init(_ content: Content) {
      self.content = content
    }

    var body: some View {
      // Read the block spacing preference and apply it as a layout value
      content
        .onPreferenceChange(BlockSpacingKey.self) { @MainActor value in
          // Override with the resolved list item spacing if enabled
          blockSpacing = listItemSpacingEnabled ? resolvedListItemSpacing : value
        }
        .layoutValue(key: BlockSpacingKey.self, value: blockSpacing)
    }
  }

  fileprivate struct BlockVStackLayout: Layout {
    struct Cache {
      var spacings: [CGFloat]
      var measurements = TextualBlockMeasurementCache<BlockMeasurementContext, CGSize>()
    }

    let context: BlockMeasurementContext

    func makeCache(subviews: Subviews) -> Cache {
      Cache(spacings: spacings(subviews: subviews))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
      // Includes same-count content changes, style DynamicProperty updates,
      // asynchronous token/attachment completion and spacing preferences. Never
      // carry an index's old size into a different SwiftUI subview generation.
      cache.spacings = spacings(subviews: subviews)
      cache.measurements.invalidate()
    }

    private func spacings(subviews: Subviews) -> [CGFloat] {
      subviews.indices.dropLast().map { index in
        let current = subviews[index]
        let next = subviews[index + 1]
        let currentBottom = current[BlockSpacingKey.self].bottom
        let nextTop = next[BlockSpacingKey.self].top

        // Take the maximum block spacing, otherwise the preferred view spacing
        return [currentBottom, nextTop].compactMap(\.self).max()
          ?? current.spacing.distance(to: next.spacing, along: .vertical)
      }
    }

    private func sizes(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> [CGSize] {
      cache.measurements.sizes(width: proposal.width.map(Double.init), count: subviews.count, context: context) { index in
        subviews[index].sizeThatFits(.init(width: proposal.width, height: nil))
      }
    }

    func sizeThatFits(
      proposal: ProposedViewSize,
      subviews: Subviews, cache: inout Cache
    ) -> CGSize {
      if let width = proposal.width, width <= 0 {
        return .zero
      }

      var size = CGSize.zero

      for viewSize in sizes(proposal: proposal, subviews: subviews, cache: &cache) {
        size.height += viewSize.height
        size.width = max(size.width, viewSize.width)
      }

      size.height += cache.spacings.reduce(0, +)

      return size
    }

    func placeSubviews(
      in bounds: CGRect,
      proposal: ProposedViewSize,
      subviews: Subviews, cache: inout Cache
    ) {
      var currentY: CGFloat = 0
      let measured = sizes(proposal: proposal, subviews: subviews, cache: &cache)

      for (index, view) in zip(subviews.indices, subviews) {
        let viewProposal = ProposedViewSize(width: proposal.width, height: nil)
        let viewSize = measured[index]

        var point = bounds.origin
        let alignment = view[BlockAlignmentKey.self] ?? context.textAlignment

        switch alignment {
        case .leading:
          break  // do nothing
        case .center:
          point.x += (bounds.width - viewSize.width) / 2
        case .trailing:
          point.x += bounds.width - viewSize.width
        }

        point.y += currentY

        view.place(at: point, proposal: viewProposal)

        currentY += viewSize.height

        if index < subviews.count - 1 {
          currentY += cache.spacings[index]
        }
      }
    }
  }

  fileprivate struct BlockMeasurementContext: Equatable, Sendable {
    let textEnvironment: TextEnvironmentValues
    let inlineStyle: InlineStyle
    let highlighterTheme: HighlighterTheme
    let locale: Locale
    let layoutDirection: LayoutDirection
    let displayScale: CGFloat
    let textAlignment: TextAlignment
    let overflowMode: OverflowMode
    let deferredHighlightingAfter: Int?
    let lineSpacing: CGFloat
    let paragraphStyle: BlockStyleSignature
    let codeBlockStyle: BlockStyleSignature
    let listItemStyle: BlockStyleSignature
  }

  /// A Sendable, value-based snapshot of a style environment value.
  ///
  /// Style environment values are existentials without `Equatable` or
  /// `Sendable` conformance, so the measurement context cannot store them
  /// directly. It records the concrete type plus a bounded fingerprint of the
  /// stored values instead. Reference-typed or otherwise opaque stored values
  /// are represented by their description (and instance identity for classes),
  /// which may over-report a difference; that only costs a remeasurement and
  /// can never validate a stale size. Custom styles that hide state behind an
  /// opaque description are therefore not safe inputs for measurement reuse.
  fileprivate struct BlockStyleSignature: Equatable, Sendable {
    private let type: String
    private let storedValues: [String]

    init(_ style: Any) {
      type = String(reflecting: Swift.type(of: style))
      storedValues = Self.fingerprint(style, depth: 0)
    }

    private static func fingerprint(_ value: Any, depth: Int) -> [String] {
      let mirror = Mirror(reflecting: value)
      var parts: [String] = [String(reflecting: mirror.subjectType)]
      if mirror.displayStyle == .class {
        // Distinct instances must not compare equal only because their
        // descriptions happen to match.
        parts.append(String(describing: ObjectIdentifier(value as AnyObject)))
      }
      guard depth < 4, !mirror.children.isEmpty, mirror.children.count <= 32 else {
        parts.append(String(describing: value))
        return parts
      }
      for child in mirror.children {
        parts.append(child.label ?? "_")
        parts.append(contentsOf: fingerprint(child.value, depth: depth + 1))
      }
      return parts
    }
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
#Preview {
  @Previewable @State var textAlignment = TextAlignment.leading
  @Previewable @State var blockSpacing: CGFloat = 1

  VStack {
    GroupBox {
      Picker("Text Alignment", selection: $textAlignment) {
        Text("Leading").tag(TextAlignment.leading)
        Text("Center").tag(TextAlignment.center)
        Text("Trailing").tag(TextAlignment.trailing)
      }
      .pickerStyle(.segmented)
      HStack {
        Text("2nd / 3rd Spacing")
        Slider(value: $blockSpacing, in: 0...3)
      }
    }
    Spacer()
    StructuredText.BlockVStack {
      Text(
        """
        Listen to your sister, Morty. To live is to risk it all, otherwise you’re just an inert \
        chunk of randomly assembled molecules drifting wherever the universe blows you.
        """
      )
      .textual.blockSpacing(.fontScaled(bottom: 1))
      Text(
        """
        Listen, Morty, I hate to break it to you but what people call "love" is just a chemical \
        reaction that compels animals to breed. It hits hard, Morty, then it slowly fades, \
        leaving you stranded in a failing marriage. I did it. Your parents are gonna do it. \
        Break the cycle, Morty. Rise above. Focus on science.
        """
      )
      .textual.blockSpacing(.fontScaled(bottom: blockSpacing))
      Text(
        """
        Wow, I really Cronenberged up the whole place, huh Morty? Just a bunch a Cronenbergs \
        walkin' around.
        """
      )
      .textual.blockSpacing(.fontScaled(top: 1, bottom: 1))
    }
    .border(Color.red)
    Spacer()
  }
  .multilineTextAlignment(textAlignment)
  .padding()
}
