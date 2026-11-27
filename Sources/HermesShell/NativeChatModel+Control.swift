import Foundation

extension NativeChatModel {
    var unknownResolutionRunID: String? {
        guard uncertain, !runtimeRetired, !suspended, !running, !stopping,
              !submitting, !loading, !syncing, !reconciling,
              !recoveryRecordsUnreadable else { return nil }
        return activeTurnRecovery?.runID ?? unavailableRunStatusID
    }

    func checkUnknownRunResolution() async throws -> UnknownRunResolutionOffer? {
        guard let runID = unknownResolutionRunID else { return nil }
        let generation = revision
        reconciling = true
        defer { if revision == generation { reconciling = false } }
        let offer = try await api.unknownRunResolutionOffer(sessionID: sessionID, runID: runID)
        guard !runtimeRetired, !suspended, !Task.isCancelled, revision == generation,
              offer?.sessionID == sessionID, offer?.runID == runID else { return nil }
        return offer
    }

    /// The confirmation is owned by the UI; background recovery never calls
    /// this method. Only the subsequent canonical GET may restore sending.
    func confirmUnknownRunResolution(_ offer: UnknownRunResolutionOffer) async -> Bool {
        guard unknownResolutionRunID == offer.runID, offer.sessionID == sessionID else { return false }
        let generation = revision
        reconciling = true
        defer { if revision == generation { reconciling = false } }
        pauseQueueForRecovery()
        do {
            let result = try await api.resolveUnknownRun(offer)
            guard !runtimeRetired, !suspended, !Task.isCancelled, revision == generation else { return false }
            if case .terminal(let outcome) = result {
                guard rememberTerminalStatus(runID: offer.runID, outcome: outcome) else { return false }
                // Release this single-flight owner before normal refresh;
                // there is no suspension between the release and call.
                reconciling = false
                await refresh(silent: true, preserveLoadedOlder: true)
                return !uncertain && !recoveryRecordsUnreadable
            }
            notice = "服务暂未确认任务结束，消息已保留。请同步状态后再处理。"
            return false
        } catch {
            guard revision == generation, !runtimeRetired, !suspended else { return false }
            if handleAuthenticationFailure(error) { return false }
            uncertain = true
            notice = "暂时无法确认恢复结果，不会自动重复提交。请同步状态。"
            return false
        }
    }

    /// Upsert one server request without disturbing sibling requests from the
    /// same run. Returns true only when this identity was newly inserted.
    @discardableResult
    func upsertPendingApproval(_ pending: ChatPendingApproval) -> Bool {
        if let index = pendingApprovals.firstIndex(where: { $0.id == pending.id }) {
            if pendingApprovals[index] != pending { pendingApprovals[index] = pending }
            return false
        }
        pendingApprovals.append(pending)
        return true
    }

    @discardableResult
    func upsertPendingClarify(_ pending: ChatPendingClarify) -> Bool {
        if let index = pendingClarifies.firstIndex(where: { $0.id == pending.id }) {
            if pendingClarifies[index] != pending { pendingClarifies[index] = pending }
            return false
        }
        pendingClarifies.append(pending)
        return true
    }

