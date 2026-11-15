import SwiftUI
import UIKit

extension NativeChatView {
    // MARK: 错误 / 只读钉住条

    /// 首屏没有任何消息时用整页失败态，不再叠一条内容相同的钉住条。
    var showsFullPageFailure: Bool {
        model.transcript.messages.isEmpty && !model.loading && model.error != nil
    }

    var showsNoticeBar: Bool {
        guard !noticeBarDismissed, !showsFullPageFailure else { return false }
        return model.error != nil || model.cachedHistoryDate != nil || model.uncertain
            || (model.hasPendingSend && !model.submitting) || model.runRecoveryNoticeShown
            || model.localPersistenceIssue != nil || model.queuePersistenceFailed
    }

    /// One interactive request stays fully visible. Sibling approvals/clarifies
    /// collapse into a compact queue so many server prompts cannot consume the
    /// transcript viewport or form stacked warning bands.
    @ViewBuilder
    var pendingRequestsSection: some View {
        let requests = pendingRequestIDs
        if !requests.isEmpty {
            let selected = expandedRequestID.flatMap { id in
                requests.contains(where: { $0.id == id }) ? id : nil
            } ?? requests[0].id
            VStack(spacing: 0) {
                if let approval = model.pendingApprovals.first(where: { $0.id == selected }) {
                    approvalCard(approval)
                } else if let clarify = model.pendingClarifies.first(where: { $0.id == selected }) {
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
                    .accessibilityLabel("待处理请求 \(requests.count) 个，当前显示 \(requests[0].kind)")
                }
            }
            .background(AppTheme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
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
                id: $0.id, kind: "审批",
                title: $0.command ?? $0.detail, symbol: "hand.raised.fill")
        } + model.pendingClarifies.map {
            PendingRequestSummary(
                id: $0.id, kind: "补充信息",
                title: $0.question, symbol: "questionmark.bubble.fill")
        }
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
                            Task { await model.respondToApproval(choice, requestID: pending.id) }
                        } label: {
                            Text(Self.approvalLabel(choice))
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(choice.lowercased() == "deny" ? AppTheme.danger : AppTheme.accent)
                        .disabled(!model.canRespondToApproval(requestID: pending.id,
                                                              choice: choice))
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
                if pending.isOpenEnded || clarifyTextModes.contains(pending.id) {
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
            .onChange(of: model.pendingClarifies.map(\.id)) { _, ids in
                if !ids.contains(pending.id) {
                    clarifyTextModes.remove(pending.id)
                    clarifyDrafts.removeValue(forKey: pending.id)
                    clarifySelections.removeValue(forKey: pending.id)
                }
            }
    }

    /// 选项按钮：每行一个（选项文字可能很长，横排会挤成一团），末行「其他」。
    private func clarifyChoices(_ pending: ChatPendingClarify) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(pending.choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    if pending.multiSelect {
                        var selected = clarifySelections[pending.id] ?? []
                        if !selected.insert(index).inserted { selected.remove(index) }
                        clarifySelections[pending.id] = selected
                    } else {
                        Task { await model.respondToClarify(choice, requestID: pending.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pending.multiSelect
                            ? ((clarifySelections[pending.id] ?? []).contains(index)
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
                .disabled(!model.canRespondToClarify(requestID: pending.id))
            }
            if pending.multiSelect {
                let selection = clarifySelections[pending.id] ?? []
                Button("提交所选（\(selection.count)）") {
                    let answer = pending.choices.enumerated()
                        .filter { selection.contains($0.offset) }.map { String($0.offset + 1) }.joined(separator: ",")
                    Task { await model.respondToClarify(answer, requestID: pending.id) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty
                          || !model.canRespondToClarify(requestID: pending.id))
                .frame(minHeight: 44)
            }
            Button {
                clarifyTextModes.insert(pending.id)
            } label: {
                Text("其他（自己输入）")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(!model.canRespondToClarify(requestID: pending.id))
        }
    }

    /// 自由输入。开放式提问和「其他」都走这里。
    private func clarifyInput(_ pending: ChatPendingClarify) -> some View {
        VStack(spacing: 8) {
            TextField(pending.multiSelect ? "输入编号或选项，用逗号分隔" : "输入回答",
                      text: Binding(
                        get: { clarifyDrafts[pending.id] ?? "" },
                        set: { clarifyDrafts[pending.id] = $0 }
                      ), axis: .vertical)
                .font(.caption)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.canRespondToClarify(requestID: pending.id))
                .onSubmit { submitClarify(pending) }
            HStack(spacing: 8) {
                if !pending.isOpenEnded {
                    Button("返回选项") { clarifyTextModes.remove(pending.id) }
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                        .disabled(!model.canRespondToClarify(requestID: pending.id))
                }
                Spacer(minLength: 0)
                Button("提交") { submitClarify(pending) }
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 88, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(!model.canRespondToClarify(requestID: pending.id)
                              || (clarifyDrafts[pending.id] ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitClarify(_ pending: ChatPendingClarify) {
        let answer = clarifyDrafts[pending.id] ?? ""
        clarifyDrafts[pending.id] = ""
        Task { await model.respondToClarify(answer, requestID: pending.id) }
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
            Button(model.localPersistenceIssue != nil || model.queuePersistenceFailed
                   || model.runRecoveryNoticeShown && !model.hasPendingSend && !model.uncertain
                   ? "详情"
                   : (model.hasPendingSend || model.uncertain ? "核对状态" : "重试")) {
                if model.localPersistenceIssue != nil || model.queuePersistenceFailed
                    || model.runRecoveryNoticeShown {
                    composerFocused = false
                    showRecoveryCenter = true
                } else {
                    Task {
                        if model.hasPendingSend {
                            // A pending POST needs the strict history-boundary
                            // reconciliation path, never a generic refresh.
                            _ = await model.reconcilePending()
                        } else {
                            await model.refresh(silent: true, preserveLoadedOlder: true)
                        }
                    }
                }
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.warning)
                .frame(minHeight: 44)
                .disabled(model.loading || model.syncing || model.submitting || model.reconciling || model.stopping || model.authenticationRequired)
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
        if model.cachedHistoryDate != nil { return model.error == nil ? model.activity.title : "联网核对失败 · 显示本地历史" }
        if model.hasPendingSend { return model.notice ?? "发送结果待核对 · 文字和附件已保留" }
        if model.uncertain { return model.notice ?? "后台状态待核对，不会自动重发消息" }
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
