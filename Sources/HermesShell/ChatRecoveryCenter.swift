import SwiftUI

/// One place for all recoverable local state. It deliberately exposes actions
/// that already exist in the chat model instead of introducing a second send
/// or reconciliation path.
struct ChatRecoveryCenter: View {
    @ObservedObject var model: NativeChatModel
    var onManageQueue: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAbandonUnreadable = false
    @State private var confirmAbandonActive = false
    @State private var confirmAbandonCorruptActive = false
    @State private var reconciling = false
    @State private var queueRecoveryID: String?
    @State private var resultText: String?
    private var queueStatus: ChatQueueStatus { ChatQueueStatus(turns: model.queuedTurns) }

    var body: some View {
        NavigationStack {
            List {
                if model.recoveryRecordsUnreadable {
                    Section("重新读取恢复记录") {
                        Text("本地文件暂时不可读或损坏。优先重新读取原记录，而不是放弃发送证据；读取成功后仍需联网核对。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            Task {
                                let restored = model.restoreUnreadableRecoveryRecords()
                                if restored {
                                    await model.refresh(silent: true, preserveLoadedOlder: true)
                                }
                                resultText = restored
                                    ? "本地记录已重新读取，请查看联网核对结果。"
                                    : "仍有恢复记录不可读；原文件与安全锁已保留。"
                            }
                        } label: {
                            Label("重新读取并核对", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .disabled(model.running || model.loading || model.syncing || model.reconciling)
                        if model.queueRecoveryUnreadable {
                            Text("队列记录不可读，暂不能编辑、清空或发送；原文件保留。")
                                .font(.caption).foregroundStyle(AppTheme.warning)
                        }
                    }
                }
                if model.pendingRecoveryUnreadable {
                    Section("发送恢复记录不可读") {
                        Text("为避免重复发送，当前暂停提交。请先查看服务端历史；放弃记录不会停止或撤销服务端任务。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("已核对历史，放弃损坏记录", role: .destructive) {
                            confirmAbandonUnreadable = true
                        }
                    }
                }
                Section("发送核对") {
                    statusRow(icon: model.hasPendingSend ? "paperplane.badge.clock" : "checkmark.circle",
                              color: model.hasPendingSend ? AppTheme.warning : AppTheme.success,
                              title: model.hasPendingSend ? "有一笔发送等待核对" : "没有待核对发送",
                              detail: model.hasPendingSend
                                ? "核对只读取服务端历史；确认不存在前不会自动重发。"
                                : "普通发送没有留下未决记录。")
                    if model.hasPendingSend {
                        Button {
                            reconcile()
                        } label: {
                            HStack {
                                Label(reconciling ? "正在核对…" : "核对发送状态",
                                      systemImage: "checkmark.shield")
                                Spacer()
                                if reconciling { ProgressView().controlSize(.small) }
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(reconciling || model.loading || model.syncing
                                  || model.submitting || model.reconciling)
                    }
                }

                Section("消息队列") {
                    statusRow(icon: model.queuedTurns.isEmpty ? "tray" : "text.line.first.and.arrowtriangle.forward",
                              color: model.queuePersistenceFailed || queueStatus.needsAttention
                                ? AppTheme.warning : AppTheme.accent,
                              title: model.queueRecoveryUnreadable ? "队列记录不可读" :
                                (model.queuedTurns.isEmpty ? "消息队列为空" : queueStatus.summary),
                              detail: model.queueRecoveryUnreadable
                                ? "已保留原队列文件；重新读取成功前不能修改。"
                                : model.queuePersistenceFailed
                                ? "队列本次未通过磁盘回读验证；当前进程内仍可继续操作。"
                                : (model.queuedTurns.isEmpty
                                   ? "没有跨会话遗留的排队消息。"
                                   : (queueStatus.needsAttention
                                      ? "待核对消息已固定到队首；确认不存在前不会自动重发。"
                                      : "重试首条前会先核对是否已送达，避免重复执行。")))
                    if let turn = model.queuedTurns.first {
                        Button {
                            recoverQueue(turn)
                        } label: {
                            HStack {
                                Label(queueRecoveryID == turn.id ? "正在核对…"
                                      : (turn.delivery == .uncertain ? "确认后重试首条" : "发送首条"),
                                      systemImage: "arrow.clockwise")
                                Spacer()
                                if queueRecoveryID == turn.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(queueRecoveryID != nil || turn.delivery == .submitting
                                  || (turn.delivery != .uncertain && !model.canSend))
                    }
                    Button {
                        dismiss()
                        onManageQueue()
                    } label: {
                        Label("打开消息队列", systemImage: "list.bullet.rectangle")
                            .frame(minHeight: 44)
                    }
                    if model.queuePersistenceFailed && !model.queueRecoveryUnreadable {
                        Button {
                            Task {
                                let result = model.retryQueuePersistence()
                                model.recordVerifiedLocalRetry(result, kind: .queue)
                                resultText = result.succeeded
                                    ? "队列已重新写入并通过回读验证。"
                                    : "这次写入仍未通过验证；队列继续保留在当前进程内。"
                            }
                        } label: {
                            Label("重新验证队列写入", systemImage: "arrow.clockwise.icloud")
                                .frame(minHeight: 44)
                        }
                    }
                }

                if model.activeRecoveryUnreadable {
                    Section("运行恢复记录不可读") {
                        Text("服务端任务可能仍在执行。请先通过服务端历史确认，再决定是否放弃这份本地记录。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("已核对，放弃损坏的运行记录", role: .destructive) {
                            confirmAbandonCorruptActive = true
                        }
                    }
                }
                Section("后台运行") {
                    if model.activeTurnRecovery != nil {
                        statusRow(icon: model.running ? "waveform" : "questionmark.circle",
                                  color: AppTheme.warning,
                                  title: model.running ? "已记录后台运行" : "已受理的运行仍待确认",
                                  detail: "运行标识已保存；状态查询不会重复提交消息。")
                        if !model.running {
                            Button("已核对服务端，放弃本地运行标记", role: .destructive) {
                                confirmAbandonActive = true
                            }
                            .disabled(model.loading || model.syncing || model.reconciling)
                        }
                    }
                    statusRow(icon: model.runRecoveryNoticeShown
                              ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath",
                              color: model.runRecoveryNoticeShown ? AppTheme.warning : AppTheme.success,
                              title: model.runRecoveryNoticeShown
                                ? "后台恢复记录降级" : "后台运行恢复可用",
                              detail: model.runRecoveryNoticeShown
                                ? "当前页面不会因此重复发送；重启 App 后可能需要重新核对。"
                                : "本轮运行标识已写入本机。")
                    statusRow(icon: model.cachedHistoryDate == nil ? "internaldrive" : "wifi.exclamationmark",
                              color: model.cachedHistoryDate == nil ? AppTheme.success : AppTheme.warning,
                              title: model.cachedHistoryDate == nil ? "历史缓存正常" : "正在使用本地历史",
                              detail: model.cachedHistoryDate == nil
                                ? "打开会话时会先显示本机副本，再联网核对。"
                                : "联网核对完成后可继续发送。")
                    if model.error != nil || model.cachedHistoryDate != nil {
                        Button {
                            Task { await model.refresh(silent: true, preserveLoadedOlder: true) }
                        } label: {
                            Label("重新联网核对", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .disabled(model.loading || model.syncing || model.submitting)
                    }
                }

                Section {
                    statusRow(icon: model.localPersistenceIssue == nil && !model.queuePersistenceFailed
                              ? "checkmark.shield.fill" : "internaldrive.fill",
                              color: model.localPersistenceIssue == nil && !model.queuePersistenceFailed
                                ? AppTheme.success : AppTheme.warning,
                              title: model.localPersistenceIssue == nil && !model.queuePersistenceFailed
                                ? "本地存储正常" : "本地存储需要处理",
                              detail: model.localPersistenceIssue == nil && !model.queuePersistenceFailed
                                ? "草稿与队列最近一次写入已通过回读验证。"
                                : "当前内存内容仍可用；检查后可继续保存。")
                    if let issue = model.localPersistenceIssue {
                        statusRow(icon: "exclamationmark.triangle.fill", color: AppTheme.warning,
                                  title: localIssueTitle(issue), detail: localIssueDetail(issue))
                    }
                    if model.localPersistenceIssue?.kind == .draft {
                        Button(action: rewriteCurrentDraft) {
                            Label("重新验证当前草稿", systemImage: "doc.badge.arrow.up")
                                .frame(minHeight: 44)
                        }
                    }
                    if model.localPersistenceIssue != nil || model.queuePersistenceFailed {
                        Button {
                            let result = model.validateLocalData()
                            resultText = result.succeeded
                                ? "草稿与队列已通过磁盘回读验证。"
                                : "本地文件仍未通过验证；旧数据与当前内存内容都保留。"
                        } label: {
                            Label("重新检查本地数据", systemImage: "checkmark.shield")
                                .frame(minHeight: 44)
                        }
                    }
                } header: {
                    Text("本地存储")
                } footer: {
                    Text("诊断提示不包含消息正文。为避免重复发送，本机受保护的恢复文件会暂存当前轮次文本、附件路径与运行标识；确认完成后删除。")
                }

                if let resultText {
                    Section {
                        Text(resultText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .confirmationDialog("放弃损坏的本地发送记录？", isPresented: $confirmAbandonUnreadable, titleVisibility: .visible) {
                Button("放弃本地记录", role: .destructive) { model.abandonUnreadablePending() }
            } message: {
                Text("不会重发、停止或删除服务端消息。请先确认历史中是否已收到这条消息。")
            }
            .confirmationDialog("放弃已受理的运行恢复标记？",
                                isPresented: $confirmAbandonActive, titleVisibility: .visible) {
                Button("仅放弃本地记录", role: .destructive) {
                    model.abandonAcceptedTurnRecovery()
                }
            } message: {
                Text("不会停止服务端任务或重发消息。请务必先核对服务端历史；队列会保持暂停。")
            }
            .confirmationDialog("放弃损坏的运行恢复记录？",
                                isPresented: $confirmAbandonCorruptActive, titleVisibility: .visible) {
                Button("仅放弃损坏记录", role: .destructive) {
                    model.abandonUnreadableActiveRecovery()
                }
            } message: {
                Text("不会停止服务端任务或重发消息。确认前请先核对服务端历史。")
            }
            .navigationTitle("恢复中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func statusRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func reconcile() {
        reconciling = true
        resultText = nil
        Task {
            let result = await model.reconcilePending()
            reconciling = false
            switch result {
            case .delivered: resultText = "服务端历史中已找到这条发送，本地待核对状态已解除。"
            case .absent: resultText = "服务端历史中没有找到这条发送；返回会话后可选择重发或放弃。"
            case .failed: resultText = "这次核对没有完成，未自动重发。请稍后再试。"
            }
        }
    }

    private func recoverQueue(_ turn: ChatQueuedTurn) {
        queueRecoveryID = turn.id
        resultText = nil
        Task {
            let accepted = await model.dispatchSelectedQueuedTurn(id: turn.id)
            if accepted {
                resultText = "所选消息已受理，队列已同步更新。"
            } else {
                resultText = model.queuedTurns.contains(where: { $0.id == turn.id })
                    ? "所选消息仍在队列中，未确认送达，也没有自动重复发送。"
                    : "所选消息记录已变化；未再次提交，请查看会话状态。"
            }
            queueRecoveryID = nil
        }
    }

    private func rewriteCurrentDraft() {
        guard let draftStore = model.draftStore else {
            resultText = "当前会话没有可写的草稿存储。"
            return
        }
        let result = draftStore.save(model.draft)
        if result.succeeded {
            model.recordSuccessfulLocalWrite(kind: .draft)
            resultText = "当前草稿已重新写入并通过回读验证。"
        } else {
            model.recordLocalWrite(result, kind: .draft)
            resultText = "草稿仍在内存中，这次写入仍未通过验证。"
        }
    }

    private func localIssueTitle(_ issue: LocalDataIssue) -> String {
        switch issue.kind {
        case .draft: return "草稿保存降级"
        case .queue: return "队列保存降级"
        case .historyCache: return "历史缓存降级"
        case .runRecovery: return "运行恢复记录降级"
        }
    }

    private func localIssueDetail(_ issue: LocalDataIssue) -> String {
        let reason: String
        switch issue.failure {
        case .encoding: reason = "内容无法编码。"
        case .payloadTooLarge: reason = "内容超过安全上限。"
        case .diskWrite: reason = "系统未能完成或验证写盘。"
        case .backupProtection: reason = "无法设置本地保护属性。"
        case .corruptFile: reason = "发现无法验证的旧文件。"
        }
        if issue.failure == .corruptFile {
            return issue.kind == .runRecovery
                ? reason + "先核对后台历史，再在恢复中心显式放弃；不会自动覆盖记录。"
                : reason + "返回会话后继续输入并保存，会以通过回读验证的新内容替换损坏副本。"
        }
        return reason + "当前内存内容仍可用；编辑后再次保存会重新尝试。"
    }
}
