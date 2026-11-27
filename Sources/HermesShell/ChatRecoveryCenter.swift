import SwiftUI

/// One place for all recoverable local state. It deliberately exposes actions
/// that already exist in the chat model instead of introducing a second send
/// or reconciliation path.
struct ChatRecoveryCenter: View {
    @ObservedObject var model: NativeChatModel
    var onManageQueue: () -> Void
    var onNewConversation: (() -> Void)? = nil
    @State private var confirmNewConversation = false
    @State private var unknownResolutionOffer: UnknownRunResolutionOffer?
    @State private var confirmUnknownResolution = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAbandonUnreadable = false
    @State private var confirmAbandonDraft = false
    @State private var confirmAbandonActive = false
    @State private var confirmPendingEnded = false
    @State private var confirmAbandonCorruptActive = false
    @State private var reconciling = false
    @State private var queueRecoveryID: String?
    @State private var resultText: String?
    @State private var remoteRecoveryCapabilities: RunRecoveryCapabilities?
    private var queueStatus: ChatQueueStatus { ChatQueueStatus(turns: model.queuedTurns) }

    var body: some View {
        NavigationStack {
            List {
                if model.recoveryRecordsUnreadable {
                    Section("重新读取恢复记录") {
                        Text("本地记录暂不可读。请先尝试恢复，再同步会话；不要重复发送。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            Task {
                                let restored = model.restoreUnreadableRecoveryRecords()
                                if restored {
                                    await model.refresh(silent: true, preserveLoadedOlder: true)
                                }
                                resultText = restored
                                    ? "已重新读取本地记录，请查看同步结果。"
                                    : "仍有恢复记录不可读；原文件与安全锁已保留。"
                            }
                        } label: {
                            Label("重新读取并同步", systemImage: "arrow.clockwise")
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
                        Button("已确认消息状态，放弃本地记录", role: .destructive) {
                            confirmAbandonUnreadable = true
                        }
                    }
                }
                Section("发送状态") {
                    statusRow(icon: model.hasPendingSend ? "paperplane.badge.clock" : "checkmark.circle",
                              color: model.hasPendingSend ? AppTheme.warning : AppTheme.success,
                              title: model.pendingDeliveryIsVerified ? "已确认消息送达，任务状态待确认" :
                                (model.hasPendingSend ? "上一条消息的发送结果尚未确认" : "没有待确认的消息"),
                              detail: model.hasPendingSend
                                ? "同步仅查看历史；在确认之前不会重复发送。"
                                : "普通发送没有留下未决记录。")
                    if model.hasPendingSend {
                        Button {
                            reconcile()
                        } label: {
                            HStack {
                                Label(reconciling ? "正在同步…" : "同步发送状态",
                                      systemImage: "checkmark.shield")
                                Spacer()
                                if reconciling { ProgressView().controlSize(.small) }
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(reconciling || model.loading || model.syncing
                                  || model.submitting || model.reconciling)
                    }
                    if model.canConfirmPendingEndedLocally {
                        Button("已确认任务结束，恢复原会话") { confirmPendingEnded = true }
                        Text("已在历史中找到原消息。请先在服务端确认任务结束；不会重发或继续队列。")
                            .font(.caption).foregroundStyle(.secondary)
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
                                ? "排队消息尚未确认保存；当前打开的会话仍保留它们。"
                                : (model.queuedTurns.isEmpty
                                   ? "没有跨会话遗留的排队消息。"
                                   : (queueStatus.needsAttention
                                      ? "队首消息尚未确认送达；不会自动重发。"
                                      : "重试前会先确认是否已送达，避免重复发送。")))
                    if let turn = model.queuedTurns.first {
                        Button {
                            recoverQueue(turn)
                        } label: {
                            HStack {
                                Label(queueRecoveryID == turn.id ? "正在同步…"
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
                                resultText = result.succeeded
                                    ? "队列和相关发送记录已重新保存。"
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
                        Button("已确认任务状态，放弃本地记录", role: .destructive) {
                            confirmAbandonCorruptActive = true
                        }
                    }
                }
                Section("后台运行") {
                    if let capabilities = remoteRecoveryCapabilities {
                        if let retention = capabilities.durableStatusRetentionSeconds {
                            statusRow(icon: "checkmark.shield", color: AppTheme.success,
                                title: "服务支持持久任务状态",
                                detail: "新任务支持服务端持久记录（\(retention >= 3600 && retention % 3600 == 0 ? "\(retention / 3600) 小时" : "\(retention) 秒")）；旧任务仍需同步确认。")
                        } else {
                            statusRow(icon: "info.circle", color: .secondary,
                                title: "服务未声明持久任务状态",
                                detail: "继续使用兼容恢复方式，不会重复发送。")
                        }
                    }
                    if model.activeTurnRecovery != nil {
                        statusRow(icon: model.running ? "waveform" : "questionmark.circle",
                                  color: AppTheme.warning,
                                  title: model.activeTurnRecovery?.terminalStatus != nil
                                    ? "回复已结束，等待历史补齐"
                                    : (model.running ? "服务端任务仍在运行" : "上一条回复是否结束尚未确认"),
                                  detail: "运行标识已保存；状态查询不会重复提交消息。")
                    }
                    if model.canConfirmEndedRunLocally {
                        Button("已确认任务结束，恢复原会话") {
                            confirmAbandonActive = true
                        }
                        Text("仅在你已通过服务端确认旧任务结束时使用；不会重发旧消息，队列仍暂停。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    statusRow(icon: model.runRecoveryNoticeShown
                              ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath",
                              color: model.runRecoveryNoticeShown ? AppTheme.warning : AppTheme.success,
                              title: model.runRecoveryNoticeShown
                                ? "后台恢复记录降级" : "后台运行恢复可用",
                              detail: model.runRecoveryNoticeShown
                                ? "不会因此重复发送；重启 App 后可能需要重新同步。"
                                : "本轮运行标识已写入本机。")
                    statusRow(icon: model.cachedHistoryDate == nil ? "internaldrive" : "wifi.exclamationmark",
                              color: model.cachedHistoryDate == nil ? AppTheme.success : AppTheme.warning,
                              title: model.cachedHistoryDate == nil ? "历史缓存正常" : "正在使用本地历史",
                              detail: model.cachedHistoryDate == nil
                                ? "打开会话时先显示本地历史，再同步最新内容。"
                                : "正在同步最新内容，完成后可继续发送。")
                    if model.unknownResolutionRunID != nil {
                        Button("检查能否恢复原会话") {
                            Task {
                                do {
                                    let offer = try await model.checkUnknownRunResolution()
                                    unknownResolutionOffer = offer
                                    confirmUnknownResolution = offer != nil
                                    if offer == nil {
                                        resultText = "当前服务无法确认这次任务是否结束。你仍可阅读消息，也可以新建会话继续聊天。"
                                    }
                                } catch {
                                    resultText = "暂时无法检查恢复方式，请稍后同步。"
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    if model.uncertain && !model.running && !model.stopping,
                       onNewConversation != nil {
                        Button("新建会话继续聊天") { confirmNewConversation = true }
                            .frame(minHeight: 44)
                        Text("旧会话的消息和恢复记录会保留；不会重新发送或停止旧任务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.error != nil || model.cachedHistoryDate != nil || model.uncertain {
                        Button {
                            Task { await model.refresh(silent: true, preserveLoadedOlder: true) }
                        } label: {
                            Label("重新同步", systemImage: "arrow.clockwise")
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
                                ? "草稿与排队消息已保存。"
                                : "当前内存内容仍可用；检查后可继续保存。")
                    ForEach(LocalDataRecord.allCases, id: \.self) { record in
                        if let issue = model.localRecordIssues[record] {
                            statusRow(icon: "exclamationmark.triangle.fill", color: AppTheme.warning,
                                      title: localIssueTitle(record), detail: localIssueDetail(issue))
                        }
                    }
                    if model.draftRecoveryUnreadable {
                        Button("重新读取文字草稿") {
                            resultText = model.restoreUnreadableDraft().succeeded
                                ? "已恢复原草稿。" : "草稿仍不可读，原记录未修改。"
                        }
                        Button("放弃本地文字草稿", role: .destructive) { confirmAbandonDraft = true }
                    } else if model.localRecordIssues[.draft] != nil {
                        Button(action: rewriteCurrentDraft) {
                            Label("重新验证当前草稿", systemImage: "doc.badge.arrow.up")
                                .frame(minHeight: 44)
                        }
                    }
                    if model.localPersistenceIssue != nil || model.queuePersistenceFailed {
                        Button {
                            let result = model.validateLocalData()
                            resultText = result.succeeded
                                ? (model.localPersistenceIssue != nil || model.queuePersistenceFailed
                                    ? "原有文件可以读取，但最新内容仍需重新保存。"
                                    : "本地文件可以读取。")
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
            .confirmationDialog("放弃本地文字草稿？", isPresented: $confirmAbandonDraft, titleVisibility: .visible) {
                Button("放弃草稿", role: .destructive) {
                    resultText = model.abandonUnreadableDraft().succeeded
                        ? "已放弃本地草稿。" : "草稿删除未通过验证，仍保留原记录。"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅删除当前会话本地文字草稿，不会发送消息或修改服务端历史。")
            }
            .confirmationDialog("放弃损坏的本地发送记录？", isPresented: $confirmAbandonUnreadable, titleVisibility: .visible) {
                Button("放弃本地记录", role: .destructive) { model.abandonUnreadablePending() }
            } message: {
                Text("不会重发、停止或删除服务端消息。请先确认历史中是否已收到这条消息。")
            }
            .confirmationDialog("确认这条消息的任务已结束？", isPresented: $confirmPendingEnded,
                                titleVisibility: .visible) {
                Button("确认结束并恢复原会话", role: .destructive) {
                    Task {
                        let recovered = await model.confirmDeliveredPendingEndedLocally()
                        resultText = recovered ? "原会话已恢复，可以继续发送。"
                            : (model.notice ?? "尚无法安全恢复。")
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("历史中的用户消息只能证明送达，不能证明执行结束。请先通过服务端确认任务已结束。本操作不重发原消息，队列保持暂停。")
            }
            .confirmationDialog("确认旧任务已经在服务端结束？",
                                isPresented: $confirmAbandonActive, titleVisibility: .visible) {
                Button("确认结束并恢复原会话", role: .destructive) {
                    Task {
                        let recovered = await model.confirmEndedRunLocally()
                        resultText = recovered ? "原会话已恢复，可以继续发送。"
                            : (model.notice ?? "尚无法安全恢复，已保留原记录。")
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("必须先在服务端确认任务已经结束。找不到任务记录不代表结束。本操作不会停止任务、重发原消息或继续队列；若你无法确认，请使用新会话。")
            }
            .confirmationDialog("放弃损坏的运行恢复记录？",
                                isPresented: $confirmAbandonCorruptActive, titleVisibility: .visible) {
                Button("仅放弃损坏记录", role: .destructive) {
                    model.abandonUnreadableActiveRecovery()
                }
            } message: {
                Text("不会停止服务端任务或重发消息。请先确认服务端任务状态。")
            }
            .confirmationDialog("结束已失联的任务？", isPresented: $confirmUnknownResolution, titleVisibility: .visible) {
                Button("确认处理失联任务", role: .destructive) {
                    guard let offer = unknownResolutionOffer else { return }
                    unknownResolutionOffer = nil
                    Task {
                        let settled = await model.confirmUnknownRunResolution(offer)
                        resultText = settled ? "任务状态已恢复，消息已同步。" :
                            "暂时无法确认恢复结果，原消息和发送限制已保留。"
                    }
                }
                Button("取消", role: .cancel) { unknownResolutionOffer = nil }
            } message: {
                Text("服务确认这次任务已失联。处理后仍需同步任务结果，不会重发原消息，也不会自动继续排队消息。")
            }
            .confirmationDialog("新建一个独立会话？", isPresented: $confirmNewConversation, titleVisibility: .visible) {
                Button("新建会话") { onNewConversation?() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("旧任务是否结束仍不确定。新会话不会重发旧消息，也不会清除旧会话的记录。")
            }
            .navigationTitle("恢复中心")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Read-only capability discovery on the exact backend object.
                // An unavailable endpoint does not change any send authority.
                let capabilities = try? await model.api.runRecoveryCapabilities()
                if !Task.isCancelled { remoteRecoveryCapabilities = capabilities }
            }
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
            case .delivered: resultText = "已在历史中找到消息，不会重复发送。"
            case .absent: resultText = "服务端历史中没有找到这条发送；返回会话后可选择重发或放弃。"
            case .failed: resultText = model.pendingDeliveryIsVerified
                ? "消息已送达，尚未确认任务结束。可按服务端实际状态处理。"
                : "暂时无法确认发送结果。未重复发送，请稍后再试。"
            }
        }
    }

    private func recoverQueue(_ turn: ChatQueuedTurn) {
        queueRecoveryID = turn.id
        resultText = nil
        Task {
            let accepted = await model.dispatchSelectedQueuedTurn(id: turn.id)
            if accepted {
                resultText = "服务端已接收所选消息，队列已更新。"
            } else {
                resultText = model.queuedTurns.contains(where: { $0.id == turn.id })
                    ? "所选消息仍在队列中，未确认送达，也没有自动重复发送。"
                    : "所选消息记录已变化；未再次提交，请查看会话状态。"
            }
            queueRecoveryID = nil
        }
    }

    private func rewriteCurrentDraft() {
        guard !model.draftRecoveryUnreadable, let draftStore = model.draftStore else {
            resultText = "当前会话没有可写的草稿存储。"
            return
        }
        let result = draftStore.save(model.draft)
        if result.succeeded {
            model.recordSuccessfulLocalWrite(kind: .draft)
            resultText = "当前草稿已重新保存。"
        } else {
            model.recordLocalWrite(result, kind: .draft)
            resultText = "草稿仍在内存中，这次写入仍未通过验证。"
        }
    }

    private func localIssueTitle(_ record: LocalDataRecord) -> String {
        switch record {
        case .draft: return "文字草稿保存异常"
        case .attachmentDraft: return "附件草稿保存异常"
        case .queuedTurns: return "队列保存异常"
        case .pendingSend: return "待确认消息记录异常"
        case .queuePause: return "队列暂停设置保存异常"
        case .historyCache: return "历史缓存异常"
        case .activeRun: return "任务恢复记录异常"
        case .runOutcome: return "任务结果记录异常"
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
                ? reason + "请先同步并确认任务状态。不会自动覆盖原记录。"
                : reason + "请先恢复原记录；需要放弃时请明确确认。"
        }
        return reason + "当前内存内容仍可用；编辑后再次保存会重新尝试。"
    }
}
