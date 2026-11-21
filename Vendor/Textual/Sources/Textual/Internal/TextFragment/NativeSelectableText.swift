#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
  import SwiftUI
  import UIKit

  extension EnvironmentValues {
    /// Opt-in native selection in the actual text fragments. Unlike the
    /// Text.Layout selection overlay, UITextView owns both glyphs and ranges.
    @Entry public var textualUsesNativeTextViews = false

    /// Gap between paragraphs that share one native text view after Hermes
    /// coalesces adjacent prose blocks. Applied only at a paragraph boundary,
    /// so the final paragraph keeps Textual's own block spacing.
    @Entry public var textualNativeParagraphSpacing: CGFloat = 0

    /// Opt-in: merge adjacent plain paragraphs into one native text view so a
    /// selection drag can cross a paragraph boundary.
    @Entry public var textualBlockCoalescing = false

    /// Per-message selection observer, used to defer the structural switch
    /// that coalescing causes until the current selection ends.
    @Entry public var textualSelectionActivity: TextualSelectionActivity? = nil
  }

  struct NativeSelectableText: UIViewRepresentable {
    let content: AttributedString
    let environment: TextEnvironmentValues
    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.textualNativeParagraphSpacing) private var paragraphSpacing
    @Environment(\.textualSelectionActivity) private var selectionActivity

    func makeUIView(context: Context) -> NativeSelectionTextView {
      NativeSelectionTextView()
    }

    func updateUIView(_ view: NativeSelectionTextView, context: Context) {
      view.openURL = openURL
      view.selectionActivity = selectionActivity
      var liveEnvironment = environment
      liveEnvironment.dynamicTypeSize = dynamicTypeSize
      view.receive(.init(content: content, environment: liveEnvironment, lineSpacing: lineSpacing,
                         alignment: alignment, paragraphSpacing: paragraphSpacing))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeSelectionTextView,
                     context: Context) -> CGSize? {
      uiView.measuredSize(width: proposal.width)
    }

    static func dismantleUIView(_ view: NativeSelectionTextView, coordinator: ()) { view.retire() }
  }

  final class NativeSelectionTextView: UITextView, UITextViewDelegate {
    struct Input: Equatable {
      let content: AttributedString
      let environment: TextEnvironmentValues
      let lineSpacing: CGFloat
      let alignment: TextAlignment
      let paragraphSpacing: CGFloat
    }

    var openURL: OpenURLAction?
    weak var selectionActivity: TextualSelectionActivity?
    private var publication = TextualSelectionPublication<Input>()
    // Keep the currently rendered source, not a deferred selection update,
    // so a UIKit trait change can regenerate every attributed font.
    private var lastRenderedInput: Input?
    // SwiftUI and UIKit may publish the same Dynamic Type change in either
    // order. Track a genuinely new SwiftUI category until UIKit catches up;
    // unrelated redraws must not reinstate stale font sizes.
    private var lastEnvironmentCategory: UIContentSizeCategory?
    private var pendingEnvironmentCategory: UIContentSizeCategory?
    private var deferredTraitCategory: UIContentSizeCategory?
    private var renderedCategory: UIContentSizeCategory = .unspecified
    private var measurement: (width: CGFloat, category: UIContentSizeCategory, size: CGSize)?
    private var naturalWidth: CGFloat?
    private var flushScheduled = false
    private var retired = false

    init() {
      // UIKit owns both constrained fitting and the readonly selection surface.
      super.init(frame: .zero, textContainer: nil)
      isEditable = false
      isSelectable = true
      // Recycled/offscreen transcript views must not remain reachable in
      // VoiceOver or screen-wide audits before joining an actual UIWindow.
      isAccessibilityElement = false
      accessibilityElementsHidden = true
      // The attributed runs resolve environment-scaled fonts, and UIKit
      // must advertise Dynamic Type support for this readonly text surface.
      font = .preferredFont(forTextStyle: .body)
      adjustsFontForContentSizeCategory = true
      isScrollEnabled = false
      backgroundColor = .clear
      textContainerInset = .zero
      textContainer.lineFragmentPadding = 0
      textContainer.widthTracksTextView = true
      showsHorizontalScrollIndicator = false
      showsVerticalScrollIndicator = false
      setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      delegate = self
      // iOS 17+ trait observation also runs when UIKit changes its category
      // without a SwiftUI UIViewRepresentable update.
      _ = registerForTraitChanges([UITraitPreferredContentSizeCategory.self],
                                  action: #selector(contentSizeCategoryChanged))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The audit can observe SwiftUI's recyclable text views between
    // attachment and their first valid layout. A window alone is not proof
    // that an element has real screen coordinates: XCTest reported
    // (inf, inf, 0, 0) nodes after Dynamic Type changed its dimensions.
    // Keep valid, rendered text fully accessible and exclude only views
    // without a finite, nonempty screen frame.
    private func synchronizeAccessibilityGeometry() {
      let valid: Bool
      if !retired, let window {
        let rect = convert(bounds, to: window)
        valid = bounds.width.isFinite && bounds.height.isFinite
          && bounds.width > 0 && bounds.height > 0
          && rect.minX.isFinite && rect.minY.isFinite
          && rect.width.isFinite && rect.height.isFinite
          && rect.width > 0 && rect.height > 0
      } else {
        valid = false
      }
      if isAccessibilityElement != valid { isAccessibilityElement = valid }
      if accessibilityElementsHidden == valid { accessibilityElementsHidden = !valid }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      synchronizeAccessibilityGeometry()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      synchronizeAccessibilityGeometry()
    }

    @objc private func contentSizeCategoryChanged() {
      guard !retired else { return }
      let category = traitCollection.preferredContentSizeCategory
      pendingEnvironmentCategory = nil
      font = .preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
      if interacting {
        // Do not destroy a user's active selection to resize Markdown.
        deferredTraitCategory = category
        measurement = nil
        naturalWidth = nil
        invalidateIntrinsicContentSize()
      } else if let lastRenderedInput {
        apply(lastRenderedInput, preferredContentSizeCategory: category)
      } else {
        renderedCategory = category
        measurement = nil
        naturalWidth = nil
        invalidateIntrinsicContentSize()
      }
    }

    private var interacting: Bool {
      return (isFirstResponder && selectedRange.length > 0) || gestureRecognizers?.contains {
        $0.state == .began || $0.state == .changed
      } == true
    }

    func receive(_ input: Input) {
      guard !retired else { return }
      let incomingCategory = UIContentSizeCategory(input.environment.dynamicTypeSize)
      let liveCategory = traitCollection.preferredContentSizeCategory
      if let previous = lastEnvironmentCategory, previous != incomingCategory {
        pendingEnvironmentCategory = incomingCategory
      }
      lastEnvironmentCategory = incomingCategory
      if incomingCategory == liveCategory { pendingEnvironmentCategory = nil }
      if let value = publication.receive(input, interacting: interacting) { apply(value) }
    }

    private func apply(_ input: Input,
                       preferredContentSizeCategory: UIContentSizeCategory? = nil) {
      // Respect whichever source genuinely changed most recently, rather
      // than unconditionally choosing a potentially stale UIKit trait.
      let liveCategory = traitCollection.preferredContentSizeCategory
      let category = preferredContentSizeCategory ?? pendingEnvironmentCategory
          ?? (liveCategory == .unspecified ? UIContentSizeCategory(input.environment.dynamicTypeSize)
                                          : liveCategory)
      let previousCategory = renderedCategory
      renderedCategory = category
      lastRenderedInput = input
      attributedText = Self.styled(input,
          preferredContentSizeCategory: category)
      #if DEBUG
      // Diagnostic facts only: no message text, URL, credential or model data.
      // The simulator audit exercises category changes; log actual glyph
      // sizes to distinguish stale font rendering from accessibility metadata.
      if previousCategory != category {
        var firstPoint: CGFloat = 0
        if attributedText.length > 0 {
          firstPoint = (attributedText.attribute(.font, at: 0, effectiveRange: nil)
                        as? UIFont)?.pointSize ?? 0
        }
        print("HERMES_FONT_EVENT trait=\(liveCategory.rawValue)"
              + " environment=\(input.environment.dynamicTypeSize)"
              + " rendered=\(category.rawValue) firstPoint=\(firstPoint)"
              + " utf16Length=\(attributedText.length)")
      }
      #endif
      // A selectable UITextView exposes its content through the native
      // value, but XCTest and VoiceOver can see a blank label after a
      // SwiftUI text view is recycled. Expose the actual rendered text
      // (never a synthetic "reply received" flag) for both accessibility
      // and the golden visible-reply assertion.
      let rendered = attributedText.string
      if accessibilityLabel != rendered { accessibilityLabel = rendered }
      selectedRange = NSRange(location: 0, length: 0)
      measurement = nil
      naturalWidth = nil
      invalidateIntrinsicContentSize()
    }

    func measuredSize(width proposed: CGFloat?) -> CGSize {
      let width: CGFloat
      if let proposed, proposed.isFinite, proposed > 0 { width = proposed }
      else {
        // Horizontal code/table containers propose no width. Measure natural
        // text width once, retaining their original horizontal scrolling.
        if naturalWidth == nil { naturalWidth = min(32_768, max(1, ceil(attributedText?.size().width ?? 0))) }
        width = naturalWidth ?? 1
      }
      if let measurement, measurement.width == width,
         measurement.category == renderedCategory { return measurement.size }
      let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      let scale = max(1, traitCollection.displayScale)
      let result = CGSize(width: width, height: max(0, ceil(fitted.height * scale) / scale))
      measurement = (width, renderedCategory, result)
      return result
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      reportSelection()
      scheduleFlush()
    }

    /// 只上报汇总状态；TextualSelectionActivity 自己做了变更去重。
    private func reportSelection() {
      guard let selectionActivity else { return }
      selectionActivity.update(self, selecting: selectedRange.length > 0)
    }

    override func resignFirstResponder() -> Bool {
      let result = super.resignFirstResponder()
      if result {
        // UITextView can retain its range after focus leaves. The transcript
        // pins hosts with active ranges, so retire that range along with focus.
        selectedRange = NSRange(location: 0, length: 0)
        selectionActivity?.update(self, selecting: false)
        scheduleFlush()
      }
      return result
    }

    private func scheduleFlush() {
      guard !retired, !flushScheduled else { return }
      flushScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.retired else { return }
        self.flushScheduled = false
        if let value = self.publication.resume(interacting: self.interacting) {
          self.deferredTraitCategory = nil
          self.apply(value)
        } else if !self.interacting, let category = self.deferredTraitCategory,
                  let input = self.lastRenderedInput {
          self.deferredTraitCategory = nil
          self.apply(input, preferredContentSizeCategory: category)
        }
      }
    }

    func retire() {
      retired = true
      selectionActivity?.update(self, selecting: false)
      selectionActivity = nil
      publication.cancel()
      deferredTraitCategory = nil
      delegate = nil
      openURL = nil
      _ = resignFirstResponder()
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
      guard case .link(let url) = textItem.content else { return defaultAction }
      return UIAction { [weak self] _ in self?.openURL?(url) }
    }

    private static func styled(_ input: Input,
                               preferredContentSizeCategory: UIContentSizeCategory? = nil) -> NSAttributedString {
      // UIKit's semantic preferred fonts retain their text-style descriptor.
      // A manually scaled systemFont in attributedText changes pointSize but
      // loses the semantic style that UIKit's Dynamic Type audit inspects.
      let standardTraits = UITraitCollection(preferredContentSizeCategory: .large)
      let currentTraits = UITraitCollection(
        preferredContentSizeCategory: preferredContentSizeCategory
            ?? .init(input.environment.dynamicTypeSize))
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = max(0, input.lineSpacing)
      switch input.alignment {
      case .leading: paragraph.alignment = .natural
      case .center: paragraph.alignment = .center
      case .trailing: paragraph.alignment = .right
      }
      struct FontKey: Hashable { let style: String; let bold: Bool; let mono: Bool; let italic: Bool }
      var fonts: [FontKey: UIFont] = [:]
      let output = NSMutableAttributedString(string: "")
      let runs = Array(input.content.runs)
      let extraSpacing = max(0, input.paragraphSpacing)
      for (index, run) in runs.enumerated() {
        let intents = run.presentationIntent?.components ?? []
        let inline = run.inlinePresentationIntent ?? []
        var style: UIFont.TextStyle = .body
        var bold = inline.contains(.stronglyEmphasized) || input.environment.legibilityWeight == .bold
        var mono = inline.contains(.code)
        var color = UIColor.label
        for intent in intents {
          switch intent.kind {
          case .header(let level):
            style = [UIFont.TextStyle.largeTitle, .title1, .title2, .title3,
                     .headline, .subheadline][min(5, max(0, level - 1))]
            bold = true
          case .codeBlock: mono = true
          case .tableHeaderRow: bold = true
          case .blockQuote: color = .secondaryLabel
          default: break
          }
        }
        let key = FontKey(style: style.rawValue, bold: bold, mono: mono,
                          italic: inline.contains(.emphasized))
        let font: UIFont
        if let cached = fonts[key] { font = cached }
        else {
          var resolved: UIFont
          if mono {
            // Monospaced code still uses the matching semantic style metrics;
            // derive its base size at .large to avoid double-scaling.
            let baseline = UIFont.preferredFont(forTextStyle: style,
                                                 compatibleWith: standardTraits).pointSize
            let code = UIFont.monospacedSystemFont(ofSize: baseline * 0.85,
                                                   weight: bold ? .semibold : .regular)
            resolved = UIFontMetrics(forTextStyle: style)
              .scaledFont(for: code, compatibleWith: currentTraits)
          } else {
            resolved = UIFont.preferredFont(forTextStyle: style,
                                            compatibleWith: currentTraits)
            var traits = resolved.fontDescriptor.symbolicTraits
            if bold { traits.insert(.traitBold) }
            if key.italic { traits.insert(.traitItalic) }
            if let descriptor = resolved.fontDescriptor.withSymbolicTraits(traits) {
              resolved = UIFont(descriptor: descriptor, size: 0)
            }
          }
          font = resolved
          fonts[key] = resolved
        }
        // A merged fragment can hold several paragraphs. The paragraph style
        // that owns the trailing newline also owns the gap after it, so only a
        // run followed by a different presentation intent gets extra spacing.
        let runParagraph: NSParagraphStyle
        if extraSpacing > 0, index + 1 < runs.count,
           runs[index + 1].presentationIntent != run.presentationIntent {
          let spaced = NSMutableParagraphStyle()
          spaced.setParagraphStyle(paragraph)
          spaced.paragraphSpacing = extraSpacing
          runParagraph = spaced
        } else {
          runParagraph = paragraph
        }
        var attributes: [NSAttributedString.Key: Any] = [
          .font: font, .foregroundColor: color, .paragraphStyle: runParagraph,
        ]
        if let color = run.foregroundColor { attributes[.foregroundColor] = UIColor(color) }
        if let color = run.backgroundColor { attributes[.backgroundColor] = UIColor(color) }
        if let ordinal = run[TextualFindOccurrenceAttribute.self] {
          attributes[NSAttributedString.Key(TextualFindOccurrenceAttribute.name)] = ordinal
        }
        if let link = run.link { attributes[.link] = link }
        if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        output.append(NSAttributedString(string: String(input.content[run.range].characters), attributes: attributes))
      }
      return output
    }
  }
#endif