    func removePendingApproval(id: String) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingApprovals.remove(at: index)
        onApprovalResolved?(sessionID, removed.requestID)
        if pendingApprovals.isEmpty { approving = false }
    }

    func removePendingClarify(id: String) {
        guard let index = pendingClarifies.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingClarifies.remove(at: index)
        onClarifyResolved?(sessionID, removed.requestID)
        if pendingClarifies.isEmpty { clarifying = false }
    }

    func removePendingApprovals(for runID: String?) {
        // An authoritative snapshot names the run that is still alive. Requests
        // from any other run are stale; a nil active run invalidates all cards.
        let removed = pendingApprovals.filter { $0.runID != runID }
        guard !removed.isEmpty else { return }
        pendingApprovals.removeAll { $0.runID != runID }
        for request in removed { onApprovalResolved?(sessionID, request.requestID) }
        if pendingApprovals.isEmpty { approving = false }
    }

    func removePendingApproval(requestID: String, runID: String, generation: Int? = nil) {
        guard let pending = pendingApprovals.first(where: {
            $0.requestID == requestID && $0.runID == runID &&
            (generation == nil || $0.executionGeneration == generation)
        }) else { return }
        removePendingApproval(id: pending.id)
    }

    func removePendingClarifies(for runID: String?) {
        let removed = pendingClarifies.filter { $0.runID != runID }
        guard !removed.isEmpty else { return }
        pendingClarifies.removeAll { $0.runID != runID }
        for request in removed { onClarifyResolved?(sessionID, request.requestID) }
        if pendingClarifies.isEmpty { clarifying = false }
    }

    /// Replace only the controls for the exact active Run. This is used when
    /// a Gateway status snapshot explicitly supplies its current pending set.
    /// Missing capability is represented by nil and never clears known cards.
    func restorePendingControls(_ snapshot: GatewayPendingControlSnapshot, runID: String) {
        // Parse before mutating. A partial projection cannot revoke a card
        // that remains actionable on the same Run, nor silently resume a queue.
        var nextApprovals: [ChatPendingApproval] = []
        var nextClarifies: [ChatPendingClarify] = []
        var incomplete = snapshot.hasIncompleteControl
        for frame in snapshot.frames {
            switch frame.event {
            case "approval":
                guard let pending = ChatPendingApproval.make(from: frame, runID: runID),
                      pending.runID == runID, pending.requestID != nil else {
                    incomplete = true
                    continue
                }
                nextApprovals.append(pending)
            case "clarify":
                guard let pending = ChatPendingClarify.make(from: frame, runID: runID),
                      pending.runID == runID else {
                    incomplete = true
                    continue
                }
                nextClarifies.append(pending)
            default:
                incomplete = true
            }
        }

        if incomplete {
            for pending in nextApprovals { _ = upsertPendingApproval(pending) }
            for pending in nextClarifies { _ = upsertPendingClarify(pending) }
            uncertain = true
            pauseQueueForRecovery()
            notice = "还有需要你处理的请求，暂时未能完整加载。已保留原请求，暂不能发送。"
            return
        }

        let oldApprovals = pendingApprovals.filter { $0.runID == runID }
        let oldClarifies = pendingClarifies.filter { $0.runID == runID }
        pendingApprovals.removeAll { $0.runID == runID }
        pendingClarifies.removeAll { $0.runID == runID }
        for pending in nextApprovals { _ = upsertPendingApproval(pending) }
        for pending in nextClarifies { _ = upsertPendingClarify(pending) }

        let approvalIDs = Set(nextApprovals.map(\.id))
        let clarifyIDs = Set(nextClarifies.map(\.id))
        for request in oldApprovals where !approvalIDs.contains(request.id) {
            onApprovalResolved?(sessionID, request.requestID)
        }
        for request in oldClarifies where !clarifyIDs.contains(request.id) {
            onClarifyResolved?(sessionID, request.requestID)
        }
        if pendingApprovals.isEmpty { approving = false }
        if pendingClarifies.isEmpty { clarifying = false }
        // Only an independent, fully verified Run/POST reconciliation may
        // clear queueRecoveryPaused. The control projection never authorizes it.
    }

    func removePendingClarify(requestID: String, runID: String? = nil, generation: Int? = nil) {
        guard let active = runID ?? streamID,
              let pending = pendingClarifies.first(where: {
                  $0.requestID == requestID && $0.runID == active &&
                  (generation == nil || $0.executionGeneration == generation)
              }) else { return }
        removePendingClarify(id: pending.id)
    }

    /// User answers may complete out of order. While one POST is in flight the
    /// UI disables every request, so selecting another card must not silently
    /// fall back to the newest slot and answer the wrong server prompt.
    func canRespondToApproval(requestID: String, choice: String, expected: ChatPendingApproval? = nil) -> Bool {
        guard let pending = pendingApprovals.first(where: { $0.id == requestID }) else {
            return false
        }
        return (expected == nil || expected == pending) && !approving && !suspended &&
            !runtimeRetired && running && !stopping && !reconciling &&
            pending.requestID != nil && pending.choices.contains(choice) &&
            streamID == pending.runID && !pending.runID.isEmpty
    }

    func canRespondToClarify(requestID: String, expected: ChatPendingClarify? = nil) -> Bool {
        guard let pending = pendingClarifies.first(where: { $0.id == requestID }) else {
            return false
        }
        return (expected == nil || expected == pending) && !clarifying && !suspended &&
            !runtimeRetired && running && !stopping && !reconciling &&
            streamID == pending.runID && !pending.runID.isEmpty
    }

    /// 回传一次审批决定。
    ///
    /// 成功就撤卡片，让流继续往下跑——网关在收到答复前不会推进本轮。
    /// 失败分三类处理：服务端说这张票已失效（not_pending）就撤掉并说明；
    /// 说选项不合法（rejected）说明是版本不匹配；网络错误保留卡片让用户重试。
    func respondToApproval(_ choice: String, requestID: String? = nil, expected: ChatPendingApproval? = nil) async {
        // An explicitly selected card may disappear before its tap is
        // handled. Never substitute a different request in that case.
        let target: ChatPendingApproval?
        if let requestID {
            target = pendingApprovals.first { $0.id == requestID }
        } else {
            target = pendingApprovals.count == 1 ? pendingApproval : nil
        }
        guard let pending = target,
              canRespondToApproval(requestID: pending.id, choice: choice, expected: expected ?? pending) else { return }
        // runID 必须已知：没有它连往哪儿发都不知道，宁可不发也不猜。
        guard !pending.runID.isEmpty else {
            notice = "无法确定这条审批所属的轮次，请刷新会话后重试。"
            return
        }
        approving = true
        let generation = revision
        let submission = UUID()
        approvalSubmission = submission
        defer { if approvalSubmission == submission { approving = false } }
        do {
            guard let requestID = pending.requestID else { return }
            let outcome = try await api.approveNativeTurn(
                runID: pending.runID, choice: choice, requestID: requestID,
                executionGeneration: pending.executionGeneration)
            noteRunRecoveryState()
            guard generation == revision, !suspended,
                  pendingApprovals.contains(pending), !Task.isCancelled else { return }
            switch outcome {
            case nil:
                removePendingApproval(id: pending.id)
                notice = nil
                recordRuntimeLog(.info, "approval", "choice=\(choice) accepted")
            case "unsupported":
                // Unsupported response does not prove the server prompt ended.
                notice = "这次审批需要在网页版完成，App 暂不支持。"
                error = notice
            case "not_pending":
                removePendingApproval(id: pending.id)
                notice = "这条审批已经失效（超时或被别处处理），稍后会同步最新状态。"
            case .some:
                notice = "服务未能接受这次审批，已保留请求，可同步后重试。"
                error = notice
            }
        } catch {
            guard generation == revision, !suspended,
                  pendingApprovals.contains(pending), !Task.isCancelled else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            recordRuntimeLog(.error, "approval",
                                             "choice=\(choice) failed err=\(error.localizedDescription)")
        }
    }

    func clearApproval() {
        let removed = pendingApprovals
        pendingApprovals = []
        for request in removed { onApprovalResolved?(sessionID, request.requestID) }
        approvalSubmission = UUID()
        approving = false
    }

    /// 回传一次补充信息答复。
    ///
    /// `answer` 传原始文本（用户输入的，或点选的选项文字）——**不做任何本地解析**。
    /// 服务端 `_coerce_text_response` 认编号、认标签、认 `1,3` 多选，也负责把
    /// 「有选项时用户直接说了一句话」判成 prose 并取消这次 clarify；客户端若自己
    /// 先映射一遍，会与服务端口径不一致，答错选项。
    ///
    /// 失败分类与审批一致：`not_pending` 撤卡片并说明；`rejected` 说明合同不匹配
    /// （多半是 generation 过期）；网络错误保留卡片让用户重试。
    func respondToClarify(_ answer: String, requestID: String? = nil, expected: ChatPendingClarify? = nil) async {
        let target: ChatPendingClarify?
        if let requestID {
            target = pendingClarifies.first { $0.id == requestID }
        } else {
            target = pendingClarifies.count == 1 ? pendingClarify : nil
        }
        guard let pending = target,
              canRespondToClarify(requestID: pending.id, expected: expected ?? pending) else { return }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // 开放式提问允许任意文本，但空串没有意义：服务端会当成空答案。
        guard !text.isEmpty else {
            notice = "请先填写或选择一项再提交。"
            return
        }
        // runID 必须已知：没有它连往哪儿发都不知道。
        guard !pending.runID.isEmpty else {
            notice = "无法确定这条提问所属的轮次，请刷新会话后重试。"
            return
        }
        clarifying = true
        let generation = revision
        let submission = UUID()
        clarifySubmission = submission
        defer { if clarifySubmission == submission { clarifying = false } }
        do {
            let outcome = try await api.clarifyNativeTurn(
                runID: pending.runID, answer: text,
                requestID: pending.requestID,
                executionGeneration: pending.executionGeneration)
            noteRunRecoveryState()
            guard generation == revision, !suspended,
                  pendingClarifies.contains(pending), !Task.isCancelled else { return }
            switch outcome {
            case nil:
                removePendingClarify(id: pending.id)
                notice = nil
                recordRuntimeLog(.info, "clarify", "answered chars=\(text.count)")
            case "unsupported":
                notice = "这次补充信息需要在网页版填写，App 暂不支持。"
                error = notice
            case "not_pending":
                removePendingClarify(id: pending.id)
                notice = "这条提问已经失效（超时或被别处处理），稍后会同步最新状态。"
            case .some:
                notice = "服务未能接受这次回答，已保留输入，可同步后重试。"
                error = notice
            }
        } catch {
            guard generation == revision, !suspended,
                  pendingClarifies.contains(pending), !Task.isCancelled else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            recordRuntimeLog(.error, "clarify",
                                             "answer failed err=\(error.localizedDescription)")
        }
    }

    func clearClarify() {
        let removed = pendingClarifies
        pendingClarifies = []
        for request in removed { onClarifyResolved?(sessionID, request.requestID) }
        clarifySubmission = UUID()
        clarifying = false
    }

    /// A stop POST is an acknowledgement, not proof that the run has ended.
    /// Keep the stream attached and ordinary sending disabled until the exact
    /// run reaches a verified terminal status and the final history GET succeeds.
    func stop() async {
        guard let active = streamID, !stopping, !submitting else { return }
        let generation = revision
        stopAcknowledged = false
        stopRejectedStatusCode = nil
        stopStatusProbeFailures = 0
        // STOP is an explicit cancellation boundary: preserve any user pause
        // and prohibit ordinary terminal-event queue dispatch from now on.
        pauseQueueForRecovery()
        transition(to: .stopping)
        do {
            try await api.stopNativeTurn(streamID: active)
            noteRunRecoveryState()
            guard generation == revision, streamID == active, !Task.isCancelled else { return }
            stopAcknowledged = true
            stopRejectedStatusCode = nil
            notice = "已请求停止，正在确认回复是否结束。"
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
        } catch {
            guard generation == revision, streamID == active else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            uncertain = true
            pauseQueueForRecovery()
            if let stopError = error as? ChatStopHTTPError,
               case .rejected(let code) = stopError {
                stopRejectedStatusCode = code
                notice = "停止请求未被接受，正在确认回复状态，暂不能发送。"
            } else {
                stopRejectedStatusCode = nil
                notice = "停止请求结果未知，正在确认回复状态，暂不能发送。"
            }
            // A failed/unknown STOP response is not terminal evidence. Perform
            // a fresh GET-only check, then continue the bounded poll if needed.
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
        }
    }

    /// Read-only verification, safe to invoke again from the visible notice.
    /// Neither the status GET nor the history GET can replay the original POST.
    func verifyPendingStop() async {
        guard stopping, let active = streamID, !stopStatusProbeInFlight else { return }
        stopStatusProbeInFlight = true
        defer { stopStatusProbeInFlight = false }
        let generation = revision
        let context = runContext(for: active, generation: generation)
        do {
            let result: ActiveRunProbe
            if let receipt = activeTurnRecovery, receipt.runID == active,
               let terminal = receipt.terminalStatus { result = .terminal(terminal) }
            else { result = try await recoveryProbe(sessionID: sessionID, runID: active) }
            guard accepts(context), stopping, !Task.isCancelled else { return }
            switch result {
            case .alive:
                stopStatusProbeFailures = 0
                if stopAcknowledged {
                    notice = "已请求停止，回复尚未结束，暂不能发送。"
                } else if stopRejectedStatusCode != nil {
                    notice = "停止请求未被接受，回复仍在进行。"
                } else {
                    notice = "停止请求结果未知，回复仍在进行。"
                }
            case .unknown:
                stopStatusProbeFailures = min(stopStatusProbeFailures + 1, 64)
                if stopAcknowledged {
                    notice = "已请求停止，暂时无法确认回复是否结束。"
                } else if stopRejectedStatusCode != nil {
                    notice = "停止请求未被接受，暂时无法确认回复是否结束。"
                } else {
                    notice = "停止请求结果未知，暂时无法确认回复是否结束。"
                }
            case .unresolved:
                stopStatusProbeFailures = 0
                unavailableRunStatusID = active
                automaticRecoveryQuiet = false
                uncertain = true
                pauseQueueForRecovery()
                streamID = nil
                stopAcknowledged = false
                transition(to: .idle)
                notice = "服务暂时找不到这次任务，尚不能确认是否停止。"
                scheduleAutomaticReconciliation()
            case .terminal(let outcome):
                stopStatusProbeFailures = 0
                guard rememberTerminalStatus(runID: active, outcome: outcome) else {
                    uncertain = true
                    pauseQueueForRecovery()
                    return
                }
                let finalHistory = try await recoveryHistory(sessionID: sessionID, before: nil)
                guard accepts(context), stopping, !Task.isCancelled else { return }
                guard finalHistory.sessionID == sessionID, !finalHistory.readOnly else {
                    uncertain = true
                    pauseQueueForRecovery()
                    notice = "任务已结束，最后的回复尚未同步，请稍后重试。"
                    return
                }
                // A different authoritative active Run can replace an
                // external STOP owner only after exact terminal proof of
                // the original and when there is no local submission/stream
                // content to settle. Never retire a protected local receipt.
                if case .active(let replacement) = finalHistory.activeRunEvidence,
                   replacement != active, activeTurnRecovery == nil, pendingSend == nil,
                   !recoveryRecordsUnreadable, lastEventID == nil,
                   buffer.messages.allSatisfy({ $0.sourceIndex != nil && $0.delivery == .confirmed }),
                   pendingApprovals.isEmpty, pendingClarifies.isEmpty {
                    try applySnapshot(finalHistory, preserveLoadedOlder: true)
                    stopStatusPollTask?.cancel()
                    stopStatusPollTask = nil
                    stopStatusPollTicket = nil
                    stopAcknowledged = false
                    stopRejectedStatusCode = nil
                    pauseQueueForRecovery()
                    attach(streamID: replacement)
                    return
                }
                guard finalHistory.activeRunEvidence == .absent else {
                    uncertain = true
                    pauseQueueForRecovery()
                    notice = "任务已结束，最后的回复尚未同步，请稍后重试。"
                    return
                }
                stopStatusPollTask?.cancel()
                stopStatusPollTask = nil
                stopStatusPollTicket = nil
                stopAcknowledged = false
                stopRejectedStatusCode = nil
                revision &+= 1
                streamTask?.cancel()
                streamTask = nil
                streamID = nil
                clearApproval()
                clearClarify()
                if outcome == .cancelled || outcome == .interrupted {
                    buffer.appendStopNotice()
                }
                transition(to: .idle)
                if try !finalizeVerifiedRun(finalHistory, runID: active, outcome: outcome) {
                    scheduleAutomaticReconciliation()
                }
            }
        } catch {
            guard accepts(context), stopping else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            stopStatusProbeFailures = min(stopStatusProbeFailures + 1, 64)
            uncertain = true
            pauseQueueForRecovery()
            notice = "暂时无法同步停止状态或最后的回复，不会重复发送消息。"
        }
    }

    /// STOP remains a GET-only owner until a verified result or cancellation.
    /// A still-running/unknown run stays locked; polling never changes queue
    /// preferences or grants permission to dispatch the next turn.
    func scheduleStopStatusPolling() {
        guard stopStatusPollTask == nil, stopping, let active = streamID,
              !suspended else { return }
        let generation = revision
        let ticket = UUID()
        stopStatusPollTicket = ticket
        let delays = stopStatusPollDelaysNanoseconds
        stopStatusPollTask = RecoveryScheduler.shared.startOwner(key: recoveryOwnerKey, ticket: ticket,
            onFinish: { [weak self] in
                guard let self, self.stopStatusPollTicket == ticket else { return }
                self.stopStatusPollTask = nil
                self.stopStatusPollTicket = nil
            }) { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                let delay: UInt64
                if !self.recoveryPresentationVisible {
                    delay = self.stopStatusPollOffscreenNanoseconds
                } else if attempt < delays.count {
                    delay = delays[attempt]
                } else {
                    delay = self.stopStatusPollSteadyNanoseconds
                }
                let backoff = self.stopStatusProbeFailures == 0 ? 0
                    : self.automaticReconciliationDelaysNanoseconds.dropFirst(self.stopStatusProbeFailures - 1).first
                        ?? self.automaticReconciliationDelaysNanoseconds.last ?? 0
                do { try await Task.sleep(nanoseconds: max(delay, backoff)) }
                catch { return }
                guard !Task.isCancelled, generation == self.revision,
                      self.streamID == active, self.stopping, !self.suspended,
                      !self.authenticationRequired else { return }
                await self.verifyPendingStop()
                guard !Task.isCancelled, generation == self.revision,
                      self.streamID == active, self.stopping, !self.suspended else { return }
                attempt = min(attempt + 1, delays.count)
            }
        }
    }

    /// Authentication failures retire the view's account namespace in AppState.
    /// Do not leave another account's cached text visible behind a login sheet,
    /// and do not spend the reconnect budget on an unauthenticated stream.
    @discardableResult func handleAuthenticationFailure(_ error: Error) -> Bool {
        guard api.requiresAuthentication(after: error) else { return false }
        recordRuntimeLog(.error, "auth", "session expired err=\(error.localizedDescription)")
        revision &+= 1
        publishTask?.cancel()
        publishTask = nil
        streamTask?.cancel()
        streamTask = nil
        stopStatusPollTask?.cancel()
        stopStatusPollTask = nil
        stopStatusPollTicket = nil
        stopAcknowledged = false
        stopRejectedStatusCode = nil
        buffer = ChatTranscript()
        confirmedHistory = nil
        confirmedHistoryEnd = nil
        settledAttachmentPaths = []
        lastEventID = nil
        streamID = nil
        olderOffset = 0
        sessionModel = nil
        sessionProvider = nil
        suspended = false
        // 登录失效是相位本身，不是叠加在相位上的事实：直接落 `.needsLogin`。
        transition(to: .needsLogin)
        readOnly = true
        uncertain = true
        // Hide the transcript and disable every mutation while unauthenticated.
        // A 401 alone does not prove the account or accepted POST disappeared.
        // AppState's explicit account retirement performs scoped deletion.
        pauseQueueForRecovery()
        lastFinalizedRecord = nil
        clearApproval()
        clearClarify()
        pendingAbsent = false
        self.error = error.localizedDescription
        notice = "登录状态已失效，请重新登录后读取历史。"
        flush()
        if !authenticationReported {
            authenticationReported = true
            onAuthenticationRequired?()
        }
        return true
    }

}
