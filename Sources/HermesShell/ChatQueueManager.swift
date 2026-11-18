import SwiftUI

/// Full queue editor. Ordering, editing and dispatch stay on NativeChatModel;
/// this view only supplies a complete, bounded surface for all queued turns.
struct ChatQueueManager: View {
    @ObservedObject var model: NativeChatModel
    @State private var editingID: String?
    @State private var editingText = ""
    @State private var editingError = false
    @State private var confirmingClear = false
    @State private var recoveringID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canDispatch: Bool {
        model.canSend && !model.running && !model.loading && !model.readOnly && !model.stopping
    }
    private var queueStatus: ChatQueueStatus { ChatQueueStatus(turns: model.queuedTurns) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: model.queueAutomaticDispatchPaused
                              ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundStyle(model.queueAutomaticDispatchPaused
                                             ? AppTheme.warning : AppTheme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.queueAutomaticDispatchPaused
                                 ? "自动续发已暂停" : "自动续发已开启")
                                .font(.subheadline.weight(.semibold))
                            Text(model.queueAutomaticDispatchPaused
                                 ? "可以调整或发送队列，不会在回复结束后自动发下一条。"
                                 : "当前回复结束后，将按顺序自动发送。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Toggle("自动续发", isOn: Binding(
                            get: { !model.queueAutomaticDispatchPaused },
                            set: { model.setQueueAutomaticDispatchPaused(!$0) }))
                            .labelsHidden()
                            .disabled(editingID != nil)
                            .accessibilityLabel("自动续发排队消息")
                    }
                    if model.queuePersistenceFailed {
                        Label("队列写入失败；当前改动重启后可能丢失。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                    }
                }

                Section {
                    if !queueStatus.isEmpty {
                        Label(queueStatus.summary, systemImage: queueStatus.needsAttention
                              ? "exclamationmark.triangle.fill" : "tray.full")
                            .font(.caption)
                            .foregroundStyle(queueStatus.needsAttention
                                             ? AppTheme.warning : Color.secondary)
                            .accessibilityLabel(queueStatus.summary)
                    }
                    if model.queuedTurns.isEmpty {
                        ContentUnavailableView {
                            Label("队列为空", systemImage: "text.line.first.and.arrowtriangle.forward")
                        } description: {
                            Text("回复进行中发送的消息会出现在这里。")
                        }
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .listRowBackground(Color.clear)
                    }
                    if model.queuedTurns.first?.delivery == .uncertain {
                        Label("首条消息的发送结果未确认。先核对会话，确认没有这条后再重试，避免重复执行。",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(model.queuedTurns.enumerated()), id: \.element.id) { index, turn in
                        if editingID == turn.id {
                            queueEditor(turn, index: index)
                                .moveDisabled(true)
                                .deleteDisabled(true)
                        } else {
                            queueRow(turn, index: index)
                                .moveDisabled(editingID != nil || turn.delivery != .waiting)
                                .deleteDisabled(editingID != nil || turn.delivery == .submitting)
                        }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                } header: {
                    Text("待发送 · \(queueStatus.total) 条")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("消息队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) {
                        confirmingClear = true
                    }
                    .disabled(model.queuedTurns.isEmpty || editingID != nil)
                }
            }
            // Empty/uncertain states are List rows. They must not cover
            // the auto-dispatch switch, toolbar, or queue action buttons.
            .onDisappear { cancelEditing() }
            .confirmationDialog("清空全部排队消息？", isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("清空 \(model.queuedTurns.count) 条消息", role: .destructive) {
                    model.setQueuedTurns([])
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会移除所有待发送正文和附件引用，且无法撤销。")
            }
        }
    }

    private func queueRow(_ turn: ChatQueuedTurn, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(index == 0 ? "下一条" : "\(index + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(index == 0 ? AppTheme.accent : Color.secondary)
                    .frame(minWidth: 34, alignment: .leading)
                Text(turn.text.isEmpty || turn.text == NativeChatModel.attachmentOnlyText
                     ? "（仅附件）" : turn.text)
                    .font(.subheadline)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            if !turn.attachments.isEmpty {
                Label("\(turn.attachments.count) 个附件", systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 42)
            }
            if turn.delivery != .waiting {
                Label(turn.delivery == .submitting ? "正在提交，等待服务端受理"
                      : "发送结果未确认；重试前请先核对会话",
                      systemImage: turn.delivery == .submitting
                          ? "clock" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(turn.delivery == .submitting
                                     ? Color.secondary : AppTheme.warning)
                    .padding(.leading, 42)
            }
            HStack(spacing: 4) {
                Button {
                    guard let snapshot = model.beginQueuedTurnEdit(id: turn.id) else { return }
                    editingText = snapshot.composerText
                    editingError = false
                    editingID = snapshot.id
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .disabled(turn.delivery != .waiting || editingID != nil || recoveringID != nil)
                .accessibilityHint(turn.delivery == .uncertain
                    ? "发送结果未确认；先核对并确认不存在后才能编辑"
                    : (turn.delivery == .submitting ? "正在提交，暂时不能编辑" : ""))
                Spacer()
                Button {
                    if model.queuedTurns.first?.id != turn.id {
                        model.setQueuedTurns(ChatQueueOrdering.move(
                            model.queuedTurns, fromOffsets: IndexSet(integer: index),
                            toOffset: 0))
                    }
                    if turn.delivery == .submitting {
                        return
                    }
                    recoveringID = turn.id
                    Task {
                        let ready: Bool
                        if turn.delivery == .uncertain {
                            ready = await model.prepareQueuedTurnForRetry(id: turn.id)
                        } else {
                            model.markQueuedTurnForManualDispatch(id: turn.id)
                            ready = true
                        }
                        if ready { await model.flushQueuedIfNeeded() }
                        recoveringID = nil
                    }
                } label: {
                    Label(recoveringID == turn.id
                          ? "核对中…"
                          : (turn.delivery == .uncertain ? "确认后重试" : "立即发送"),
                          systemImage: turn.delivery == .uncertain
                              ? "arrow.clockwise" : "paperplane")
                }
                .disabled(turn.delivery == .submitting || recoveringID != nil || editingID != nil
                          || (turn.delivery != .uncertain && !canDispatch))
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.leading, 42)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(index + 1) 条\(deliveryLabel(turn))")
    }

    @ViewBuilder
    private func queueEditor(_ turn: ChatQueuedTurn, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑第 \(index + 1) 条排队消息")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $editingText)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 220)
                .accessibilityLabel("排队消息正文")
            ForEach(Array(turn.attachments.enumerated()), id: \.offset) { _, attachment in
                Label(attachment.name, systemImage: "paperclip")
                    .font(.caption)
            }
            Text("保留原附件和队列位置。编辑期间暂停派发；若回复已结束，可在保存后手动发送。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if editingError {
                Label("未能保存修改，原队列消息未被替换。请重试或取消。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(AppTheme.warning)
            }
            HStack {
                Button("取消", action: cancelEditing)
                Spacer()
                Button("保存修改") {
                    guard let id = editingID else { return }
                    if model.commitQueuedTurnEdit(id: id, composerText: editingText) {
                        editingID = nil
                        editingText = ""
                        editingError = false
                    } else {
                        editingError = true
                    }
                }
                .fontWeight(.semibold)
                .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && turn.attachments.isEmpty)
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
        .padding(.vertical, 6)
    }

    private func cancelEditing() {
        if let id = editingID { model.cancelQueuedTurnEdit(id: id) }
        editingID = nil
        editingText = ""
        editingError = false
    }

    private func deliveryLabel(_ turn: ChatQueuedTurn) -> String {
        switch turn.delivery {
        case .waiting: return "待发送消息"
        case .submitting: return "正在提交的消息"
        case .uncertain: return "发送结果待核对的消息"
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        model.setQueuedTurns(ChatQueueOrdering.move(
            model.queuedTurns, fromOffsets: offsets, toOffset: destination))
    }

    private func delete(_ offsets: IndexSet) {
        var next = model.queuedTurns
        for index in offsets.sorted(by: >) where next.indices.contains(index) {
            next.remove(at: index)
        }
        model.setQueuedTurns(next)
    }
}
