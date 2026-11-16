import SwiftUI

/// Full-page cross-host browser. Drawer and native chat stay untouched while
/// read-only discovery runs; changing the active instance happens only on tap.
struct UnifiedSessionBrowser: View {
    @EnvironmentObject var app: AppState
    let onClose: () -> Void
    let backToSingleInstance: Bool
    let backToDrawer: Bool
    let onSingleInstance: () -> Void
    let onSelect: (UnifiedSessionRecord) -> Bool

    @ObservedObject var center: UnifiedSessionModel
    @Binding var query: String
    @Binding var filter: Int
    @State private var navigationError: String?

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

    private var visible: [UnifiedSessionRecord] {
        let now = Date()
        return center.records.filter { item in
            switch filter {
            case 1: return item.session.isStreaming == true
            case 2: return item.session.pinned == true
            case 3: return item.session.updatedDate.map {
                now.timeIntervalSince($0) <= 7 * 24 * 60 * 60
            } ?? false
            default: return true
            }
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
                        center.start(sources: sources(), query: query)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("切换浏览范围与刷新")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)

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
                Text("运行中").tag(1)
                Text("置顶").tag(2)
                Text("近7天").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.bottom, 10)

            SessionRefreshList(refresh: {
                // Join an in-flight identical request rather than replacing it.
                let run = center.start(sources: sources(), query: query)
                await run.value
            }) {
                if let navigationError {
                    Label(navigationError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .padding(.vertical, 8)
                }
                if !center.loading.isEmpty && center.records.isEmpty {
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
                                    Task { await center.retry(source: source, query: query) }
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
                                if record.session.isStreaming == true {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("运行中")
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
                    Divider().padding(.horizontal, AppTheme.pagePadding)
                }
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(AppTheme.canvas)
        .task(id: scopeStamp + "\u{0}" + query) {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { try await Task.sleep(nanoseconds: 350_000_000) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            navigationError = nil
            // Cache-first: no network for a fresh query/scope. Expired
            // snapshots refresh silently without clearing the visible rows.
            if let run = center.refreshIfNeeded(sources: sources(), query: query) {
                await run.value
            }
        }
        .onDisappear { center.cancel() }
    }
}
