import SwiftUI
import UIKit

extension NativeChatView {
    private var composerStatusMessage: String? {
        if preparingAttachmentSend && !attachments.batch.items.isEmpty {
            return "正在上传附件，尚未发送消息…"
        }
        if model.draftRecoveryUnreadable { return "本地草稿暂不可读，请在恢复中心重试读取。" }
        if model.authenticationRequired { return "登录后即可继续发送。" }
        if model.stopping { return "正在确认是否停止，暂不能发送。" }
        if model.activeTurnRecovery?.terminalStatus != nil && model.uncertain {
            return "回复已结束，正在补齐历史消息。"
        }
        if model.unavailableRunStatusID != nil {
            return "任务状态暂不可用，正在自动同步；仍可阅读消息。"
        }
        if model.uncertain || model.recoveryRecordsUnreadable {
            if model.syncing || model.loading || model.reconciling {
                return "正在同步消息，暂不能发送。"
            }
            return "上一条消息尚未确认送达，正在自动同步。"
        }
        if model.cachedHistoryDate != nil {
            return model.syncing ? "正在同步最新消息…" : "正在显示本地历史，联网后可发送。"
        }
        return nil
    }

    var composerSection: some View {
        ChatComposer(
            // 输入文本由输入框自己持有（见 ChatComposer）：一次按键只失效输入框子树，
            // 不再触发本页重建 + ChatListSnapshot 的 2000 行比较。
            initialDraft: objects.initialDraft,
            draftSync: draftSync,
            insertion: composerInsertion,
            draftStore: draftStore,
            canPersistDraft: { !model.draftRecoveryUnreadable && objects.registry.mayWriteDraft(objects.runtimeKey,
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
            readOnly: model.readOnly || model.draftRecoveryUnreadable,
            loading: model.loading,
            running: model.running,
            stopping: model.stopping,
            canStop: model.streamID != nil && !model.submitting,
            canSend: !model.draftRecoveryUnreadable && (model.canSend || model.canSendWhileRunning) && attachments.canSend && !preparingAttachmentSend,
            preparingSubmission: preparingAttachmentSend && !attachments.batch.items.isEmpty,
            hasReadyAttachments: attachments.canSend && !attachments.batch.items.isEmpty,
            hasAttachmentItems: !attachments.batch.items.isEmpty || attachments.isImporting ||
                attachments.errorMessage != nil || attachments.lastPersistenceResult?.failure != nil,
            onSend: { text in
                // Prepare files only after the explicit send tap. Until every
                // upload is confirmed, do not issue ANY Run/Session/chat POST.
                // Lock the composer across this preflight to avoid a second
                // tap or overwriting newly typed text during an await.
                guard !preparingAttachmentSend, !model.draftRecoveryUnreadable, visible, attachments.canSend,
                      (model.canSend || model.canSendWhileRunning),
                      objects.registry.owns(objects.runtimeKey, presentation: objects.presentation) else { return }
                let ticket = UUID()
                let needsUpload = !attachments.batch.items.isEmpty
                attachmentSendTicket = ticket
                preparingAttachmentSend = true
                // Capture the exact submitted text before any suspension. A
                // later composer publication must never replace this snapshot.
                syncedDraft = text
                model.draft = text
                attachmentSendTask = Task {
                    defer {
                        if attachmentSendTicket == ticket {
                            preparingAttachmentSend = false
                            attachmentSendTask = nil
                        }
                    }
                    let payloads: [ChatAttachmentPayload]
                    do {
                        if needsUpload {
                            payloads = try await attachments.prepareForSend(sessionID: sessionID)
                                .map(ChatAttachmentPayload.init(uploaded:))
                        } else {
                            // Text-only sends have no upload preflight and must
                            // not toggle the UIKit editor into a read-only state.
                            payloads = []
                        }
                        try Task.checkCancellation()
                        // A navigation/account change must never submit an
                        // upload prepared under the previous session's identity.
                        guard visible, attachmentSendTicket == ticket,
                              attachments.batch.sessionID == sessionID,
                              model.sessionID == sessionID, model.draft == text,
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
                    userIDBeforeSend = model.latestSubmissionFocus?.localID
                    pendingUserTurnFocus = !model.running
                    // A rejected/uncertain POST preserves the draft and ready
                    // attachment references. No automatic replay of the POST.
                    let accepted = await model.send(attachments: payloads)
                    if !accepted { pendingUserTurnFocus = false }
                    if objects.registry.owns(objects.runtimeKey, presentation: objects.presentation),
                       AttachmentResetPolicy.shouldReset(accepted: accepted,
                        hasError: model.error != nil, uncertain: model.uncertain) {
                        // The model and UI share exact accepted references.
                        // Never clear a newly prepared sibling attachment.
                        attachments.consumeSettledPaths(Set(payloads.map(\.path)))
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
            readOnlyMessage: composerStatusMessage,
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
