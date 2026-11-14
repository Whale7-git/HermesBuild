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
    @GestureState private var browserBackDrag: CGFloat = 0

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
                        closeSidebar()
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

                ChatCardContainer(
                    size: geometry.size, topInset: topInset, bottomInset: bottomInset,
                    progress: progress, translation: exposed,
                    reduceMotion: reduceMotion,
                    showsDismissSurface: sidebarOpen,
                    onDismiss: closeSidebar
                ) {
                    Group {
                        if let sessionID = app.currentSessionID {
                            chatDestination(ChatRoute(sessionID: sessionID))
                        } else {
                            emptyConversation
                        }
                    }
                    .accessibilityHidden(sidebarOpen)
                }

                // Distinct from the root drawer: this is a pushed, full-page
                // native-Session browser. The underlying chat remains mounted,
                // and a rightward edge pan returns to that actual chat page.
                if browserOpen {
                    let backProgress = min(1, max(0,
                        browserBackDrag / max(1, geometry.size.width)))
                    ChatCardContainer(
                        size: geometry.size, topInset: topInset, bottomInset: bottomInset,
                        progress: backProgress, translation: browserBackDrag,
                        reduceMotion: reduceMotion,
                        showsDismissSurface: false,
                        onDismiss: {}
                    ) {
                        SessionListPane(
                            mode: .page,
                            selectedID: app.currentSessionID,
                            onSelect: { session in
                                browserOpen = false
                                app.openSession(session)
                            },
                            onNew: {
                                browserOpen = false
                                startConversation()
                            },
                            onSettings: {
                                browserOpen = false
                                app.showSettings = true
                            },
                            onClose: { browserOpen = false }
                        )
                        .environmentObject(app)
                    }
                    .transition(.move(edge: .trailing))
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 18)
                            .updating($browserBackDrag) { value, drag, _ in
                                guard ChatPageBackInteraction.shouldTrack(
                                    startX: Double(value.startLocation.x),
                                    horizontal: Double(value.translation.width),
                                    vertical: Double(value.translation.height)) else { return }
                                drag = max(0, value.translation.width)
                            }
                            .onEnded { value in
                                guard ChatPageBackInteraction.shouldTrack(
                                    startX: Double(value.startLocation.x),
                                    horizontal: Double(value.translation.width),
                                    vertical: Double(value.translation.height)) else { return }
                                if ChatPageBackInteraction.shouldDismiss(
                                    width: Double(geometry.size.width),
                                    predictedTranslation: Double(value.predictedEndTranslation.width)) {
                                    browserOpen = false
                                }
                            }
                    )
                }
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

    /// An empty workspace, not the session management screen. Creating a chat
    /// remains an explicit user action: never create server sessions on launch.
    private var emptyConversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: openSidebar) {
                    ChromeIcon(symbol: "line.3.horizontal")
                }
                .accessibilityLabel("打开会话侧栏")
                HStack(spacing: 5) {
                    Text("Hermes").font(.headline.weight(.semibold))
                    Text(app.active.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    startConversation()
                } label: {
                    if app.creating { ProgressView().frame(width: 44, height: 44) }
                    else { ChromeIcon(symbol: "square.and.pencil") }
                }
                .disabled(app.creating)
                .accessibilityLabel(app.needsInstanceSetup ? "配置连接" : "新建对话")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 56)

            Spacer(minLength: 48)
            VStack(spacing: 16) {
                Image(systemName: "sparkle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.primary)
                Text(app.needsInstanceSetup ? "连接你的 Hermes" : "有什么可以帮你？")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(app.needsInstanceSetup ? "先在设置中添加自己的网关地址与密钥。" : "选择一个 Hermes 实例的会话，或开始新的对话。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 48)
            VStack(spacing: 10) {
                Button {
                    startConversation()
                } label: {
                    Label(app.needsInstanceSetup ? "配置连接" : (app.creating ? "正在创建…" : "开始新对话"),
                          systemImage: app.needsInstanceSetup ? "gearshape" : "square.and.pencil")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.action)
                .disabled(app.creating)

                Button(app.needsInstanceSetup ? "查看实例设置" : "查看历史会话") {
                    if app.needsInstanceSetup { app.showSettings = true }
                    else { openSidebar() }
                }
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(AppTheme.canvas)
    }

    private func startConversation() {
        if app.needsInstanceSetup { app.showSettings = true }
        else { Task { await app.createSession() } }
    }

    private func openSidebar() {
        guard !browserOpen else { return }
        sidebarOpen = true
    }
    private func closeSidebar() { sidebarOpen = false }

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
