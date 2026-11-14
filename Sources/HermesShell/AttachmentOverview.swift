import SwiftUI

/// An explicit, bounded view of the conversation's loaded attachment metadata.
/// Earlier pages use the existing atomic history pager; no second full-history
/// fetch or eager full-size attachment download is started by opening this page.
struct AttachmentOverview: View {
    @ObservedObject var model: NativeChatModel
    let baseURL: URL
    let sessionID: String
    let scope: String
    /// 预览/下载该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var authorization: AttachmentAuthorization = .cookieOnly
    let ratios: ImageRatioSnapshot
    let onLocate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter = 0
    @State private var loading = false
    @State private var shown = 20
    @State private var catalog: [AttachmentCatalog.Entry]
    /// 上一次「加载更早历史」的结果提示；nil 表示还没加载过。
    /// 总览按 messages.reversed() 排列，更早的条目落在列表末尾，
    /// 不给出可见反馈时用户会以为按钮没生效。
    @State private var loadOutcome: LoadOutcome?

    init(model: NativeChatModel, baseURL: URL, sessionID: String, scope: String,
         authorization: AttachmentAuthorization = .cookieOnly,
         ratios: ImageRatioSnapshot, onLocate: @escaping (String) -> Void, initialFilter: Int = 0) {
        self.model = model; self.baseURL = baseURL; self.sessionID = sessionID
        self.scope = scope; self.authorization = authorization
        self.ratios = ratios; self.onLocate = onLocate
        _filter = State(initialValue: (0...2).contains(initialFilter) ? initialFilter : 0)
        _catalog = State(initialValue: AttachmentCatalog.entries(model.transcript.messages))
    }

    private struct LoadOutcome: Equatable {
        let added: Int
        let reachedEnd: Bool
    }

    private func paths(_ entry: AttachmentCatalog.Entry) -> [String] {
        HistoryAttachment.parse(entry.paths, baseURL: baseURL).filter {
            (filter == 0 || (filter == 1 ? $0.kind == .image : $0.kind != .image))
                && (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query))
        }.map(\.id)
    }

    private var matching: [AttachmentCatalog.Entry] { catalog.filter { !paths($0).isEmpty } }
    private var canLoad: Bool {
        model.olderOffset > 0 && !model.olderLimitReached && !model.uncertain && !model.running && !model.loading && !model.syncing
            && !model.submitting && !model.reconciling && model.cachedHistoryDate == nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("附件类型", selection: $filter) {
                        Text("全部").tag(0)
                        Text("图片").tag(1)
                        Text("文件").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text(model.olderOffset > 0 ? "仅显示已载入历史中的附件，可继续加载更早记录。" : "已载入历史中的附件。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if matching.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "暂无符合条件的附件" : "未找到附件",
                        systemImage: "paperclip", description: Text("可切换筛选，或加载更早历史。"))
                }

                ForEach(Array(matching.prefix(shown))) { entry in
                    Section {
                        AttachmentStrip(paths: paths(entry), name: "overview-" + entry.id,
                            baseURL: baseURL, sessionID: sessionID, authorization: authorization,
                            imageRatios: ratios, imageRatioScope: scope)
                        Button {
                            onLocate(entry.rowID)
                            dismiss()
                        } label: {
                            Label("定位到原消息", systemImage: "arrow.turn.up.left")
                                .frame(minHeight: 44)
                        }
                    } header: {
                        HStack {
                            Text(entry.role == "user" ? "你" : "Hermes")
                            if let timestamp = entry.timestamp {
                                Text(Date(timeIntervalSince1970: timestamp), style: .date)
                                Text(Date(timeIntervalSince1970: timestamp), style: .time)
                            }
                        }
                    }
                }

                if matching.count > shown {
                    Button("显示更多已载入附件") { shown += 20 }.frame(minHeight: 44)
                }
                if model.olderOffset > 0 {
                    Section {
                        Button {
                            guard canLoad, !loading else { return }
                            loading = true
                            let before = catalog.count
                            Task {
                                await model.loadOlder()
                                loading = false
                                refreshCatalog()
                                // 新条目在列表末尾，落在 prefix(shown) 之外；
                                // 回到第一页并给出计数，按钮才有可见效果。
                                shown = 20
                                loadOutcome = LoadOutcome(
                                    added: max(0, catalog.count - before),
                                    reachedEnd: model.olderOffset <= 0)
                            }
                        } label: {
                            HStack {
                                if loading { ProgressView() }
                                Text(loading ? "正在加载更早历史…" : "加载更早历史中的附件")
                            }.frame(minHeight: 44)
                        }
                        .disabled(!canLoad || loading)
                        if model.running { Text("生成结束后可加载更早历史。") }
                    }
                    if let outcome = loadOutcome {
                        Text(outcomeText(outcome))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会话附件")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索附件名称")
            .onChange(of: query) { _, _ in shown = 20 }
            .onChange(of: filter) { _, _ in shown = 20 }
            .onChange(of: model.olderOffset) { _, _ in refreshCatalog() }
            .onChange(of: model.transcript.messages.count) { _, _ in refreshCatalog() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新附件列表", systemImage: "arrow.clockwise") { refreshCatalog() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func refreshCatalog() { catalog = AttachmentCatalog.entries(model.transcript.messages) }

    /// 加载结果必须说清「多了几条」或「没有更多」，不能让按钮看起来没反应。
    private func outcomeText(_ outcome: LoadOutcome) -> String {
        if outcome.added > 0 {
            return outcome.reachedEnd
                ? "已加载 \(outcome.added) 条更早记录，已到最早。"
                : "已加载 \(outcome.added) 条更早记录。"
        }
        return outcome.reachedEnd ? "已到最早，没有更早的附件。" : "更早的历史里没有附件。"
    }
}
