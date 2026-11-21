#if DEBUG
import SwiftUI
import UIKit
import Textual

/// Isolated simulator fixture. Not reachable in a production (Release) build.
/// Compare system SwiftUI Text, plain UIKit, attributed UIKit and Textual.
struct HermesNativeFontProbeView: View {
    private let mode: String
    @State private var large = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        mode = ["swiftui", "uikit", "attributed", "textual"]
            .first(where: { arguments.contains("-hermes-probe-\($0)") }) ?? "swiftui"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(large ? "PROBE NORMAL" : "PROBE ENLARGE") {
                large.toggle()
            }
            .accessibilityIdentifier("probe-toggle")

            Text(large ? "PROBE LARGE" : "PROBE NORMAL")
                .accessibilityIdentifier("probe-scale-state")

            ScrollView {
                Group {
                    switch mode {
                    case "uikit":
                        HermesUIKitFontProbe(attributed: false)
                    case "attributed":
                        HermesUIKitFontProbe(attributed: true)
                    case "textual":
                        StructuredText(attributedString: probeContent)
                            .environment(\.textualUsesNativeTextViews, true)
                            .font(.body)
                    default:
                        Text("PROBE SWIFTUI BODY: changing text size must grow the glyphs and layout.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("probe-font")
                    }
                }
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .padding()
    }

    private var probeContent: AttributedString {
        (try? AttributedString(markdown:
            "# PROBE TEXTUAL HEADING\n\nPROBE TEXTUAL BODY: native selectable Markdown must increase text size, preserve bold **emphasis** and keep a readable layout."
        )) ?? AttributedString("PROBE TEXTUAL BODY")
    }
}

private struct HermesUIKitFontProbe: UIViewRepresentable {
    let attributed: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> HermesProbeTextView {
        HermesProbeTextView()
    }

    func updateUIView(_ view: HermesProbeTextView, context: Context) {
        view.attributedMode = attributed
        // Explicit changes test render invalidation. The UIKit trait observer
        // separately tests system-initiated changes in accessibility audits.
        let category: UIContentSizeCategory = dynamicTypeSize.isAccessibilitySize
            ? .accessibilityExtraExtraExtraLarge : .large
        view.render(category: category)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HermesProbeTextView,
                      context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 320)
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

private final class HermesProbeTextView: UITextView {
    var attributedMode = false
    private let content = "PROBE UIKIT BODY: styled text must increase size when Dynamic Type changes."
    private var desired: UIContentSizeCategory = .large

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        accessibilityIdentifier = "probe-font"
        _ = registerForTraitChanges([UITraitPreferredContentSizeCategory.self],
                                    action: #selector(traitChanged))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(category: UIContentSizeCategory) {
        desired = category
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        if attributedMode {
            attributedText = NSAttributedString(string: content,
                                                attributes: [.font: body])
        } else {
            font = body
            text = content
        }
        accessibilityLabel = content
        accessibilityValue = String(format: "fontPt=%.2f", body.pointSize)
        invalidateIntrinsicContentSize()
    }

    @objc private func traitChanged() {
        // Audit changes must reach attributed runs, not just UITextView.font.
        let category = traitCollection.preferredContentSizeCategory
        if category != .unspecified && category != desired { render(category: category) }
    }
}
#endif
