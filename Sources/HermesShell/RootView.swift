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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sidebarOpen = false
    @GestureState private var sidebarGesture = ChatDrawerGestureState()
    @State private var foregroundListPolicy = ForegroundListRefreshPolicy()
    @State private var drawerGestureOwner = RootDrawerGestureOwnership()
    @State private var sessionBackOwner = RootPageGestureOwnership()
    @State private var browserBackOwner = RootPageGestureOwnership()
    // Full-page session browser has its own navigation gesture and a real
    // back destination; do not mistake this for opening the root drawer.
    @State private var browserOpen = false
    @State private var browserSearchRequested = false
    @State private var browserRoute: [UnifiedBrowserPage] = []
    @State private var browserSource: UnifiedBrowserSource = .chat
    @State private var browserSessionOpen = false
    private enum PageReturnTarget: Equatable { case chat, browser }
    // Persist interactive offset past GestureState reset and keep the
    // outgoing top card mounted until its settling animation ends.
    @State private var settlingPage: PageReturnTarget?
    @State private var pageReturnOffset: CGFloat = 0
    @State private var pageReturnTicket = UUID()
    /// The sheet belongs to the root, not to a horizontally moving page.
    @State private var taskCenterPresented = false
    @State private var taskCenterScope: String?
    @State private var pendingTaskSheetSelection: (scope: String, sessionID: String)?
    @GestureState private var sessionBackDrag = RootPageGestureState()
    @StateObject private var unifiedCenter = UnifiedSessionModel()
    @State private var unifiedQuery = ""
    // Task search belongs to the browser navigation owner, not its
    // conditional SwiftUI page, so returning from a chat keeps the filter.
    @State private var unifiedTaskQuery = ""
    @State private var unifiedSessionScrollAnchor: String?
    @State private var unifiedTaskScrollAnchor: String?
    @State private var unifiedSessionScrollIndex = 0
    @State private var unifiedTaskScrollIndex = 0
    @State private var unifiedFilter = 0
    @State private var unifiedSection = 0
    private var browserAllInstances: Bool { browserRoute.last == .all }
    private var browserFromSingle: Bool { browserRoute.count > 1 }
    private var navigationGesturesAllowed: Bool {
        RootNavigationModalPolicy.allowsGesture(taskCenterPresented: taskCenterPresented,
            settingsPresented: app.showSettings, needsLogin: app.needsLogin)
            && scenePhase == .active && settlingPage == nil
    }
    @GestureState private var browserBackDrag = RootPageGestureState()
    @State private var homeText = ""
    @State private var homeFocused = false
    @State private var homeSelectedModel: ModelOption?
    @State private var homeModelPickerOpen = false
    /// Retain the departing store across an instance switch long enough to
    /// flush its last un-debounced keystrokes to the correct account scope.
    @State private var boundHomeDraft: (scope: String, store: ChatDraftStore)?

    private var homeScope: String { app.historyInstanceID + "|" + app.historyAccountScope }

    /// Account retirement, endpoint edits and instance removal invalidate
    /// global browser bookmarks; ordinary active-instance switching does not.
    private var unifiedBrowseIdentity: String {
        app.instances.map { instance in
            let endpoint = ChatHistoryIdentity.instanceID(id: instance.id,
                                                          baseURL: instance.baseURL)
            let account = ChatHistoryIdentity.accountScope(instanceID: endpoint)
            return [instance.id.uuidString, endpoint, account]
                .map { "\($0.utf8.count):\($0)" }.joined()
        }.joined(separator: "|")
    }

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
                                              open: sidebarOpen, translation: sidebarGesture.translation))
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
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelNavigationGestures() }
                synchronizeConversationVisibility()
            }
            .onChange(of: sidebarOpen) { _, _ in
                drawerGestureOwner.cancelled()
                synchronizeConversationVisibility()
            }
            .onChange(of: browserOpen) { _, _ in
                cancelNavigationGestures()
                synchronizeConversationVisibility()
            }
            .onChange(of: browserSessionOpen) { _, _ in
                cancelNavigationGestures()
                synchronizeConversationVisibility()
            }
            .onChange(of: taskCenterPresented) { _, _ in
                cancelNavigationGestures()
                synchronizeConversationVisibility()
            }
            .onChange(of: app.showSettings) { _, shown in
                if shown {
                    cancelNavigationGestures()
                    taskCenterPresented = false
                }
                synchronizeConversationVisibility()
            }
            .onChange(of: app.needsLogin) { _, shown in
                if shown {
                    cancelNavigationGestures()
                    taskCenterPresented = false
                }
                synchronizeConversationVisibility()
            }
            .onChange(of: unifiedBrowseIdentity) { _, _ in
                unifiedQuery = ""
                unifiedTaskQuery = ""
                unifiedFilter = 0
                unifiedSessionScrollAnchor = nil
                unifiedTaskScrollAnchor = nil
                unifiedSessionScrollIndex = 0
                unifiedTaskScrollIndex = 0
                unifiedCenter.cancel()
            }
            .onChange(of: homeScope) { _, _ in
                // A token/account change can invalidate a task-sheet identity
                // even without an explicit instance-switch button.
                if taskCenterPresented { taskCenterPresented = false }
                cancelNavigationGestures()
            }
            .onChange(of: app.currentSessionID) { _, current in
                cancelNavigationGestures()
                // A chat opened from the browser can create a new draft via
                // its own toolbar. Closing the session must also retire the
                // browser route; otherwise the empty composer inherits an
                // unrelated old session-list back stack.
                if UnifiedBrowserPresentation.shouldRetireBrowserForNewDraft(
                    browserOpen: browserOpen, browserSessionOpen: browserSessionOpen,
                    currentSessionID: current) {
                    browserSessionOpen = false
                    browserOpen = false
                    browserRoute = []
                }
                synchronizeConversationVisibility()
            }
            .onAppear { synchronizeConversationVisibility() }
            .onDisappear { cancelNavigationGestures() }
            .sheet(isPresented: $taskCenterPresented, onDismiss: {
                // Never move the underlying page during the sheet's native
                // dismissal animation. Apply navigation only after it finishes.
                let pending = pendingTaskSheetSelection
                pendingTaskSheetSelection = nil
                taskCenterScope = nil
                cancelNavigationGestures()
                if let pending,
                   RootTaskSheetNavigation.canOpen(
                       pendingScope: pending.scope, currentScope: homeScope,
                       sessionAvailable: app.sessions.contains(where: {
                           $0.sessionId == pending.sessionID
                       })),
                   let session = app.sessions.first(where: {
                       $0.sessionId == pending.sessionID
                   }) {
                    browserSessionOpen = false
                    browserOpen = false
                    browserRoute = []
                    sidebarOpen = false
                    app.openSession(session)
                }
            }) {
                SessionTaskCenterView(
                    sessions: app.sessions,
                    summaries: app.visibleTaskSummaries,
                    acknowledgements: app.acknowledgedTaskEntries,
                    onSelect: { session in
                        guard taskCenterScope == homeScope,
                              app.sessions.contains(where: {
                                  $0.sessionId == session.sessionId
                              }) else {
                            taskCenterPresented = false
                            return
                        }
                        pendingTaskSheetSelection = (
                            scope: homeScope, sessionID: session.sessionId)
                        taskCenterPresented = false
                    },
                    onAcknowledge: { sessionID, signal in
                        guard taskCenterScope == homeScope else { return }
                        app.acknowledgeTask(sessionID: sessionID, signal: signal)
                    },
                    onUndo: { acknowledgement in
                        guard taskCenterScope == homeScope else { return }
                        app.undoTaskAcknowledgement(acknowledgement)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(AppTheme.radiusSheet)
            }
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
                if sidebarOpen || exposed > 0.5 {
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
                        unifiedSection = 0
                        browserSearchRequested = false
                        browserSessionOpen = false
                        browserOpen = true
                    },
                    onBrowseAllTasks: {
                        browserSource = .drawer
                        browserRoute = [.all]
                        unifiedSection = 1
                        browserSearchRequested = false
                        browserSessionOpen = false
                        browserOpen = true
                    },
                    onShowTaskCenter: presentTaskCenter
                )
                .environmentObject(app)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(width: width, height: fullHeight)
                .background(AppTheme.softFill)
                .offset(x: CGFloat(style.drawerParallax))
                // Keep the drawer mounted behind the fully opaque chat canvas.
                // Flipping opacity/hit-testing at exposed == 0 introduced a
                // compositing and gesture hit-map discontinuity on left return.
                .opacity(exposed > 0.5 && !browserOpen ? 1 : 0)
                .allowsHitTesting(sidebarOpen && !browserOpen && settlingPage == nil)
                // The permanently mounted covered drawer must not contribute
                // text to accessibility scans of the active chat/home card.
                // In addition to hiding the covered drawer, omit its AX
                // descendants. opacity(0) and accessibilityHidden alone were
                // insufficient for Xcode's Dynamic Type screen audit.
                .accessibilityElement(children: exposed <= 0.5 || browserOpen
                    ? .ignore : .contain)
                .accessibilityHidden(exposed <= 0.5 || browserOpen)
                }
                // The collapsed drawer has no rendered descendants. Keeping
                // an opaque, hidden list mounted still exposed its text to
                // XCTest's Dynamic Type visual audit. AppState still owns
                // the session data; the pane is rebuilt on next reveal.

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
                DragGesture(minimumDistance: 14)
                    .updating($sidebarGesture) { value, state, _ in
                        guard navigationGesturesAllowed, !browserOpen else { return }
                        state.update(
                            startX: Double(value.startLocation.x),
                            horizontal: Double(value.translation.width),
                            vertical: Double(value.translation.height),
                            open: sidebarOpen, width: Double(width),
                            allowFullCard: false)
                    }
                    .onChanged { value in
                        guard navigationGesturesAllowed, !browserOpen, !browserSessionOpen else {
                            drawerGestureOwner.cancelled()
                            return
                        }
                        drawerGestureOwner.changed(
                            open: sidebarOpen,
                            startX: Double(value.startLocation.x),
                            horizontal: Double(value.translation.width),
                            vertical: Double(value.translation.height),
                            width: Double(width))
                    }
                    .onEnded { value in
                        guard navigationGesturesAllowed, !browserOpen, !browserSessionOpen else {
                            drawerGestureOwner.cancelled()
                            return
                        }
                        guard let shouldOpen = drawerGestureOwner.ended(
                            open: sidebarOpen, width: Double(width),
                            predictedTranslation: Double(value.predictedEndTranslation.width))
                        else { return }
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
            cancelNavigationGestures()
            // Retire the old host/account sheet on any instance change.
            if taskCenterPresented { taskCenterPresented = false }
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
        .onChange(of: scenePhase) { oldPhase, phase in
            guard phase == .active else { return }
            openPendingNotificationTarget()
            // The chat can stay mounted while its host's collection ages in
            // background. Refresh the collection without replacing the chat,
            // draft, search filters or scroll bookmarks.
            let scope = homeScope
            guard !app.needsLogin, !app.needsInstanceSetup,
                  foregroundListPolicy.shouldRefresh(
                      wasActive: oldPhase == .active, isActive: true, scope: scope,
                      lastSuccess: app.lastSessionRefresh) else { return }
            Task { @MainActor in
                guard scope == homeScope, scenePhase == .active else { return }
                await app.refresh()
            }
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
    let sessionOffset = settlingPage == .chat
        ? pageReturnOffset : CGFloat(ChatPageBackInteraction.offset(
            width: Double(size.width), translation: sessionBackDrag.translation))
    return ChatCardContainer(
        size: size, topInset: topInset, bottomInset: bottomInset,
        progress: browserSessionOpen
            ? min(1, max(0, sessionOffset / max(1, size.width)))
            : progress,
        translation: browserSessionOpen ? sessionOffset : exposed,
        reduceMotion: reduceMotion,
        showsDismissSurface: sidebarOpen && !browserSessionOpen,
        suppressVerticalScroll: browserSessionOpen
            ? (sessionBackDrag.claimed || settlingPage == .chat)
            : (!browserOpen && sidebarGesture.claimed),
        onDismiss: closeSidebar
    ) {
        Group {
            if let sessionID = app.currentSessionID {
                chatDestination(ChatRoute(sessionID: sessionID))
            } else {
                emptyConversation
            }
        }
        .accessibilityHidden((sidebarOpen || browserOpen) && !browserSessionOpen)
    }
    .zIndex(browserSessionOpen ? 3 : 0)
    .allowsHitTesting(settlingPage == nil && (!browserOpen || browserSessionOpen))
    .simultaneousGesture(
        DragGesture(minimumDistance: 26)
            .updating($sessionBackDrag) { value, drag, _ in
                guard navigationGesturesAllowed, browserOpen && browserSessionOpen else { return }
                drag.update(
                    startX: Double(value.startLocation.x),
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height))
            }
            .onChanged { value in
                guard navigationGesturesAllowed, browserOpen && browserSessionOpen else {
                    sessionBackOwner.cancelled()
                    return
                }
                sessionBackOwner.changed(
                    startX: Double(value.startLocation.x),
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height))
            }
            .onEnded { value in
                guard navigationGesturesAllowed, browserOpen && browserSessionOpen else {
                    sessionBackOwner.cancelled()
                    return
                }
                let claimed = sessionBackOwner.claimed
                let shouldReturn = sessionBackOwner.ended(
                    width: Double(size.width),
                    predictedTranslation: Double(value.predictedEndTranslation.width))
                if claimed {
                    settlePageReturn(.chat, width: size.width,
                                     translation: value.translation.width,
                                     shouldReturn: shouldReturn)
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
        // The previous browser is only a visual background; the top route
        // alone receives hit testing and accessibility focus during a pan.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    }

    @ViewBuilder
    private func activeBrowserLayer(size: CGSize, topInset: CGFloat,
                                    bottomInset: CGFloat) -> some View {
    if browserOpen {
        let browserOffset = settlingPage == .browser
            ? pageReturnOffset : CGFloat(ChatPageBackInteraction.offset(
                width: Double(size.width), translation: browserBackDrag.translation))
        let backProgress = min(1, max(0, browserOffset / max(1, size.width)))
        ChatCardContainer(
            size: size, topInset: topInset, bottomInset: bottomInset,
            progress: backProgress, translation: browserOffset,
            reduceMotion: reduceMotion,
            showsDismissSurface: false,
            suppressVerticalScroll: browserBackDrag.claimed || settlingPage == .browser,
            onDismiss: {}
        ) {
            if browserAllInstances {
                UnifiedSessionBrowser(
                    center: unifiedCenter,
                    query: $unifiedQuery,
                    taskSearch: $unifiedTaskQuery,
                    sessionScrollAnchor: $unifiedSessionScrollAnchor,
                    taskScrollAnchor: $unifiedTaskScrollAnchor,
                    sessionScrollIndex: $unifiedSessionScrollIndex,
                    taskScrollIndex: $unifiedTaskScrollIndex,
                    filter: $unifiedFilter,
                    section: $unifiedSection,
                    onClose: backFromBrowser,
                    backToSingleInstance: browserFromSingle,
                    backToDrawer: browserSource == .drawer && !browserFromSingle,
                    onSingleInstance: {
                        browserRoute = [.single]
                    },
                    onOpenCurrentTaskCenter: presentTaskCenter,
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
                    guard navigationGesturesAllowed, browserOpen && !browserSessionOpen else { return }
                    drag.update(
                        startX: Double(value.startLocation.x),
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height))
                }
                .onChanged { value in
                    guard navigationGesturesAllowed, browserOpen && !browserSessionOpen else {
                        browserBackOwner.cancelled()
                        return
                    }
                    browserBackOwner.changed(
                        startX: Double(value.startLocation.x),
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height))
                }
                .onEnded { value in
                    guard navigationGesturesAllowed, browserOpen && !browserSessionOpen else {
                        browserBackOwner.cancelled()
                        return
                    }
                    let claimed = browserBackOwner.claimed
                    let shouldReturn = browserBackOwner.ended(
                        width: Double(size.width),
                        predictedTranslation: Double(value.predictedEndTranslation.width))
                    if claimed {
                        settlePageReturn(.browser, width: size.width,
                                         translation: value.translation.width,
                                         shouldReturn: shouldReturn)
                    }
                }
        )
        .zIndex(2)
        .allowsHitTesting(!browserSessionOpen && settlingPage == nil)
        .accessibilityHidden(browserSessionOpen)
    }
    }

    /// Hold z-order and route identity constant for the whole gesture
    /// completion (including cancellation). Underlying content remains
    /// mounted and never receives the in-flight tap/scroll.
    private func settlePageReturn(_ target: PageReturnTarget, width: CGFloat,
                                  translation: CGFloat, shouldReturn: Bool) {
        guard settlingPage == nil, width.isFinite, width > 0 else { return }
        if reduceMotion {
            if shouldReturn {
                if target == .chat { browserSessionOpen = false }
                else { backFromBrowser() }
            }
            return
        }
        let ticket = UUID()
        pageReturnTicket = ticket
        let scope = homeScope
        let route = browserRoute
        withTransaction(Transaction(animation: nil)) {
            settlingPage = target
            pageReturnOffset = CGFloat(ChatPageBackInteraction.offset(
                width: Double(width), translation: Double(translation)))
        }
        withAnimation(.easeOut(duration: 0.24), completionCriteria: .logicallyComplete) {
            pageReturnOffset = shouldReturn ? width : 0
        } completion: {
            guard pageReturnTicket == ticket, settlingPage == target else { return }
            let stillCurrent = scope == homeScope && route == browserRoute && browserOpen
                && browserSessionOpen == (target == .chat)
            // Removing the settled top card / changing its z-index must not
            // start a second full-page transition or flash the old card.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if shouldReturn && stillCurrent {
                    if target == .chat { browserSessionOpen = false }
                    else { backFromBrowser() }
                }
                settlingPage = nil
                pageReturnOffset = 0
            }
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
            backToDrawer: browserSource == .drawer && browserRoute.count == 1,
            onBrowseAllInstances: {
                unifiedSection = 0
                if browserRoute.last != .all { browserRoute.append(.all) }
            },
            onBrowseAllTasks: {
                unifiedSection = 1
                if browserRoute.last != .all { browserRoute.append(.all) }
            },
            startSearching: browserSearchRequested,
            onShowTaskCenter: presentTaskCenter
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
                        // A single host title avoids clipping in fixed chrome;
                        // the full identity stays in the Menu's AX label.
                        Text(app.active.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.down").font(.caption2)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 156,
                           minHeight: 44, alignment: .leading)
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("切换 Hermes 实例，当前\(app.active.name)")
                Spacer(minLength: 6)
                Button {
                    homeFocused = false
                    browserSearchRequested = true
                    browserSource = .chat
                    browserRoute = app.instances.count > 1 ? [.all] : [.single]
                    unifiedSection = 0
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
            .frame(minHeight: 56)

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
        guard UnifiedBrowserPresentation.canOpenSidebar(
            browserOpen: browserOpen, browserSessionOpen: browserSessionOpen) else { return }
        // The toolbar hamburger is a direct drawer action, not another
        // browser back-swipe. Retire that route while keeping the selected
        // Hermes Session and its draft unchanged.
        if browserSessionOpen {
            browserSessionOpen = false
            browserOpen = false
            browserRoute = []
        }
        sidebarOpen = true
    }
    private func closeSidebar() { sidebarOpen = false }

    private func presentTaskCenter() {
        guard !taskCenterPresented else { return }
        taskCenterScope = homeScope
        pendingTaskSheetSelection = nil
        cancelNavigationGestures()
        taskCenterPresented = true
    }

    /// Browser routing stays unchanged; only gesture event ownership is reset.
    /// Call on scope, foreground, modal and navigation transitions.
    private func cancelNavigationGestures() {
        drawerGestureOwner.cancelled()
        sessionBackOwner.cancelled()
        browserBackOwner.cancelled()
        // A new scope, modal or inactive scene invalidates an old animation
        // completion and cannot navigate the newly visible conversation.
        pageReturnTicket = UUID()
        settlingPage = nil
        pageReturnOffset = 0
    }

    /// Planner suppression is only valid for an active app whose chat page is
    /// unobscured. A backgrounded app keeps the same `currentSessionID`, but
    /// that must not hide the notification the user needs when returning.
    private func synchronizeConversationVisibility() {
        let visible = UnifiedBrowserPresentation.conversationVisible(
            active: scenePhase == .active,
            sidebarOpen: sidebarOpen,
            browserOpen: browserOpen,
            browserSessionOpen: browserSessionOpen,
            modalOpen: app.showSettings || app.needsLogin || taskCenterPresented,
            hasSession: app.currentSessionID != nil)
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
