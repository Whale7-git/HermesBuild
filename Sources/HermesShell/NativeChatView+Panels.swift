import SwiftUI

extension NativeChatView {
    var panelBinding: Binding<ChatPanel?> {
        Binding(get: { activePanel }, set: { next in
            if next == nil && activePanel != nil { panelDismissing = true }
            activePanel = next
        })
    }
    var showDrawer: Bool {
        get { activePanel?.id == "drawer" }
        nonmutating set { setPanel(.drawer, shown: newValue) }
    }
    var showModelPicker: Bool {
        get { activePanel?.id == "models" }
        nonmutating set { setPanel(.models, shown: newValue) }
    }
    var showAttachments: Bool {
        get { if case .attachments = activePanel { return true }; return false }
        nonmutating set { setPanel(.attachments(0), shown: newValue) }
    }
    var showUsage: Bool {
        get { activePanel?.id == "usage" }
        nonmutating set { setPanel(.usage, shown: newValue) }
    }
    var showQueueManager: Bool {
        get { activePanel?.id == "queue" }
        nonmutating set { setPanel(.queue, shown: newValue) }
    }
    var showRecoveryCenter: Bool {
        get { activePanel?.id == "recovery" }
        nonmutating set { setPanel(.recovery, shown: newValue) }
    }
    var showMessageNavigation: Bool {
        get { activePanel?.id == "navigation" }
        nonmutating set { setPanel(.navigation, shown: newValue) }
    }
    var readingMessage: ChatMessage? {
        get { if case .reader(let message) = activePanel { return message }; return nil }
        nonmutating set {
            if let message = newValue { showPanel(.reader(message)) }
            else if case .reader(let message) = activePanel { setPanel(.reader(message), shown: false) }
        }
    }

    func showPanel(_ panel: ChatPanel) {
        composerFocused = false
        if panelDismissing { pendingPanel = panel; return }
        guard activePanel?.id != panel.id else { return }
        if activePanel == nil { activePanel = panel }
        else { pendingPanel = panel; panelDismissing = true; activePanel = nil }
    }

    private func setPanel(_ panel: ChatPanel, shown: Bool) {
        if shown { showPanel(panel) }
        else if activePanel?.id == panel.id { panelDismissing = true; activePanel = nil }
    }

    func dismissPanel(then action: ChatPanelAction) {
        afterPanelAction = action
        pendingPanel = nil
        if activePanel != nil { panelDismissing = true; activePanel = nil }
        else if !panelDismissing { panelDidDismiss() }
    }

