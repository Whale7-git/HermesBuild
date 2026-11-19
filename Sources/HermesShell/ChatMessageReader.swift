import SwiftUI
import UIKit

enum ChatReaderPresentationPolicy {
    static func canPresent(isStreaming: Bool, text: String) -> Bool {
        !isStreaming && ChatRenderableText.hasVisibleContent(text)
    }
}

struct ChatReaderScrollSnapshot: Equatable {
    var offset: Double = 0
    var maximumOffset: Double = 0
    var viewportWidth: Double = 0

    var progress: Double {
        guard maximumOffset > 0 else { return 0 }
        return min(1, max(0, offset / maximumOffset))
    }
}

/// A focused reading surface for a completed answer. The transcript remains
/// mounted underneath, so closing this sheet restores the exact conversation
/// position and streaming state without creating a second message model.
struct ChatMessageReader: View {
    let message: ChatMessage
    let replyText: String
    let initialPosition: ChatReaderPosition?
    let onPositionChange: (ChatReaderScrollSnapshot) -> Void
    let onPositionPersist: (ChatReaderScrollSnapshot) -> Void
    let makeShareFile: () -> SharedTemporaryFile?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var sharingFile: SharedTemporaryFile?
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findOrdinal = 0
    @State private var matchCount = 0
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var hasMoreSearchMatches = false
    @State private var searchQueryTooLong = false
    @State private var outline: [ChatReaderOutline.Section] = []
    @State private var showOutline = false
    @State private var queuedChapter: ChatReaderOutline.Section?
    @State private var chapterJump: ChatReaderOutline.Section?
    @State private var chapterNotice: String?
    @State private var scroll = ChatReaderScrollSnapshot()
    @State private var restoreNotice = false

    private var activeFindOrdinal: Int? {
        showFind && matchCount > 0 ? min(max(0, findOrdinal), matchCount - 1) : nil
    }

