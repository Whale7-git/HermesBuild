import SwiftUI
import UIKit

/// Read-only native text surface: select/copy large tool output without opening a keyboard.
struct ReadOnlyResultView: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.accessibilityLabel = "完整工具结果"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

struct CodeCopyButton: View {
    let action: () -> Void
    @State private var copied = false
    var body: some View {
        Button {
            action()
            copied = true
            UIAccessibility.post(notification: .announcement, argument: "代码已复制")
        } label: {
            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 4)
                .frame(minWidth: 60, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "代码已复制" : "复制代码")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
