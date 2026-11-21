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
    @Environment(\.textualNativeParagraphSpacing) private var paragraphSpacing
    @Environment(\.textualSelectionActivity) private var selectionActivity

    func makeUIView(context: Context) -> NativeSelectionTextView {
      NativeSelectionTextView()
    }

    func updateUIView(_ view: NativeSelectionTextView, context: Context) {
      view.openURL = openURL
      view.selectionActivity = selectionActivity
      view.receive(.init(content: content, environment: environment, lineSpacing: lineSpacing,
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
    private var measurement: (width: CGFloat, size: CGSize)?
    private var naturalWidth: CGFloat?
    private var flushScheduled = false
    private var retired = false

    init() {
      // UIKit owns both constrained fitting and the readonly selection surface.
      super.init(frame: .zero, textContainer: nil)
      isEditable = false
      isSelectable = true
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
        // Keep the UIKit text control's own preferred font in sync with the
        // category while SwiftUI restyles its attributed glyph runs.
        font = .preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
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
      if let value = publication.receive(input, interacting: interacting) { apply(value) }
    }

    private func apply(_ input: Input) {
      attributedText = Self.styled(input)
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
      if let measurement, measurement.width == width { return measurement.size }
      let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      let scale = max(1, traitCollection.displayScale)
      let result = CGSize(width: width, height: max(0, ceil(fitted.height * scale) / scale))
      measurement = (width, result)
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
        if let value = self.publication.resume(interacting: self.interacting) { self.apply(value) }
      }
    }

    func retire() {
      retired = true
      selectionActivity?.update(self, selecting: false)
      selectionActivity = nil
      publication.cancel()
      delegate = nil
      openURL = nil
      _ = resignFirstResponder()
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
      guard case .link(let url) = textItem.content else { return defaultAction }
      return UIAction { [weak self] _ in self?.openURL?(url) }
    }

    private static func styled(_ input: Input) -> NSAttributedString {
      let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body,
                                                                in: input.environment)
      let baseSize = descriptor.pointSize
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = max(0, input.lineSpacing)
      switch input.alignment {
      case .leading: paragraph.alignment = .natural
      case .center: paragraph.alignment = .center
      case .trailing: paragraph.alignment = .right
      }
      struct FontKey: Hashable { let size: CGFloat; let bold: Bool; let mono: Bool; let italic: Bool }
      var fonts: [FontKey: UIFont] = [:]
      let output = NSMutableAttributedString(string: "")
      let runs = Array(input.content.runs)
      let extraSpacing = max(0, input.paragraphSpacing)
      for (index, run) in runs.enumerated() {
        let intents = run.presentationIntent?.components ?? []
        let inline = run.inlinePresentationIntent ?? []
        var size = baseSize
        var bold = inline.contains(.stronglyEmphasized) || input.environment.legibilityWeight == .bold
        var mono = inline.contains(.code)
        var color = UIColor.label
        for intent in intents {
          switch intent.kind {
          case .header(let level):
            size *= [CGFloat(2), 1.5, 1.25, 1, 0.875, 0.85][min(5, max(0, level - 1))]
            bold = true
          case .codeBlock: mono = true
          case .tableHeaderRow: bold = true
          case .blockQuote: color = .secondaryLabel
          default: break
          }
        }
        if mono { size *= 0.85 }
        let key = FontKey(size: size, bold: bold, mono: mono, italic: inline.contains(.emphasized))
        let font: UIFont
        if let cached = fonts[key] { font = cached }
        else {
          var resolved = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                              : UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
          if key.italic,
             let italic = resolved.fontDescriptor.withSymbolicTraits(resolved.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            resolved = UIFont(descriptor: italic, size: size)
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
