import SwiftUI
import UIKit

extension NativeChatView {
    var composerSection: some View {
        ChatComposer(
            // 输入文本由输入框自己持有（见 ChatComposer）：一次按键只失效输入框子树，
            // 不再触发本页重建 + ChatListSnapshot 的 2000 行比较。
            initialDraft: objects.initialDraft,
            draftSync: draftSync,
            insertion: composerInsertion,
            draftStore: draftStore,
            onPersistenceResult: { model.recordLocalWrite($0, kind: .draft) },
            onLocalWriteSuccess: { model.recordSuccessfulLocalWrite(kind: .draft) },
            focused: $composerFocused,
            modelLabel: modelLabel,
            onChooseModel: {
                composerFocused = false
                showModelPicker = true
            },
            readOnly: model.readOnly,
            loading: model.loading,
            running: model.running,
            stopping: model.stopping,
            canStop: model.streamID != nil && !model.submitting,
            canSend: (model.canSend || model.canSendWhileRunning) && !attachments.isEditing,
            hasReadyAttachments: attachments.canSend && !attachments.batch.items.isEmpty,
            hasAttachmentItems: !attachments.batch.items.isEmpty || attachments.isImporting || attachments.errorMessage != nil,
            onSend: { text in
                // 附件未全部就绪就不能发：否则会静默发出“只有文字”的消息，
                // 用户以为文件发出去了。
                let payloads: [ChatAttachmentPayload]
                do {
                    payloads = try attachments.payload(for: sessionID).map(ChatAttachmentPayload.init(uploaded:))
                } catch {
                    showToast(error.localizedDescription)
                    return
                }
                // 只在提交这一刻把文本交给模型：模型仍以 draft 为发送来源，
                // 失败时也仍能把草稿还回输入框（下方 onChange 负责回填）。
                syncedDraft = text
                model.draft = text
                userIDBeforeSend = model.transcript.messages.last(where: { $0.role == "user" })?.id
                // A steer/queue message issued while Hermes is already
                // running is not a fresh conversation turn. Do not force a
                // new top anchor or steal the user's current reading position.
                pendingUserTurnFocus = !model.running
                Task {
                    // A09：send 返回 false（本地被拒）也保留附件供重试；
                    // 只有「已受理 + 无错误 + 结果确定」才清空。
                    let accepted = await model.send(attachments: payloads)
                    if !accepted { pendingUserTurnFocus = false }
                    if AttachmentResetPolicy.shouldReset(accepted: accepted,
                        hasError: model.error != nil, uncertain: model.uncertain) {
                        attachments.reset(sessionID: sessionID)
                    }
                }
            },
            onStop: { Task { await model.stop() } },
            onAttach: { showAttachInfo = true },
            attachments: AnyView(
                AttachmentComposerBar(model: attachments,
                    isLocked: model.submitting || model.reconciling || !model.canSend,
                    showsPicker: false)
                    .padding(.top, 8)
            ),
            attachmentMenu: AnyView(
                AttachmentComposerBar(model: attachments,
                    isLocked: model.submitting || model.reconciling || !model.canSend,
                    showsItems: false, launchPicker: attachmentPickerTrigger)
            ),
            readOnlyMessage: model.cachedHistoryDate != nil
                ? (model.syncing ? "本地历史 · 正在联网核对…" : "本地历史 · 联网核对后可继续发送") : nil,
            sendMode: Binding(get: { model.sendMode }, set: { model.sendMode = $0 }),
            queuedText: model.queuedText,
            canSendQueued: model.canSend,
            onSendQueued: { Task { await model.flushQueuedIfNeeded() } },
            queuedTurns: model.queuedTurns,
            onSendQueuedTurn: { id in
                Task {
                    // Only the first eligible turn can be sent through the
                    // normal dispatcher. Selecting a later row first brings it
                    // to the front without bypassing uncertainty checks.
                    if let first = model.queuedTurns.first, first.id != id {
                        model.moveQueuedTurn(id: id, before: first.id)
                    }
                    guard let next = model.queuedTurns.first else { return }
                    let ready: Bool
                    if next.delivery == .uncertain {
                        ready = await model.prepareQueuedTurnForRetry(id: next.id)
                    } else {
                        model.markQueuedTurnForManualDispatch(id: next.id)
                        ready = true
                    }
                    if ready { await model.flushQueuedIfNeeded() }
                }
            },
            onEditQueuedTurn: { _ in
                // Edit in the queue itself, never replace a separate draft.
                composerFocused = false
                showQueueManager = true
            },
            onManageQueue: {
                composerFocused = false
                showQueueManager = true
            },
            onRemoveQueuedTurn: { model.removeQueuedTurn(id: $0) },
            contextPressure: ChatContextPressure(usage: model.transcript.usage),
            onShowContextUsage: {
                composerFocused = false
                showUsage = true
            },
            onInsertCompressCommand: {
                // The composer owns the insertion token; the parent only
                // dismisses its own sheets before focus is restored.
                showUsage = false
            },
            showsQueueSummary: false
        )
    }
}
