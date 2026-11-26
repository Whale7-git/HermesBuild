import Combine
import SwiftUI

enum ChatPanel: Identifiable {
    case drawer, models, usage, queue, recovery, navigation, task, info
    case attachments(Int)
    case reader(ChatMessage)
    case share(SharedTemporaryFile)
    var id: String {
        switch self {
        case .drawer: return "drawer"
        case .models: return "models"
        case .usage: return "usage"
        case .queue: return "queue"
        case .recovery: return "recovery"
        case .navigation: return "navigation"
        case .task: return "task"
        case .info: return "info"
        case .attachments(let filter): return "attachments-\(filter)"
        case .reader(let message): return "reader-\(message.id)"
        case .share(let file): return "share-\(file.id)"
        }
    }
}

enum ChatPanelAction {
    case settings, newSession, find, select(SessionSummary), locateTool(String), export(fullHistory: Bool)
    case locateMessage(String), latestMessage
}

/// The current conversation's task detail. Cross-session discovery belongs on
/// the home list, where every row is backed by server truth or a local fact.
struct ChatTaskPanel: View {
    @ObservedObject var model: NativeChatModel
    let onQueue: () -> Void
    let onRecovery: () -> Void
    let onLocateTool: (String) -> Void
    @State private var toolFilter: ChatTaskToolFilter = .all
    @State private var toolQuery = ""
    @State private var visibleToolLimit = 40
    @State private var toolSnapshot = ChatTaskToolInspector.Snapshot()
    @State private var matchingTools: [ChatTaskToolInspector.Row] = []
    @State private var projectedStructureID: UUID?
    @State private var projectedLive: Bool?
    @Environment(\.dismiss) private var dismiss
    private var queue: ChatQueueStatus { ChatQueueStatus(turns: model.queuedTurns) }

