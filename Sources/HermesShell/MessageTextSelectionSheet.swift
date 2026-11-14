import SwiftUI
import UIKit

/// An immutable snapshot so streaming/row recycling cannot move the selection.
struct MessageSelectionText: Identifiable {
    let id = UUID()
    let text: String
}

/// Native text selection remains available independently of rich-text overlays.
/// Markdown source is preserved, including code and URLs, for exact copying.
struct MessageTextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            SelectableMessageTextView(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("选择文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(copied ? "已复制" : "复制全文") {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableMessageTextView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> MessageSelectionController {
        MessageSelectionController(text: text)
    }

    func updateUIViewController(_ controller: MessageSelectionController, context: Context) {
        // The sheet identity owns an immutable snapshot. Do not reassign text
        // or select again on streaming updates, rotation or toolbar updates.
    }
}

private final class MessageSelectionController: UIViewController {
    private let source: String
    private let textView = UITextView()
    private var didStartSelection = false

    init(text: String) {
        source = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        textView.accessibilityLabel = "回复原文，可选择文字"
        textView.text = source
        view = textView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Run after the sheet is actually on screen, rather than racing its
        // presentation with an arbitrary delay. UIKit owns word boundaries,
        // selection handles and the edit menu. Noneditable text cannot type.
        guard !didStartSelection, !source.isEmpty else { return }
        didStartSelection = true
        textView.selectedRange = NSRange(location: 0, length: 0)
        if textView.becomeFirstResponder() { textView.select(nil) }
    }
}
