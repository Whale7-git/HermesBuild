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
            canPersistDraft: { objects.registry.mayWriteDraft(objects.runtimeKey,
                presentation: objects.presentation) },
            onPersistenceResult: { model.recordLocalWrite($0, kind: .draft) },
            onLocalWriteSuccess: { model.recordSuccessfulLocalWrite(kind: .draft) },
            focused: $composerFocused,
            modelLabel: modelLabel,
            onChooseModel: {
                guard !preparingAttachmentSend else { return }
                composerFocused = false
                showModelPicker = true
            },
            readOnly: model.readOnly,
            loading: model.loading,
            running: model.running,
            stopping: model.stopping,
            canStop: model.streamID != nil && !model.submitting,
            canSend: (model.canSend || model.canSendWhileRunning) && attachments.canSend && !preparingAttachmentSend,
            preparingSubmission: preparingAttachmentSend,
            hasReadyAttachments: attachments.canSend && !attachments.batch.items.isEmpty,
            hasAttachmentItems: !attachments.batch.items.isEmpty || attachments.isImporting || attachments.errorMessage != nil,
            onSend: { text in
                // Prepare files only after the explicit send tap. Until every
                // upload is confirmed, do not issue ANY Run/Session/chat POST.
                // Lock the composer across this preflight to avoid a second
                // tap or overwriting newly typed text during an await.
                guard !preparingAttachmentSend else { return }
                let ticket = UUID()
                attachmentSendTicket = ticket
                preparingAttachmentSend = true
                attachmentSendTask = Task {
                    defer {
                        if attachmentSendTicket == ticket {
                            preparingAttachmentSend = false
                            attachmentSendTask = nil
                        }
                    }
                    let payloads: [ChatAttachmentPayload]
                    do {
                        payloads = try await attachments.prepareForSend(sessionID: sessionID)
                            .map(ChatAttachmentPayload.init(uploaded:))
                        try Task.checkCancellation()
                        // A navigation/account change must never submit an
                        // upload prepared under the previous session's identity.
                        guard visible, attachments.batch.sessionID == sessionID,
                              model.sessionID == sessionID,
                              objects.registry.owns(objects.runtimeKey,
                                presentation: objects.presentation) else { return }
                    } catch is CancellationError {
                        return
                    } catch {
                        if visible { showToast(error.localizedDescription) }
                        return
                    }
                    // The preflight is complete. Detach the chat POST from
                    // cancellation on view disappearance: a submitted POST is
                    // owned by the model's uncertain-delivery reconciliation.
                    if attachmentSendTicket == ticket {
                        attachmentSendTask = nil
                        preparingAttachmentSend = false
                    }
                    syncedDraft = text
                    model.draft = text
                    userIDBeforeSend = model.transcript.messages.last(where: { $0.role == "user" })?.id
                    pendingUserTurnFocus = !model.running
                    // A rejected/uncertain POST preserves the draft and ready
                    // attachment references. No automatic replay of the POST.
                    let accepted = await model.send(attachments: payloads)
                    if !accepted { pendingUserTurnFocus = false }
                    if objects.registry.owns(objects.runtimeKey, presentation: objects.presentation),
                       AttachmentResetPolicy.shouldReset(accepted: accepted,
                        hasError: model.error != nil, uncertain: model.uncertain) {
                        attachments.reset(sessionID: sessionID)
                    }
                }
            },
            onStop: { Task { await model.stop() } },
            onAttach: { showAttachInfo = true },
            attachments: AnyView(
                AttachmentComposerBar(model: attachments,
                    isLocked: model.submitting || model.reconciling || !model.canSend || preparingAttachmentSend,
                    showsPicker: false)
                    .padding(.top, 8)
            ),
            attachmentMenu: AnyView(
                AttachmentComposerBar(model: attachments,
                    isLocked: model.submitting || model.reconciling || !model.canSend || preparingAttachmentSend,
                    showsItems: false, launchPicker: attachmentPickerTrigger)
            ),
            readOnlyMessage: preparingAttachmentSend
                ? "正在上传附件，尚未提交消息…"
                : (model.cachedHistoryDate != nil
                    ? (model.syncing ? "本地历史 · 正在联网核对…" : "本地历史 · 联网核对后可继续发送") : nil),
            // Silent verified cache warmup; the editor still stays read-only
            // until the server GET establishes authority. Keep all problems
            // visible as actionable, persistent UI states.
            quietReadOnlyNotice: model.cachedHistoryDate != nil && model.syncing
                && model.error == nil && !model.uncertain && !model.hasPendingSend
                && !model.authenticationRequired && !model.runRecoveryNoticeShown
                && model.localPersistenceIssue == nil && !model.queuePersistenceFailed,
            sendMode: Binding(get: { model.sendMode }, set: { model.sendMode = $0 }),
            queuedText: model.queuedText,
            canSendQueued: model.canSend,
            onSendQueued: { Task { await model.flushQueuedIfNeeded() } },
            queuedTurns: model.queuedTurns,
            onSendQueuedTurn: { id in
                Task {
                    await model.dispatchSelectedQueuedTurn(id: id)
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
