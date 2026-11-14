import SwiftUI
import UIKit
import Textual

/// User text remains literal. A native surface is needed only while finding,
/// so ordinary bubble selection and its existing layout stay on their old path.
struct ChatFindPlainText: UIViewRepresentable {
    let text: String
    let query: String
    let activeOrdinal: Int?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection),
            .foregroundColor: UIColor.label, .paragraphStyle: paragraph
        ])
        for (ordinal, range) in ChatFindHighlight.utf16Ranges(of: query, in: text, limit: 300).enumerated() {
            value.addAttributes([
                .backgroundColor: UIColor(AppTheme.accent.opacity(ordinal == activeOrdinal ? 0.45 : 0.20)),
                NSAttributedString.Key(TextualFindOccurrenceAttribute.name): ordinal
            ], range: range)
        }
        if view.attributedText != value { view.attributedText = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

enum ChatFindGeometry {
    /// Called only for an explicit Find command and only in its target host.
    /// No private UIKit APIs, reflection, selectedRange writes or pan-tick scans.
    static func occurrence(_ ordinal: Int, in root: UIView) -> (UITextView, CGRect)? {
        if let text = root as? UITextView, let content = text.attributedText, content.length > 0 {
            var found: NSRange?
            content.enumerateAttribute(NSAttributedString.Key(TextualFindOccurrenceAttribute.name),
                in: NSRange(location: 0, length: content.length)) { value, range, stop in
                if (value as? Int) == ordinal { found = range; stop.pointee = true }
            }
            if let found,
               let start = text.position(from: text.beginningOfDocument, offset: found.location),
               let end = text.position(from: start, offset: found.length),
               let range = text.textRange(from: start, to: end) {
                let rect = text.firstRect(for: range)
                if !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 { return (text, rect) }
            }
        }
        for child in root.subviews {
            if let result = occurrence(ordinal, in: child) { return result }
        }
        return nil
    }

    /// Reveal code/table content horizontally without disturbing the outer
    /// transcript's vertical offset, which its scroll controller owns.
    static func revealHorizontally(_ rect: CGRect, in text: UITextView, stoppingAt root: UIView) {
        var ancestor = text.superview
        while let view = ancestor, view !== root {
            if let scroll = view as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                let local = text.convert(rect, to: scroll)
                let x = min(max(0, local.midX - scroll.bounds.width / 2),
                            max(0, scroll.contentSize.width - scroll.bounds.width))
                scroll.setContentOffset(CGPoint(x: x, y: scroll.contentOffset.y), animated: false)
            }
            ancestor = view.superview
        }
    }
}
