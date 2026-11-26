import SwiftUI
import UIKit

extension NativeChatView {
    // MARK: 错误 / 只读钉住条

    /// 首屏没有任何消息时用整页失败态，不再叠一条内容相同的钉住条。
    var showsFullPageFailure: Bool {
        model.transcript.messages.isEmpty && !model.loading && model.error != nil
    }

    var showsNoticeBar: Bool {
        guard !showsFullPageFailure else { return false }
        // Dismiss presentation only. The title/task panel and composer retain
        // the state and recovery entry; the model's send authority is unchanged.
        guard !noticeBarDismissed else { return false }
        // An ordinary confirmed disk snapshot is already on screen. Its
        // authoritative GET must run, but the healthy cache/sync transition
        // is not a warning and must not insert a yellow row on every open.
        return model.presentationState.showsNotice
    }

    /// One interactive request stays fully visible. Sibling approvals/clarifies
    /// collapse into a compact queue so many server prompts cannot consume the
    /// transcript viewport or form stacked warning bands.
    @ViewBuilder
    var pendingRequestsSection: some View {
        let requests = pendingRequestIDs
        Group {
        if !requests.isEmpty {
            let selected = expandedRequestID.flatMap { id in
                requests.contains(where: { $0.id == id }) ? id : nil
            } ?? requests[0].id
            VStack(spacing: 0) {
                if let approval = model.pendingApprovals.first(where: { approvalKey($0) == selected }) {
                    approvalCard(approval)
                } else if let clarify = model.pendingClarifies.first(where: { clarifyKey($0) == selected }) {
                    clarifyCard(clarify)
                }
                if requests.count > 1 {
                    Menu {
                        ForEach(requests) { request in
                            Button {
                                expandedRequestID = request.id
                            } label: {
                                Label(
                                    "\(request.kind) · \(request.title)",
                                    systemImage: request.id == selected
                                        ? "checkmark.circle.fill" : request.symbol
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "tray.full")
                            Text("另有 \(requests.count - 1) 个待处理请求")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppTheme.pagePadding)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("待处理请求 \(requests.count) 个，当前显示 \(requests.first(where: { $0.id == selected })?.kind ?? "请求")")
                }
            }
            .background(AppTheme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
            }
        }
        }
        // Observe the stable parent even when the final card disappears.
        // A same-ID payload replacement invalidates previous choice indices.
        .onChange(of: model.pendingClarifies, initial: true) { previous, current in
            let valid = Set(current.filter { request in
                !previous.contains(where: { clarifyKey($0) == clarifyKey(request) && $0 != request })
            }.map { clarifyKey($0) })
            clarifyTextModes.formIntersection(valid)
            clarifyDrafts = clarifyDrafts.filter { valid.contains($0.key) }
            clarifySelections = clarifySelections.filter { valid.contains($0.key) }
        }
        .onChange(of: requests.map(\.id), initial: true) { _, ids in
            if let expandedRequestID, !ids.contains(expandedRequestID) {
                self.expandedRequestID = nil
            }
        }
    }

    private struct PendingRequestSummary: Identifiable {
        let id: String
        let kind: String
        let title: String
        let symbol: String
    }

    private var pendingRequestIDs: [PendingRequestSummary] {
        model.pendingApprovals.map {
            PendingRequestSummary(
                id: approvalKey($0), kind: "审批",
                title: $0.command ?? $0.detail, symbol: "hand.raised.fill")
        } + model.pendingClarifies.map {
            PendingRequestSummary(
                id: clarifyKey($0), kind: "补充信息",
                title: $0.question, symbol: "questionmark.bubble.fill")
        }
    }

    private func requestKey(_ kind: String, _ run: String, _ id: String, _ generation: Int) -> String {
        "\(kind):\(run.utf8.count):\(run):\(id.utf8.count):\(id):\(generation)"
    }

    private func approvalKey(_ pending: ChatPendingApproval) -> String {
        requestKey("approval", pending.runID, pending.id, pending.executionGeneration)
    }

    private func clarifyKey(_ pending: ChatPendingClarify) -> String {
        requestKey("clarify", pending.runID, pending.id, pending.executionGeneration)
    }

    private func approvalCard(_ pending: ChatPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("需要你确认后才能继续")
                            .font(.caption.weight(.semibold))
                        Text(pending.detail)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if let command = pending.command {
                            Text(command)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Spacer(minLength: 0)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                    ForEach(pending.choices, id: \.self) { choice in
                        Button {
                            Task { await model.respondToApproval(choice, requestID: pending.id, expected: pending) }
                        } label: {
                            Text(Self.approvalLabel(choice))
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(choice.lowercased() == "deny" ? AppTheme.danger : AppTheme.accent)
                        .disabled(!model.canRespondToApproval(requestID: pending.id,
                                                              choice: choice, expected: pending))
                    }
                }
                if model.approving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在提交…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 10)
            .background(AppTheme.warning.opacity(0.10))
            .accessibilityElement(children: .contain)
    }

    /// 服务端的选项名直接展示会让人看不懂（once/session/always/deny），
    /// 这里做成中文；认不出的取值原样显示，不猜它的语义。
    private static func approvalLabel(_ choice: String) -> String {
        switch choice.lowercased() {
        case "once", "allow", "approve", "approved": return "允许一次"
        case "session": return "本会话允许"
        case "always": return "总是允许"
        case "deny": return "拒绝"
        default: return choice
        }
    }

    private func clarifyCard(_ pending: ChatPendingClarify) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pending.multiSelect ? "需要你补充信息（可多选）" : "需要你补充信息")
                            .font(.caption.weight(.semibold))
                        Text(pending.question)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if pending.isOpenEnded || clarifyTextModes.contains(clarifyKey(pending)) {
                    clarifyInput(pending)
                } else {
                    clarifyChoices(pending)
                }
                if model.clarifying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在提交…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 10)
            .background(AppTheme.accent.opacity(0.08))
            .accessibilityElement(children: .contain)

    }

    /// 选项按钮：每行一个（选项文字可能很长，横排会挤成一团），末行「其他」。
    private func clarifyChoices(_ pending: ChatPendingClarify) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(pending.choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    if pending.multiSelect {
                        var selected = clarifySelections[clarifyKey(pending)] ?? []
                        if !selected.insert(index).inserted { selected.remove(index) }
                        clarifySelections[clarifyKey(pending)] = selected
                    } else {
                        Task { await model.respondToClarify(choice, requestID: pending.id, expected: pending) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pending.multiSelect
                            ? ((clarifySelections[clarifyKey(pending)] ?? []).contains(index)
                                ? "checkmark.circle.fill" : "circle")
                            : "chevron.right")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(choice)
                            .font(.caption.weight(.medium))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)
                .disabled(!model.canRespondToClarify(requestID: pending.id, expected: pending))
            }
            if pending.multiSelect {
                let selection = clarifySelections[clarifyKey(pending)] ?? []
                Button("提交所选（\(selection.count)）") {
                    let answer = pending.choices.enumerated()
                        .filter { selection.contains($0.offset) }.map { String($0.offset + 1) }.joined(separator: ",")
                    Task { await model.respondToClarify(answer, requestID: pending.id, expected: pending) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty
                          || !model.canRespondToClarify(requestID: pending.id, expected: pending))
                .frame(minHeight: 44)
            }
            Button {
                clarifyTextModes.insert(clarifyKey(pending))
            } label: {
                Text("其他（自己输入）")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(!model.canRespondToClarify(requestID: pending.id, expected: pending))
        }
    }

    /// 自由输入。开放式提问和「其他」都走这里。
    private func clarifyInput(_ pending: ChatPendingClarify) -> some View {
        VStack(spacing: 8) {
            TextField(pending.multiSelect ? "输入编号或选项，用逗号分隔" : "输入回答",
                      text: Binding(
                        get: { clarifyDrafts[clarifyKey(pending)] ?? "" },
                        set: { clarifyDrafts[clarifyKey(pending)] = $0 }
                      ), axis: .vertical)
                .font(.caption)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.canRespondToClarify(requestID: pending.id, expected: pending))
                .onSubmit { submitClarify(pending) }
            HStack(spacing: 8) {
                if !pending.isOpenEnded {
                    Button("返回选项") { clarifyTextModes.remove(clarifyKey(pending)) }
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                        .disabled(!model.canRespondToClarify(requestID: pending.id, expected: pending))
                }
                Spacer(minLength: 0)
                Button("提交") { submitClarify(pending) }
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 88, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(!model.canRespondToClarify(requestID: pending.id, expected: pending)
                              || (clarifyDrafts[clarifyKey(pending)] ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitClarify(_ pending: ChatPendingClarify) {
        let answer = clarifyDrafts[clarifyKey(pending)] ?? ""
        Task { await model.respondToClarify(answer, requestID: pending.id, expected: pending) }
    }

    /// The action shown is the action actually executed.
    private var noticeAction: ChatNoticeAction {
        if model.stopping { return .verifyStatus }
        return ChatNoticeAction.choose(
            hasPendingSend: model.hasPendingSend,
            uncertain: model.uncertain || model.activity == .needsVerification,
            persistenceIssue: model.localPersistenceIssue != nil || model.queuePersistenceFailed,
            recoveryDegraded: model.runRecoveryNoticeShown)
    }

    var noticeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.error != nil ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.warning)
            Text(noticeBarText)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { performNoticeAction(noticeAction) } label: {
                HStack(spacing: 4) {
                    if noticeChecking { ProgressView().controlSize(.mini) }
                    Text(noticeChecking ? "同步中…" : noticeAction.title)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.warning)
            .frame(minHeight: 44)
            .disabled(noticeChecking || model.loading || model.syncing
                      || model.submitting || model.reconciling
                      || model.authenticationRequired)
            Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { noticeBarDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
        }
        .padding(.leading, AppTheme.pagePadding)
        .padding(.trailing, 4)
        .frame(minHeight: 40)
        .background(AppTheme.warning.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.hairline).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    private func performNoticeAction(_ action: ChatNoticeAction) {
        if action == .details {
            composerFocused = false
            showRecoveryCenter = true
            return
        }
        guard !noticeChecking else { return }
        noticeChecking = true
        Task { @MainActor in
            defer { noticeChecking = false }
            switch action {
            case .reconcilePending:
                // GET only; never replay the uncertain original POST.
                let result = await model.reconcilePending()
                switch result {
                case .delivered: showToast("消息已送达，没有重复发送")
                case .absent: showToast("未找到这条消息，可以选择重试或放弃")
                case .failed: showToast("暂时无法确认是否送达，请稍后重试")
                }
            case .verifyStatus, .retry:
                if model.stopping {
                    await model.verifyPendingStop()
                    showToast(model.stopping ? "还无法确认是否已停止" : "状态已更新")
                    return
                }
                let hadAcceptedRun = model.activeTurnRecovery != nil
                await model.refresh(silent: true, preserveLoadedOlder: true)
                // Accepted-run recovery may schedule a separate bounded probe.
                if let probe = model.activeRunProbeTask { await probe.value }
                let longHistoryVerified = await model.reconcileLongAcceptedRun()
                if longHistoryVerified {
                    showToast("回复已完整同步")
                } else if model.error != nil {
                    showToast("同步失败，暂时不能发送")
                } else if hadAcceptedRun && model.activeTurnRecovery == nil && !model.uncertain && !model.running {
                    showToast("已确认回复结束")
                } else if model.activeTurnRecovery != nil && !model.running {
                    showToast("还无法确认回复是否结束")
                } else if model.uncertain {
                    model.notice = model.notice ?? "暂时无法确认回复状态，不会重复发送。"
                    showToast("暂时无法确认回复状态")
                } else if model.running {
                    showToast("回复仍在进行")
                } else {
                    showToast("消息已同步")
                }
            case .details:
                break
            }
        }
    }

    private var noticeBarText: String {
        if model.queuePersistenceFailed, model.localPersistenceIssue == nil {
            return "消息队列未能可靠保存；当前内容仍在内存中。点详情查看处理方式。"
        }
        if let issue = model.localPersistenceIssue {
            let name: String
            switch issue.kind {
            case .draft: name = "草稿"
            case .queue: name = "消息队列"
            case .historyCache: name = "历史缓存"
            case .runRecovery: name = "运行恢复记录"
            }
            return "\(name)未能可靠保存；当前内容仍在内存中。点详情查看处理方式。"
        }
        if model.runRecoveryNoticeShown,
           model.error == nil, model.cachedHistoryDate == nil,
           !model.hasPendingSend, !model.uncertain {
            return "本轮后台恢复记录未能保存；当前页面不会重复发送，重启 App 后可能需要重新核对。"
        }
        if model.authenticationRequired { return model.activity.title }
        if model.cachedHistoryDate != nil && model.error != nil {
            return "同步失败 · 已显示本地历史"
        }
        if model.hasPendingSend { return model.notice ?? "暂未确认送达 · 已保留文字和附件" }
        if model.uncertain { return model.notice ?? "回复状态尚未确认，不会重复发送" }
        return model.error ?? model.activity.title
    }
    @ViewBuilder
    var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.hairline))
                .padding(.top, 52)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        UIAccessibility.post(notification: .announcement, argument: label)
        showToast(label, announce: false)
    }

    /// 所有经由浮层传达的错误/结果也朗读一次，避免 VoiceOver 用户「无声失败」。
    func showToast(_ text: String, announce: Bool = true) {
        if announce, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { toast = nil }
        }
    }
}