    func panelDidDismiss() {
        panelDismissing = false
        guard visible else { pendingPanel = nil; afterPanelAction = nil; return }
        if let target = attachmentTarget {
            attachmentTarget = nil
            if items.contains(where: { $0.id == target }) {
                composerFocused = false
                attachmentHighlightTask?.cancel()
                attachmentHighlight = target
                navigate(to: target)
                attachmentHighlightTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    attachmentHighlight = nil
                }
            } else { showToast("原消息当前不可定位，请刷新历史后重试") }
        }
        if let next = pendingPanel {
            pendingPanel = nil
            activePanel = next
            return
        }
        // A file lease remains retained by the presented system controller.
        export.sharingFile = nil
        guard let action = afterPanelAction else { return }
        afterPanelAction = nil
        switch action {
        case .settings: app.showSettings = true
        case .newSession: Task { await app.createSession() }
        case .select(let session): app.openSession(session)
        case .export(let fullHistory): exportTranscript(fullHistory: fullHistory)
        case .locateTool(let id): locateTaskTool(id)
        case .find:
            restoreCancelled = true; restoringReading = false; showFind = true
            scheduleFind(.queryChanged, jump: false)
        }
    }

    /// Resolve the tool against the current projection after the task sheet
    /// dismisses, so navigation never captures a stale row from an old window.
    func locateTaskTool(_ toolID: String) {
        guard let rowID = ChatTaskToolInspector.rowID(for: toolID, in: items),
              let item = items.first(where: { $0.id == rowID }) else {
            showToast("工具记录不在当前已加载的历史中，请刷新后重试")
            return
        }
        var state = cellStates[rowID] ?? ChatCellState()
        state.collapsed = false
        switch item.row.kind {
        case .tools:
            state.toolsExpanded = true
        case .process:
            state.processExpanded = true
            state.toolsExpanded = true
        default: break
        }
        state.expandedToolIDs.insert(toolID)
        cellStates[rowID] = state
        composerFocused = false
        navigate(to: rowID)
    }

    @ViewBuilder
    func panelContent(_ panel: ChatPanel) -> some View {
        switch panel {
        case .drawer:
            SessionListPane(
                mode: .drawer,
                selectedID: sessionID,
                onSelect: { session in
                    // 先关侧栏再切会话，避免两个遮盖层叠在一起。
                    dismissPanel(then: .select(session))
                },
                onNew: {
                    dismissPanel(then: .newSession)
                },
                onSettings: { dismissPanel(then: .settings) },
                onClose: { showDrawer = false }
            )
            .environmentObject(app)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        case .models:
            Group {
                if let catalog = app.modelCatalog {
                    ModelPickerView(
                        catalog: catalog,
                        currentModel: model.sessionModel ?? app.currentSession?.model,
                        currentProvider: model.sessionProvider,
                        busy: app.sessionActionBusy,
                        onPick: { option in
                            guard let option else { return }
                            let token = app.activeChangeToken
                            Task {
                                guard app.activeChangeToken == token,
                                      app.currentSessionID == sessionID else { return }
                                let changed = await app.setModel(option, for: sessionID)
                                guard changed, !Task.isCancelled, app.activeChangeToken == token,
                                      app.currentSessionID == sessionID else { return }
                                model.setConfirmedModel(option.model, provider: option.providerID)
                                // The server has now confirmed this exact model+
                                // provider. Only then may the picker close.
                                if !model.api.supportsReasoningEffort { showModelPicker = false }
                            }
                        },
                        onReload: { await app.loadModels(force: true) },
                        errorMessage: app.sessionActionError,
                        reasoningEffort: model.api.supportsReasoningEffort
                            ? Binding(get: { model.requestedReasoningEffort ?? "" },
                                      set: { model.chooseReasoningEffort($0.isEmpty ? nil : $0) })
                            : nil
                    )
                } else {
                    NavigationStack {
                        ContentUnavailableView {
                            Label("模型目录未就绪", systemImage: "cpu")
                        } description: {
                            Text(app.catalogLoading ? "正在读取…" : "还没读到模型目录，或上次读取失败。")
                        } actions: {
                            Button("重新读取") { Task { await app.loadModels(force: true) } }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { showModelPicker = false }
                            }
                        }
                    }
                }
            }
            .task { await app.loadModels() }
        case .usage:
            ContextUsageView(usage: model.transcript.usage, contextStatus: model.transcript.contextStatus)
        case .queue:
            ChatQueueManager(model: model)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .recovery:
            ChatRecoveryCenter(model: model) { showPanel(.queue) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .navigation:
            ChatNavigationView(
                nodes: ChatTimeline.navigationNodes(
                    messages: model.transcript.messages,
                    tools: model.transcript.tools,
                    notices: model.transcript.notices),
                canLoadOlder: model.olderOffset > 0 && !model.loading && !model.running
                    && !model.reconciling && model.cachedHistoryDate == nil && !model.olderLimitReached,
                onLoadOlder: { await model.loadOlder() },
                onSelect: { id in
                    if cellStates[id]?.collapsed == true { cellStates[id]?.collapsed = false }
                    navigate(to: id)
                },
                onLatest: { goToLatest(animated: true) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .reader(let message):
            messageReaderSheet(message)
        case .attachments(let filter):
            AttachmentOverview(model: model, baseURL: app.api.webConsoleBaseURL,
                sessionID: sessionID, scope: displayScope,
                authorization: app.api.attachmentPreviewAuthorization,
                ratios: imageRatios, onLocate: { attachmentTarget = $0 }, initialFilter: filter)
        case .share(let file):
            ShareSheet(items: [file.url], lifetime: file.lifetime) { setPanel(.share(file), shown: false) }
        case .task:
            ChatTaskPanel(model: model, onQueue: { showPanel(.queue) },
                          onRecovery: { showPanel(.recovery) },
                          onLocateTool: { dismissPanel(then: .locateTool($0)) })
                .presentationDetents([.medium, .large])
        case .info:
            ChatConversationInfo(model: model, title: currentTitle, instance: app.active.name,
                modelLabel: modelLabel, baseURL: app.api.webConsoleBaseURL, sessionID: sessionID,
                scope: displayScope, authorization: app.api.attachmentPreviewAuthorization,
                ratios: imageRatios, canExportFullHistory: canFetchFullExport,
                onPanel: showPanel, onFind: { dismissPanel(then: .find) },
                onExport: { dismissPanel(then: .export(fullHistory: $0)) })
        }
    }

    var taskSummary: ChatTaskSummary {
        let queue = ChatQueueStatus(turns: model.queuedTurns)
        return ChatTaskSummary(activity: model.activity.title, progressing: model.activity.showsProgress,
            queued: queue.waiting, submitting: queue.submitting, uncertain: queue.uncertain,
            needsVerification: model.uncertain || (model.hasPendingSend && !model.submitting) || model.runRecoveryNoticeShown,
            hasError: model.error != nil,
            storageIssue: model.localPersistenceIssue != nil || model.queuePersistenceFailed)
    }

    @ViewBuilder
    var taskSummaryBar: some View {
        let summary = taskSummary
        if summary.needsActionBar && !showsNoticeBar && model.pendingApproval == nil {
            Button { showPanel(.task) } label: {
                HStack(spacing: 8) {
                    Image(systemName: summary.kind == .attention ? "exclamationmark.circle" : "waveform")
                        .foregroundStyle(summary.kind == .attention ? AppTheme.warning : AppTheme.accent)
                    Text(summary.title).font(.caption.weight(.medium)).lineLimit(2)
                    if let detail = summary.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, AppTheme.pageInset)
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开当前会话任务与消息队列")
        }
    }
}
