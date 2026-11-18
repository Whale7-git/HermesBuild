import SwiftUI
import UIKit

/// 会话列表：同一份内容既作主页，也作聊天里的侧栏。
/// 扁平分组（置顶 / 最近），发丝线分隔，不用卡片套卡片。
struct SessionListPane: View {
    enum Mode { case page, drawer }

    @EnvironmentObject var app: AppState
    let mode: Mode
    let selectedID: String?
    let onSelect: (SessionSummary) -> Void
    let onNew: () -> Void
    let onSettings: () -> Void
    var onClose: (() -> Void)?
    var onBrowseAll: (() -> Void)? = nil
    var backToDrawer = false
    var onBrowseAllInstances: (() -> Void)? = nil
    var onBrowseAllTasks: (() -> Void)? = nil
    var startSearching = false
    /// Supplied by the root shell so the sheet does not move with this pane.
    /// Standalone callers retain the existing local presentation fallback.
    var onShowTaskCenter: (() -> Void)? = nil

    @State private var query = ""
    @State private var showsSearch = false
    @State private var filterPinnedOnly = false
    @State private var showArchived = false
    @State private var showTaskCenter = false
    @State private var pendingLocalTaskSelection: (scope: String, sessionID: String)?
    @StateObject private var searchModel = SessionSearchModel()
    @StateObject private var archiveModel = SessionArchiveModel()
    @State private var renameTarget: SessionSummary?
    @State private var renameScope: String?
    @State private var renameText = ""
    @State private var deleteTarget: SessionSummary?
    @State private var deleteScope: String?
    /// 归档撤销条只属于会话列表区域，不复用聊天页顶部 toast。
    /// 撤销目标（单条或批量 N 条）在 AppState.lastArchiveUndo 上，这里只保留 3 秒可见性。
    @State private var undoVisible = false
    /// 无障碍：开启「减弱动态效果」时跳过撤销条的转场动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var undoTask: Task<Void, Never>?
    /// 多选只是列表的本地视图状态，不写回 AppState，也不依赖 List 的 EditMode。
    @State private var selecting = false
    @State private var selectedSessionIDs: Set<String> = []
    @State private var selectionScope: String?
    @State private var batchDeletePresented = false
    @State private var confirmClearDamagedTaskState = false
    @State private var batchBusy = false
    @FocusState private var searchFocused: Bool

