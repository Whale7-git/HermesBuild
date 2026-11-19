import SwiftUI

/// Full-page cross-host browser. Drawer and native chat stay untouched while
/// read-only discovery runs; changing the active instance happens only on tap.
struct UnifiedSessionBrowser: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    let onClose: () -> Void
    let backToSingleInstance: Bool
    let backToDrawer: Bool
    let onSingleInstance: () -> Void
    /// Separate read-only cross-instance evidence from the active host's local
    /// actionable task center; do not invent a cross-instance run on a miss.
    let onOpenCurrentTaskCenter: () -> Void
    let onSelect: (UnifiedSessionRecord) -> Bool

    @ObservedObject var center: UnifiedSessionModel
    @Binding var query: String
    @Binding var taskSearch: String
    @Binding var sessionScrollAnchor: String?
    @Binding var taskScrollAnchor: String?
    @Binding var sessionScrollIndex: Int
    @Binding var taskScrollIndex: Int
    @State private var visibleScrollID: String?
    @State private var userOwnsScroll = false
    @Binding var filter: Int
    @Binding var section: Int
    @State private var navigationError: String?
    @State private var userRefreshing = false
    /// Read other hosts' persisted facts only on entering a task scope, not
    /// for every SwiftUI render or every finger movement of its parent card.
    @State private var otherTaskSnapshots: [UnifiedSessionIdentity: SessionTaskStore.LoadResult] = [:]
    @State private var taskEvidenceNow = Date()

    /// Explicit initializer: @EnvironmentObject is injected by the parent,
    /// while the root-owned model and bindings are supplied by RootView.
    init(center: UnifiedSessionModel, query: Binding<String>,
         taskSearch: Binding<String>,
         sessionScrollAnchor: Binding<String?>, taskScrollAnchor: Binding<String?>,
         sessionScrollIndex: Binding<Int>, taskScrollIndex: Binding<Int>,
         filter: Binding<Int>, section: Binding<Int>,
         onClose: @escaping () -> Void, backToSingleInstance: Bool,
         backToDrawer: Bool, onSingleInstance: @escaping () -> Void,
         onOpenCurrentTaskCenter: @escaping () -> Void,
         onSelect: @escaping (UnifiedSessionRecord) -> Bool) {
        self.center = center
        self._query = query
        self._taskSearch = taskSearch
        self._sessionScrollAnchor = sessionScrollAnchor
        self._taskScrollAnchor = taskScrollAnchor
        self._sessionScrollIndex = sessionScrollIndex
        self._taskScrollIndex = taskScrollIndex
        self._filter = filter
        self._section = section
        self.onClose = onClose
        self.backToSingleInstance = backToSingleInstance
        self.backToDrawer = backToDrawer
        self.onSingleInstance = onSingleInstance
        self.onOpenCurrentTaskCenter = onOpenCurrentTaskCenter
        self.onSelect = onSelect
    }

    /// Rotate the dataset on endpoint edits, account retirement or instance deletion.
    /// The active instance's switching generation is intentionally absent:
    /// browsing cannot silently change the meaning of a scoped result.
    private var scopeStamp: String {
        app.instances.map { instance in
            let id = ChatHistoryIdentity.instanceID(id: instance.id, baseURL: instance.baseURL)
            let account = ChatHistoryIdentity.accountScope(instanceID: id)
            return [instance.id.uuidString, id, account].map { "\($0.utf8.count):\($0)" }.joined()
        }.joined(separator: "|")
    }

    private func sources() -> [UnifiedSessionSource] {
        app.instances.map { instance in
            let endpoint = ChatHistoryIdentity.instanceID(id: instance.id, baseURL: instance.baseURL)
            let identity = UnifiedSessionIdentity(
                instanceID: instance.id, endpointIdentity: endpoint,
                accountScope: ChatHistoryIdentity.accountScope(instanceID: endpoint))
            let backend = instance.id == app.active.id && instance.baseURL == app.active.baseURL
                ? app.api : AppState.makeBackend(for: instance)
            let discovery = (backend as? DiscoveryProviding)?.discovery
            let search: (@MainActor (String) async throws -> [SessionSearchHit])?
            if backend.capabilities.searchesFullBody, let discovery {
                search = { term in
                    await backend.syncCookiesFromWebKit()
                    return try await discovery.searchSessions(query: term).hits
                }
            } else {
                search = nil
            }
            var source = UnifiedSessionSource(
                identity: identity, instanceName: instance.name,
                cached: app.unifiedCachedSessions(for: instance),
                load: {
                    await backend.syncCookiesFromWebKit()
                    return try await SessionRefreshLoader.load(api: backend, policy: .standard)
                },
                searchFullBody: search)
            source.cachedAt = app.unifiedCachedSessionDate(for: instance)
            return source
        }
    }

    private func runEvidence(for record: UnifiedSessionRecord) -> UnifiedRunEvidence {
        UnifiedRunEvidence.evaluate(
            isStreaming: record.session.isStreaming,
            lastSuccessfulList: center.lastSuccessfulListRefresh(for: record.identity),
            failed: center.failures[record.identity] != nil,
            now: taskEvidenceNow)
    }

    private var visible: [UnifiedSessionRecord] {
        center.records.filter { item in
            switch filter {
            case 1: return runEvidence(for: item) == .recentlyRunning
            case 2: return item.session.pinned == true
            case 3: return item.session.updatedDate.map {
                taskEvidenceNow.timeIntervalSince($0) <= 7 * 24 * 60 * 60
            } ?? false
            case 4: return runEvidence(for: item) == .historicalRunning
            default: return true
            }
        }
    }

    /// Task view never runs full-body search to invent task state. Its local
    /// search filters the complete scoped session-list snapshot instead.
    private var requestQuery: String { section == 1 ? "" : query }

    /// Refreshes only when the task tab or host/account identity changes.
    /// Active-host observations remain live via AppState's @Published field.
    private func refreshTaskSnapshots() {
        guard section == 1 else { return }
        var next: [UnifiedSessionIdentity: SessionTaskStore.LoadResult] = [:]
        for instance in app.instances {
            guard instance.id != app.active.id || instance.baseURL != app.active.baseURL else { continue }
            let endpoint = ChatHistoryIdentity.instanceID(
                id: instance.id, baseURL: instance.baseURL)
            let identity = UnifiedSessionIdentity(
                instanceID: instance.id, endpointIdentity: endpoint,
                accountScope: ChatHistoryIdentity.accountScope(instanceID: endpoint))
            next[identity] = app.unifiedTaskObservations(for: instance)
        }
        otherTaskSnapshots = next
        taskEvidenceNow = Date()
    }

    /// Schedule only the next evidence expiry. No periodic network polling,
    /// and no per-second redraw while the user is reading the task list.
    private var nextEvidenceDeadline: Date? {
        let dates = app.instances.compactMap { instance -> Date? in
            let endpoint = ChatHistoryIdentity.instanceID(
                id: instance.id, baseURL: instance.baseURL)
            let identity = UnifiedSessionIdentity(
                instanceID: instance.id, endpointIdentity: endpoint,
                accountScope: ChatHistoryIdentity.accountScope(instanceID: endpoint))
            return center.lastSuccessfulListRefresh(for: identity)
        }
        return UnifiedTaskWorkspace.nextEvidenceExpiry(
            lastSuccess: dates, after: taskEvidenceNow)
    }

    private var evidenceExpiryKey: String {
        [scopeStamp, String(section),
         nextEvidenceDeadline.map { String($0.timeIntervalSince1970) } ?? "no-expiry"]
            .joined(separator: "|")
    }

    private var scopedTaskStates: [UnifiedSessionIdentity: UnifiedTaskSourceState] {
        var result: [UnifiedSessionIdentity: UnifiedTaskSourceState] = [:]
        for instance in app.instances {
            let endpoint = ChatHistoryIdentity.instanceID(
                id: instance.id, baseURL: instance.baseURL)
            let identity = UnifiedSessionIdentity(
                instanceID: instance.id, endpointIdentity: endpoint,
                accountScope: ChatHistoryIdentity.accountScope(instanceID: endpoint))
            let observations: [String: SessionTaskObservation]
            let snapshot: SessionTaskStore.LoadResult =
                instance.id == app.active.id && instance.baseURL == app.active.baseURL
                ? app.unifiedTaskObservations(for: instance)
                : (otherTaskSnapshots[identity] ?? .missing)
            switch snapshot {
            case .loaded(let rows): observations = rows
            case .missing, .corrupt: observations = [:]
            }
            result[identity] = UnifiedTaskSourceState(
                observations: observations,
                lastSuccessfulList: center.lastSuccessfulListRefresh(for: identity),
                failed: center.failures[identity] != nil)
        }
        return result
    }

    private var taskEntries: [UnifiedTaskEntry] {
        UnifiedTaskWorkspace.entries(
            records: center.records, states: scopedTaskStates,
            now: taskEvidenceNow).filter { entry in
                let needle = taskSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { return true }
                return entry.record.session.displayTitle.localizedStandardContains(needle)
                    || entry.record.instanceName.localizedStandardContains(needle)
                    || entry.status.localizedStandardContains(needle)
            }
    }

    private var damagedTaskInstances: [String] {
        app.instances.compactMap { instance in
            let endpoint = ChatHistoryIdentity.instanceID(
                id: instance.id, baseURL: instance.baseURL)
            let identity = UnifiedSessionIdentity(
                instanceID: instance.id, endpointIdentity: endpoint,
                accountScope: ChatHistoryIdentity.accountScope(instanceID: endpoint))
            let snapshot: SessionTaskStore.LoadResult =
                instance.id == app.active.id && instance.baseURL == app.active.baseURL
                ? app.unifiedTaskObservations(for: instance)
                : (otherTaskSnapshots[identity] ?? .missing)
            if case .corrupt = snapshot { return instance.name }
            return nil
        }
    }

    @ViewBuilder
    private var taskResults: some View {
        let entries = taskEntries
        let activeAttention = app.visibleTaskSummaries.filter(\.needsAttention).count
        Text("跨实例视图仅展示已关联到已加载会话的任务证据。此处没有条目，不代表本实例没有待处理事项；不会推测网关未知的运行状态。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 8)
        if activeAttention > 0 {
            Button(action: onOpenCurrentTaskCenter) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist.checked")
                        .foregroundStyle(AppTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本实例有 \(activeAttention) 项待处理")
                            .font(.subheadline.weight(.semibold))
                        Text("打开本实例任务中心核对，不受跨实例列表筛选影响")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(AppTheme.softFill,
                            in: RoundedRectangle(cornerRadius: AppTheme.radiusM))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppTheme.pagePadding)
            .accessibilityLabel("本实例有 \(activeAttention) 项待处理，打开任务中心")
        }
        if !damagedTaskInstances.isEmpty {
            Label("部分实例的本机任务记录损坏，已保留原始数据："
                  + damagedTaskInstances.joined(separator: "、"),
                  systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption).foregroundStyle(AppTheme.warning)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 8)
        }
        if entries.isEmpty && center.loading.isEmpty {
            HermesEmptyState(
                symbol: "checklist",
                title: center.failures.isEmpty ? "跨实例暂无可确认的任务" : "跨实例任务状态尚未全部确认",
                message: "可下拉刷新各实例。Gateway 未提供 is_streaming 时，"
                    + "未打开过的后台任务可能无法从会话列表识别；不会猜测运行状态。")
                .padding(.top, 44)
        }
        ForEach(UnifiedTaskEntry.Group.allCases, id: \.rawValue) { group in
            let grouped = entries.filter { $0.group == group }
            if !grouped.isEmpty {
                Text("\(group.title) · \(grouped.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.pagePadding)
                    .padding(.top, 15)
                    .padding(.bottom, 5)
                ForEach(grouped) { entry in
                    Button {
                        navigationError = nil
                        if !onSelect(entry.record) {
                            navigationError = "实例或账号已变化，请刷新后重新选择。"
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.group == .running ? "waveform"
                                  : (entry.group == .attention ? "hand.raised" : "questionmark.circle"))
                                .foregroundStyle(entry.group == .attention
                                                 ? AppTheme.warning : Color.secondary)
                                .frame(width: 26)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.record.session.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary).lineLimit(2)
                                Text(entry.status)
                                    .font(.caption).foregroundStyle(.primary)
                                Text(entry.record.instanceName + " · " + entry.evidence)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .padding(.top, 5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(entry.record.session.displayTitle)，"
                                        + "\(entry.record.instanceName)，\(entry.status)，\(entry.evidence)")
                    .accessibilityHint("打开此实例中的原生会话，核对并处理任务")
                    .id(entry.id)
                    Divider().padding(.horizontal, AppTheme.pagePadding)
                }
            }
        }
    }

    private var visibleScrollIDs: [String] {
        section == 1 ? taskEntries.map(\.id) : visible.map(\.id)
    }

    private var failedScrollSources: Set<UnifiedSessionIdentity> {
        Set(center.failures.keys)
    }

    private var waitingForBookmarkHost: Bool {
        guard let anchor = section == 1 ? taskScrollAnchor : sessionScrollAnchor else {
            return false
        }
        return !visibleScrollIDs.contains(anchor)
            && UnifiedBrowserScrollPolicy.onFailedSource(
                anchor, failures: failedScrollSources)
    }

    private func reconcileScrollBookmark() {
        guard center.hasResolvedSnapshot, center.loading.isEmpty else { return }
        let available = visibleScrollIDs
        if section == 1 {
            let next = UnifiedBrowserScrollPolicy.reconcile(
                anchor: taskScrollAnchor, index: taskScrollIndex, available: available,
                resolved: true, failedSources: failedScrollSources)
            if next != taskScrollAnchor {
                userOwnsScroll = false
                taskScrollAnchor = next
                visibleScrollID = next
            }
        } else {
            let next = UnifiedBrowserScrollPolicy.reconcile(
                anchor: sessionScrollAnchor, index: sessionScrollIndex, available: available,
                resolved: true, failedSources: failedScrollSources)
            if next != sessionScrollAnchor {
                userOwnsScroll = false
                sessionScrollAnchor = next
                visibleScrollID = next
            }
        }
    }

    private func restoreScrollBookmark() {
        userOwnsScroll = false
        let saved = section == 1 ? taskScrollAnchor : sessionScrollAnchor
        visibleScrollID = UnifiedBrowserScrollPolicy.reconcile(
            anchor: saved, index: section == 1 ? taskScrollIndex : sessionScrollIndex,
            available: visibleScrollIDs,
            resolved: center.hasResolvedSnapshot && center.loading.isEmpty,
            failedSources: failedScrollSources)
    }

    private func rememberScrollBookmark(_ id: String?) {
        // SwiftUI also publishes scrollPosition changes caused by restored
        // frames, filtering and refresh. Only a real user interaction may
        // overwrite the root-owned reading bookmark.
        guard userOwnsScroll, let id,
              let index = visibleScrollIDs.firstIndex(of: id) else { return }
        if section == 1 {
            taskScrollAnchor = id
            taskScrollIndex = index
        } else {
            sessionScrollAnchor = id
            sessionScrollIndex = index
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel(backToSingleInstance ? "返回当前实例会话" :
                                    (backToDrawer ? "返回侧栏" : "返回聊天"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("全部实例").font(.title2.weight(.semibold))
                    Text("跨 \(app.instances.count) 个 Hermes 实例")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("当前实例会话", systemImage: "server.rack", action: onSingleInstance)
                    Button("刷新全部实例", systemImage: "arrow.clockwise") {
                        guard !userRefreshing else { return }
                        userRefreshing = true
                        Task {
                            let run = center.start(sources: sources(), query: requestQuery)
                            await run.value
                            userRefreshing = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if userRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "ellipsis")
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .accessibilityLabel("切换浏览范围与刷新")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Picker("浏览内容", selection: $section) {
                Text("会话").tag(0)
                Text("任务").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.top, 5)
            if section == 1 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选任务或实例", text: $taskSearch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !taskSearch.isEmpty {
                        Button { taskSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 44)
                        }
                        .accessibilityLabel("清除任务筛选")
                    }
                }
                .padding(.leading, 12)
                .frame(height: 44)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: AppTheme.radiusS))
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索所有实例", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .accessibilityHint("WebUI 搜索正文；Gateway 仅搜索标题和摘要")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, height: 44)
                        }
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.leading, 12)
                .frame(height: 44)
                .background(Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: AppTheme.radiusS))
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 8)
                .buttonStyle(.plain)

                Picker("筛选", selection: $filter) {
                    Text("全部").tag(0)
                    Text("最近运行").tag(1)
                    Text("置顶").tag(2)
                    Text("近7天").tag(3)
                    Text("待核对").tag(4)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, 10)

            }

            SessionRefreshList(scrollID: $visibleScrollID,
                               onUserScroll: { userOwnsScroll = true },
                               refresh: {
                // Join an in-flight identical request rather than replacing it.
                let run = center.start(sources: sources(), query: requestQuery)
                await run.value
            }) {
                if waitingForBookmarkHost {
                    Label("原浏览位置所在实例暂不可用；已保留位置，重试后尝试恢复。",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 6)
                }
                if let navigationError {
                    Label(navigationError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 8)
                }
                if !center.loading.isEmpty && !center.hasResolvedSnapshot &&
                   center.records.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("首次读取会话…")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, AppTheme.pagePadding)
                    .padding(.vertical, 8)
                }
                ForEach(app.instances) { instance in
                    let endpoint = ChatHistoryIdentity.instanceID(id: instance.id,
                                                                   baseURL: instance.baseURL)
                    let identity = UnifiedSessionIdentity(instanceID: instance.id,
                        endpointIdentity: endpoint,
                        accountScope: ChatHistoryIdentity.accountScope(instanceID: endpoint))
                    if let error = center.failures[identity] {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Image(systemName: "wifi.exclamationmark")
                                Text(instance.name).fontWeight(.medium).lineLimit(1)
                                Spacer(minLength: 0)
                                Button("重试") {
                                    guard let source = sources().first(where: {
                                        $0.identity == identity
                                    }) else { return }
                                    Task { await center.retry(source: source, query: requestQuery) }
                                }
                                .font(.caption.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .disabled(center.loading.contains(identity))
                                .accessibilityLabel("重试实例 \(instance.name)")
                            }
                            Text(error).lineLimit(2)
                            Text("其他实例仍可浏览，重试仅重新请求此实例。")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 6)
                    }
                }
                if section == 1 {
                    taskResults
                } else {
                if visible.isEmpty && center.loading.isEmpty {
                    if !app.instances.isEmpty &&
                       center.failures.count == app.instances.count {
                        HermesEmptyState(symbol: "wifi.exclamationmark",
                            title: "所有实例读取失败",
                            message: "尚未确认会话是否为空。可分别重试失败实例。")
                            .padding(.top, 44)
                    } else if !center.failures.isEmpty {
                        HermesEmptyState(symbol: "wifi.exclamationmark",
                            title: "部分实例不可用",
                            message: "其余实例暂无匹配结果；失败实例尚未完成查询。")
                            .padding(.top, 44)
                    } else {
                        HermesEmptyState(symbol: "square.stack",
                            title: query.isEmpty ? "暂无会话" : "没有匹配的会话",
                            message: "可下拉刷新；网关只搜索会话标题与摘要。")
                            .padding(.top, 44)
                    }
                }
                ForEach(visible) { record in
                    Button {
                        navigationError = nil
                        if !onSelect(record) {
                            navigationError = "实例或账号已变化，请刷新后重新选择。"
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(record.session.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                switch runEvidence(for: record) {
                                case .recentlyRunning:
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("最近确认运行")
                                case .historicalRunning:
                                    Image(systemName: "clock.badge.questionmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("历史运行记录，状态待核对")
                                case .recentlyNotRunning, .unknown:
                                    EmptyView()
                                }
                                if record.session.pinned == true {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .accessibilityLabel("已置顶")
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let excerpt = record.excerpt, !excerpt.isEmpty {
                                Text(excerpt).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "server.rack")
                                Text(record.instanceName).lineLimit(1)
                                if record.matchedFullBody {
                                    Text("· 正文匹配")
                                }
                                Spacer(minLength: 4)
                                if let date = record.session.updatedDate {
                                    Text(date, style: .relative)
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(record.session.displayTitle)，实例 \(record.instanceName)")
                    .id(record.id)
                    Divider().padding(.horizontal, AppTheme.pagePadding)
                }
                }
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(AppTheme.canvas)
        .task(id: scopeStamp + "\u{0}" + requestQuery + "\u{0}" + String(section)) {
            if section == 0 && !requestQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { try await Task.sleep(nanoseconds: 350_000_000) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            navigationError = nil
            // Cache-first: no network for a fresh query/scope. Expired
            // snapshots refresh silently without clearing the visible rows.
            if let run = center.refreshIfNeeded(sources: sources(), query: requestQuery,
                                                   maxAge: section == 1
                                                       ? UnifiedTaskWorkspace.freshnessWindow : nil) {
                await run.value
            }
        }
        // Snapshot decoding is scoped and amortized, not repeated by each
        // task row's body evaluation or by the card's drag progress.
        .task(id: scopeStamp + "|task|" + String(section)
                  + "|host|" + String(app.activeChangeToken)) {
            refreshTaskSnapshots()
        }
        .task(id: evidenceExpiryKey) {
            guard let deadline = nextEvidenceDeadline else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(
                    max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled else { return }
            taskEvidenceNow = Date()
        }
        .onAppear { restoreScrollBookmark() }
        .onChange(of: visibleScrollID) { _, newValue in
            rememberScrollBookmark(newValue)
        }
        .onChange(of: section) { _, _ in
            restoreScrollBookmark()
        }
        .onChange(of: query) { _, _ in
            userOwnsScroll = false
            sessionScrollAnchor = nil
            sessionScrollIndex = 0
            if section == 0 { visibleScrollID = nil }
        }
        .onChange(of: taskSearch) { _, _ in
            userOwnsScroll = false
            taskScrollAnchor = nil
            taskScrollIndex = 0
            if section == 1 { visibleScrollID = nil }
        }
        .onChange(of: filter) { _, _ in
            userOwnsScroll = false
            sessionScrollAnchor = nil
            sessionScrollIndex = 0
            if section == 0 { visibleScrollID = nil }
        }
        .onChange(of: visibleScrollIDs) { _, _ in
            userOwnsScroll = false
            reconcileScrollBookmark()
        }
        .onChange(of: center.loading) { _, loading in
            if !loading.isEmpty { userOwnsScroll = false }
            if loading.isEmpty {
                taskEvidenceNow = Date()
                reconcileScrollBookmark()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                taskEvidenceNow = Date()
                refreshTaskSnapshots()
            }
        }
        .onDisappear { center.cancel() }
    }
}
