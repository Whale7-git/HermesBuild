import SwiftUI

/// List supplies a native refresh control in every state, including zero rows
/// and a single short row. Row styling stays with the existing session views.
struct SessionRefreshList<Content: View>: View {
    let refresh: () async -> Void
    let content: Content
    /// Only the cross-instance browser opts into a target-aware scroll view.
    /// Existing single-instance lists retain native List presentation.
    let scrollID: Binding<String?>?

    init(scrollID: Binding<String?>? = nil, refresh: @escaping () async -> Void,
         @ViewBuilder content: () -> Content) {
        self.scrollID = scrollID
        self.refresh = refresh
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if let scrollID {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    content
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: scrollID, anchor: .top)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await refresh() }
        } else {
            List {
                content
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .listRowSpacing(4)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await refresh() }
        }
    }
}

/// WebUI searches full history; gateway discovery matches titles/previews.
@MainActor struct SessionSearchView: View {
    let query: String
    let scope: String
    let service: SessionDiscoveryService
    let onSelect: (SessionSummary) -> Void
    @ObservedObject var app: AppState
    @ObservedObject var model: SessionSearchModel

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 是否搜索正文。读能力表：网关只匹配标题与预览。
    private var searchesFullHistory: Bool { app.api.capabilities.searchesFullBody }

    var body: some View {
        SessionRefreshList(refresh: { await model.refresh(query: query, scope: scope, service: service) }) {
                if model.scope == scope {
                    searchStatus
                    if model.hits.isEmpty && !model.loading && model.errorText == nil {
                        HermesEmptyState(symbol: "magnifyingglass",
                                         title: "没有匹配的对话",
                                         message: needle.isEmpty
                                            ? (searchesFullHistory ? "输入关键词搜索标题与完整正文。" : "输入关键词搜索会话标题与摘要。")
                                            : (searchesFullHistory ? "「\(needle)」没有命中标题或正文，试试更短的关键词。"
                                                : "「\(needle)」没有命中标题或摘要，试试更短的关键词。"))
                            .padding(.top, 48)
                            .padding(.bottom, 24)
                    }
                    if !model.hits.isEmpty {
                        Text("\(model.hits.count) 个结果")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 6)
                        ForEach(model.hits) { hit in
                            SessionRowContainer(showsSeparator: hit.id != model.hits.last?.id) {
                                Button { onSelect(hit.session) } label: {
                                    HStack(alignment: .top, spacing: 0) {
                                        SessionRowContent(title: hit.session.displayTitle,
                                            preview: hit.preview, date: hit.session.updatedDate,
                                            pinned: hit.session.pinned == true,
                                            running: hit.session.isStreaming == true,
                                            badge: badge(for: hit), highlight: needle)
                                            .padding(.horizontal, 12)
                                            .accessibilityLabel(searchRowLabel(for: hit))
                                        // 搜索结果与主列表同一套完成标记；只在标题行 trailing 占位。
                                        SessionCompletionDot(
                                            completed: app.completedSessionIDs.contains(hit.session.sessionId))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else { ProgressView().padding(24) }
        }
        .task(id: scope) { search() }
        .onChange(of: query) { _, _ in search() }
        .onDisappear { model.cancel() }
    }

    /// 加载态只在还没有结果时占一整行；有旧结果时由页脚小菊花表示刷新，列表不闪白。
    @ViewBuilder
    private var searchStatus: some View {
        if model.loading && model.hits.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在搜索…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        if let error = model.errorText {
            VStack(alignment: .leading, spacing: 12) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                Button("重试搜索") {
                    Task { await model.refresh(query: query, scope: scope, service: service) }
                }.frame(minHeight: 44)
            }
            .padding(24)
        }
    }

    /// 服务端只在两种命中类型间取值；未知类型不猜成「标题匹配」，宁可不显示。
    private func badge(for hit: SessionSearchHit) -> String? {
        let kind: String?
        switch hit.matchType ?? "" {
        case "content": kind = searchesFullHistory ? "正文" : "摘要"
        case "title": kind = "标题"
        default: kind = nil
        }
        guard hit.session.archived == true else { return kind }
        return kind.map { "\($0) · 已归档" } ?? "已归档"
    }

    /// 结果行沿用「标题 + 摘要 + 命中类型」，完成标记以「有新回复」追加在末尾。
    private func searchRowLabel(for hit: SessionSearchHit) -> Text {
        var label = Text(hit.session.displayTitle)
        if let preview = hit.preview, !preview.isEmpty { label = label + Text("，\(preview)") }
        if let badge = badge(for: hit) { label = label + Text("，\(badge)") }
        if app.completedSessionIDs.contains(hit.session.sessionId) { label = label + Text("，有新回复") }
        return label
    }

    private func search() { model.update(query: query, scope: scope, service: service) }
}

@MainActor struct SessionArchiveView: View {
    let scope: String
    let service: SessionDiscoveryService
    let onSelect: (SessionSummary) -> Void
    @ObservedObject var app: AppState
    @ObservedObject var model: SessionArchiveModel

    var body: some View {
        SessionRefreshList(refresh: { await model.reload(scope: scope, service: service) }) {
                if model.scope == scope {
                    ForEach(model.sessions) { session in
                        SessionRowContainer(showsSeparator: session.id != model.sessions.last?.id) {
                            Button { onSelect(session) } label: {
                                SessionRowContent(title: session.displayTitle,
                                    preview: archivePreview(for: session), date: session.updatedDate,
                                    pinned: session.pinned == true)
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.plain)
                        }
                        .contextMenu {
                            Button { restore(session) } label: {
                                Label("恢复到会话列表", systemImage: "arrow.uturn.backward")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { restore(session) } label: {
                                Label("恢复", systemImage: "arrow.uturn.backward")
                            }
                            .tint(AppTheme.accent)
                        }
                        .accessibilityAction(named: "恢复") { restore(session) }
                    }
                    if model.loading {
                        ProgressView("正在读取归档…").font(.footnote).padding(24)
                    } else {
                        if let error = model.errorText {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.orange).padding(.horizontal, 24).padding(.top, 12)
                        } else if model.sessions.isEmpty {
                            HermesEmptyState(symbol: "archivebox",
                                             title: "没有归档会话",
                                             message: "归档的对话会保留在这里，可随时恢复。")
                                .padding(.top, 48)
                                .padding(.bottom, 24)
                        }
                        if model.nextOffset != nil {
                            Button(model.errorText == nil ? "加载更多" : "重试加载") {
                                Task { await model.loadMore(service: service) }
                            }
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .padding(.horizontal, 24)
                        } else if !model.sessions.isEmpty {
                            Text("已载入全部 \(model.sessions.count) 个归档")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        }
                    }
                } else { ProgressView().padding(24) }
        }
        .task(id: scope) { await model.reload(scope: scope, service: service) }
        .onDisappear { model.reset() }
    }

    /// 恢复由服务端确认后，归档分页与主列表都重读一次：
    /// 该行离开归档列表，同时按真实顺序回流到会话列表。
    /// 与主列表同一套兜底：服务端不再下发 preview 时，用消息条数代替空文案。
    private func archivePreview(for session: SessionSummary) -> String? {
        if let text = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        let count = session.messageCount ?? 0
        return count > 0 ? "\(count) 条消息" : nil
    }

    private func restore(_ session: SessionSummary) {
        Task {
            await app.restore(sessionID: session.sessionId)
            guard app.sessionActionError == nil else { return }
            await model.reload(scope: scope, service: service)
            await app.refresh()
        }
    }
}