    var body: some View {
        NavigationStack {
            ReaderScrollView(
                initialPosition: initialPosition,
                replyText: replyText,
                findQuery: chapterJump?.title ?? (showFind ? findQuery : ""),
                activeFindOrdinal: chapterJump?.ordinal ?? activeFindOrdinal,
                isChapterJump: chapterJump != nil,
                onChapterNavigationDone: { succeeded in
                    chapterJump = nil
                    if !succeeded { chapterNotice = "暂时无法精确定位该章节" }
                },
                onPositionChange: { snapshot in
                    scroll = snapshot
                    onPositionChange(snapshot)
                },
                onPositionPersist: onPositionPersist) {
                VStack(alignment: .leading, spacing: 16) {
                    NativeMarkdownView(
                        text: replyText,
                        cacheable: true,
                        findQuery: chapterJump?.title ?? (showFind ? findQuery : ""),
                        activeFindOrdinal: chapterJump?.ordinal ?? activeFindOrdinal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.canvas)
            .navigationTitle("阅读模式")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    readerHeader
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 8)
                    if showFind { searchBar }
                }
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                navigationBar
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !outline.isEmpty {
                        Button {
                            showOutline = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("查看回答章节目录")
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showFind.toggle()
                        }
                        if showFind {
                            scheduleSearch(reset: true)
                        } else {
                            closeSearch()
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(showFind ? "关闭回答内查找" : "在回答内查找")
                    Button {
                        UIPasteboard.general.string = replyText
                        UIAccessibility.post(notification: .announcement,
                                             argument: "已复制整轮回答")
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                    }
                    .accessibilityLabel("复制全文")
                    Button {
                        sharingFile = makeShareFile()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享全文")
                }
            }
            .sheet(isPresented: $showOutline, onDismiss: {
                guard let chapter = queuedChapter else { return }
                queuedChapter = nil
                if showFind {
                    closeSearch()
                    showFind = false
                }
                chapterNotice = nil
                chapterJump = chapter
            }) {
                NavigationStack {
                    List(outline) { section in
                        Button {
                            queuedChapter = section
                            showOutline = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(section.title)
                                    .font(section.level == 1 ? .headline : .subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.leading, CGFloat(max(0, section.level - 1)) * 10)
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(section.id + 1) 章，\(section.title)")
                        .accessibilityHint("跳转到回答中的对应标题")
                    }
                    .navigationTitle("回答目录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showOutline = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $sharingFile) { file in
                ShareSheet(items: [file.url], lifetime: file.lifetime) {
                    sharingFile = nil
                }
            }
            .onChange(of: findQuery) { _, _ in scheduleSearch(reset: true) }
            .task(id: replyText) {
                let source = replyText
                let sections = await Task.detached(priority: .utility) {
                    ChatReaderOutline.sections(in: source)
                }.value
                guard !Task.isCancelled else { return }
                outline = sections
            }
            .onAppear {
                guard initialPosition != nil else { return }
                restoreNotice = true
                UIAccessibility.post(notification: .announcement,
                                     argument: "已恢复上次阅读位置")
            }
            .onDisappear {
                searchTask?.cancel()
                searchTask = nil
            }
        }
    }

    private var readerHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            HermesAvatar(size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hermes")
                    .font(.headline)
                HStack(spacing: 6) {
                    if let timestamp = message.timestamp {
                        Text(ChatPresentation.timeLabel(Date(timeIntervalSince1970: timestamp)))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text("完整回答")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppTheme.softFill, in: Capsule())
                    if restoreNotice {
                        Label("已恢复上次位置", systemImage: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.accent)
                            .lineLimit(1)
                    }
                    if let chapterNotice {
                        Text(chapterNotice)
                            .font(.caption2).foregroundStyle(AppTheme.warning)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("在回答中查找", text: $findQuery)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { stepFind(0) }
                if !findQuery.isEmpty {
                    Button {
                        findQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("清空查找")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 10))

            if searching {
                ProgressView().controlSize(.small).frame(width: 54)
            } else {
                Text(searchQueryTooLong ? "过长"
                     : (matchCount == 0 ? "0"
                        : "\(findOrdinal + 1)/\(matchCount)" + (hasMoreSearchMatches ? "+" : "")))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle((searchQueryTooLong || matchCount == 0 && !findQuery.isEmpty)
                                     ? AppTheme.warning : Color.secondary)
                    .frame(minWidth: 42)
                    .accessibilityLabel(findMatchAccessibilityLabel)
            }

            Button { stepFind(-1) } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
            }
            .disabled(matchCount == 0 || searching || searchQueryTooLong)
            .accessibilityLabel("上一处匹配")
            Button { stepFind(1) } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
            }
            .disabled(matchCount == 0 || searching || searchQueryTooLong)
            .accessibilityLabel("下一处匹配")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.bottom, 8)
    }

    private var navigationBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                progressLabel
                Spacer(minLength: 8)
                navigationButtons
            }
            VStack(spacing: 4) {
                progressLabel
                navigationButtons
            }
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var progressLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "text.page")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
            Text("已读 \(Int((scroll.progress * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("阅读进度 \(Int((scroll.progress * 100).rounded()))%")
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button {
                ReaderScrollCommand.shared.send(.top)
            } label: {
                Label("顶部", systemImage: "arrow.up.to.line")
                    .font(.caption)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("回到回答顶部")
            Button {
                ReaderScrollCommand.shared.send(.bottom)
            } label: {
                Label("底部", systemImage: "arrow.down.to.line")
                    .font(.caption)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("回到回答底部")
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
    }

    private var findMatchAccessibilityLabel: String {
        if searching { return "正在查找" }
        if searchQueryTooLong { return "关键词超过 512 个 UTF-16 单元" }
        if findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "尚未输入查找内容"
        }
        if matchCount == 0 { return "没有匹配" }
        return "第 \(findOrdinal + 1) 处，显示 \(matchCount) 处"
            + (hasMoreSearchMatches ? "，还有更多匹配" : "")
    }

    private func stepFind(_ direction: Int) {
        guard !searching, !searchQueryTooLong, matchCount > 0 else { return }
        findOrdinal = (findOrdinal + direction + matchCount) % matchCount
        UIAccessibility.post(notification: .announcement,
                             argument: "第 \(findOrdinal + 1) 处，共 \(matchCount) 处")
    }

    private func closeSearch() {
        searchTask?.cancel()
        searchTask = nil
        findQuery = ""
        matchCount = 0
        findOrdinal = 0
        hasMoreSearchMatches = false
        searchQueryTooLong = false
        searching = false
    }

    private func scheduleSearch(reset: Bool) {
        searchTask?.cancel()
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matchCount = 0
            findOrdinal = 0
            hasMoreSearchMatches = false
            searchQueryTooLong = false
            searching = false
            return
        }
        guard query.utf16.count <= 512 else {
            matchCount = 0
            findOrdinal = 0
            hasMoreSearchMatches = false
            searchQueryTooLong = true
            searching = false
            return
        }
        searchQueryTooLong = false
        hasMoreSearchMatches = false
        searching = true
        matchCount = 0
        findOrdinal = 0
        let text = replyText
        searchTask = Task {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            let plain = await Task.detached(priority: .userInitiated) {
                ChatConversationSearch.searchableText(
                    .init(id: "reader", text: text, markdown: true))
            }.value
            guard !Task.isCancelled,
                  query == findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            let total = ChatFindHighlight.characterRanges(of: query, in: plain, limit: 301).count
            let nextCount = min(300, total)
            let more = total > 300
            guard !Task.isCancelled,
                  query == findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            matchCount = nextCount
            hasMoreSearchMatches = more
            if reset || findOrdinal >= matchCount { findOrdinal = 0 }
            searching = false
            UIAccessibility.post(
                notification: .announcement,
                argument: matchCount == 0 ? "没有匹配"
                    : (more ? "超过 300 处匹配，已显示前 300 处" : "找到 \(matchCount) 处匹配"))
        }
    }
}

private enum ReaderScrollCommandValue {
    case top
    case bottom
}

/// One reader sheet owns one scroll view. This bridge avoids threading a
/// coordinator object through the navigation bar while retaining UIKit as the
/// sole owner of exact content offsets.
private final class ReaderScrollCommand {
    static let shared = ReaderScrollCommand()
    private var handler: ((ReaderScrollCommandValue) -> Void)?

