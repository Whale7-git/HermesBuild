import SwiftUI
import UIKit

/// Read-only native text surface: select/copy large tool output without opening a keyboard.
struct ReadOnlyResultView: UIViewRepresentable {
    let text: String
    var selection: NSRange? = nil
    var selectionToken: UUID? = nil
    final class Coordinator {
        var selectionToken: UUID?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.accessibilityLabel = "工具内容"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
        if context.coordinator.selectionToken != selectionToken {
            context.coordinator.selectionToken = selectionToken
            if let selection, NSMaxRange(selection) <= (text as NSString).length {
                view.selectedRange = selection
                view.scrollRangeToVisible(selection)
            } else {
                view.selectedRange = NSRange(location: 0, length: 0)
            }
        }
    }
}

/// The reader owns an immutable snapshot; new SSE frames do not invalidate a
/// selection, change copied content or jump to another page while reading.
struct ToolPayloadPresentation: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let omittedBytes: Int?
}

struct ToolPayloadReader: View {
    let snapshot: ToolPayloadPresentation
    let copied: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: ToolPayloadIndex?
    @State private var page = 0
    @State private var query = ""
    @State private var nextOffset = 0
    @State private var selection: NSRange?
    @State private var selectionToken: UUID?
    @State private var searchMessage: String?
    @State private var searching = false
    @State private var searchTicket = UUID()
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let omitted = snapshot.omittedBytes {
                    Text("仅搜索已缓存内容，原始约 \(omitted) 字节；完整内容尚未取得。")
                        .font(.caption).foregroundStyle(AppTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                if let index {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索全部已载入内容", text: $query)
                            .submitLabel(.search)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { search() }
                        Button(searching ? "搜索中" : "查找下一个") { search() }
                            .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .frame(minHeight: 44)
                    }
                    .font(.subheadline).padding(.horizontal, 16)
                    if let searchMessage {
                        Text(searchMessage).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 6)
                    }
                    Divider()
                    ReadOnlyResultView(text: index.pageText(page), selection: selection,
                                       selectionToken: selectionToken)
                    Divider()
                    HStack {
                        Button("上一页") { move(to: page - 1) }
                            .disabled(page == 0)
                        Spacer()
                        Text("\(page + 1) / \(index.pages.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("下一页") { move(to: page + 1) }
                            .disabled(page >= index.pages.count - 1)
                    }
                    .frame(minHeight: 44).padding(.horizontal, 20)
                } else {
                    Spacer()
                    ProgressView("正在准备内容…")
                    Spacer()
                }
            }
            .navigationTitle(snapshot.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(snapshot.omittedBytes == nil ? "复制" : "复制已缓存内容") { copied(snapshot.text) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                let text = snapshot.text
                let worker = Task.detached(priority: .userInitiated) {
                    ToolPayloadIndex.build(text: text, isCancelled: { Task.isCancelled })
                }
                let result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                if !Task.isCancelled, let result { index = result }
            }
            .onChange(of: query) { _, _ in
                cancelSearch()
                nextOffset = 0
                searchMessage = nil
                selection = nil
                selectionToken = UUID()
            }
            .onDisappear { cancelSearch() }
        }
    }

    private func move(to target: Int) {
        guard let index else { return }
        cancelSearch()
        page = min(max(0, target), index.pages.count - 1)
        selection = nil
        selectionToken = UUID()
        searchMessage = nil
    }

    private func cancelSearch() {
        searchTicket = UUID()
        searchTask?.cancel()
        searchTask = nil
        searching = false
    }

    private func search() {
        guard let index else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard term.utf16.count <= 512 else {
            searchMessage = "搜索词过长（最多 512 个 UTF-16 单元）。"
            return
        }
        cancelSearch()
        let ticket = searchTicket
        let offset = nextOffset
        searching = true
        searchTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                index.find(term, after: offset, isCancelled: { Task.isCancelled })
            }
            let match = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, searchTicket == ticket else { return }
            searching = false
            searchTask = nil
            guard let match else {
                selection = nil
                selectionToken = UUID()
                searchMessage = "已载入内容中没有匹配结果"
                return
            }
            page = match.page
            nextOffset = match.nextOffset
            selection = NSRange(location: match.location, length: match.length)
            selectionToken = UUID()
            searchMessage = match.spansPages ? "匹配跨页；下一页包含其余文字"
                : "匹配位于第 \(match.page + 1) 页"
        }
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
