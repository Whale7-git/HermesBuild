import SwiftUI
import UIKit

extension NativeChatView {
    // MARK: thread

    var thread: some View {
        ZStack {
            StableChatScrollView(
                snapshot: ChatListSnapshot(
                    items: items, itemsStamp: timeline.itemsStamp, states: cellStates,
                    actionsEnabled: model.canSend && !app.sessionActionBusy,
                    capabilities: app.api.capabilities,
                    status: statusSnapshot, olderOffset: model.olderOffset,
                    loadingOlder: isLoadingOlder,
                    canLoadOlder: model.canLoadOlderHistory && !isLoadingOlder,
                    olderLimitReached: model.olderLimitReached,
                    dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme,
                    focusedRowID: activeFindRowID ?? attachmentHighlight,
                    findQuery: showFind ? findQuery : "",
                    findOrdinal: activeFindRowID.flatMap { findOrdinal(for: $0) },
                    canResendPending: model.canResendPending,
                    pendingBusy: model.loading || model.syncing || model.reconciling || model.submitting),
                isGenerating: model.running,
                command: scrollCommand,
                row: { item in
                    AnyView(ChatRowCell(
                        item: item,
                        actionsEnabled: model.canSend && !app.sessionActionBusy,
                        capabilities: app.api.capabilities,
                        baseURL: app.api.webConsoleBaseURL,
                        sessionID: sessionID,
                        attachmentAuthorization: app.api.attachmentPreviewAuthorization,
                        placeholderScope: displayScope,
                        imageRatios: imageRatios, imageRatioScope: displayScope,
                        onAction: forkAction,
                        onCopyReply: { id in
                            copy(ChatTimeline.replyText(endingAt: id, messages: model.transcript.messages),
                                 label: "已复制已加载的回复")
                        },
                        onCopyProcess: { id in
                            copy(ChatTimeline.replyProcessText(
                                endingAt: id, messages: model.transcript.messages),
                                 label: "已复制整轮过程")
                        },
                        onShareReply: { id in shareReply(endingAt: id) },
                        onQuote: { message in quote(message) },
                        onOpenReader: { message in
                            guard ChatReaderPresentationPolicy.canPresent(
                                isStreaming: item.isStreaming,
                                text: ChatTimeline.replyText(
                                    endingAt: message.id,
                                    messages: model.transcript.messages)) else { return }
                            let anchor = ChatTimeline.replyAnchor(
                                for: message.id, messages: model.transcript.messages)
                            readingMessage = model.transcript.messages.first {
                                $0.id == anchor
                            } ?? message
                        },
                        onCopy: { text, label in copy(text, label: label) },
                        state: cellStateBinding(for: item.id),
                        findQuery: showFind ? findQuery : "",
                        activeFindOrdinal: findOrdinal(for: item.id),
                        canResendPending: model.canResendPending,
                        pendingBusy: model.loading || model.syncing || model.reconciling || model.submitting,
                        onReconcilePending: { _ in reconcilePending() },
                        onResendPending: { _ in
                            Task { _ = await model.resendPending() }
                        },
                        onDiscardPending: { _ in model.discardPending() }
                    )
                    .overlay {
                        if item.id == activeFindRowID || item.id == attachmentHighlight {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.accent.opacity(0.6), lineWidth: 2)
                                .padding(.horizontal, 8).allowsHitTesting(false)
                        }
                    }
                    .tint(AppTheme.accent)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.colorScheme, colorScheme))
                },
                footer: {
                    AnyView(ChatStatusFooter(
                        state: statusSnapshot,
                        webURL: app.api.browserSessionURL?.appendingPathComponent("session")
                            .appendingPathComponent(sessionID))
                    .tint(AppTheme.accent)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.colorScheme, colorScheme))
                },
                onDistance: note,
                onLoadOlder: loadOlderIfNeeded,
                onBackgroundTap: { composerFocused = false },
                onReadingPosition: { value in
                    if !restoringReading && !showFind { readingStore.save(value) }
                },
                onUserScroll: {
                    restoreCancelled = true
                    restoringReading = false
                    // A manual history gesture overrides both an in-flight
                    // focus request and an optimistic→confirmed ID handoff.
                    pendingUserTurnFocus = false
                    focusedUserTurnID = nil
                    focusedUserTurnText = nil
                },
                onControllerReady: { controllerBox.value = $0 },
                onFindLocationUnavailable: { showToast("该命中暂未能精确定位，请查看消息高亮") }
            )

            if model.transcript.messages.isEmpty && !model.loading && !model.running && model.error == nil {
                emptyState
            } else if model.loading && model.transcript.messages.isEmpty {
                ProgressView("读取历史…")
            } else if showsFullPageFailure {
                failedState
            }
        }
        // Never change the scroll viewport height as a consequence of
        // scroll.following: a conditional safeAreaInset creates a feedback loop
        // (distance -> following -> inset -> distance) during keyboard transitions.
        .overlay(alignment: .bottom) {
            if !scroll.following { jumpBar }
        }
    }

    /// UIKit supplies distance from the upright visual bottom, including viewport height.
    private func note(_ offset: Double) {
        var next = scroll
        guard next.update(distanceFromBottom: offset) else { return }
        scroll = next
    }

    /// 折叠/展开状态按 item id 保留，与视口位置无关。
    private func cellStateBinding(for id: String) -> Binding<ChatCellState> {
        Binding(
            get: { cellStates[id] ?? ChatCellState() },
            set: { cellStates[id] = $0 }
        )
    }

    /// 与草稿/阅读位置同一作用域键，账号与实例切换后互不可见。
    var cellStateStore: ChatCellStateStore {
        ChatCellStateStore(instanceID: app.historyInstanceID,
                           accountScope: app.historyAccountScope, sessionID: sessionID)
    }

    func restoreCollapsedCells() {
        let saved = cellStateStore.loadCollapsed()
        guard !saved.isEmpty else { return }
        for id in saved where cellStates[id] == nil {
            var state = ChatCellState()
            state.collapsed = true
            cellStates[id] = state
        }
    }

    /// 首屏只给「上次读到」摘要；真正的定位仍交给 restoreReadingPosition。
    func prepareResumeHint() {
        guard let position = initialReadingPosition, position.following == false else { return }
        let messages = model.transcript.messages.map { message in
            ReadingResumeMessage(rowID: "m-\(message.id)",
                                 timestamp: message.timestamp.map { Date(timeIntervalSince1970: $0) },
                                 text: message.content)
        }
        resumeHint = ReadingResumeSummaryBuilder.make(position: position, messages: messages)
        resumePosition = position
    }

    /// Cancel the view-owned pagination without settling any backend Run.
    /// A cancelled old response must not clear a newer page's loading state.
    func retirePagination() {
        paginationOwnership.retire()
        paginationTask?.cancel()
        paginationTask = nil
        controllerBox.value?.notePaginationEnded()
        isLoadingOlder = false
    }

    /// 顶部距离触发分页；UIKit 对本次加载统一保位。
    private func loadOlderIfNeeded() {
        guard visible, !restoringReading, !isLoadingOlder,
              model.canLoadOlderHistory, paginationTask == nil else { return }
        let ticket = paginationOwnership.begin()
        let changeToken = app.activeChangeToken
        let scopedSession = sessionID
        let scopedInstance = displayScope
        isLoadingOlder = true
        controllerBox.value?.notePaginationBegan()
        paginationTask = Task {
            await model.loadOlder()
            // 让本轮保位与高度提交跑完再收尾，样本覆盖「请求→prepend→一次布局」。
            do { try await Task.sleep(nanoseconds: 60_000_000) }
            catch { return }
            guard !Task.isCancelled, paginationOwnership.owns(ticket),
                  visible, app.activeChangeToken == changeToken,
                  app.currentSessionID == scopedSession,
                  app.historyInstanceID + "|" + app.historyAccountScope == scopedInstance
            else { return }
            paginationOwnership.retire()
            paginationTask = nil
            controllerBox.value?.notePaginationEnded()
            isLoadingOlder = false
        }
    }

    private var emptyState: some View {
        // A calm, centered start state, like a modern conversation-first app.
        // No fake suggestion chips: every visible affordance must be actionable.
        VStack(spacing: 14) {
            HermesLogo(size: 48)
                .padding(.bottom, 8)
            Text("今天想让 Hermes 做什么？")
                .font(.system(.title2, design: .default, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("提问、写代码，或者把任务交给 Agent。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, AppTheme.pagePadding)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// 首屏失败：错误不能只留在页脚，否则整页只剩空白。
    private var failedState: some View {
        ContentUnavailableView {
            Label("连不上后端", systemImage: "wifi.exclamationmark")
        } description: {
            Text(model.error ?? "请检查网络后再试。")
        } actions: {
            Button("重试") { Task { await model.refresh() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.loading)
            Button("查看本地历史") { Task { await model.load() } }
                .disabled(model.loading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.canvas)
    }
    /// A floating control outside transcript geometry: its appearance must not
    /// affect viewport size or the reading anchor. It only appears while detached.
    private var jumpBar: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Button { goToLatest(animated: true) } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.hairline.opacity(0.75), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 9)
            .accessibilityLabel(scroll.hasUnreadContent ? "有新内容，回到最新消息" : "回到最新消息")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48, alignment: .bottom)
        // No 64pt gradient over live text and no layout-dependent safeAreaInset.
        // The button overlays the content without changing transcript geometry.
        .transition(.opacity)
    }
    private func forkAction(_ message: ChatMessage, regenerate: Bool) {
        guard model.canSend, !app.sessionActionBusy else { return }
        do {
            let plan = try regenerate
                ? MessageForkPlan.regenerate(messageID: message.id, messages: model.transcript.messages)
                : MessageForkPlan.edit(messageID: message.id, messages: model.transcript.messages)
            Task { await app.forkMessage(plan, from: sessionID) }
        } catch { showToast(error.localizedDescription) }
    }

    private func quote(_ message: ChatMessage) {
        guard model.canSend, !model.readOnly, !app.sessionActionBusy,
              let reference = ChatQuote.reference(for: message) else {
            showToast("这条消息没有可引用的文字")
            return
        }
        composerInsertion = ChatComposerInsertion(
            token: composerInsertion.token &+ 1, quote: reference)
    }

    /// Sharing is a local temporary file; no server write occurs. The existing
    /// SharedTemporaryFile lifetime removes the file after the system surface
    /// releases it.
    func shareReply(endingAt id: String) {
        guard let file = makeReplyShareFile(endingAt: id) else { return }
        export.sharingFile = file
    }

    func makeReplyShareFile(endingAt id: String) -> SharedTemporaryFile? {
        let text = ChatTimeline.replyText(endingAt: id, messages: model.transcript.messages)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("这条回复没有可分享的文字")
            return nil
        }
        let base = currentTitle.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0)
        }.map(String.init).joined().prefix(40)
        let leaf = (base.isEmpty ? "Hermes 回复" : String(base) + " · 回复") + ".md"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesReply-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let file = url.appendingPathComponent(leaf)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return SharedTemporaryFile(url: file)
        } catch {
            showToast("生成分享文件失败：\(error.localizedDescription)")
            return nil
        }
    }
    // MARK: scroll helpers

    /// An explicit command is the only action allowed to interrupt user scrolling.
    func goToLatest(animated: Bool) {
        restoreCancelled = true
        scroll.jumpToLatest()
        scrollCommand.targetID = nil
        scrollCommand.offsetInRow = 0
        scrollCommand.findOrdinal = nil
        scrollCommand.sequence &+= 1
        scrollCommand.animated = animated && !reduceMotion
    }
    /// 发送结果未确认时：先只读核对后台历史，确认没有这条之后才允许重发，
    /// 避免服务端已受理时重复执行工具调用。
    private func reconcilePending() {
        Task {
            switch await model.reconcilePending() {
            case .delivered: showToast("已核对：后台已有这条消息")
            case .absent: showToast("当前历史未发现这条消息，可选择重发")
            case .failed: showToast("暂不能确认发送结果，请稍后再核对")
            }
        }
    }
    func navigate(to id: String, offset: Double = 0, findOrdinal: Int? = nil) {
        scroll.update(distanceFromBottom: ChatScrollState.detachThreshold + 1)
        scrollCommand.targetID = id
        scrollCommand.offsetInRow = offset
        scrollCommand.findOrdinal = findOrdinal
        scrollCommand.animated = false
        scrollCommand.sequence &+= 1
    }

    func restoreReadingPosition() async {
        await restoreReadingPosition(initialReadingPosition)
    }

    func restoreReadingPosition(_ position: ChatReadingPosition?) async {
        guard let position, !position.following,
              scenePhase == .active, !restoringReading, !restoreCancelled, !Task.isCancelled else { return }
        restoringReading = true
        defer { restoringReading = false }
        // Bound automatic history reads. A very old anchor can be retried from
        // the menu; gestures and Send cancel restoration and always take priority.
        for page in 0...12 {
            guard visible, scenePhase == .active, !restoreCancelled, !Task.isCancelled else { return }
            // 查已算好的 `timeline.items`，不重建整条时间线。
            // 原先这里每轮都调 `ChatTimeline.build` 全量重建——最坏 13 次，
            // 而 `items` 是 `ChatTimelineProjection` 早就维护好的同一份结果。
            // 分页会在 `loadOlder()` 里刷新 transcript，`items` 随之更新，
            // 所以下一轮看到的仍是当前真实行集合，不需要自己重建。
            if items.contains(where: { $0.id == position.rowID }) {
                navigate(to: position.rowID, offset: position.offsetInRow)
                return
            }
            guard page < 12, model.canLoadOlderHistory else { break }
            let before = model.olderOffset
            await model.loadOlder()
            if model.olderOffset >= before { break }
        }
        if visible && !restoreCancelled && !Task.isCancelled { showToast("上次位置尚未载入，可在菜单中重试恢复。") }
    }
}
