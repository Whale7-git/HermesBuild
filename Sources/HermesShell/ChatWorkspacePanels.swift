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
    case settings, newSession, find, select(SessionSummary), export(fullHistory: Bool)
}

/// The current conversation's task detail. Cross-session discovery belongs on
/// the home list, where every row is backed by server truth or a local fact.
struct ChatTaskPanel: View {
    @ObservedObject var model: NativeChatModel
    let onQueue: () -> Void
    let onRecovery: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var queue: ChatQueueStatus { ChatQueueStatus(turns: model.queuedTurns) }

    var body: some View {
        let liveIDs = activeIDs
        NavigationStack {
            List {
                Section("当前会话") {
                    Label(model.activity.title,
                          systemImage: model.activity.showsProgress ? "waveform" : "bubble.left")
                    if model.pendingApproval != nil {
                        Label("需要你确认后继续；请回聊天页处理审批。", systemImage: "hand.raised")
                            .foregroundStyle(AppTheme.warning)
                        Button("返回聊天处理审批") { dismiss() }
                    }
                    if let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(AppTheme.warning).textSelection(.enabled)
                    }
                    if let notice = model.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("消息与恢复") {
                    Button(action: onQueue) {
                        Label(queue.isEmpty ? "消息队列为空" : queue.summary, systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button(action: onRecovery) {
                        Label("核对发送与本地数据", systemImage: "lifepreserver")
                    }
                    Text("断开连接不代表后台任务停止。发送结果不明确时先核对，不自动重发。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if currentTools.isEmpty {
                        Text("当前没有可关联的工具记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(currentTools) { tool in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: tool.isError ? "exclamationmark.circle" : (tool.done ? "checkmark.circle" : "clock"))
                                    .foregroundStyle(tool.isError ? AppTheme.warning : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tool.name).font(.subheadline)
                                    Text(tool.isError ? "执行失败" : (tool.done ? "已完成" : (liveIDs.contains(tool.id) && model.running ? "执行中" : "状态待核对")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("本轮工具") }
                  footer: { Text("只显示当前一轮最多 40 条工具；完整过程可在聊天中展开。") }
            }
            .scrollContentBackground(.hidden).background(AppTheme.canvas)
            .navigationTitle("任务与消息队列").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var activeIDs: Set<String> {
        ChatActivity.activeToolIDs(messages: model.transcript.messages, tools: model.transcript.tools)
    }
    private var currentTools: [ChatTool] {
        let messages = model.transcript.messages
        let start = messages.lastIndex(where: { $0.role == "user" }) ?? messages.startIndex
        let anchors = Set(messages[start...].map(\.id))
        return Array(model.transcript.tools.filter { tool in
            tool.afterMessageID.map { anchors.contains($0) } == true
        }.suffix(40))
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
