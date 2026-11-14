import Foundation

extension NativeChatModel {
    /// 回传一次审批决定。
    ///
    /// 成功就撤卡片，让流继续往下跑——网关在收到答复前不会推进本轮。
    /// 失败分三类处理：服务端说这张票已失效（not_pending）就撤掉并说明；
    /// 说选项不合法（rejected）说明是版本不匹配；网络错误保留卡片让用户重试。
    func respondToApproval(_ choice: String) async {
        guard let pending = pendingApproval, !approving, !suspended,
              pending.choices.contains(choice), streamID == pending.runID else { return }
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
            let outcome = try await api.approveNativeTurn(runID: pending.runID,
                                                          choice: choice,
                                                          requestID: pending.requestID)
            noteRunRecoveryState()
            guard generation == revision, !suspended,
                  pendingApproval == pending, !Task.isCancelled else { return }
            switch outcome {
            case nil:
                pendingApproval = nil
                notice = nil
                RuntimeLogRecorder.shared.record(.info, "approval", "choice=\(choice) accepted")
            case "unsupported":
                pendingApproval = nil
                notice = "当前后端不支持在 App 内审批，请在 WebUI 处理。"
            case "not_pending":
                pendingApproval = nil
                notice = "这条审批已经失效（超时或被别处处理），稍后会同步最新状态。"
            case let other?:
                pendingApproval = nil
                notice = "服务端拒绝了这次审批（\(other)）。"
            }
        } catch {
            guard generation == revision, !suspended,
                  pendingApproval == pending, !Task.isCancelled else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            RuntimeLogRecorder.shared.record(.error, "approval",
                                             "choice=\(choice) failed err=\(error.localizedDescription)")
        }
    }

    func clearApproval() {
        pendingApproval = nil
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
    func respondToClarify(_ answer: String) async {
        guard let pending = pendingClarify, !clarifying, !suspended,
              streamID == pending.runID else { return }
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
                  pendingClarify == pending, !Task.isCancelled else { return }
            switch outcome {
            case nil:
                pendingClarify = nil
                notice = nil
                RuntimeLogRecorder.shared.record(.info, "clarify", "answered chars=\(text.count)")
            case "unsupported":
                pendingClarify = nil
                notice = "当前后端不支持在 App 内回答补充信息，请在 WebUI 处理。"
            case "not_pending":
                pendingClarify = nil
                notice = "这条提问已经失效（超时或被别处处理），稍后会同步最新状态。"
            case let other?:
                pendingClarify = nil
                notice = "服务端拒绝了这次回答（\(other)）。"
            }
        } catch {
            guard generation == revision, !suspended,
                  pendingClarify == pending, !Task.isCancelled else { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            RuntimeLogRecorder.shared.record(.error, "clarify",
                                             "answer failed err=\(error.localizedDescription)")
        }
    }

    func clearClarify() {
        pendingClarify = nil
        clarifySubmission = UUID()
        clarifying = false
    }

    func stop() async {
        guard let active = streamID, !stopping, !submitting else { return }
        let generation = revision
        // 每次停止提交自己的身份。`defer` 只能收尾这一次提交：
        // 离开页面再回来可能已经发起了第二笔停止，旧请求的收尾不能把新的
        // `.stopping` 改成 `.idle`（那会解锁普通发送，而服务端并未确认停止）。
        let submission = UUID()
        stopSubmission = submission
        transition(to: .stopping)
        // 退出时若仍停在 `.stopping`，落回静止态。停止失败的分支会先改成
        // `.streaming(connected: false)`，那时这里不再覆盖。
        //
        // 三个条件缺一不可：仍是本次提交、相位仍停在 `.stopping`、且没有被
        // 作用域轮换作废。后台失败那笔的 catch 因 generation 失配跳过，但
        // 未确认停止同样不能无条件落 idle —— 那等于谎报本轮已结束。
        defer {
            if stopSubmission == submission, generation == revision,
               case .stopping = phase {
                transition(to: .idle)
            }
        }
        do {
            try await api.stopNativeTurn(streamID:active)
            noteRunRecoveryState()
            RuntimeLogRecorder.shared.record(.info, "stream", "stop ok")
            guard generation == revision else { return }
            publishTask?.cancel()
            publishTask = nil
            revision &+= 1
            streamTask?.cancel()
            streamTask = nil
            streamID = nil
            // 停止已确认：本轮结束。这里显式落回静止态，不依赖 defer——
            // 后面还要 await load()，defer 要到函数末尾才跑，中间这段时间
            // 界面会一直停在「正在停止…」。
            transition(to: .idle)
            // run 已经停了，这张票永远投不出去，留着只会误导。
            pendingApproval = nil
            pendingClarify = nil
            notice = "服务器已确认停止。"
            // 停止是本轮的正常终态，要在对话流里留下可回看的记录（F-32）。
            buffer.appendStopNotice()
            await load(silent: true, preserveLoadedOlder: true)
        } catch {
            if generation == revision {
                if handleAuthenticationFailure(error) { return }
                self.error = error.localizedDescription
                // 停止失败：本轮可能还在跑，退回「流式但未连上」比假装结束更诚实。
                transition(to: .streaming(connected: false))
            }
        }
    }

    /// Authentication failures retire the view's account namespace in AppState.
    /// Do not leave another account's cached text visible behind a login sheet,
    /// and do not spend the reconnect budget on an unauthenticated stream.
    @discardableResult func handleAuthenticationFailure(_ error: Error) -> Bool {
        guard api.requiresAuthentication(after: error) else { return false }
        RuntimeLogRecorder.shared.record(.error, "auth", "session expired err=\(error.localizedDescription)")
        revision &+= 1
        publishTask?.cancel()
        publishTask = nil
        streamTask?.cancel()
        streamTask = nil
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
        // 换账号后既不能保留上一账号的待核对正文，也不能凭它的附件引用重发。
        pendingSend = nil
        queuedTurns = []
        queueAutomaticDispatchPaused = false
        queueSaveFailed = false
        let clearResult = draftStore?.saveQueued(nil)
        if let clearResult, !clearResult.succeeded {
            recordLocalWrite(clearResult, kind: .queue)
        } else if localPersistenceIssue?.kind == .queue {
            localPersistenceIssue = nil
        }
        pendingApproval = nil
        approvalSubmission = UUID()
        approving = false
        pendingClarify = nil
        clarifySubmission = UUID()
        clarifying = false
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