    var body: some View {
        let counts = toolSnapshot.counts
        let matching = matchingTools
        let visible = matching.prefix(visibleToolLimit)
        NavigationStack {
            List {
                Section("当前会话") {
                    Label(model.presentationState.title,
                          systemImage: model.presentationState.showsProgress ? "waveform"
                          : (model.presentationState.showsWarning ? "exclamationmark.circle" : "bubble.left"))
                    if model.pendingApproval != nil {
                        Label("需要你确认后继续；请回聊天页处理审批。", systemImage: "hand.raised")
                            .foregroundStyle(AppTheme.warning)
                        Button("返回聊天处理审批") { dismiss() }
                    }
                    if model.pendingClarify != nil {
                        Label("需要你补充信息后继续。", systemImage: "questionmark.bubble")
                            .foregroundStyle(AppTheme.warning)
                        Button("返回聊天补充信息") { dismiss() }
                    }
                    if model.presentationState.hasError, let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(AppTheme.warning).textSelection(.enabled)
                    }
                    if let notice = model.presentationState.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("消息与恢复") {
                    Button(action: onQueue) {
                        Label(queue.isEmpty ? "消息队列为空" : queue.summary,
                              systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button(action: onRecovery) {
                        Label("核对发送与本地数据", systemImage: "lifepreserver")
                    }
                    Text("断开连接不代表后台任务停止。发送结果不明确时先核对，不自动重发。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack(spacing: 8) {
                        Text("总计 \(counts.total)")
                        Spacer(minLength: 0)
                        Text("完成 \(counts.finished)")
                        Text("失败 \(counts.failed)")
                            .foregroundStyle(counts.failed > 0 ? AppTheme.warning : Color.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if counts.active > 0 || counts.unresolved > 0 {
                        Text("执行中 \(counts.active) · 状态待核对 \(counts.unresolved)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("工具状态", selection: $toolFilter) {
                        ForEach(ChatTaskToolFilter.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索工具名称或 ID", text: $toolQuery)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !toolQuery.isEmpty {
                            Button { toolQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除工具搜索")
                        }
                    }
                    if matching.isEmpty {
                        Text(toolSnapshot.rows.isEmpty ? "当前没有可关联的工具记录" : "没有符合筛选条件的工具")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("显示 \(visible.count) / \(matching.count) 条 · 最新在前")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(visible) { tool in
                            Button { onLocateTool(tool.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: tool.status == .failed ? "exclamationmark.circle"
                                          : (tool.status == .finished ? "checkmark.circle" : "clock"))
                                        .foregroundStyle(tool.status == .failed ? AppTheme.warning : Color.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tool.name).font(.subheadline).foregroundStyle(.primary)
                                        Text(tool.status == .failed ? "执行失败" :
                                             (tool.status == .finished ? "已完成" :
                                              (tool.status == .active ? "执行中" : "状态待核对")))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("跳转到聊天中对应的工具过程并展开")
                        }
                        if visible.count < matching.count {
                            Button("显示更早的 \(min(40, matching.count - visible.count)) 条") {
                                visibleToolLimit += 40
                            }
                            .frame(minHeight: 44)
                        }
                    }
                } header: { Text("本轮工具") }
                  footer: {
                    Text("搜索覆盖当前已加载的本轮工具。点击可定位原始工具记录；完整参数和结果可在详情内搜索。")
                }
            }
            .scrollContentBackground(.hidden).background(AppTheme.canvas)
            .onReceive(model.$transcript.combineLatest(model.$phase, model.$uncertain, model.$suspended)) { values in
                let (transcript, phase, uncertain, suspended) = values
                let live = phase.isRunning && phase.isConnected && !uncertain && !suspended && !transcript.terminal
                if let identity = transcript.transcriptStructureID,
                   identity == projectedStructureID, live == projectedLive { return }
                projectedStructureID = transcript.transcriptStructureID
                projectedLive = live
                let snapshot = ChatTaskToolInspector.snapshot(messages: transcript.messages,
                    tools: transcript.tools, live: live)
                if snapshot != toolSnapshot {
                    toolSnapshot = snapshot
                    matchingTools = snapshot.matching(filter: toolFilter, query: toolQuery)
                }
            }
            .onChange(of: toolFilter) { _, _ in updateToolFilter() }
            .onChange(of: toolQuery) { _, _ in updateToolFilter() }
            .navigationTitle("任务与消息队列").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            } }
        }
    }
    private func updateToolFilter() {
        visibleToolLimit = 40
        matchingTools = toolSnapshot.matching(filter: toolFilter, query: toolQuery)
    }
}

struct ChatConversationInfo: View {
    @ObservedObject var model: NativeChatModel
    let title: String
    let instance: String
    let modelLabel: String
    let baseURL: URL
    let sessionID: String
    let scope: String
    /// 预览/下载该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var authorization: AttachmentAuthorization = .cookieOnly
    let ratios: ImageRatioSnapshot
    let canExportFullHistory: Bool
    let onPanel: (ChatPanel) -> Void
    let onFind: () -> Void
    let onExport: (Bool) -> Void
    @State private var catalog: [AttachmentCatalog.Entry] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.title2.weight(.semibold))
                        Text("\(instance) · \(modelLabel)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section {
                    if let entry = catalog.first {
                        AttachmentStrip(paths: Array(entry.paths.prefix(4)), name: "info-\(entry.id)",
                            baseURL: baseURL, sessionID: sessionID, authorization: authorization,
                            imageRatios: ratios, imageRatioScope: scope)
                    }
                    Button { onPanel(.attachments(1)) } label: { Label("图片", systemImage: "photo.on.rectangle") }
                    Button { onPanel(.attachments(2)) } label: { Label("文件", systemImage: "doc") }
                    Button { onPanel(.attachments(0)) } label: { Label("所有会话附件", systemImage: "paperclip") }
                } header: { Text("图片与文件") }
                  footer: { Text("仅展示已载入历史中的附件；附件页可主动加载更早记录并定位到原消息。") }
                Section("浏览") {
                    Button(action: onFind) { Label("在当前会话查找", systemImage: "magnifyingglass") }
                    Button { onPanel(.navigation) } label: { Label("消息导航", systemImage: "list.bullet.rectangle") }
                        .disabled(model.transcript.messages.allSatisfy { $0.role != "user" })
                    Button { onPanel(.usage) } label: { Label("上下文与用量", systemImage: "chart.bar") }
                    Button { onPanel(.task) } label: { Label("任务与消息队列", systemImage: "waveform") }
                }
                Section {
                    Button { onExport(false) } label: { Label("导出已加载内容", systemImage: "square.and.arrow.up") }
                        .disabled(model.transcript.messages.isEmpty)
                    Button { onExport(true) } label: { Label("获取完整历史后导出", systemImage: "clock.arrow.circlepath") }
                        .disabled(model.transcript.messages.isEmpty || !canExportFullHistory)
                    if !canExportFullHistory {
                        Text("生成中、核对中或离线时仍可导出已加载内容。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("导出") }
            }
            .scrollContentBackground(.hidden).background(AppTheme.canvas)
            .navigationTitle("会话资料").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { refreshCatalog() }
            .onChange(of: model.olderOffset) { _, _ in refreshCatalog() }
            .onChange(of: model.transcript.messages.count) { _, _ in refreshCatalog() }
        }
    }
    private func refreshCatalog() { catalog = AttachmentCatalog.entries(model.transcript.messages) }
}