    func install(_ handler: @escaping (ReaderScrollCommandValue) -> Void) {
        self.handler = handler
    }

    func clear() {
        handler = nil
    }

    func send(_ value: ReaderScrollCommandValue) {
        handler?(value)
    }
}

private struct ReaderScrollView<Content: View>: UIViewRepresentable {
    let initialPosition: ChatReaderPosition?
    let replyText: String
    let findQuery: String
    let activeFindOrdinal: Int?
    let isChapterJump: Bool
    let onChapterNavigationDone: (Bool) -> Void
    let onPositionChange: (ChatReaderScrollSnapshot) -> Void
    let onPositionPersist: (ChatReaderScrollSnapshot) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(initialPosition: initialPosition, replyText: replyText,
                    findQuery: findQuery, activeFindOrdinal: activeFindOrdinal,
                    onChapterNavigationDone: onChapterNavigationDone,
                    onPositionChange: onPositionChange,
                    onPositionPersist: onPositionPersist)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        let host = UIHostingController(rootView: content())
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        context.coordinator.host = host
        context.coordinator.installCommandBridge()
        context.coordinator.beginRestoring(in: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host?.rootView = content()
        context.coordinator.onPositionChange = onPositionChange
        context.coordinator.onPositionPersist = onPositionPersist
        context.coordinator.onChapterNavigationDone = onChapterNavigationDone
        context.coordinator.updateFind(query: findQuery, ordinal: activeFindOrdinal,
                                       isChapterJump: isChapterJump)
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.persistCurrentPosition(in: scrollView)
        ReaderScrollCommand.shared.clear()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let initialPosition: ChatReaderPosition?
        let replyText: String
        var onPositionChange: (ChatReaderScrollSnapshot) -> Void
        var onPositionPersist: (ChatReaderScrollSnapshot) -> Void
        var onChapterNavigationDone: (Bool) -> Void
        var host: UIHostingController<Content>?
        private var restoreTarget: Double?
        private var contentSizeObservation: NSKeyValueObservation?
        private var restorationDeadline: DispatchWorkItem?
        private var userInterruptedRestore = false
        private var lastReported = ChatReaderScrollSnapshot()
        private var lastFindQuery = ""
        private var lastFindOrdinal: Int?
        private var pendingFindOrdinal: Int?
        private var findRetries = 0
        private var findRetryScheduled = false
        private var chapterPending = false

        init(initialPosition: ChatReaderPosition?, replyText: String,
             findQuery: String, activeFindOrdinal: Int?,
             onChapterNavigationDone: @escaping (Bool) -> Void,
             onPositionChange: @escaping (ChatReaderScrollSnapshot) -> Void,
             onPositionPersist: @escaping (ChatReaderScrollSnapshot) -> Void) {
            self.initialPosition = initialPosition
            self.replyText = replyText
            self.onPositionChange = onPositionChange
            self.onPositionPersist = onPositionPersist
            self.onChapterNavigationDone = onChapterNavigationDone
            self.lastFindQuery = findQuery
            self.lastFindOrdinal = activeFindOrdinal
        }

        func installCommandBridge() {
            ReaderScrollCommand.shared.install { [weak self] value in
                guard let self else { return }
                DispatchQueue.main.async { self.perform(value) }
            }
        }

        func beginRestoring(in scrollView: UIScrollView) {
            guard initialPosition != nil else { return }
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.initial, .new]) {
                [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                DispatchQueue.main.async { self.applyPendingRestore(in: scrollView) }
            }
            let deadline = DispatchWorkItem { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.applyPendingRestore(in: scrollView)
                self.finishRestoring()
            }
            restorationDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: deadline)
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                scrollView.layoutIfNeeded()
                self.applyPendingRestore(in: scrollView)
            }
        }

        private func applyPendingRestore(in scrollView: UIScrollView) {
            guard !userInterruptedRestore, restoreTarget == nil,
                  let position = initialPosition,
                  scrollView.contentSize.height > scrollView.bounds.height + 1,
                  scrollView.bounds.width > 0 else { return }
            let maximum = max(0, Double(scrollView.contentSize.height - scrollView.bounds.height))
            guard let target = ChatReaderPositionRestorePolicy.targetOffset(
                position, maximumOffset: maximum,
                viewportWidth: Double(scrollView.bounds.width), content: replyText)
            else {
                finishRestoring()
                return
            }
            restoreTarget = target
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            if abs(Double(scrollView.contentOffset.y) - target) <= 1 {
                let snapshot = snapshot(in: scrollView)
                finishRestoring()
                report(snapshot)
            }
        }

        private func finishRestoring() {
            restoreTarget = nil
            restorationDeadline?.cancel()
            restorationDeadline = nil
            contentSizeObservation = nil
        }

        private func perform(_ command: ReaderScrollCommandValue) {
            guard let scrollView = host?.view.superview as? UIScrollView else { return }
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let target = command == .top ? 0 : maximum
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            lastReported = ChatReaderScrollSnapshot()
            report(scrollView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak scrollView] in
                guard let self, let scrollView, !scrollView.isDragging else { return }
                self.persistCurrentPosition(in: scrollView)
            }
        }

        func updateFind(query: String, ordinal: Int?, isChapterJump: Bool) {
            guard query != lastFindQuery || ordinal != lastFindOrdinal
                      || isChapterJump != chapterPending else { return }
            lastFindQuery = query
            lastFindOrdinal = ordinal
            findRetries = 0
            pendingFindOrdinal = ordinal
            chapterPending = isChapterJump
            if isChapterJump && restoreTarget != nil {
                userInterruptedRestore = true
                finishRestoring()
            }
            guard !query.isEmpty, ordinal != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.applyPendingFind() }
        }

        private func applyPendingFind() {
            guard let ordinal = pendingFindOrdinal, let host else { return }
            host.view.layoutIfNeeded()
            guard let (text, rect) = ChatFindGeometry.occurrence(ordinal, in: host.view) else {
                retryFind()
                return
            }
            guard let scrollView = host.view.superview as? UIScrollView else { return }
            ChatFindGeometry.revealHorizontally(rect, in: text, stoppingAt: host.view)
            let local = text.convert(rect, to: host.view)
            let desired = local.midY - scrollView.bounds.height * 0.38
            let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            pendingFindOrdinal = nil
            scrollView.setContentOffset(
                CGPoint(x: 0, y: min(maximum, max(0, desired))), animated: true)
            if chapterPending {
                chapterPending = false
                DispatchQueue.main.async { [weak self] in
                    self?.onChapterNavigationDone(true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.persistCurrentPosition(in: scrollView)
            }
        }

        private func retryFind() {
            guard pendingFindOrdinal != nil else { return }
            guard findRetries < 40 else {
                pendingFindOrdinal = nil
                if chapterPending {
                    chapterPending = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onChapterNavigationDone(false)
                    }
                }
                return
            }
            guard !findRetryScheduled else { return }
            findRetryScheduled = true
            findRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.findRetryScheduled = false
                self.applyPendingFind()
            }
        }

        func persistCurrentPosition(in scrollView: UIScrollView) {
            guard restoreTarget == nil else { return }
            let snapshot = snapshot(in: scrollView)
            report(snapshot)
            DispatchQueue.main.async { [weak self] in
                self?.onPositionPersist(snapshot)
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if chapterPending {
                chapterPending = false
                pendingFindOrdinal = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onChapterNavigationDone(true)
                }
            }
            if restoreTarget != nil {
                userInterruptedRestore = true
                finishRestoring()
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            report(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { persistCurrentPosition(in: scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            persistCurrentPosition(in: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            persistCurrentPosition(in: scrollView)
        }

        private func report(_ scrollView: UIScrollView) {
            guard restoreTarget == nil else { return }
            report(snapshot(in: scrollView))
        }

        private func snapshot(in scrollView: UIScrollView) -> ChatReaderScrollSnapshot {
            ChatReaderScrollSnapshot(
                offset: max(0, Double(scrollView.contentOffset.y)),
                maximumOffset: max(0, Double(scrollView.contentSize.height - scrollView.bounds.height)),
                viewportWidth: max(0, Double(scrollView.bounds.width)))
        }

        private func report(_ snapshot: ChatReaderScrollSnapshot) {
            guard snapshot != lastReported else { return }
            lastReported = snapshot
            DispatchQueue.main.async { [weak self] in
                self?.onPositionChange(snapshot)
            }
        }
    }
}
