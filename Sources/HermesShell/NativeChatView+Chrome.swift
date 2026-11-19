import SwiftUI
import UIKit

extension NativeChatView {
    @ViewBuilder
    var findBar: some View {
        if showFind {
            ChatFindBar(query: $findQuery, count: findHits.count, index: findIndex,
                searching: finding,
                snippet: findHits.indices.contains(findIndex) ? findHits[findIndex].snippet : nil,
                hasMoreMatches: findHasMoreMatches, queryTooLong: findQueryTooLong,
                canLoadOlder: model.canLoadOlderHistory && !isLoadingOlder,
                loadingOlder: isLoadingOlder, olderLimitReached: model.olderLimitReached,
                canReturnToOrigin: findOrigin != nil, onStep: stepFind,
                onLoadOlder: { loadOlderForFind() }, onReturnToOrigin: returnToFindOrigin,
                onClose: closeFind)
        }
    }

    @ViewBuilder
    var readingPositionBar: some View {
        if let hint = resumeHint {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(AppTheme.accent)
                Text("上次读到 · \(hint.preview)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button("回到那里") {
                    resumeHint = nil
                    restoreCancelled = false
                    Task { await restoreReadingPosition(resumePosition) }
                }
                .font(.caption.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                Button {
                    resumeHint = nil
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("不再提示上次阅读位置")
            }
            .padding(.horizontal, 12)
            .accessibilityElement(children: .contain)
        }
        if restoringReading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在恢复上次阅读位置…").font(.caption).foregroundStyle(.secondary)
                Button("取消") { restoreCancelled = true; restoringReading = false }
                    .font(.caption).frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    // MARK: header

    var header: some View {
        HStack(spacing: 8) {
            // A persistent conversation canvas uses a left drawer, not a
            // navigation pop that tears down the ongoing scroll/stream state.
            Button {
                composerFocused = false
                onOpenSidebar()
            } label: {
                ChromeIcon(symbol: "line.3.horizontal")
            }
            .accessibilityLabel("打开会话侧栏")

            // One navigation row. A fixed 44pt slot prevents model/run state
            // transitions from resizing the transcript viewport mid-stream.
            titleSwitchButton
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)

            // ChatGPT-style light chrome: chat actions are a single menu;
            // keep the info panel accessible there instead of a permanent icon.
            Button {
                composerFocused = false
                // Match the drawer's New Chat action: a local empty draft
                // workspace, not an empty network-created Session.
                app.closeSession()
            } label: {
                if app.creating { ProgressView().frame(width: 44, height: 44) }
                else { ChromeIcon(symbol: "square.and.pencil") }
            }
            .disabled(app.creating)
            .accessibilityLabel("新建对话")

            Menu {
                Button("切换模型", systemImage: "square.stack.3d.up") {
                    composerFocused = false
                    showModelPicker = true
                }
                Divider()
                Button("会话资料", systemImage: "info.circle") { showPanel(.info) }
                Divider()
                Button("任务与消息队列", systemImage: "waveform") { showPanel(.task) }
                Button {
                    composerFocused = false
                    if showFind { closeFind() }
                    showAttachments = true
                } label: { Label("会话附件", systemImage: "photo.on.rectangle.angled") }
                Button {
                    beginFind()
                } label: { Label("在当前会话查找", systemImage: "magnifyingglass") }
                Button {
                    composerFocused = false
                    showMessageNavigation = true
                } label: {
                    Label("消息导航", systemImage: "list.bullet.rectangle")
                }
                .disabled(model.transcript.messages.allSatisfy { $0.role != "user" })
                Button { showUsage = true } label: {
                    Label("上下文与用量", systemImage: "chart.bar")
                }
                if initialReadingPosition?.following == false {
                    Button("恢复上次阅读位置", systemImage: "bookmark") {
                        restoreCancelled = false
                        Task { await restoreReadingPosition() }
                    }
                }
                Menu {
                    Button {
                        renameDraft = currentTitle
                        showRename = true
                    } label: { Label("重命名会话", systemImage: "pencil") }
                    .disabled(app.sessionActionBusy)
                    Button {
                        Task {
                            await app.togglePin(sessionID: sessionID)
                            if let failure = app.sessionActionError { showToast("置顶失败：\(failure)") }
                        }
                    } label: {
                        Label(isPinned ? "取消置顶" : "置顶会话",
                              systemImage: isPinned ? "pin.slash" : "pin")
                    }
                    .disabled(app.sessionActionBusy)
                    if app.api.capabilities.canArchive {
                        Button {
                            Task {
                                await app.archive(sessionID: sessionID)
                                if let failure = app.sessionActionError { showToast("归档失败：\(failure)") }
                            }
                        } label: { Label("归档会话", systemImage: "archivebox") }
                        .disabled(app.sessionActionBusy)
                    }
                } label: {
                    Label("管理会话", systemImage: "slider.horizontal.3")
                }
                Menu {
                    Button("导出已加载内容", systemImage: "doc.text") { exportTranscript() }
                        .disabled(model.transcript.messages.isEmpty || export.isBusy)
                    Button("获取完整历史后导出", systemImage: "clock.arrow.circlepath") {
                        exportTranscript(fullHistory: true)
                    }
                    .disabled(model.transcript.messages.isEmpty || export.isBusy
                              || !canFetchFullExport)
                    if !canFetchFullExport {
                        Text("生成中、核对中或离线时，仍可导出已加载内容。")
                    }
                } label: {
                    Label("导出会话", systemImage: "doc.text")
                }
                Divider()
                Button {
                    composerFocused = false
                    showRecoveryCenter = true
                } label: {
                    Label(recoveryMenuTitle, systemImage: "lifepreserver")
                }
                Menu {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新会话状态", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loading || model.submitting || model.stopping)
                    Button {
                        UIPasteboard.general.string = sessionID
                        UIAccessibility.post(notification: .announcement, argument: "会话 ID 已复制")
                        showToast("已复制会话 ID")
                    } label: {
                        Label("复制会话 ID", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("诊断信息", systemImage: "stethoscope")
                }
            } label: {
                ChromeIcon(symbol: "ellipsis")
            }
            .accessibilityLabel("更多操作")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(AppTheme.canvas)
    }

    /// Keep the conversation identity primary and the live activity secondary.
    /// Both occupy the existing fixed 44pt header slot, so streaming status
    /// transitions cannot resize the transcript viewport.
    private var titleSwitchButton: some View {
        Button {
            // Reuse the existing tool/queue panel, preserving a 44pt fixed
            // header slot across ready, streaming and recovery states.
            showPanel(.task)
        } label: {
        VStack(spacing: 2) {
            Text(currentTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 5) {
                if model.activity.showsProgress {
                    ProgressView().controlSize(.mini)
                } else if model.activity != .ready {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.warning)
                } else {
                    Circle()
                        .fill(AppTheme.success)
                        .frame(width: 5, height: 5)
                }
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(model.activity == .ready ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(currentTitle)，\(statusLine)，查看任务与消息队列")
        .accessibilityHint("双击查看当前会话运行、工具和排队状态")
    }

    private var recoveryMenuTitle: String {
        if model.hasPendingSend || model.uncertain || model.queuePersistenceFailed
            || model.runRecoveryNoticeShown || model.cachedHistoryDate != nil
            || model.localPersistenceIssue != nil {
            return "恢复与本地数据"
        }
        return "恢复中心"
    }

    /// 标题以 AppState 的会话表为准：改名成功后立即回显，不必等页面重建。
    var currentTitle: String {
        app.sessions.first { $0.sessionId == sessionID }?.displayTitle ?? title
    }

    private var isPinned: Bool {
        app.sessions.first { $0.sessionId == sessionID }?.pinned == true
    }

    private var statusLine: String { model.activity.title }
    var activeFindRowID: String? {
        showFind && findHits.indices.contains(findIndex) ? findHits[findIndex].rowID : nil
    }

    private func beginFind() {
        guard !showFind else { return }
        composerFocused = false
        restoreCancelled = true
        restoringReading = false
        // Capture what is actually visible, never a possibly stale disk bookmark.
        findOrigin = controllerBox.value?.captureCurrentReadingPosition()
        findHasMoreMatches = false
        findQueryTooLong = false
        showFind = true
        scheduleFind(.queryChanged, jump: false)
    }

    private func returnToFindOrigin() {
        guard let origin = findOrigin else { return }
        closeFind()
        restoreCancelled = false
        if origin.following {
            goToLatest(animated: false)
        } else if items.contains(where: { $0.id == origin.rowID }) {
            navigate(to: origin.rowID, offset: origin.offsetInRow)
        } else {
            // Only a user-selected return may page toward a missing bookmark.
            Task { await restoreReadingPosition(origin) }
        }
    }

    private func closeFind() {
        scheduleFind(.cancelled, jump: false)
        showFind = false
        findQuery = ""
        findHits = []
        findIndex = 0
        findHasMoreMatches = false
        findQueryTooLong = false
        findOrigin = nil
        finding = false
    }

    /// A running computation owns its slot until it publishes. A content burst
    /// is coalesced into one subsequent pass, including while the worker runs.
    func scheduleFind(_ event: FindDebouncePolicy.Event, jump: Bool) {
        switch FindDebouncePolicy.action(event, running: findWork.active) {
        case .cancel:
            findTask?.cancel()
            findTask = nil
            findWork.cancel()
            controllerBox.value?.cancelFindNavigation()
        case .keepWaiting:
            findWork.contentChanged()
            return
        case .restart:
            findTask?.cancel()
            findWork.cancel()
            controllerBox.value?.cancelFindNavigation()
            guard showFind else { return }
            let query = findQuery
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finding = false; findHits = []; findIndex = 0
                findHasMoreMatches = false; findQueryTooLong = false; return
            }
            finding = true
            let ticket = findWork.begin()
            findTask = Task { @MainActor in
                var shouldJump = jump
                repeat {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    guard !Task.isCancelled, showFind, query == findQuery,
                          findWork.startSearch(ticket) else { return }
                    let documents = model.transcript.messages.map {
                        ChatConversationSearch.Document(id: "m-\($0.id)", text: $0.content,
                                                        markdown: $0.role != "user")
                    }
                    let engine = findWorker
                    let worker = Task.detached(priority: .userInitiated) {
                        await engine.findDetailed(query, in: documents)
                    }
                    let result = await withTaskCancellationHandler(operation: { await worker.value },
                        onCancel: { worker.cancel() })
                    guard !Task.isCancelled, showFind, query == findQuery,
                          findWork.ticket == ticket else { return }
                    let old = findHits.indices.contains(findIndex) ? findHits[findIndex].id : nil
                    findHits = result.hits
                    findHasMoreMatches = result.hasMoreMatches
                    findQueryTooLong = result.queryTooLong
                    findIndex = result.hits.firstIndex(where: { $0.id == old }) ?? 0
                    finding = false
                    if shouldJump && !result.hits.isEmpty { stepFind(0) }
                    shouldJump = false
                } while findWork.completeSearch(ticket)
                findTask = nil
            }
        }
    }

    private func stepFind(_ direction: Int) {
        guard !finding, !findQueryTooLong, !findHits.isEmpty else { return }
        findIndex = (findIndex + direction + findHits.count) % findHits.count
        let id = findHits[findIndex].rowID
        if cellStates[id]?.collapsed == true { cellStates[id]?.collapsed = false }
        navigate(to: id, findOrdinal: findOrdinal(for: id))
    }

    /// 当前命中在本行内是第几个（0-based）。只有当前命中所在行返回非 nil，
    /// 其余行不传序号 → 全部按「普通命中」着色。
    func findOrdinal(for rowID: String) -> Int? {
        guard showFind, findHits.indices.contains(findIndex) else { return nil }
        guard findHits[findIndex].rowID == rowID else { return nil }
        return findHits[..<findIndex].reduce(0) { $0 + ($1.rowID == rowID ? 1 : 0) }
    }
    var canFetchFullExport: Bool {
        model.cachedHistoryDate == nil && !model.loading && !model.syncing && !model.running
            && !model.submitting && !model.uncertain && !model.reconciling && !model.stopping
    }

    @ViewBuilder var exportOverlay: some View {
        if let progress = export.progress {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progress.pages == 0 ? "正在准备导出…"
                     : "已获取 \(progress.messages) 条消息 · 第 \(progress.pages) 页")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("取消") { cancelExport() }.frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(12)
            .accessibilityElement(children: .contain)
        } else if export.readyFile != nil {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(AppTheme.accent)
                Text("导出文件已就绪").font(.caption)
                Spacer(minLength: 4)
                Button("分享") { export.shareReadyFile() }.frame(minWidth: 44, minHeight: 44)
                Button { export.dismissReadyFile() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("关闭并清理导出文件")
            }
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(12)
            .accessibilityElement(children: .contain)
        } else if let failure = export.failure {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.warning)
                    Text("导出未完成")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Button {
                        export.dismissFailure()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("关闭导出失败提示")
                }
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重试导出") {
                        export.dismissFailure()
                        exportTranscript(fullHistory: export.failedFullHistory)
                    }
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 44)
                    Button("先导出已加载内容") {
                        export.dismissFailure()
                        exportTranscript(fullHistory: false)
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .disabled(export.failedFullHistory == false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(12)
            .accessibilityElement(children: .contain)
        }
    }

    func cancelExport() {
        export.cancel()
    }

    /// Capture immutable values; the independent pager never calls loadOlder().
    /// Files are formatted/written off MainActor, and a stale task cannot raise
    /// a share sheet after leaving this account/instance/conversation.
    func exportTranscript(fullHistory: Bool = false) {
        guard export.progress == nil, !model.transcript.messages.isEmpty,
              !fullHistory || canFetchFullExport else { return }
        let ticket = UUID()
        export.ticket = ticket
        export.readyFile = nil
        export.failure = nil
        export.progress = .init()
        let capturedTitle = currentTitle
        let instance = app.active.id
        let account = app.historyAccountScope
        let change = app.activeChangeToken
        let loadedMessages = model.transcript.messages
        let loadedTools = model.transcript.tools
        let loadedUsage = model.transcript.usage
        let loadedContext = TranscriptExportContext(hasUnloadedHistory: model.olderOffset > 0,
            cached: model.cachedHistoryDate != nil, generating: model.running && !model.transcript.terminal)
        export.task = Task { @MainActor in
            do {
                var messages = loadedMessages
                var tools = loadedTools
                var usage = loadedUsage
                var context = loadedContext
                var partial: String?
                if fullHistory {
                    let result = try await TranscriptPager.fetch(sessionID: sessionID, history: { before in
                        guard visible, export.ticket == ticket, app.active.id == instance,
                              app.historyAccountScope == account, app.activeChangeToken == change
                        else { throw CancellationError() }
                        do { return try await model.api.history(sessionID: sessionID, before: before) }
                        catch {
                            if model.api.requiresAuthentication(after: error) { throw TranscriptPagerError.authenticationRequired }
                            throw error
                        }
                    }, onProgress: { progress in
                        if export.ticket == ticket { export.progress = progress }
                    })
                    messages = result.messages; tools = result.tools; usage = result.usage
                    partial = result.partialReason
                    context = .init(hasUnloadedHistory: !result.complete, completeHistory: result.complete,
                                    partialReason: result.partialReason)
                }
                try Task.checkCancellation()
                let snapshotMessages = messages, snapshotTools = tools, snapshotUsage = usage, snapshotContext = context
                let writer = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let document = TranscriptExporter.document(title: capturedTitle, messages: snapshotMessages,
                        tools: snapshotTools, usage: snapshotUsage, context: snapshotContext)
                    try Task.checkCancellation()
                    let base = String(capturedTitle.unicodeScalars.filter {
                        !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0)
                    }.map(String.init).joined().prefix(40))
                    let url = try AttachmentDownloadFiles.createDestination(leaf: (base.isEmpty ? "会话" : base) + ".md")
                    do {
                        try document.markdown.write(to: url, atomically: true, encoding: .utf8)
                        try Task.checkCancellation()
                        return url
                    } catch { AttachmentDownloadFiles.remove(url); throw error }
                }
                let url = try await withTaskCancellationHandler(operation: { try await writer.value },
                                                                onCancel: { writer.cancel() })
                guard !Task.isCancelled, visible, export.ticket == ticket, app.active.id == instance,
                      app.historyAccountScope == account, app.activeChangeToken == change else {
                    AttachmentDownloadFiles.remove(url)
                    return
                }
                export.readyFile = SharedTemporaryFile(url: url)
                export.failure = nil
                RuntimeLogRecorder.shared.record(.info, "export",
                    "ok messages=\(messages.count) full=\(fullHistory) partial=\(partial != nil)")
                showToast(partial == nil ? "导出已就绪，点击分享保存到文件"
                          : "部分历史已就绪，文件开头注明了原因")
            } catch is CancellationError {
            } catch {
                if visible, export.ticket == ticket, app.active.id == instance,
                   app.historyAccountScope == account, app.activeChangeToken == change {
                    RuntimeLogRecorder.shared.record(.error, "export",
                        "fail full=\(fullHistory) err=\(error.localizedDescription)")
                    if case TranscriptPagerError.authenticationRequired = error { model.onAuthenticationRequired?() }
                    export.markFailure(error.localizedDescription, fullHistory: fullHistory)
                }
            }
            if export.ticket == ticket { export.task = nil; export.progress = nil }
        }
    }
}
