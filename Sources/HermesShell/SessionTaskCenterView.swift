import SwiftUI

/// Cross-session task overview. It uses only server streaming truth and facts
/// this device has observed, then routes the user back to the exact session.
struct SessionTaskCenterView: View {
    let sessions: [SessionSummary]
    /// 已按确认过滤的摘要：用户标过「已处理」的恢复问题不在这里。
    let summaries: [SessionTaskSummary]
    /// 「已处理」分区的条目。
    let acknowledgements: [TaskAcknowledgement]
    let onSelect: (SessionSummary) -> Void
    let onAcknowledge: (String, SessionTaskSignal) -> Void
    let onUndo: (TaskAcknowledgement) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 「已处理」默认折叠：它是历史，不是待办。
    @State private var showAcknowledged = false

    private var sessionsByID: [String: SessionSummary] {
        Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { current, _ in current })
    }
    private var attention: [SessionTaskSummary] { summaries.filter(\.needsAttention) }
    private var running: [SessionTaskSummary] {
        summaries.filter { !$0.needsAttention && $0.isRunning }
    }

    var body: some View {
        NavigationStack {
            List {
                if summaries.isEmpty && acknowledgements.isEmpty {
                    ContentUnavailableView(
                        "当前没有进行中的任务",
                        systemImage: "checkmark.circle",
                        description: Text("正在运行、等待审批或需要恢复的会话会集中显示在这里。")
                    )
                    .listRowBackground(Color.clear)
                }
                if !attention.isEmpty {
                    Section {
                        ForEach(attention) { summary in
                            row(summary, acknowledgeable: summary.signals.contains(.recoveryIssue))
                        }
                    } header: {
                        Text("需要处理 · \(attention.count)")
                    } footer: {
                        Text("打开会话继续处理。已解决的恢复提示可标记为已处理。")
                    }
                }
                if !running.isEmpty {
                    Section("正在处理 · \(running.count)") {
                        ForEach(running) { summary in
                            row(summary, acknowledgeable: false)
                        }
                    }
                }
                if !acknowledgements.isEmpty {
                    acknowledgedSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.canvas)
            .navigationTitle("任务中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 已处理分区：默认折叠，展开后每行可撤销。
    @ViewBuilder
    private var acknowledgedSection: some View {
        Section {
            if showAcknowledged {
                ForEach(acknowledgements, id: \.stableKey) { ack in
                    acknowledgedRow(ack)
                }
            }
        } header: {
            Button {
                showAcknowledged.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("已处理 · \(acknowledgements.count)")
                    // 用同一个字符旋转 90°，与 ChatToolGroup 等处保持一致；
                    // 换 chevron.down 是两个字符，没有连续感。
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showAcknowledged ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showAcknowledged)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(showAcknowledged ? "收起已处理的任务" : "展开已处理的任务")
        }
    }

    /// 一行任务。
    ///
    /// 整行不再是 `Button`：SwiftUI 里 `Button` 嵌套 `Button` 会让内层点击失效。
    /// 改为行主体 `onTapGesture`，「标记已处理」保持独立可点。
    @ViewBuilder
    private func row(_ summary: SessionTaskSummary, acknowledgeable: Bool) -> some View {
        if let session = sessionsByID[summary.sessionID] {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: summary.icon)
                        .foregroundStyle(summary.needsAttention ? AppTheme.warning : AppTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(summary.detail)
                            .font(.caption)
                            .foregroundStyle(summary.needsAttention ? AppTheme.warning : Color.secondary)
                        if let date = session.updatedDate {
                            Text(ChatPresentation.shortAge(date))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
                // The presenting owner performs the single dismissal and
                // the post-dismissal navigation. Do not dismiss twice here.
                .onTapGesture { onSelect(session) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(session.displayTitle)，\(summary.title)，\(summary.detail)")
                .accessibilityHint("打开对应会话")
                .accessibilityAddTraits(.isButton)

                if acknowledgeable {
                    acknowledgeButton(sessionID: summary.sessionID,
                                      signal: .recoveryIssue,
                                      title: session.displayTitle)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(session) }
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// 「标记已处理」。只在恢复问题上出现——审批和待核对必须等服务端事实。
    private func acknowledgeButton(sessionID: String, signal: SessionTaskSignal,
                                   title: String) -> some View {
        Button {
            onAcknowledge(sessionID, signal)
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("标记已处理")
        .accessibilityHint("把「\(title)」的恢复提示移到已处理，可撤销")
    }

    @ViewBuilder
    private func acknowledgedRow(_ ack: TaskAcknowledgement) -> some View {
        let title = sessionsByID[ack.sessionID]?.displayTitle ?? "已删除的会话"
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                        .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(ChatPresentation.shortAge(
                    Date(timeIntervalSince1970: ack.acknowledgedAt)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("撤销") { onUndo(ack) }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
                .accessibilityHint("让这条恢复提示重新出现在需要处理里")
        }
        .frame(minHeight: 44)
    }
}

private extension TaskAcknowledgement {
    /// `ForEach` 的稳定身份：同一会话同一信号同一观察时间就是同一条确认。
    var stableKey: String {
        "\(sessionID)|\(signal.rawValue)|\(observedAt)"
    }
}
