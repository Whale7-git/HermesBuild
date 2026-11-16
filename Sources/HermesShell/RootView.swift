import SwiftUI

/// Chat-first root shell. The conversation is the canvas; the native Hermes
/// sessions remain available in a left-side drawer without a navigation push.
/// Keeping the chat mounted while the drawer opens avoids the stream/anchor
/// teardown that a modal sheet or NavigationStack pop can cause.
struct RootView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("hermesAppearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarOpen = false
    @GestureState private var sidebarDrag: CGFloat = 0
    // Full-page session browser has its own navigation gesture and a real
    // back destination; do not mistake this for opening the root drawer.
    @State private var browserOpen = false
    @State private var browserSearchRequested = false
    @State private var browserRoute: [UnifiedBrowserPage] = []
    @State private var browserSource: UnifiedBrowserSource = .chat
    @State private var browserSessionOpen = false
    @GestureState private var sessionBackDrag: CGFloat = 0
    @StateObject private var unifiedCenter = UnifiedSessionModel()
    @State private var unifiedQuery = ""
    @State private var unifiedFilter = 0
    private var browserAllInstances: Bool { browserRoute.last == .all }
    private var browserFromSingle: Bool { browserRoute.count > 1 }
    @GestureState private var browserBackDrag: CGFloat = 0
    @State private var homeText = ""
    @State private var homeFocused = false
    @State private var homeSelectedModel: ModelOption?
    @State private var homeModelPickerOpen = false
    /// Retain the departing store across an instance switch long enough to
    /// flush its last un-debounced keystrokes to the correct account scope.
    @State private var boundHomeDraft: (scope: String, store: ChatDraftStore)?

    private var homeScope: String { app.historyInstanceID + "|" + app.historyAccountScope }

    private var homeDraftStore: ChatDraftStore {
        let instanceID = app.historyInstanceID
        let accountScope = app.historyAccountScope
        let id = "__home-composer__"
        return ChatDraftStore(instanceID: instanceID, accountScope: accountScope,
            sessionID: id, fileStore: LocalDataFileStore(
                instanceID: instanceID, accountScope: accountScope, sessionID: id))
    }

    /// Root-side interactive card reveal. Keep the chat mounted during gestures.
    private func drawerWidth(_ width: CGFloat) -> CGFloat { min(340, width * 0.86) }

    private func reveal(width: CGFloat) -> CGFloat {
        CGFloat(ChatDrawerInteraction.reveal(width: Double(drawerWidth(width)),
                                              open: sidebarOpen, translation: Double(sidebarDrag)))
    }

    var body: some View {
        content
            .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
            .overlay {
                if scenePhase != .active {
                    AppTheme.canvas
                        .ignoresSafeArea()
                        .overlay {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                }
            }
            .animation(nil, value: scenePhase)
            .onChange(of: scenePhase) { _, _ in
                synchronizeConversationVisibility()
            }
            .onChange(of: sidebarOpen) { _, _ in
                synchronizeConversationVisibility()
            }
            .onChange(of: browserOpen) { _, _ in
                synchronizeConversationVisibility()
            }
            .onChange(of: app.showSettings) { _, _ in
                synchronizeConversationVisibility()
            }
            .onChange(of: app.needsLogin) { _, _ in
                synchronizeConversationVisibility()
            }
            .onChange(of: app.currentSessionID) { _, _ in
                synchronizeConversationVisibility()
            }
            .onAppear { synchronizeConversationVisibility() }
    }

    private var content: some View {
        GeometryReader { geometry in
            let width = drawerWidth(geometry.size.width)
            let exposed = reveal(width: geometry.size.width)
            let progress = width > 0 ? exposed / width : 0
            let topInset = geometry.safeAreaInsets.top
            let bottomInset = geometry.safeAreaInsets.bottom
            let fullHeight = geometry.size.height + topInset + bottomInset
            let style = ChatCardPresentation.style(progress: Double(progress),
                                                     reduceMotion: reduceMotion)

            // Unlike build151, the moving page includes its status-bar and
            // home-indicator backgrounds using one shared card container.
            // Only its interior content is padded into the safe area.
            ZStack(alignment: .leading) {
                SessionListPane(
                    mode: .drawer,
                    selectedID: app.currentSessionID,
                    onSelect: { session in
                        closeSidebar()
                        app.openSession(session)
                    },
                    onNew: {
                        closeSidebar()
                        startConversation()
                    },
                    onSettings: {
                        closeSidebar()
                        app.showSettings = true
                    },
                    onClose: closeSidebar,
                    onBrowseAll: {
                        browserSource = .drawer
                        browserRoute = [.single]
                        browserSearchRequested = false
                        browserSessionOpen = false
                        browserOpen = true
                    },
                    onBrowseAllInstances: {
                        browserSource = .drawer
                        browserRoute = [.all]
                        browserSearchRequested = false
                        browserSessionOpen = false
                        browserOpen = true
                    }
                )
                .environmentObject(app)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(width: width, height: fullHeight)
                .background(AppTheme.softFill)
                .offset(x: CGFloat(style.drawerParallax))
                .opacity(exposed > 0 ? 1 : 0)
                .allowsHitTesting(sidebarOpen || exposed > 0)
                .accessibilityHidden(!sidebarOpen)

                chatCardLayer(size: geometry.size, topInset: topInset, bottomInset: bottomInset,
                              progress: progress, exposed: exposed)
                precedingBrowserLayer(size: geometry.size, topInset: topInset, bottomInset: bottomInset)
                activeBrowserLayer(size: geometry.size, topInset: topInset, bottomInset: bottomInset)
            }
            .frame(width: geometry.size.width, height: fullHeight,
                   alignment: .leading)
            .background(AppTheme.softFill)
            .offset(y: -topInset)
            // Prevent vertical scrolling/text selection from triggering a
            // horizontal navigation. The open drawer's host picker also
            // retains exclusive control of its own horizontal gestures.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .updating($sidebarDrag) { value, state, _ in
                        guard !browserOpen else { return }
                        guard ChatDrawerInteraction.shouldTrack(
                            startX: Double(value.startLocation.x),
                            translationX: Double(value.translation.width),
                            translationY: Double(value.translation.height),
                            open: sidebarOpen, width: Double(width)) else { return }
                        state = sidebarOpen ? min(0, value.translation.width)
                                            : max(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard !browserOpen else { return }
                        guard ChatDrawerInteraction.shouldTrack(
                            startX: Double(value.startLocation.x),
                            translationX: Double(value.translation.width),
                            translationY: Double(value.translation.height),
                            open: sidebarOpen, width: Double(width)) else { return }
                        let shouldOpen = ChatDrawerInteraction.finishOpen(
                            width: Double(width), wasOpen: sidebarOpen,
                            predictedTranslation: Double(value.predictedEndTranslation.width))
                        if shouldOpen && !sidebarOpen { openSidebar() }
                        else if !shouldOpen && sidebarOpen { closeSidebar() }
                    }
            )
        }
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.34,
                                                            dampingFraction: 0.88),
                   value: sidebarOpen)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.36,
                                                            dampingFraction: 0.9),
                   value: browserOpen)
        .onChange(of: app.activeChangeToken) { _, _ in
            // Keep the drawer visible when selecting another Hermes host: the
            // user still has to pick a native Session from that host. Account
            // login remains a sheet and must hide the previously opened drawer.
            if app.needsLogin {
                closeSidebar()
                browserOpen = false
                browserSessionOpen = false
                browserRoute = []
            } else {
                openPendingNotificationTarget()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            openPendingNotificationTarget()
        }
        .onAppear { openPendingNotificationTarget() }
        .onReceive(NotificationCenter.default.publisher(for: GatewayBackend.runsChanged)) { event in
            guard let backend = event.object as? GatewayBackend, backend === app.api else { return }
            Task { await app.refresh() }
        }
        .onChange(of: app.sessions.map(\.sessionId)) { _, _ in openPendingNotificationTarget() }
        .onChange(of: app.sessions) { _, updated in
            guard app.hasLoadedSessions else { return }
            let endpoint = app.historyInstanceID
            let identity = UnifiedSessionIdentity(
                instanceID: app.active.id, endpointIdentity: endpoint,
                accountScope: app.historyAccountScope)
            unifiedCenter.adoptActiveList(
                identity: identity, instanceName: app.active.name,
                rows: updated, refreshedAt: app.lastSessionRefresh)
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationNavigation.changed)) { _ in
            openPendingNotificationTarget()
        }
        .sheet(isPresented: Binding(
            get: { app.needsLogin || app.showSettings },
            set: { shown in
                if !shown { app.needsLogin = false; app.showSettings = false }
            }
        )) {
            if app.needsLogin { LoginView().environmentObject(app) }
            else { SettingsView().environmentObject(app) }
        }
        .task {
            Task.detached(priority: .utility) { AttachmentDownloadFiles.purge() }
            await app.refresh()
            openPendingNotificationTarget()
        }
    }

    /// The home screen is a draft workspace, never a server Session until
    /// the user explicitly sends or requests an attachment-capable chat.


    /// Compiler-isolated layers: keep the conversation mounted when a Session
    /// browser is presented, while the card itself remains the swipe surface.
    private func chatCardLayer(size: CGSize, topInset: CGFloat, bottomInset: CGFloat,
                               progress: CGFloat, exposed: CGFloat) -> some View {
    ChatCardContainer(
        size: size, topInset: topInset, bottomInset: bottomInset,
        progress: browserSessionOpen
            ? min(1, max(0, sessionBackDrag / max(1, size.width)))
            : progress,
        translation: browserSessionOpen ? sessionBackDrag : exposed,
        reduceMotion: reduceMotion,
        showsDismissSurface: sidebarOpen && !browserSessionOpen,
        onDismiss: closeSidebar
    ) {
        Group {
            if let sessionID = app.currentSessionID {
                chatDestination(ChatRoute(sessionID: sessionID))
            } else {
                emptyConversation
            }
        }
        .accessibilityHidden(sidebarOpen && !browserSessionOpen)
    }
    .zIndex(browserSessionOpen ? 3 : 0)
    .simultaneousGesture(
        DragGesture(minimumDistance: 26)
            .updating($sessionBackDrag) { value, drag, _ in
                guard browserOpen && browserSessionOpen,
                      ChatPageBackInteraction.shouldTrack(
                          startX: Double(value.startLocation.x),
                          horizontal: Double(value.translation.width),
                          vertical: Double(value.translation.height),
                          allowFullCard: true) else { return }
                drag = max(0, value.translation.width)
            }
            .onEnded { value in
                guard browserOpen && browserSessionOpen,
                      ChatPageBackInteraction.shouldTrack(
                          startX: Double(value.startLocation.x),
                          horizontal: Double(value.translation.width),
                          vertical: Double(value.translation.height),
                          allowFullCard: true) else { return }
                if ChatPageBackInteraction.shouldDismiss(
                    width: Double(size.width),
                    predictedTranslation: Double(value.predictedEndTranslation.width)) {
                    browserSessionOpen = false
                    if browserSource == .drawer { sidebarOpen = true }
                }
            }
    )
    }

    @ViewBuilder
    private func precedingBrowserLayer(size: CGSize, topInset: CGFloat,
                                       bottomInset: CGFloat) -> some View {
    if browserOpen && browserAllInstances && browserFromSingle {
        ChatCardContainer(
            size: size, topInset: topInset, bottomInset: bottomInset,
            progress: 0, translation: 0, reduceMotion: reduceMotion,
            showsDismissSurface: false, onDismiss: {}
        ) {
            singleInstanceBrowser
        }
        .zIndex(1)
    }
    }

    @ViewBuilder
    private func activeBrowserLayer(size: CGSize, topInset: CGFloat,
                                    bottomInset: CGFloat) -> some View {
    if browserOpen {
        let backProgress = min(1, max(0,
            browserBackDrag / max(1, size.width)))
        ChatCardContainer(
            size: size, topInset: topInset, bottomInset: bottomInset,
            progress: backProgress, translation: browserBackDrag,
            reduceMotion: reduceMotion,
            showsDismissSurface: false,
            onDismiss: {}
        ) {
            if browserAllInstances {
                UnifiedSessionBrowser(
                    center: unifiedCenter,
                    query: $unifiedQuery,
                    filter: $unifiedFilter,
                    onClose: backFromBrowser,
                    backToSingleInstance: browserFromSingle,
                    backToDrawer: browserSource == .drawer && !browserFromSingle,
                    onSingleInstance: {
                        browserRoute = [.single]
                    },
                    onSelect: { record in
                        let opened = app.openSessionFromInstance(
                            instanceID: record.identity.instanceID,
                            endpointIdentity: record.identity.endpointIdentity,
                            accountScope: record.identity.accountScope,
                            session: record.session)
                        if opened {
                            sidebarOpen = false
                            browserSessionOpen = true
                        }
                        return opened
                    }
                )
                .environmentObject(app)
            } else {
                singleInstanceBrowser
            }
        }
        .transition(.move(edge: .trailing))
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .updating($browserBackDrag) { value, drag, _ in
                    guard ChatPageBackInteraction.shouldTrack(
                        startX: Double(value.startLocation.x),
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height),
                        allowFullCard: true) else { return }
                    drag = max(0, value.translation.width)
                }
                .onEnded { value in
                    guard ChatPageBackInteraction.shouldTrack(
                        startX: Double(value.startLocation.x),
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height),
                        allowFullCard: true) else { return }
                    if ChatPageBackInteraction.shouldDismiss(
                        width: Double(size.width),
                        predictedTranslation: Double(value.predictedEndTranslation.width)) {
                        backFromBrowser()
                    }
                }
        )
        .zIndex(2)
    }
    }

    /// Keep a real page stack: pop the visible page. The original
    /// drawer stays mounted and remains the destination of a direct entry.
    private func backFromBrowser() {
        guard !browserRoute.isEmpty else { return }
        switch UnifiedBrowserBackNavigation.destination(
            route: browserRoute, source: browserSource) {
        case .singleInstance:
            browserRoute.removeLast()
        case .chat, .drawer:
            browserRoute = []
            browserOpen = false
            browserSessionOpen = false
            if browserSource == .drawer { sidebarOpen = true }
        }
    }

    private var singleInstanceBrowser: some View {
        SessionListPane(
            mode: .page,
            selectedID: app.currentSessionID,
            onSelect: { session in
                sidebarOpen = false
                app.openSession(session)
                browserSessionOpen = true
            },
            onNew: {
                browserOpen = false
                browserSessionOpen = false
                startConversation()
            },
            onSettings: {
                browserOpen = false
                browserSessionOpen = false
                app.showSettings = true
            },
            onClose: backFromBrowser,
            onBrowseAllInstances: {
                if browserRoute.last != .all { browserRoute.append(.all) }
            },
            startSearching: browserSearchRequested
        )
        .environmentObject(app)
    }

    private var emptyConversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: openSidebar) { ChromeIcon(symbol: "line.3.horizontal") }
                    .accessibilityLabel("打开会话侧栏")
                // One compact title/instance control instead of two
                // competing headings across the top navigation bar.
                Menu {
                    ForEach(Array(app.instances.enumerated()), id: \.element.id) { index, instance in
                        Button {
                            guard index != app.activeIndex else { return }
                            app.switchTo(index)
                        } label: {
                            if index == app.activeIndex {
                                Label(instance.name, systemImage: "checkmark")
                            } else { Text(instance.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Hermes").font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(app.active.name).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Image(systemName: "chevron.down").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 156, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("切换 Hermes 实例，当前\(app.active.name)")
                Spacer(minLength: 6)
                Button {
                    homeFocused = false
                    browserSearchRequested = true
                    browserSource = .chat
                    browserRoute = app.instances.count > 1 ? [.all] : [.single]
                    browserSessionOpen = false
                    browserOpen = true
                } label: { ChromeIcon(symbol: "magnifyingglass") }
                .accessibilityLabel("搜索会话")
                Button {
                    homeFocused = true
                } label: { ChromeIcon(symbol: "square.and.pencil") }
                .accessibilityLabel("输入新消息")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 56)

            Spacer(minLength: 24)
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 29, weight: .light))
                Text(app.needsInstanceSetup ? "连接 Hermes" : "有什么可以帮你？")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)
                if app.needsInstanceSetup {
                    Text("请先在设置中配置网关或 WebUI 连接。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 330)
            Spacer(minLength: 24)

            if app.needsInstanceSetup {
                Button("配置连接", systemImage: "gearshape") { app.showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.action)
                    .frame(minHeight: 48)
                    .padding(.horizontal, 24)
            } else {
                let composerScope = homeScope
                HomeConversationComposer(
                    text: $homeText, focused: $homeFocused,
                    isCurrentScope: {
                        composerScope == app.historyInstanceID + "|" + app.historyAccountScope
                    },
                    draftStore: homeDraftStore,
                    modelLabel: homeSelectedModel?.label ?? "默认模型",
                    creating: app.creating, needsSetup: app.needsInstanceSetup,
                    onSubmit: { transferHomeDraft(sendImmediately: true) },
                    onChooseModel: {
                        homeFocused = false
                        homeModelPickerOpen = true
                    },
                    onAttach: {
                        // Transfer any typed text WITHOUT posting it. The
                        // normal composer in the new session then owns the
                        // draft and attachment selection together.
                        transferHomeDraft(sendImmediately: false)
                    }
                )
                .id(composerScope)
                if let error = app.homeSendError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .padding(.horizontal, 22)
                        .accessibilityIdentifier("home-send-error")
                }
            }
            // This MUST NOT be a Spacer. A third flexible Spacer below
            // the composer was consuming a large portion of screen height,
            // placing the input card hundreds of points above the home edge.
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.canvas)
        .onAppear(perform: restoreHomeDraft)
        .onChange(of: homeScope) { _, _ in restoreHomeDraft() }
        .sheet(isPresented: $homeModelPickerOpen) {
            Group {
                if let catalog = app.modelCatalog {
                    ModelPickerView(
                        catalog: catalog,
                        currentModel: homeSelectedModel?.model,
                        currentProvider: homeSelectedModel?.providerID,
                        busy: app.creating,
                        onPick: { homeSelectedModel = $0 },
                        onReload: { await app.loadModels(force: true) })
                } else {
                    NavigationStack {
                        ContentUnavailableView {
                            Label("模型目录未就绪", systemImage: "cpu")
                        } description: {
                            Text(app.catalogLoading ? "正在读取模型…" : "尚未获取模型目录。")
                        } actions: {
                            Button("重新读取") { Task { await app.loadModels(force: true) } }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { homeModelPickerOpen = false }
                            }
                        }
                    }
                }
            }
            .task { await app.loadModels() }
        }
    }

    private func restoreHomeDraft() {
        let scope = homeScope
        guard boundHomeDraft?.scope != scope else { return }
        if let previous = boundHomeDraft {
            _ = previous.store.save(homeText)
            homeFocused = false
        }
        homeSelectedModel = nil
        let current = homeDraftStore
        boundHomeDraft = (scope: scope, store: current)
        homeText = current.load()
    }

    private func transferHomeDraft(sendImmediately: Bool) {
        let text = homeText
        let model = homeSelectedModel
        let scope = homeScope
        homeFocused = false
        Task {
            let accepted = await app.createSessionForHomeTurn(
                text, model: model, sendImmediately: sendImmediately)
            guard accepted, scope == homeScope else { return }
            // Do not destroy text newly typed after the original submission.
            // The matching text already lives in the created Session's draft.
            if homeText == text {
                homeText = ""
                _ = homeDraftStore.save("")
            }
        }
    }

    private func startConversation() {
        if app.needsInstanceSetup { app.showSettings = true; return }
        // "New chat" navigates to a draft workspace. It must not create an
        // empty remote session until the user sends or attaches a file.
        app.closeSession()
        homeFocused = true
    }

    private func openSidebar() {
        guard !browserOpen else { return }
        sidebarOpen = true
    }
    private func closeSidebar() { sidebarOpen = false }

    /// Planner suppression is only valid for an active app whose chat page is
    /// unobscured. A backgrounded app keeps the same `currentSessionID`, but
    /// that must not hide the notification the user needs when returning.
    private func synchronizeConversationVisibility() {
        let visible = scenePhase == .active
            && !sidebarOpen && !browserOpen
            && !app.showSettings && !app.needsLogin
            && app.currentSessionID != nil
        app.setPresentationVisibility(
            appActive: scenePhase == .active,
            conversationVisible: visible)
    }

    /// Notification navigation is still scoped to the active backend. A stale
    /// or deleted target must not open an unrelated instance's conversation.
    private func openPendingNotificationTarget() {
        guard let target = NotificationNavigation.shared.pendingTarget else { return }
        // A bare session ID can collide across Hermes hosts. Never open a
        // legacy unscoped notification against whichever host is active.
        guard target.isScoped else {
            _ = NotificationNavigation.shared.consume(target: target)
            return
        }
        guard let index = app.instances.firstIndex(where: {
            ChatHistoryIdentity.instanceID(id: $0.id, baseURL: $0.baseURL) == target.instanceID
        }), ChatHistoryIdentity.accountScope(instanceID: target.instanceID) == target.accountScope else {
            _ = NotificationNavigation.shared.consume(target: target)
            return
        }
        if app.activeIndex != index {
            // Switch first, then let the normal sessions-change callback open
            // the target after the selected account's list has been restored.
            app.switchTo(index)
            return
        }
        guard app.historyAccountScope == target.accountScope else {
            _ = NotificationNavigation.shared.consume(target: target)
            return
        }
        guard let session = app.sessions.first(where: { $0.sessionId == target.sessionID }) else {
            RuntimeLogRecorder.shared.record(.info, "notify", "navigation target missing session in scope")
            return
        }
        guard NotificationNavigation.shared.consume(target: target) else { return }
        closeSidebar()
        browserOpen = false
        browserSessionOpen = false
        browserRoute = []
        app.openSession(session)
    }

    private func chatDestination(_ route: ChatRoute) -> some View {
        let title = app.currentSession?.displayTitle ?? "会话"
        return NativeChatView(
            sessionID: route.sessionID,
            title: title,
            api: app.api,
            instanceID: app.historyInstanceID,
            accountScope: app.historyAccountScope,
            readingStore: ChatReadingPositionStore(instanceID: app.historyInstanceID,
                accountScope: app.historyAccountScope, sessionID: route.sessionID),
            historyStore: ChatHistoryStore(
                instanceID: app.historyInstanceID,
                sessionID: route.sessionID,
                accountScope: app.historyAccountScope,
                report: { report in
                    guard let failure = report.failure else { return }
                    Task { @MainActor in
                        RuntimeLogRecorder.shared.recordApp(
                            .warning, "history-cache",
                            "cache write failed reason=\(failure.rawValue)")
                    }
                }
            ),
            onOpenSidebar: openSidebar
        )
        .modifier(ChatLogScope(instanceID: app.historyInstanceID,
            accountScope: app.historyAccountScope, sessionID: route.sessionID, title: title))
        .id(route.scope + ":" + route.sessionID)
    }
}

/// Each mounted conversation owns its token. Session switches and identity
/// changes close the previous log scope before opening the new one.
private struct ChatLogScope: ViewModifier {
    let instanceID: String
    let accountScope: String
    let sessionID: String
    let title: String
    @State private var token: RuntimeLogToken?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token == nil else { return }
                token = RuntimeLogRecorder.shared.beginScope(instanceID: instanceID,
                    accountScope: accountScope, sessionID: sessionID, label: title)
            }
            .onDisappear {
                guard let closing = token else { return }
                token = nil
                RuntimeLogRecorder.shared.endScope(closing)
            }
    }
}