    private var filtered: [SessionSummary] {
        app.sessions.filter { !filterPinnedOnly || $0.pinned == true }
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var discoveryScope: String { "\(app.active.id)-\(app.active.baseURL)-\(app.activeChangeToken)" }
    /// Both backends provide discovery; the supported match fields differ.
    private var discoveryService: SessionDiscoveryService {
        (app.api as? DiscoveryProviding)?.discovery ?? UnavailableDiscoveryService()
    }
    private var refreshing: Bool {
        if searching { return searchModel.loading }
        if showArchived { return archiveModel.loading }
        return app.loadingSessions
    }
    private var homeSections: SessionHomeSections {
        app.homeSections(pinnedOnly: filterPinnedOnly)
    }
    private var attention: [SessionSummary] { homeSections.attention }
    private var running: [SessionSummary] { homeSections.running }
    private var pinned: [SessionSummary] { homeSections.pinned }
    private var recent: [SessionSummary] { homeSections.recent }
    private var visibleSessionIDs: [String] { filtered.map(\.sessionId) }
    /// 批量请求的顺序稳定、可复现：先按当前可见顺序，再接上被筛选隐藏的已选项。
    /// 隐藏项也必须真正执行——否则界面显示「已选 N 项」却只处理了一部分。
    private var orderedSelection: [String] {
        var ordered = visibleSessionIDs.filter { selectedSessionIDs.contains($0) }
        let visible = Set(ordered)
        ordered += app.sessions.map(\.sessionId)
            .filter { selectedSessionIDs.contains($0) && !visible.contains($0) }
        return ordered
    }
    private var selectedCount: Int { selectedSessionIDs.count }
    private var canBatchAct: Bool {
        !selectedSessionIDs.isEmpty && !batchBusy && selectionScope == discoveryScope
    }
    /// 归档能力读能力表（原先是本地一份 `== .webui` 字面量，与 AppState 重复）。
    private var supportsArchive: Bool { app.api.capabilities.canArchive }
    /// 置顶语义：选中项里只要还有一条未置顶，就整体置顶；全部已置顶时才取消置顶。
    private var batchPinValue: Bool {
        app.sessions.contains { selectedSessionIDs.contains($0.sessionId) && $0.pinned != true }
    }
    private var allVisibleSelected: Bool {
        !filtered.isEmpty && Set(visibleSessionIDs).isSubset(of: selectedSessionIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Fixed search row, compact host rail and two adjacent global
            // actions leave most of the sidebar to actual conversation rows.
            if !selecting || showsSearch || searching {
                searchField.disabled(selecting)
            }
            if mode == .drawer && app.instances.count > 1 {
                instanceStrip
            }
            if !selecting && !searching && !searchFocused {
                quickActions
            }
            // 搜索时由搜索结果接管列表；筛选条收起，避免顶部留下整块空白。
            if selecting {
                selectionToolbar
            } else {
                if !searching && (filterPinnedOnly || showArchived) { filterRow }
            }
            if searching {
                SessionSearchView(query: query, scope: discoveryScope, service: discoveryService,
                                  onSelect: onSelect, app: app, model: searchModel)
            } else if showArchived {
                SessionArchiveView(scope: discoveryScope, service: discoveryService,
                                   onSelect: onSelect, app: app, model: archiveModel)
            } else {
                SessionRefreshList(refresh: { await app.refresh() }) {
                    if let error = app.errorText, !app.needsLogin { refreshError(error) }
                    if let warning = app.localCleanupWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(warning)
                        }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("local-cleanup-warning")
                    }
                    if let warning = app.sessionTaskPersistenceWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "externaldrive.badge.exclamationmark")
                            Text(warning)
                        }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("task-store-warning")
                    }
                    if app.hasDamagedTaskStore {
                        Button("清除损坏的任务状态记录") {
                            confirmClearDamagedTaskState = true
                        }
                        .font(.footnote)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .accessibilityIdentifier("clear-corrupt-task-record")
                    }
                    if let warning = app.taskAcknowledgementWarning {
                        Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, AppTheme.pagePadding)
                    }
                    if filtered.isEmpty {
                        if !app.hasLoadedSessions && app.errorText == nil {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在加载会话…").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                            .accessibilityIdentifier("session-list-loading")
                        } else if !app.hasLoadedSessions && app.errorText != nil {
                            HermesEmptyState(symbol: "wifi.exclamationmark",
                                             title: "无法加载会话",
                                             message: "连接失败，请检查实例连接后下拉刷新。")
                                .padding(.top, 56)
                        } else {
                            emptyState
                        }
                    }
                    else {
                        if !attention.isEmpty {
                            sectionCaption("需要处理 · \(attention.count)")
                            rows(attention)
                        }
                        if !running.isEmpty {
                            sectionCaption("正在处理 · \(running.count)")
                            rows(running)
                        }
                        if !pinned.isEmpty { sectionCaption("置顶"); rows(pinned) }
                        ForEach(SessionRecencyBucket.allCases) { bucket in
                            let group = recent.filter { SessionRecencyBucket.bucket(for: $0.updatedDate) == bucket }
                            if !group.isEmpty { sectionCaption(bucket.title); rows(group) }
                        }
                    }
                    footer
                }
            }
        }
        // 横屏与未来 iPad：内容最多 640 并居中，不把行拉成一条长带。
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(mode == .drawer ? AppTheme.softFill : AppTheme.canvas)
        .alert("重命名会话", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil; renameScope = nil } }
        )) {
            TextField("会话标题", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil; renameScope = nil }
            Button("保存") {
                guard let target = renameTarget, renameScope == discoveryScope else { return }
                let scope = discoveryScope
                let value = renameText
                renameTarget = nil
                renameScope = nil
                Task {
                    guard scope == discoveryScope else { return }
                    await app.rename(sessionID: target.sessionId, title: value)
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("标题会写回服务端，其他客户端同步可见。")
        }
        .alert("删除会话？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil; deleteScope = nil } }
        ), presenting: deleteTarget) { target in
            Button("取消", role: .cancel) { deleteTarget = nil; deleteScope = nil }
            Button("删除", role: .destructive) {
                guard deleteScope == discoveryScope else { return }
                let scope = discoveryScope
                deleteTarget = nil
                deleteScope = nil
                Task {
                    guard scope == discoveryScope else { return }
                    await app.delete(sessionID: target.sessionId)
                }
            }
        } message: { target in
            Text("将永久删除「\(target.displayTitle)」及其历史，无法恢复。")
        }
        // 批量删除走确认弹窗：服务端一并删除，没有撤销通道。
        .confirmationDialog("删除 \(selectedCount) 个会话？",
                            isPresented: $batchDeletePresented,
                            titleVisibility: .visible) {
            Button("删除 \(selectedCount) 个会话", role: .destructive) { deleteSelection() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务端会话一并删除，此操作无法撤销。")
        }
        .confirmationDialog("清除损坏的任务状态记录？",
                            isPresented: $confirmClearDamagedTaskState,
                            titleVisibility: .visible) {
            Button("清除本地损坏记录", role: .destructive) {
                app.clearDamagedTaskStore()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除当前实例和账号的本地任务状态记录，不删除远端会话。清除后无法恢复原始损坏数据。")
        }
        .overlay(alignment: .bottom) { bottomBanners }
        // 归档当前会话会关闭侧栏并换出新的列表页，所以进入时也要补一次：
        // 撤销信息在 AppState 上，新建的列表页同样能看到这条提示。
        .onAppear {
            if !app.lastArchiveUndo.isEmpty { presentUndo() }
            if startSearching && !selecting {
                showsSearch = true
                searchFocused = true
            }
        }
        .onChange(of: app.lastArchiveUndo) { _, targets in
            if targets.isEmpty { dismissUndo() } else { presentUndo() }
        }
        // 只丢弃**已不存在**的会话；切换筛选不静默清空已选。
        // 否则「全选 → 切到置顶 → 批量归档」会少归档一半而没有任何提示。
        .onChange(of: app.sessions.map(\.sessionId)) { _, ids in
            guard selecting else { return }
            selectedSessionIDs.formIntersection(Set(ids))
        }
        .onChange(of: discoveryScope) { _, _ in
            // This pane survives instance/account switches. Old selected IDs
            // and confirmation targets must never be applied to the new API.
            renameTarget = nil; renameScope = nil; renameText = ""
            deleteTarget = nil; deleteScope = nil
            selecting = false; selectionScope = nil
            selectedSessionIDs.removeAll()
            batchDeletePresented = false; batchBusy = false
            showArchived = false
            showTaskCenter = false
            pendingLocalTaskSelection = nil
            query = ""; searchFocused = false; showsSearch = false
            searchModel.cancel(); archiveModel.reset()
            dismissUndo()
        }
        .onDisappear {
            undoTask?.cancel()
            selecting = false
            selectionScope = nil
            selectedSessionIDs.removeAll()
        }
        .sheet(isPresented: $showTaskCenter, onDismiss: {
            let target = pendingLocalTaskSelection
            pendingLocalTaskSelection = nil
            if let target, target.scope == discoveryScope,
               let session = app.sessions.first(where: { $0.sessionId == target.sessionID }) {
                onSelect(session)
            }
        }) {
            SessionTaskCenterView(
                sessions: app.sessions,
                summaries: app.visibleTaskSummaries,
                acknowledgements: app.acknowledgedTaskEntries,
                onSelect: { session in
                    pendingLocalTaskSelection = (discoveryScope, session.sessionId)
                    showTaskCenter = false
                },
                onAcknowledge: { sessionID, signal in
                    app.acknowledgeTask(sessionID: sessionID, signal: signal)
                },
                onUndo: { acknowledgement in
                    app.undoTaskAcknowledgement(acknowledgement)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(AppTheme.radiusSheet)
        }
    }

    /// 底部提示统一出口：选择操作条在最上，撤销条其次，失败提示在下，互不遮挡。
    private var bottomBanners: some View {
        VStack(spacing: 8) {
            if selecting { selectionActionBar }
            archiveUndoBar
            actionErrorToast
        }
        .padding(.bottom, 56)
    }

    // MARK: 撤销条

    /// 归档成功后 3 秒内可撤销；条本身可点，撤销按钮 ≥44pt 且独立可达。
    /// 目标是数组：单条显示标题，批量显示条数；撤销失败保留并重新计时。
    @ViewBuilder
    private var archiveUndoBar: some View {
        let targets = app.lastArchiveUndo
        if undoVisible, !targets.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(undoTitle(targets))
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    // 用户已决定撤销，停掉自动消失；失败时保留提示并重新计时。
                    undoTask?.cancel()
                    undoTask = nil
                    let scope = discoveryScope
                    Task {
                        guard scope == discoveryScope else { return }
                        await app.undoArchive()
                        guard scope == discoveryScope else { return }
                        if app.lastArchiveUndo.isEmpty { dismissUndo() } else { presentUndo() }
                    }
                } label: {
                    Text("撤销")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(undoAccessibilityLabel(targets))
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.hairline))
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func undoTitle(_ targets: [ArchiveUndoTarget]) -> String {
        targets.count == 1 ? "已归档「\(targets[0].title)」" : "已归档 \(targets.count) 个会话"
    }

    private func undoAccessibilityLabel(_ targets: [ArchiveUndoTarget]) -> String {
        targets.count == 1 ? "撤销归档，恢复「\(targets[0].title)」" : "撤销归档，恢复 \(targets.count) 个会话"
    }

    private func undoAnnouncement(_ targets: [ArchiveUndoTarget]) -> String {
        targets.count == 1 ? "已归档「\(targets[0].title)」，可撤销" : "已归档 \(targets.count) 个会话，可撤销"
    }

    private func presentUndo() {
        let targets = app.lastArchiveUndo
        guard !targets.isEmpty else { dismissUndo(); return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { undoVisible = true }
        UIAccessibility.post(notification: .announcement, argument: undoAnnouncement(targets))
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { undoVisible = false }
        }
    }

    private func dismissUndo() {
        undoTask?.cancel()
        undoTask = nil
        guard undoVisible else { return }
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { undoVisible = false }
    }

    /// 会话操作失败时明确报错，不静默吞掉（例如只读会话、置顶超额）。
    @ViewBuilder
    private var actionErrorToast: some View {
        if let message = app.sessionActionError {
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.hairline))
                .transition(.opacity)
                .onTapGesture { app.sessionActionError = nil }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 4) {
            if mode == .page, let onClose {
                Button(action: onClose) { ChromeIcon(symbol: "chevron.left") }
                     .accessibilityLabel(backToDrawer ? "返回侧栏" : "返回聊天")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(mode == .drawer ? "Hermes" : "对话")
                    .font(.title2.weight(.semibold)).tracking(-0.5)
                // The compact instance rail already owns switching in drawer
                // mode. Don't repeat a long raw URL under the title: it
                // consumes an entire navigation row on a 340pt canvas.
                if mode != .drawer || app.instances.count <= 1 {
                    Menu {
                        if mode == .page && app.instances.count > 1, let onBrowseAllInstances {
                            Button("全部实例", systemImage: "square.stack.3d.up") {
                                onBrowseAllInstances()
                            }
                            Divider()
                        }
                        ForEach(Array(app.instances.enumerated()), id: \.element.id) { index, instance in
                            Button { app.switchTo(index) } label: {
                                if index == app.activeIndex { Label(instance.name, systemImage: "checkmark") }
                                else { Text(instance.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "server.rack").font(.caption2)
                            Text(app.active.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 150, alignment: .leading)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("切换实例，当前 \(app.active.name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button(action: onNew) {
                if app.creating {
                    ProgressView().controlSize(.small)
                        .frame(width: 44, height: 44)
                } else {
                    ChromeIcon(symbol: "square.and.pencil")
                }
            }
            .disabled(app.creating || selecting)
            .accessibilityLabel("新建对话")
            Menu {
                Button("全部对话", systemImage: "bubble.left.and.bubble.right") { cancelSearch(); resetFilters() }
                    .disabled(selecting)
                if mode == .drawer, let onBrowseAll {
                    Button("展开会话管理", systemImage: "rectangle.expand.vertical") {
                        onBrowseAll()
                    }
                    .disabled(selecting)
                }
                Button("置顶会话", systemImage: "pin") { cancelSearch(); filterPinnedOnly = true; showArchived = false }
                    .disabled(selecting)
                if supportsArchive {
                    Button("归档会话", systemImage: "archivebox") { cancelSearch(); showArchived = true; filterPinnedOnly = false }
                        .disabled(selecting)
                }
                Button(selecting ? "完成选择" : "选择多个会话", systemImage: "checkmark.circle") { toggleSelecting() }
                Divider()
                Button("刷新对话", systemImage: "arrow.clockwise") { Task { await refreshCurrentList() } }
                    .disabled(refreshing)
                Button("设置", systemImage: "gearshape", action: onSettings)
            } label: { ChromeIcon(symbol: "ellipsis") }
            .accessibilityLabel("对话筛选与管理")
            if mode == .drawer {
                Button { onClose?() } label: { ChromeIcon(symbol: "xmark") }
                    .accessibilityLabel("关闭会话列表")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, mode == .page ? 12 : 24)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Visible instance picker for scattered NAS/Linux/Windows Hermes hosts.
    /// The session list remains scoped to the selected host and account: do
    /// not display sessions/counts from another backend without fetching them.
    /// Switching hosts keeps the drawer open so a native session can be picked.
    /// A configured URL is an endpoint, not a readable host name.
    /// Only recognize the explicitly numbered Hermes endpoints; do not
    /// rename arbitrary user-defined instance titles.
    private func compactInstanceName(_ name: String) -> String {
        guard let url = URLComponents(string: name),
              let host = url.host?.lowercased() else { return name }
        let components = host.split(separator: ".")
        guard components.count >= 3 else { return name }
        let prefix = String(components[0])
        if prefix == "hermes-api", components.count >= 4,
           let number = Int(components[1]), number > 0 {
            return "\(number) 号"
        }
        if prefix.hasPrefix("hermes-api-"),
           let number = Int(prefix.dropFirst("hermes-api-".count)), number > 0 {
            return "\(number) 号"
        }
        return name
    }

    private var instanceStrip: some View {
        GeometryReader { geometry in
            let chipWidths = app.instances.map {
                CGFloat(ChatDrawerRailLayout.readableChipWidth(for: compactInstanceName($0.name)))
            }
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(Array(app.instances.enumerated()), id: \.element.id) { index, instance in
                            Button {
                                guard index != app.activeIndex else { return }
                                app.switchTo(index)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: index == app.activeIndex
                                          ? "checkmark.circle.fill" : "server.rack")
                                        .font(.caption2)
                                    Text(compactInstanceName(instance.name))
                                        .font(.caption.weight(index == app.activeIndex ? .semibold : .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .foregroundStyle(index == app.activeIndex ? AppTheme.onAction : Color.primary)
                                .frame(width: chipWidths[index], height: 44)
                                .background(index == app.activeIndex ? AppTheme.action : AppTheme.surface,
                                            in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(instance.id)
                            .accessibilityLabel("Hermes 实例：\(instance.name)")
                            .accessibilityValue(index == app.activeIndex ? "当前实例" : "点击切换")
                        }
                    }
                    .padding(.horizontal, AppTheme.pagePadding)
                }
                .onAppear { reader.scrollTo(app.active.id, anchor: .center) }
                .onChange(of: app.active.id) { _, id in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        reader.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: geometry.size.width) { _, _ in
                    reader.scrollTo(app.active.id, anchor: .center)
                }
            }
        }
        .frame(height: 44)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// Global browsing remains available, but uses one compact row rather
    /// than two full-height actions. The instance task center has one owner.
    private var quickActions: some View {
        VStack(spacing: 4) {
            if app.instances.count > 1 {
                HStack(spacing: 8) {
                    if let onBrowseAllInstances {
                        compactBrowseAction("全部会话", symbol: "square.stack.3d.up",
                                            action: onBrowseAllInstances)
                            .accessibilityLabel("浏览全部 Hermes 实例的会话")
                    }
                    if let onBrowseAllTasks {
                        compactBrowseAction("全部任务", symbol: "list.bullet.rectangle.portrait",
                                            action: onBrowseAllTasks)
                            .accessibilityLabel("浏览全部 Hermes 实例的任务工作台")
                    }
                }
            }
            Button(action: presentTaskCenter) {
                let summaries = app.visibleTaskSummaries
                let attention = summaries.filter(\.needsAttention).count
                HStack(spacing: 8) {
                    Image(systemName: attention > 0 ? "exclamationmark.circle.fill" : "list.bullet.clipboard")
                        .foregroundStyle(attention > 0 ? AppTheme.warning : Color.secondary)
                    Text(attention > 0 ? "本实例 · \(attention) 项待处理" : "本实例任务中心")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !summaries.isEmpty {
                        Text("\(summaries.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("本实例任务中心，查看运行及待处理会话")
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.bottom, 4)
    }

    private func compactBrowseAction(_ title: String, symbol: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.body)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous))
            .contentShape(Rectangle())
        }
    }

    private func presentTaskCenter() {
        if let onShowTaskCenter { onShowTaskCenter() }
        else {
            pendingLocalTaskSelection = nil
            showTaskCenter = true
        }
    }

    /// 系统语义的搜索框：36pt 高、8pt 圆角、tertiarySystemFill 底，右侧「取消」清词并收键盘。
    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("搜索对话", text: $query)
                    .font(.subheadline)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityHint(app.api.capabilities.searchesFullBody
                        ? "搜索标题与完整正文，包含归档"
                        : "搜索当前网关的会话标题与摘要")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, query.isEmpty ? 10 : 2)
            .frame(height: 36)
            .background(Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: AppTheme.radiusS, style: .continuous))

            if searching || searchFocused {
                Button("取消") { cancelSearch() }
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消搜索")
            }
        }
        // 固定 44pt 行高：右侧「取消」出现/消失都不会带动列表跳动。
        .frame(height: 44)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.bottom, 4)
    }

    /// 清空关键词、收键盘；搜索退出后筛选条自动恢复。
    private func cancelSearch() {
        query = ""
        searchFocused = false
        showsSearch = false
        searchModel.cancel()
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            chip("全部", active: !filterPinnedOnly && !showArchived) { filterPinnedOnly = false; showArchived = false }
            chip("置顶", active: filterPinnedOnly && !showArchived) { filterPinnedOnly = true; showArchived = false }
            if supportsArchive {
                chip("归档", active: showArchived) { showArchived = true; filterPinnedOnly = false }
            }
            Spacer(minLength: 0)
            if app.loadingSessions { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.bottom, 4)
    }

    /// 选择模式顶栏：与筛选条同高（44pt），进入/退出列表不跳。
    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Button { toggleSelectAll() } label: {
                Text(allVisibleSelected ? "取消全选" : "全选（\(filtered.count)）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(AppTheme.softFill, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)
            .accessibilityLabel(allVisibleSelected ? "取消全选" : "全选当前列表 \(filtered.count) 项")
            .accessibilityHint("已选中的项在切换筛选后仍保留")
            // 反选：批量整理时比全选更实用（留下少数、清掉多数）。
            // 只翻转**当前列表**的选中状态，被筛选隐藏的已选项保持不变，
            // 与「全选」的语义一致，不会让屏幕外的选择突然丢失。
            Button { invertSelection() } label: {
                Text("反选")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(AppTheme.softFill, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(filtered.isEmpty)
            .accessibilityLabel("反选当前列表 \(filtered.count) 项")
            .accessibilityHint("已选变未选，未选变已选；被筛选隐藏的选择保持不变")
            if batchBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.bottom, 4)
    }

    private func chip(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? AppTheme.onAction : Color.secondary)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(active ? AppTheme.action : Color.clear, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var emptyState: some View {
        Group {
            if app.sessions.isEmpty {
                HermesEmptyState(symbol: "bubble.left.and.bubble.right",
                                 title: "还没有会话",
                                 message: "新建一个对话开始，或下拉刷新列表。",
                                 primaryTitle: "新建对话",
                                 primaryAction: { onNew() })
            } else {
                HermesEmptyState(symbol: "line.3.horizontal.decrease.circle",
                                 title: "没有找到会话",
                                 message: "当前筛选下没有会话，换个条件试试。",
                                 secondaryTitle: "查看全部",
                                 secondaryAction: { resetFilters() })
            }
        }
        .padding(.top, 56)
        .padding(.bottom, 24)
    }

    private func resetFilters() {
        filterPinnedOnly = false
        showArchived = false
    }

    private func refreshError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("刷新未完成", systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let refreshedAt = app.lastSessionRefresh {
                Text("当前内容更新于 \(refreshTime(refreshedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button("重试刷新") { Task { await app.refresh() } }
                .font(.footnote)
                .frame(minHeight: 44)
                .disabled(app.loadingSessions)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.2)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func rows(_ list: [SessionSummary]) -> some View {
        ForEach(list) { session in
            SessionRowContainer(showsSeparator: mode == .page && session.id != list.last?.id) {
                if selecting {
                    Button { toggleSelection(session) } label: { row(session) }
                        .buttonStyle(.plain)
                        .accessibilityAction(named: "选择") { toggleSelection(session) }
                } else if mode == .drawer {
                    // Native session operations remain on long press. The
                    // visible drawer has a compact single-line conversation list.
                    Button { onSelect(session) } label: { drawerRow(session) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: session) }
                } else {
                    Button { onSelect(session) } label: { row(session) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: session) }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteScope = discoveryScope
                    deleteTarget = session
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button { Task { await app.togglePin(sessionID: session.sessionId) } } label: {
                    Label(session.pinned == true ? "取消置顶" : "置顶", systemImage: "pin")
                }
                .tint(.orange)
            }
        }
    }

    private func drawerRow(_ session: SessionSummary) -> some View {
        let selected = session.sessionId == selectedID
        return HStack(spacing: 9) {
            Text(session.displayTitle)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if session.isStreaming == true || app.taskSummary(for: session.sessionId) != nil {
                Circle()
                    .fill(app.taskSummary(for: session.sessionId)?.needsAttention == true
                          ? AppTheme.warning : AppTheme.success)
                    .frame(width: 6, height: 6)
            }
            if session.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(selected ? AppTheme.softFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .accessibilityLabel(session.displayTitle)
        .accessibilityValue(selected ? "当前会话" : (session.pinned == true ? "已置顶" : ""))
    }

    /// 与 Desktop 侧栏对齐的操作集：改名、置顶、分支、归档、删除、复制 ID。
    /// 归档与删除会二次确认，删除与浏览器/WebUI 同一条路由，不可撤销。
    @ViewBuilder
    private func menu(for session: SessionSummary) -> some View {
        Button {
            renameScope = discoveryScope
            renameText = session.displayTitle
            renameTarget = session
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            Task { await app.togglePin(sessionID: session.sessionId) }
        } label: {
            Label(session.pinned == true ? "取消置顶" : "置顶", systemImage: "pin")
        }
        Button {
            Task { await app.branch(sessionID: session.sessionId, keepCount: nil) }
        } label: {
            Label("创建分支", systemImage: "arrow.triangle.branch")
        }
        Divider()
        if supportsArchive {
            Button {
                Task { await app.archive(sessionID: session.sessionId) }
            } label: {
                Label("归档", systemImage: "archivebox")
            }
        }
        Button(role: .destructive) {
            deleteScope = discoveryScope
            deleteTarget = session
        } label: {
            Label("删除", systemImage: "trash")
        }
        Divider()
        Button {
            UIPasteboard.general.string = session.sessionId
            UIAccessibility.post(notification: .announcement, argument: "会话 ID 已复制")
        } label: {
            Label("复制会话 ID", systemImage: "doc.on.doc")
        }
    }

    /// 服务端 `/api/sessions` 当前不再下发 `preview`（`Session.compact()` 只给 message_count），
    /// 有消息时用条数兜底，只有真正 0 条才说「尚无消息」，避免每行都谎报空会话。
    private func rowPreview(for session: SessionSummary) -> String {
        if let text = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        let count = session.messageCount ?? 0
        return count > 0 ? "\(count) 条消息" : "尚无消息"
    }

    private func row(_ session: SessionSummary) -> some View {
        let isSelectedHere = selecting
            ? selectedSessionIDs.contains(session.sessionId)
            : session.sessionId == selectedID
        return HStack(alignment: .top, spacing: 0) {
            if selecting { selectionMark(isOn: isSelectedHere) }
            SessionRowContent(title: session.displayTitle,
                preview: rowPreview(for: session),
                date: session.updatedDate, pinned: session.pinned == true,
                running: session.isStreaming == true,
                task: app.taskSummary(for: session.sessionId),
                selected: isSelectedHere)
                .padding(.horizontal, 12)
                .accessibilityLabel(rowAccessibilityLabel(session))
                .accessibilityValue(rowAccessibilityValue(session, isSelected: isSelectedHere))
                .accessibilityAddTraits(isSelectedHere ? .isSelected : [])
            // 完成标记放在标题行 trailing，与副行的「运行中」绿点位置分开。
            SessionCompletionDot(completed: app.completedSessionIDs.contains(session.sessionId))
        }
    }

    /// 选择圈：44pt 热区，点击由整行接管，圆圈本身对 VoiceOver 隐藏。
    private func selectionMark(isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(isOn ? AppTheme.accent : Color.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private func rowAccessibilityLabel(_ session: SessionSummary) -> Text {
        var label = Text(session.displayTitle)
        if let preview = session.preview, !preview.isEmpty { label = label + Text("，\(preview)") }
        if app.completedSessionIDs.contains(session.sessionId) { label = label + Text("，有新回复") }
        if let task = app.taskSummary(for: session.sessionId) {
            label = label + Text("，\(task.title)")
        }
        return label
    }

    private func rowAccessibilityValue(_ session: SessionSummary, isSelected: Bool) -> String {
        if selecting { return isSelected ? "已选择" : "未选择" }
        let task = app.taskSummary(for: session.sessionId)?.title
        return [session.pinned == true ? "已置顶" : "", task ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "，")
    }

    // MARK: 多选

    private func toggleSelecting() {
        if selecting {
            exitSelection()
        } else {
            // 选择只作用于主列表：进入时退出搜索与归档视图，避免行语义混在一起。
            query = ""
            searchFocused = false
            showsSearch = false
            showArchived = false
            // 回到「全部」，否则「全选」只覆盖被筛选出的置顶行，容易被误解。
            filterPinnedOnly = false
            selectedSessionIDs.removeAll()
            selectionScope = discoveryScope
            batchDeletePresented = false
            withAnimation(.easeOut(duration: 0.2)) { selecting = true }
        }
    }

    private func exitSelection() {
        batchDeletePresented = false
        selectedSessionIDs.removeAll()
        selectionScope = nil
        withAnimation(.easeIn(duration: 0.2)) { selecting = false }
    }

    private func toggleSelection(_ session: SessionSummary) {
        let id = session.sessionId
        if selectedSessionIDs.contains(id) { selectedSessionIDs.remove(id) }
        else { selectedSessionIDs.insert(id) }
    }

    private func toggleSelectAll() {
        let all = Set(visibleSessionIDs)
        if all.isSubset(of: selectedSessionIDs) { selectedSessionIDs.subtract(all) }
        else { selectedSessionIDs.formUnion(all) }
    }

    /// 只翻转当前可见项的选中状态。
    /// 屏幕外已选项不动——它们仍会参与批量操作，与「全选」保持同一语义。
    private func invertSelection() {
        for id in visibleSessionIDs {
            if selectedSessionIDs.contains(id) { selectedSessionIDs.remove(id) }
            else { selectedSessionIDs.insert(id) }
        }
    }

    private func archiveSelection() {
        let ids = orderedSelection
        guard !ids.isEmpty, !batchBusy, selectionScope == discoveryScope else { return }
        let scope = discoveryScope
        batchBusy = true
        Task {
            guard scope == discoveryScope else { return }
            app.sessionActionError = nil
            let result = await app.archiveSessions(ids: ids)
            guard scope == discoveryScope else { return }
            batchBusy = false
            reportBatch(result, verb: "归档")
            // 归档成功就退出选择，把位置让给撤销条；全失败时保留选中便于重试。
            if result.succeeded > 0 { exitSelection() }
        }
    }

    private func pinSelection() {
        let ids = orderedSelection
        guard !ids.isEmpty, !batchBusy, selectionScope == discoveryScope else { return }
        let scope = discoveryScope
        batchBusy = true
        let pinned = batchPinValue
        Task {
            guard scope == discoveryScope else { return }
            app.sessionActionError = nil
            let result = await app.setPinned(pinned, ids: ids)
            guard scope == discoveryScope else { return }
            batchBusy = false
            reportBatch(result, verb: pinned ? "置顶" : "取消置顶")
            if result.failed == 0 { exitSelection() }
        }
    }

    private func deleteSelection() {
        let ids = orderedSelection
        guard !ids.isEmpty, !batchBusy, selectionScope == discoveryScope else { return }
        let scope = discoveryScope
        batchBusy = true
        Task {
            guard scope == discoveryScope else { return }
            app.sessionActionError = nil
            let result = await app.deleteSessions(ids: ids)
            guard scope == discoveryScope else { return }
            batchBusy = false
            reportBatch(result, verb: "删除")
            if result.succeeded > 0 { exitSelection() }
        }
    }

    /// 失败统一走 sessionActionError；部分失败要给出「成功 X / 失败 Y」。
    private func reportBatch(_ result: BatchActionResult, verb: String) {
        guard !result.isFullSuccess else { return }
        if result.succeeded == 0 {
            app.sessionActionError = "\(verb)失败：\(result.failed) 个会话未处理"
        } else {
            app.sessionActionError = "\(verb)部分失败：成功 \(result.succeeded) / 失败 \(result.failed)"
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 2) {
            Text("已选 \(selectedCount) 项")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .accessibilityLabel("已选择 \(selectedCount) 项")
            Spacer(minLength: 6)
            if supportsArchive {
                batchActionButton("归档", symbol: "archivebox") { archiveSelection() }
            }
            batchActionButton(batchPinValue ? "置顶" : "取消置顶",
                              symbol: batchPinValue ? "pin" : "pin.slash") { pinSelection() }
                .accessibilityHint("所选会话里有未置顶的就全部置顶，全部已置顶时才取消置顶")
            batchActionButton("删除", symbol: "trash", destructive: true) { batchDeletePresented = true }
        }
        .padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.hairline))
        .padding(.horizontal, 24)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func batchActionButton(_ title: String, symbol: String, destructive: Bool = false,
                                   action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : AppTheme.accent)
        .opacity(canBatchAct ? 1 : 0.4)
        .disabled(!canBatchAct)
        .accessibilityLabel("\(title)，已选 \(selectedCount) 项")
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text("已载入 \(app.sessions.count) 个会话")
            if let refreshedAt = app.lastSessionRefresh {
                Text("· 更新于 \(refreshTime(refreshedAt))")
            }
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }

    private func refreshCurrentList() async {
        if searching {
            await searchModel.refresh(query: query, scope: discoveryScope, service: discoveryService)
        } else if showArchived {
            await archiveModel.reload(scope: discoveryScope, service: discoveryService)
        } else {
            await app.refresh()
        }
    }

    private func refreshTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// 完成标记：6pt 圆点，贴在行内容 trailing、与标题首行同轴。
/// 外层固定 12×12 槽位，未完成时只是透明，行宽不会在完成/未完成之间跳动。
/// 主列表与搜索结果共用，圆点本身不进 VoiceOver，语义写在行 label 里。
struct SessionCompletionDot: View {
    let completed: Bool

    var body: some View {
        Circle()
            .fill(AppTheme.accent)
            .frame(width: 6, height: 6)
            .opacity(completed ? 1 : 0)
            .frame(width: 12, height: 12)
            .padding(.top, 16)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
    }
}
