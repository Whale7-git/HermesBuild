import Foundation

extension NativeChatModel {

    /// Display-only preflight for first paint: no network, POST, stream
    /// attachment or authority to send. Also used by normal load().
    func warmupCachedHistory() async {
        guard !historyReadAttempted, !Task.isCancelled else { return }
        historyReadAttempted = true
        let generation = revision
        let cached = await historyStore?.load()
        guard generation == revision, !Task.isCancelled else { return }
        guard let cached, cached.sessionID == sessionID,
              buffer.messages.isEmpty, buffer.tools.isEmpty else { return }
        buffer = ChatTranscript()
        buffer.messages = Array(cached.messages.suffix(Self.cachedWarmupMessages))
        let visibleIDs = Set(buffer.messages.map(\.id))
        buffer.tools = Array(cached.tools.filter {
            $0.afterMessageID.map { visibleIDs.contains($0) } ?? true
        }.suffix(Self.cachedWarmupMessages))
        buffer.usage = cached.usage
        // The cache is intentionally bounded. Never present missing tool IDs
        // as proof that the server history contains no other tools.
        if cached.uncachedToolCount > 0 && notice == nil {
            notice = "本地缓存尚缺 \(cached.uncachedToolCount) 项工具记录；联网刷新后核对。"
        }
        olderOffset = max(cached.olderOffset, buffer.messages.first?.sourceIndex ?? cached.olderOffset)
        sessionModel = cached.model
        readOnly = true
        streamID = nil
        lastEventID = nil
        transition(to: .cached(savedAt: cached.savedAt, syncing: loading || syncing))
        flush()
    }

    /// `allowWhileReconciling` 供 `reconcilePending()` 的核对 GET 使用：
    /// 那个 GET 自己就是置起 `reconciling` 的人，不能被同一个标志挡住。
    func load(silent: Bool = false, preserveLoadedOlder: Bool = false,
              allowWhileReconciling: Bool = false) async {
        if submitting { resumeRequested = true; return }
        guard !syncing, !loading else { return }
        // A-07：核对流程自己持有 `reconciling`，只有它能带 allowWhileReconciling 进来。
        guard allowWhileReconciling || !reconciling else { return }
        if running && streamTask != nil { return }
        publishTask?.cancel()
        publishTask = nil
        activeRunProbeTask?.cancel()
        activeRunProbeTask = nil
        activeRunProbeRunID = nil
        revision &+= 1
        let generation = revision
        suspended = false
        // 正在显示磁盘历史时**不能**改成 `.loading`：那样会丢掉「当前显示的是
        // 缓存」这个事实，而 `applySnapshot` 正靠它决定丢弃过期的 model/usage
        // 元数据（缓存里存的是上次快照的值，联网后必须被权威值替换而不是合并）。
        // 保持 `.cached(syncing: true)` 也更符合界面语义：内容可见、正在核对。
        if let savedAt = phase.cachedSince {
            transition(to: .cached(savedAt: savedAt, syncing: true))
        } else {
            transition(to: silent ? .syncing : .loading)
        }
        error = nil
        // 只清「本次 load 自己置起的」过渡态。若 load 过程中已挂上流
        // （`.streaming`）或仍在显示缓存（`.cached`），那不是本函数该收的尾。
        defer {
            if generation == revision, !phase.isRunning, !phase.isCached { transition(to: .idle) }
        }
        // The page may prewarm and paint this same scoped history before GET.
        // One-shot per model; the authoritative request remains mandatory.
        await warmupCachedHistory()
        guard generation == revision, !Task.isCancelled else { return }
        do {
            let snap = try await api.history(sessionID:sessionID,before:nil)
            guard generation == revision, !Task.isCancelled else { return }
            RuntimeLogRecorder.shared.record(.info, "history",
                "load ok messages=\(snap.messages.count) tools=\(snap.tools.count) active=\(snap.activeStreamID != nil)")
            try applySnapshot(snap, preserveLoadedOlder: preserveLoadedOlder)
            // Do not erase the unresolved accepted-run status after history GET.
            if pendingSend == nil && !uncertain { notice = nil }
            // 相位已由 applySnapshot 按 active_stream_id 落定；attach 会再确认一次。
            if case .active(let active) = snap.activeRunEvidence { attach(streamID:active) }
        } catch {
            if generation == revision {
                if handleAuthenticationFailure(error) { return }
                self.error = error.localizedDescription
                RuntimeLogRecorder.shared.record(.error, "history", "load fail err=\(error.localizedDescription)")
                uncertain = true
                // 缓存失败保留 `.cached`（历史还在屏幕上），只是不再声称在核对。
                if let savedAt = cachedHistoryDate {
                    transition(to: .cached(savedAt: savedAt, syncing: false))
                    notice = "已显示本地历史，联网核对成功前不能发送。"
                } else {
                    transition(to: .idle)
                }
            }
        }
    }

    func loadOlder() async {
        guard canLoadOlderHistory else { return }
        let generation = revision
        let requestedOffset = olderOffset
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let snap = try await api.history(sessionID:sessionID,before:requestedOffset)
            guard generation == revision, olderOffset == requestedOffset,
                  !Task.isCancelled, !suspended else { return }
            guard snap.sessionID == sessionID else { throw ChatCoreError.malformed("history session mismatch") }
            let oldIDs = Set(buffer.messages.map(\.id))
            let newMessages = snap.messages.filter { !oldIDs.contains($0.id) }
            let toolIDs = Set(buffer.tools.map(\.id))
            let newTools = snap.tools.filter { !toolIDs.contains($0.id) }
            // Accept or refuse the whole page before mutating anything. The old
            // order (prepend, then trim the oldest rows) removed the page that
            // had just arrived while `olderOffset` still moved past it, so the
            // range became unreachable and the cursor skipped history.
            let addedBytes = newMessages.reduce(0) { $0 + Self.cost($1) }
                + newTools.reduce(0) { $0 + Self.cost($1) }
            let projectedCount = buffer.messages.count + newMessages.count
            let projectedBytes = loadedBytes + addedBytes
            guard projectedCount <= Self.maxLoadedMessages, projectedBytes <= Self.maxLoadedBytes else {
                RuntimeLogRecorder.shared.record(.warning, "paging",
                    "refused page count=\(projectedCount) bytes=\(projectedBytes)")
                olderLimitReached = true
                notice = "已到本地历史窗口上限（\(Self.maxLoadedMessages) 条 / \(Self.maxLoadedBytes / 1024 / 1024) MB）。更早内容可用「导出 Markdown → 获取完整历史」查看。"
                return
            }
            buffer.messages.insert(contentsOf: newMessages, at: 0)
            buffer.tools.insert(contentsOf: newTools, at: 0)
            olderOffset = snap.olderOffset
            olderLimitReached = false
            RuntimeLogRecorder.shared.record(.info, "paging",
                "page ok added=\(newMessages.count) offset=\(snap.olderOffset)")
            confirmedHistory?.prepend(snap)
            if let confirmedHistory { historyStore?.schedule(confirmedHistory) }
            flush()
        } catch {
            // A dismissed page cancels its GET. Cancellation, suspension and
            // obsolete generation must not surface a spurious paging error
            // into a new/returned Session UI.
            guard generation == revision, !Task.isCancelled, !suspended else { return }
            if error is CancellationError { return }
            if handleAuthenticationFailure(error) { return }
            self.error = error.localizedDescription
            RuntimeLogRecorder.shared.record(.error, "paging", "page fail err=\(error.localizedDescription)")
        }
    }

    /// Bytes currently held by the data window; pages are budgeted against this.
    private var loadedBytes: Int {
        buffer.messages.reduce(0) { $0 + Self.cost($1) } + buffer.tools.reduce(0) { $0 + Self.cost($1) }
    }

    private static func cost(_ message: ChatMessage) -> Int {
        160 + message.id.utf8.count + message.content.utf8.count
            + message.attachmentPaths.reduce(0) { $0 + $1.utf8.count }
    }

    private static func cost(_ tool: ChatTool) -> Int {
        160 + tool.id.utf8.count + tool.name.utf8.count + tool.args.utf8.count
            + tool.result.utf8.count + (tool.afterMessageID?.utf8.count ?? 0)
    }

    /// Drops the oldest rows only when the window grows past the budget through
    /// snapshot replacement (server window), never after an accepted page.
    /// 把消息窗口压回上限，并同步丢弃锚点已不在窗口内的工具。
    ///
    /// 预算（`loadedBytes`）把工具算进去了，但裁剪以前只动 `messages`：
    /// 工具占的字节永远不释放，长会话里分页会被提前拒绝（提示「已到上限」
    /// 而消息数远没到）；同时锚点失效的工具在时间线里三个分支都不命中，
    /// 等于静默消失。两个问题同一个根因，一起修。
    @discardableResult
    private func trimLoadedMessages() -> Bool {
        let count = buffer.messages.count
        var remainingBytes = loadedBytes
        guard count > Self.maxLoadedMessages || remainingBytes > Self.maxLoadedBytes else { return false }

        // Account for the tools that disappear when their message anchor is
        // evicted. Count and byte limits must describe the SAME retained window;
        // a 60-row snapshot containing huge tool results can exceed 16 MiB.
        var toolBytesByAnchor: [String: Int] = [:]
        for tool in buffer.tools {
            if let anchor = tool.afterMessageID {
                toolBytesByAnchor[anchor, default: 0] += Self.cost(tool)
            }
        }
        var removedMessages = 0
        while count - removedMessages > 1 &&
              (count - removedMessages > Self.maxLoadedMessages ||
               remainingBytes > Self.maxLoadedBytes) {
            let oldest = buffer.messages[removedMessages]
            remainingBytes -= Self.cost(oldest) + (toolBytesByAnchor[oldest.id] ?? 0)
            removedMessages += 1
        }
        if removedMessages > 0 {
            buffer.messages.removeFirst(removedMessages)
            pruneOrphanedTools()
        }

        // A single current turn can own more tool output than the entire data
        // budget. Drop oldest complete tool records first, never truncate a
        // message or discard the last tool; full history remains on the server.
        var removedTools = 0
        remainingBytes = loadedBytes
        if remainingBytes > Self.maxLoadedBytes && buffer.tools.count > 1 {
            for tool in buffer.tools.dropLast() where remainingBytes > Self.maxLoadedBytes {
                remainingBytes -= Self.cost(tool)
                removedTools += 1
            }
            if removedTools > 0 { buffer.tools.removeFirst(removedTools) }
        }
        // One oversized message/tool is kept intact rather than presenting
        // clipped content as if it were a complete server response.
        return removedMessages > 0 || removedTools > 0
    }

    /// 只保留「无锚点」或「锚点仍在窗口内」的工具。
    /// 无锚点的是尾部流式工具，本来就挂在末尾，不随裁剪失效。
    private func pruneOrphanedTools() {
        guard !buffer.tools.isEmpty else { return }
        let visible = Set(buffer.messages.map(\.id))
        let kept = buffer.tools.filter { tool in
            guard let anchor = tool.afterMessageID else { return true }
            return visible.contains(anchor)
        }
        if kept.count != buffer.tools.count { buffer.tools = kept }
    }


    private func historyPrefix(for snap: ChatSnapshot, source: ChatTranscript, preserve: Bool)
        -> (messages: [ChatMessage], tools: [ChatTool]) {
        var earlierMessages: [ChatMessage] = []
        var earlierTools: [ChatTool] = []
        // Preserve only a contiguous, still-identical canonical prefix. A
        // changed/truncated conversation must not resurrect removed history.
        let canonical = source.messages.compactMap { message -> (Int, ChatMessage)? in
            guard let index = message.sourceIndex else { return nil }
            return (index, message)
        }
        let oldCanonical = canonical.map(\.1)
        let oldByIndex = Dictionary(canonical.map { ($0.0, $0.1.id) },
                                    uniquingKeysWith: { first, _ in first })
        let overlapsAgree = snap.messages.allSatisfy { message in
            guard let index = message.sourceIndex, let oldID = oldByIndex[index] else { return true }
            return oldID == message.id
        }
        let contiguous = confirmedHistoryEnd.map {
            snap.olderOffset <= $0 && snap.rawMessageEndIndex >= $0
        } ?? false
        if preserve && cachedHistoryDate == nil && contiguous && overlapsAgree {
            earlierMessages = oldCanonical.filter {
                ($0.sourceIndex ?? Int.max) < snap.olderOffset
                    && !$0.id.hasPrefix("local-") && !$0.id.hasPrefix("streaming:")
            }
            let anchors = Set(earlierMessages.map(\.id))
            let newToolIDs = Set(snap.tools.map(\.id))
            earlierTools = source.tools.filter { tool in
                !newToolIDs.contains(tool.id) && tool.afterMessageID.map { anchors.contains($0) } == true
            }
        }
        return (earlierMessages, earlierTools)
    }

    /// 把「空正文 + 附件」的本地行换成服务端那一行的真实 ID。
    ///
    /// 只接受唯一命中：候选必须全部满足角色、窗口、非旧回声、正文一致、
    /// 附件覆盖；命中 0 条继续等下一份快照，命中 ≥2 条直接放弃（保持显示文字）。
    private func bindPlaceholderCandidates(in snap: ChatSnapshot) {
        guard !placeholderCandidates.isEmpty else { return }
        var remaining: [PlaceholderCandidate] = []
        for candidate in placeholderCandidates {
            guard let historyEnd = candidate.historyEnd,
                  snap.olderOffset <= historyEnd,
                  snap.rawMessageEndIndex >= historyEnd else {
                // 窗口还不足以判断：留到下一份快照，不猜。
                remaining.append(candidate)
                continue
            }
            let matches = snap.messages.filter { message in
                message.role == "user"
                    && (message.sourceIndex ?? -1) >= historyEnd
                    && !candidate.knownIDs.contains(message.id)
                    && message.content == candidate.text
                    && candidate.attachmentPaths.isSubset(of: Set(message.attachmentPaths))
            }
            guard matches.count == 1, let hit = matches.first else {
                // 0 条：继续等；≥2 条：永久放弃这次绑定（不猜）。
                if matches.isEmpty { remaining.append(candidate) }
                else {
                    ChatAttachmentPlaceholderStore.shared.forgetLocal(
                        scope: displayScope, sessionID: sessionID, id: candidate.localID)
                }
                continue
            }
            ChatAttachmentPlaceholderStore.shared.bind(
                scope: displayScope, sessionID: sessionID,
                localID: candidate.localID, confirmedID: hit.id)
        }
        placeholderCandidates = remaining
    }

    func applySnapshot(_ snap:ChatSnapshot, preserveLoadedOlder: Bool = false) throws {
        guard snap.sessionID == sessionID else { throw ChatCoreError.malformed("history session mismatch") }
        // A status GET failure is not authoritative absence. Preserve the
        // streamed accumulator, SSE cursor, request cards and send lock.
        if snap.activeRunEvidence == .unknown {
            uncertain = true
            pauseQueueForRecovery()
            notice = "后台状态暂时无法确认；已保留当前回复与待处理请求，不会自动重发。"
            // History lookup failure cannot erase the accepted receipt. Probe
            // the exact Run independently, including after a run-status 404;
            // otherwise the status remains unknown forever on this screen.
            if let receipt = activeTurnRecovery, !submitting {
                probeAcceptedRun(receipt)
            }
            return
        }
        // Manual/foreground history refresh must respect the same accepted
        // Run receipt as terminal SSE finalization. A stale GET is not allowed
        // to erase a visibly streamed answer after a recovery retry timeout.
        let streamedAssistantPresent = buffer.messages.contains {
            $0.role == "assistant" && $0.id.hasPrefix("streaming:")
        }
        if buffer.terminal && buffer.failure == nil && streamedAssistantPresent &&
           !ChatFinalHistoryGate.canReplace(
               snap, sessionID: sessionID, receipt: activeTurnRecovery,
               streamedAssistantPresent: true, expectedRunID: streamID) {
            throw ChatCoreError.server("最终历史尚未确认本轮回复，流式内容已保留")
        }
        latestRecoverySnapshot = snap
        let wasCached = cachedHistoryDate != nil
        let previousOffset = olderOffset
        var windowTrimmed = false
        let (earlierMessages, earlierTools) = historyPrefix(for: snap, source: buffer, preserve: preserveLoadedOlder)
        // 终态通知行（失败/取消/打断/预算上限）不在服务端历史里，是流式收尾产生的。
        // 它们要作为「可回看的记录」留在对话里，直到下一轮 submit 用全新 ChatTranscript
        // 清空——所以任何 reset 都带回，而不是只在「这轮刚结束」那一次带（那会让一次
        // 普通刷新/回前台就把失败记录抹掉）。
        let carriedNotices = buffer.notices
        let keepsAccumulator = !wasCached && lastEventID != nil && snap.activeStreamID != nil
            && snap.activeStreamID == streamID && !buffer.terminal
        // A history GET has no event cursor. Keep the in-memory accumulator
        // when it still describes the same live stream, including seen IDs.
        if wasCached || lastEventID == nil || snap.activeStreamID == nil || snap.activeStreamID != streamID || buffer.terminal {
            let previousUsage = wasCached ? nil : buffer.usage
            let wasTerminal = buffer.terminal
            buffer = ChatTranscript()
            buffer.notices = carriedNotices
            buffer.usage = previousUsage
            buffer.messages = earlierMessages + snap.messages
            // 先装配工具再裁剪：反过来会让 earlierTools 逃过锚点清理。
            buffer.tools = earlierTools + snap.tools
            windowTrimmed = trimLoadedMessages()
            // 终态后必须保持「已收尾」：清掉 lastEventID 又不标记 terminal，
            // 会让随后的 attach 用空游标全量重连，把已渲染正文重放成新消息。
            if wasTerminal { buffer.terminal = true }
            lastEventID = nil
        }
        buffer.usage = buffer.usage?.merging(snap.usage) ?? snap.usage
        olderOffset = !earlierMessages.isEmpty || keepsAccumulator ? min(previousOffset, snap.olderOffset) : snap.olderOffset
        if windowTrimmed, let first = buffer.messages.first?.sourceIndex {
            // Rows trimmed from a server window are no longer loaded. Keep
            // their range reachable instead of jumping the next page below it.
            olderOffset = max(olderOffset, first)
        }
        // A fresh authoritative window can be smaller than the refused one, so
        // the local budget may have room again.
        if buffer.messages.count < Self.maxLoadedMessages { olderLimitReached = false }
        readOnly = snap.readOnly
        sessionModel = snap.model
        sessionProvider = snap.modelProvider
        streamID = snap.activeStreamID
        removePendingApprovals(for: snap.activeStreamID)
        // clarify 同理：权威快照说这一轮已经不是那个 run 了，卡片就必须撤掉，
        // 否则会留一个发给已结束 run 的输入框。
        removePendingClarifies(for: snap.activeStreamID)
        uncertain = false
        confirmedHistoryEnd = snap.rawMessageEndIndex
        bindPlaceholderCandidates(in: snap)
        if let pending = pendingSend, !submitting {
            switch pending.resolution(in: snap) {
            case .delivered:
                buffer.messages.removeAll { $0.id == pending.id }
                pendingSend = nil
                pendingAbsent = false
                acknowledgeDeliveredQueuedTurn(matching: pending)
                settledAttachmentPaths = pending.attachments.map(\.path)
                // Clear only the restored original; preserve a newer draft.
                if draft == pending.composerText { draft = "" }
            case .absent, .failed:
                let provenAbsent = pending.resolution(in: snap) == .absent
                if provenAbsent && pending.hiddenFromTranscript == true {
                    // An explicitly dismissed placeholder can be retired only
                    // after authoritative proof of absence.
                    pendingSend = nil
                    pendingAbsent = false
                    uncertain = false
                    notice = nil
                    break
                }
                pendingAbsent = provenAbsent
                uncertain = !pendingAbsent
                if pending.hiddenFromTranscript != true
                    && !buffer.messages.contains(where: { $0.id == pending.id }) {
                    buffer.messages.append(ChatMessage(id: pending.id, role: "user", content: pending.text,
                        timestamp: pending.createdAt,
                        attachmentPaths: pending.attachments.map(\.path), delivery: .unconfirmed))
                }
                notice = pendingAbsent ? "历史核对未发现本次消息，可选择重发或放弃。"
                    : "当前历史不足以确认本次发送结果，暂不能重发；请稍后核对。"
            }
        }
        // A restored accepted turn is independent from PendingSend. Even if
        // the backend temporarily omits active_stream_id, do not turn an old
        // assistant answer into permission to send another POST.
        if let receipt = activeTurnRecovery, !submitting {
            if snap.activeStreamID == receipt.runID {
                if pendingSend == nil { uncertain = false }
            } else if receipt.confirmsCompletion(in: snap) {
                if clearAcceptedTurnRecovery(), pendingSend == nil {
                    uncertain = false
                    notice = nil
                }
            } else {
                uncertain = true
                pauseQueueForRecovery()
                notice = "已受理的后台任务目前无法确认是否结束；请核对历史，消息不会重新发送。"
                probeAcceptedRun(receipt)
            }
        }
        if let controls = snap.gatewayPendingControls, let activeRunID = snap.activeStreamID {
            restorePendingControls(controls, runID: activeRunID)
        }
        authenticationReported = false
        // 收到权威快照即证明登录有效、且已脱离「只显示磁盘历史」的缓存态。
        // 相位落到与 `active_stream_id` 一致的终态：有活跃流就是流式（尚未收到帧），
        // 否则回到静止态。调用方（load/attach 的收尾）若需要别的相位会在之后覆盖。
        transition(to: snap.activeStreamID == nil ? .idle : .streaming(connected: false))
        var record = ChatHistoryRecord(snapshot: snap)
        if !earlierMessages.isEmpty {
            // Do not overwrite the disk cache into a record that holds only the
            // newest window: re-attach the preserved older messages so the next
            // cold start still shows the previously paged history and its
            // oldest fetched cursor and tool details.
            record.messages.insert(contentsOf: earlierMessages, at: 0)
            record.tools.insert(contentsOf: earlierTools, at: 0)
            record.olderOffset = olderOffset
        }
        confirmedHistory = record
        historyStore?.schedule(record)
        flush()
    }

    /// Manual, bounded, read-only recovery for a long agent turn. The normal
    /// history GET is only 60 raw rows, including many invisible tool records;
    /// a valid accepted receipt may therefore precede the visible tail.
    /// Never unlock on gaps, a changed session/run, or partial evidence.
    func reconcileLongAcceptedRun() async -> Bool {
        guard let receipt = activeTurnRecovery,
              error == nil,
              let latest = latestRecoverySnapshot,
              latest.sessionID == sessionID, !latest.readOnly,
              latest.activeRunEvidence == .absent,
              !submitting, !loading, !syncing, !running, !reconciling,
              !suspended else { return false }
        guard let boundary = receipt.historyEnd else {
            notice = "缺少本轮发送前的历史位置，无法仅凭历史确认结束。"
            return false
        }
        if latest.activeStreamID == receipt.runID {
            notice = "后台任务仍在运行；本轮结束前不会解除发送锁定。"
            return false
        }
        guard latest.activeStreamID == nil else {
            notice = "服务端还有后台任务在运行，暂不能通过历史确认本轮结束。"
            return false
        }
        guard latest.olderOffset > boundary else {
            notice = "最新历史已经覆盖本轮起点，但尚不足以确认结束；发送仍保持锁定。"
            return false
        }
        let generation = revision
        reconciling = true
        defer { reconciling = false }
        var pages = [latest]
        // Hard request budget: at most 63 older GETs + one final head check.
        // Never modify the source window or download the entire conversation.
        for _ in 0..<63 where (pages.last?.olderOffset ?? 0) > boundary {
            guard generation == revision, activeTurnRecovery == receipt,
                  !Task.isCancelled, !suspended else { return false }
            let cursor = pages[pages.count - 1].olderOffset
            do {
                let older = try await api.history(sessionID: sessionID, before: cursor)
                guard generation == revision, activeTurnRecovery == receipt,
                      !Task.isCancelled, !suspended else { return false }
                guard older.sessionID == sessionID, !older.readOnly,
                      older.rawMessageEndIndex == cursor,
                      older.olderOffset < cursor,
                      older.activeRunEvidence == .absent else {
                    notice = "历史分页发生变化或不连续；未解除发送锁定，请稍后核对。"
                    return false
                }
                if older.activeStreamID == receipt.runID {
                    notice = "后台任务仍在运行；本轮结束前不会解除发送锁定。"
                    return false
                }
                guard older.activeStreamID == nil else {
                    notice = "后台出现了另一轮运行；本轮发送仍保持锁定，请稍后核对。"
                    return false
                }
                pages.append(older)
            } catch {
                guard generation == revision, !Task.isCancelled else { return false }
                if handleAuthenticationFailure(error) { return false }
                self.error = error.localizedDescription
                notice = "回溯历史失败；发送仍保持锁定，未重新提交消息。"
                return false
            }
        }
        guard (pages.last?.olderOffset ?? Int.max) <= boundary else {
            notice = "本轮历史超过本次核对上限，无法安全确认；未重新发送消息。"
            return false
        }
        guard receipt.confirmsCompletion(in: pages) else {
            notice = "已回溯本轮历史，但缺少唯一的原始提问与后续回复证据；发送仍保持锁定。"
            return false
        }
        // Re-check the live tail after pagination: another client may have
        // appended rows or restarted execution while we were reading pages.
        do {
            let current = try await api.history(sessionID: sessionID, before: nil)
            guard generation == revision, activeTurnRecovery == receipt,
                  !Task.isCancelled, !suspended else { return false }
            guard current.sessionID == sessionID, current.activeRunEvidence == .absent,
                  !current.readOnly,
                  current.rawMessageEndIndex == latest.rawMessageEndIndex,
                  current.messages.last?.id == latest.messages.last?.id else {
                notice = "核对期间服务端历史或运行状态发生变化，请重新核对；未解除发送锁定。"
                return false
            }
        } catch {
            guard generation == revision, !Task.isCancelled else { return false }
            if handleAuthenticationFailure(error) { return false }
            self.error = error.localizedDescription
            notice = "核对最终状态失败；发送仍保持锁定。"
            return false
        }
        guard clearAcceptedTurnRecovery() else { return false }
        uncertain = pendingSend != nil || pendingRecoveryUnreadable || activeRecoveryUnreadable
        if !uncertain { notice = nil }
        error = nil
        RuntimeLogRecorder.shared.record(.info, "recovery",
            "long-run history verified pages=\(pages.count) without POST")
        return !uncertain
    }

    /// Follow up an inconclusive run/send automatically while the chat is
    /// visible. GET-only, bounded and serial. A run/queue safety lock is never
    /// cleared merely because these attempts exhaust their budget.
    func scheduleAutomaticReconciliation() {
        guard automaticReconciliationTask == nil, !suspended, !authenticationRequired,
              !stopping, !running, !submitting, !loading, !syncing, !reconciling,
              uncertain || pendingSend != nil || activeTurnRecovery != nil else { return }
        // An authoritative absence allows an explicit user decision to resend;
        // the automatic worker must not re-send or nag by rechecking that proof.
        if pendingSend != nil && pendingAbsent && activeTurnRecovery == nil { return }
        let runID = activeTurnRecovery?.runID
        let pendingID = pendingSend?.id
        let ticket = UUID()
        automaticReconciliationTicket = ticket
        automaticReconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.automaticReconciliationTicket == ticket {
                    self.automaticReconciliationTask = nil
                    self.automaticReconciliationTicket = nil
                }
            }
            for (attempt, delay) in self.automaticReconciliationDelaysNanoseconds.enumerated() {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled, self.automaticReconciliationTicket == ticket,
                      !self.suspended, !self.authenticationRequired, !self.stopping,
                      !self.running, !self.submitting,
                      !self.loading, !self.syncing, !self.reconciling,
                      self.activeTurnRecovery?.runID == runID,
                      self.pendingSend?.id == pendingID else { return }
                if let pendingID, self.pendingAbsent,
                   self.pendingSend?.id == pendingID, runID == nil { return }

                // A lost POST remains a durable PendingSend. Reconcile it by
                // history only; never invoke send(), resendPending() or flush.
                if self.pendingSend != nil {
                    _ = await self.reconcilePending()
                } else {
                    await self.refresh(silent: true, preserveLoadedOlder: true)
                }
                guard !Task.isCancelled, self.automaticReconciliationTicket == ticket,
                      !self.suspended, !self.authenticationRequired, !self.stopping,
                      (self.activeTurnRecovery?.runID == runID ||
                       (runID != nil && self.activeTurnRecovery == nil)),
                      (self.pendingSend?.id == pendingID ||
                       (pendingID != nil && self.pendingSend == nil)) else { return }
                if let probe = self.activeRunProbeTask { await probe.value }
                guard !Task.isCancelled, self.automaticReconciliationTicket == ticket,
                      !self.suspended, !self.stopping, !self.authenticationRequired else { return }
                // A deep history crawl is expensive; try it only twice in
                // this recovery window, after the status probe and latest GET.
                if self.activeTurnRecovery != nil && !self.running && self.error == nil,
                   (attempt == 1 || attempt == self.automaticReconciliationDelaysNanoseconds.count - 1) {
                    _ = await self.reconcileLongAcceptedRun()
                }
                if self.running || (!self.uncertain && self.pendingSend == nil &&
                                   self.activeTurnRecovery == nil) { return }
                if self.pendingAbsent && self.activeTurnRecovery == nil { return }
            }
            if self.automaticReconciliationTicket == ticket,
               !self.suspended, !self.authenticationRequired,
               (self.uncertain || self.activeTurnRecovery != nil || self.pendingSend != nil) {
                self.notice = "连接状态暂时无法确认，已完成自动核对；不会重复发送。网络恢复或重新进入会话时将再检查。"
            }
        }
    }

    /// A missing active_stream_id is not terminal evidence. Query the exact
    /// accepted run; only an explicit terminal result can settle it without a
    /// matching reply in history.
    func probeAcceptedRun(_ receipt: ActiveTurnRecovery) {
        // Suppress only an *in-flight* duplicate. A completed unknown probe
        // must not prevent a later foreground/refresh retry of the same Run.
        guard activeRunProbeRunID != receipt.runID || activeRunProbeTask == nil else { return }
        // applySnapshot runs while `load` still owns the loading/syncing phase.
        // The probe task starts only after the current MainActor job yields, and
        // a later load cancels it, so the in-progress snapshot is the correct
        // place to schedule the one bounded receipt check.
        guard !suspended, !submitting, !stopping, !authenticationRequired else { return }
        activeRunProbeTask?.cancel()
        activeRunProbeRunID = receipt.runID
        let generation = revision
        activeRunProbeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeRunProbeRunID == receipt.runID {
                    self.activeRunProbeTask = nil
                    self.activeRunProbeRunID = nil
                }
            }
            do {
                let result = try await self.api.probeActiveRun(
                    sessionID: self.sessionID, runID: receipt.runID)
                guard generation == self.revision, !Task.isCancelled,
                      !self.suspended,
                      self.activeTurnRecovery == receipt else { return }
                switch result {
                case .alive:
                    self.streamID = receipt.runID
                    // The receipt proves the POST was accepted, so an older
                    // pre-POST PendingSend is now resolved as delivered.
                    if self.pendingSend != nil {
                        self.pendingSend = nil
                        self.pendingAbsent = false
                    }
                    self.uncertain = false
                    self.resumeQueueAfterRecovery()
                    self.notice = nil
                    self.attach(streamID: receipt.runID)
                case .terminal(let outcome):
                    guard self.streamID == nil, !self.running else { return }
                    // A confirmed terminal status still requires a final read-only
                    // history GET; do not replay the original accepted POST.
                    self.pauseQueueForRecovery()
                    do {
                        let finalHistory = try await self.api.history(sessionID: self.sessionID, before: nil)
                        guard generation == self.revision, !Task.isCancelled, !self.suspended,
                              self.activeTurnRecovery == receipt else { return }
                        guard finalHistory.sessionID == self.sessionID,
                              finalHistory.activeRunEvidence == .absent, !finalHistory.readOnly else {
                            self.uncertain = true
                            self.notice = "任务已结束，但服务端历史仍无法安全确认；稍后再核对。"
                            return
                        }
                        try self.applySnapshot(finalHistory, preserveLoadedOlder: true)
                        guard self.clearAcceptedTurnRecovery() else { return }
                        self.uncertain = self.pendingSend != nil || self.pendingRecoveryUnreadable
                            || self.activeRecoveryUnreadable
                        self.notice = outcome.notice
                    } catch {
                        guard generation == self.revision, !Task.isCancelled,
                              self.activeTurnRecovery == receipt else { return }
                        if self.handleAuthenticationFailure(error) { return }
                        self.uncertain = true
                        self.notice = "任务已结束，但最终历史同步失败；未重新发送消息，请稍后核对。"
                    }
                case .unresolved:
                    // Bounded exact-Run 404 proof retires the local live
                    // indicator, not the accepted POST receipt. Discard any
                    // retired SSE callback without touching a newer stream.
                    guard self.streamID == nil || self.streamID == receipt.runID else { return }
                    self.uncertain = true
                    self.pauseQueueForRecovery()
                    self.revision &+= 1
                    self.streamTask?.cancel()
                    self.streamTask = nil
                    self.streamID = nil
                    self.transition(to: .idle)
                    self.notice = "服务端连续未找到原 Run；本地运行标记已收敛，消息仍待核对。"
                case .unknown:
                    self.uncertain = true
                    self.pauseQueueForRecovery()
                    self.notice = "已受理的后台任务目前无法确认是否结束；请核对历史，消息不会重新发送。"
                }
            } catch {
                guard generation == self.revision, !Task.isCancelled,
                      self.activeTurnRecovery == receipt else { return }
                if self.handleAuthenticationFailure(error) { return }
                self.uncertain = true
                self.pauseQueueForRecovery()
                self.notice = "后台任务状态核对失败；消息不会重新发送，请稍后刷新。"
            }
        }
    }

    func flush() {
        publishTask?.cancel()
        publishTask = nil
        transcript = buffer
        reasoning = buffer.reasoning
    }

    private func schedulePublication(generation:UInt) {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:40_000_000) }
            catch { return }
            guard let self, generation == self.revision, !Task.isCancelled else { return }
            self.flush()
        }
    }


    /// - Parameter recoverBudget: 断线后重新订阅的剩余次数。
    ///   服务端可能报着 `activeStreamID` 却一帧也推不出来（run 已死但终态没落盘）。
    ///   每重入一次减一，耗尽就落定成待核对态，把决定权交回用户，
    ///   而不是让界面永远停在「正在恢复」。
    func attach(streamID:String, recoverBudget: Int = 3) {
        streamTask?.cancel()
        publishTask?.cancel()
        publishTask = nil
        revision &+= 1
        let generation = revision
        suspended = false
        transition(to: .streaming(connected: false))
        streamTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == revision {
                    self.streamTask = nil
                    // 收尾时「已连上」这一位必然失效：流已经断了。
                    if case .streaming = self.phase {
                        self.transition(to: .streaming(connected: false))
                    } else if case .reconnecting = self.phase {
                        self.transition(to: .streaming(connected: false))
                    }
                    self.reconciling = false
                }
            }
            var active = streamID
            var retries = 0
            var resubscribed = 0
            var terminalEvent: String?
            while generation == revision && !Task.isCancelled {
                do {
                    try await api.streamNativeTurn(streamID:active,lastEventID:lastEventID) { frame in
                        // A late frame belongs to the exact run and immutable
                        // model instance that installed this stream handler.
                        // Generation alone cannot identify a resubscribed run.
                        guard self.accepts(self.runContext(for: active, generation: generation)),
                              !Task.isCancelled else { return true }
                        if !self.streamConnected {
                            RuntimeLogRecorder.shared.record(.info, "stream", "connected stream=\(active) resumed=\(self.lastEventID != nil)")
                        }
                        // 收到帧即「已连上」。若此前处于重连中，这一帧就结束了恢复期，
                        // 恢复提示与残留错误一并撤掉。
                        let wasReconnecting = self.reconnecting
                        if self.phase != .streaming(connected: true) && !self.stopping {
                            self.transition(to: .streaming(connected: true))
                        }
                        if wasReconnecting {
                            self.notice = nil
                            self.error = nil
                        }
                        let prefix: (messages: [ChatMessage], tools: [ChatTool])
                        if frame.event == "done" {
                            let snapshot = try ChatSnapshot(data: Data(frame.data.utf8))
                            guard snapshot.sessionID == self.sessionID else { throw ChatCoreError.malformed("done session mismatch") }
                            prefix = self.historyPrefix(for: snapshot, source: self.buffer, preserve: true)
                        } else { prefix = ([], []) }
                        try self.buffer.apply(frame)
                        if !prefix.messages.isEmpty {
                            self.buffer.messages.insert(contentsOf: prefix.messages, at: 0)
                            self.buffer.tools.insert(contentsOf: prefix.tools, at: 0)
                            self.trimLoadedMessages()
                        }
                        self.lastEventID = self.buffer.lastEventID
                        if frame.event == "replay_truncated" {
                            // The gateway's replay window expired while the
                            // accepted Run may still be live (possibly waiting
                            // for user approval). Never settle it as a failure,
                            // discard actionable cards, or send queued turns.
                            // A stale Last-Event-ID would trigger the same gap
                            // on the next reconnect; start the next read-only
                            // recovery from the newest authoritative state.
                            self.lastEventID = nil
                            self.buffer.lastEventID = nil
                            self.uncertain = true
                            self.pauseQueueForRecovery()
                            self.notice = "续传记录已过期，已保留消息和待处理卡片；后台状态待核对，发送保持锁定。"
                        }
                        if frame.event == "approval" {
                            // run 挂在服务端等这一票。能认出请求就出卡片；
                            // 认不出（老版本后端只给一句话）退回文字提示，别出空卡片。
                            let runID = self.streamID ?? active
                            if let pending = ChatPendingApproval.make(from: frame, runID: runID) {
                                let isNew = self.upsertPendingApproval(pending)
                                self.notice = nil
                                // 只在请求身份首次出现时提醒一次；
                                // 同一请求重复推送不该重复打扰。
                                if isNew {
                                    self.onApprovalArrived?(self.sessionID, pending.requestID)
                                }
                            } else {
                                self.notice = "需要审批：服务端没有给出可操作的选项，请在 WebUI 处理。"
                            }
                        } else if frame.event == "approval_resolved" {
                            if let resolved = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any],
                               let requestID = resolved["request_id"] as? String {
                                let runID = self.streamID ?? active
                                self.removePendingApproval(requestID: requestID, runID: runID)
                            }
                        } else if frame.event == "clarify" {
                            // agent 卡在这儿等服务端拿到答复。以前只写一句
                            // 「请在 WebUI 处理后刷新」——纯网关实例根本没有 WebUI
                            // 可去，任务会一直挂到超时。现在出可操作卡片。
                            let runID = self.streamID ?? active
                            if let pending = ChatPendingClarify.make(from: frame, runID: runID) {
                                let isNew = self.upsertPendingClarify(pending)
                                self.notice = nil
                                // 与审批同一规则：只在身份首次出现时提醒一次。
                                if isNew {
                                    self.onClarifyArrived?(self.sessionID, pending.requestID)
                                }
                            } else {
                                // 解析不出 request_id / execution_generation 就没法答复，
                                // 与其留一张点了会 400 的卡片，不如明说去哪儿处理。
                                self.notice = "需要补充信息：服务端没有给出可回答的请求标识，请在 WebUI 处理。"
                            }
                        } else if frame.event == "clarify_resolved" {
                            if let resolved = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any],
                               let requestID = resolved["request_id"] as? String {
                                self.removePendingClarify(requestID: requestID)
                            }
                        }
                        if frame.event == "approval_resolved" {
                            self.noteRunRecoveryState()
                        }
                        if self.buffer.terminal {
                            self.clearApproval()
                            terminalEvent = frame.event
                            let failure = self.buffer.failure
                            RuntimeLogRecorder.shared.record(
                                failure == nil ? .info : .error, "stream",
                                "terminal event=\(frame.event)\(failure.map { " err=\($0)" } ?? "")")
                            self.flush()
                            // A concurrent STOP owns terminal authorization.
                            // Even an SSE done frame cannot unlock sending or
                            // flush the queue until that exact run is verified.
                            if self.stopping {
                                self.notice = "已收到任务结束事件，仍需确认停止终态和最终历史。"
                                return true
                            }
                            // 终态已到：本轮结束。核对标志与相位正交，单独置起。
                            self.transition(to: .idle)
                            self.reconciling = true
                            self.error = self.buffer.failure
                            return true
                        }
                        self.schedulePublication(generation:generation)
                        return false
                    }
                } catch {
                    guard generation == revision, !Task.isCancelled else { return }
                    if handleAuthenticationFailure(error) { return }
                    RuntimeLogRecorder.shared.record(.warning, "stream", "interrupted err=\(error.localizedDescription)")
                    self.error = error.localizedDescription
                }
                guard generation == revision, !Task.isCancelled else { return }
                if buffer.terminal {
                    if stopping {
                        // The STOP POST might still be in flight. Its callback
                        // will verify the run; do not settle via the ordinary
                        // stream-completion path or auto-dispatch a queued turn.
                        if stopAcknowledged {
                            await verifyPendingStop()
                            if stopping { scheduleStopStatusPolling() }
                        }
                        return
                    }
                    let terminalFailure = buffer.failure
                    // 只有「干净收尾」才允许放行排队的那条：中断、核对失败、
                    // 结果不确定都必须把队列留着，让用户看见它还没发出去。
                    var settled = false
                    var finalHistoryConfirmed = false
                    do {
                        // Terminal SSE is not proof that the server's final
                        // assistant history row has been committed. GET only:
                        // never replay the accepted POST or clear its receipt.
                        let streamedAssistantPresent = buffer.messages.contains {
                            $0.role == "assistant" && $0.id.hasPrefix("streaming:")
                        }
                        let receipt = activeTurnRecovery
                        var snap = try await api.history(sessionID:sessionID,before:nil)
                        for attempt in 0..<3 {
                            guard accepts(runContext(for: active, generation: generation)),
                                  !Task.isCancelled else { return }
                            if ChatFinalHistoryGate.canReplace(
                                snap, sessionID: sessionID, receipt: receipt,
                                streamedAssistantPresent: streamedAssistantPresent,
                                expectedRunID: active) { break }
                            if attempt == 2 {
                                uncertain = true
                                pauseQueueForRecovery()
                                transition(to: .idle)
                                reconciling = false
                                notice = "回复已结束，但最终历史尚未同步；已保留当前回复并暂停自动续发，可稍后核对。"
                                flush()
                                RuntimeLogRecorder.shared.record(.warning, "stream",
                                    "final history pending run=\(active) attempts=3")
                                return
                            }
                            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 200_000_000)
                            snap = try await api.history(sessionID:sessionID,before:nil)
                        }
                        guard accepts(runContext(for: active, generation: generation)),
                              !Task.isCancelled else { return }
                        let userPauseWasActive = queueUserPaused
                        let recoveryPauseWasActive = queueRecoveryPaused
                        try applySnapshot(snap, preserveLoadedOlder: true)
                        error = terminalFailure
                        if pendingSend == nil {
                            notice = terminalFailure != nil ? "回复已中断，历史已同步。"
                                : (terminalEvent == "cancel" ? "回复已取消，历史已同步。" : nil)
                        }
                        // An explicit terminal frame plus a matching accepted
                        // run ID is stronger evidence than a possibly incomplete
                        // history window (slash commands may have no assistant row).
                        if snap.activeStreamID == nil,
                           activeTurnRecovery?.runID == active,
                           terminalEvent != nil {
                            if clearAcceptedTurnRecovery(), pendingSend == nil {
                                uncertain = false
                                // The matching terminal frame resolves the temporary
                                // pause introduced by an incomplete history window.
                                // Preserve any pause that existed before this GET.
                                queueUserPaused = userPauseWasActive
                                queueRecoveryPaused = recoveryPauseWasActive
                                updateQueuePause()
                            }
                        }
                        if snap.activeStreamID == nil && terminalFailure == nil,
                           terminalEvent == "done" || terminalEvent == "stream_end" {
                            completedReplies &+= 1
                        }
                        // 核对完成，撤掉「核对中」。相位在这里显式落定：
                        // 有活跃流就接上（尚未收到帧），否则回到静止态。
                        reconciling = false
                        if snap.activeStreamID == nil {
                            transition(to: .idle)
                        } else {
                            transition(to: .streaming(connected: false))
                        }
                        if let next = snap.activeStreamID { attach(streamID:next) }
                        // An explicit failed/cancelled terminal can safely
                        // unlock a manual send after a consistent history GET,
                        // but it must NEVER authorize automatic queued dispatch.
                        finalHistoryConfirmed = snap.activeStreamID == nil
                        settled = finalHistoryConfirmed && terminalFailure == nil
                            && (terminalEvent == "done" || terminalEvent == "stream_end")
                    } catch {
                        guard generation == revision, !Task.isCancelled else { return }
                        if handleAuthenticationFailure(error) { return }
                        self.error = error.localizedDescription
                        // 核对失败：本轮状态无法确认，退回静止态但置 uncertain
                        // 把发送锁住（不假装还在跑，也不假装已结束）。
                        transition(to: .idle)
                        uncertain = true
                        notice = "历史核对失败，发送保持锁定；请刷新确认后台状态。"
                    }
                    let decision = ChatRuntimeCoordinator.terminalAction(
                        stopPending: stopping || stopAcknowledged,
                        sameRun: activeTurnRecovery == nil,
                        terminalFrame: terminalEvent != nil,
                        finalHistoryConfirmed: finalHistoryConfirmed && self.streamID == nil,
                        successful: settled, uncertain: uncertain,
                        userPaused: queueUserPaused, recoveryPaused: queueRecoveryPaused)
                    if decision == .keepLocked {
                        // An unmatched receipt or inconclusive final history
                        // cannot be made safe merely by reaching idle.
                        uncertain = true
                        pauseQueueForRecovery()
                        notice = notice ?? "本轮终态证据不完整；发送仍锁定，请核对状态。"
                    }
                    if decision == .finishAndDispatch {
                        // 斜杠命令的兜底说明：命令已原样转发，但服务端没有任何
                        // 可见回应（既没报错也没产出正文）。这时必须讲清「客户端
                        // 只能转发、语义由服务端决定」，否则用户会以为命令静默失败。
                        if let command = pendingSlashCommand {
                            let hasAssistantOutput = buffer.messages.contains { $0.role != "user" }
                            if !hasAssistantOutput {
                                notice = ChatSlashCommand.noEffectNotice(for: command)
                            }
                        }
                        pendingSlashCommand = nil
                        await flushQueuedIfNeeded(completedStreamID: active)
                    }
                    return
                }
                // A stop acknowledgement keeps the sending lock even if SSE
                // disconnects; status verification owns its terminal decision.
                if stopping {
                    notice = "停止请求已受理，流连接已断开；请核对后台任务状态。"
                    return
                }
                // EOF and transport errors both recover via GET only. The
                // budget is per attachment, not reset by a successful token.
                var recovered = false
                while retries < 3 && !recovered {
                    retries += 1
                    RuntimeLogRecorder.shared.record(.info, "stream", "recover attempt=\(retries)")
                    // 重连期间本轮**未结束**：相位是 `.reconnecting`，
                    // `isRunning` 为真，但 `allowsSteer` 为假（服务端此刻没有
                    // 活跃 agent 可注入）。这是本版修掉的真实缺陷。
                    transition(to: .reconnecting)
                    notice = "连接中断，正在恢复后台状态（不会重发消息）。"
                    do {
                        try await Task.sleep(nanoseconds:UInt64(retries) * 100_000_000)
                        guard generation == revision, !Task.isCancelled else { return }
                        let snap = try await api.history(sessionID:sessionID,before:nil)
                        guard generation == revision, !Task.isCancelled else { return }
                        let trackingAccepted = activeTurnRecovery != nil
                        try applySnapshot(snap, preserveLoadedOlder: true)
                        error = nil
                        if trackingAccepted, activeTurnRecovery == nil, !uncertain,
                           snap.activeStreamID == nil {
                            // The new-turn receipt was verified and removed by
                            // applySnapshot. Its history boundary is now nil;
                            // do not incorrectly fall through to "unconfirmed".
                            notice = nil
                            transition(to: .idle)
                            return
                        }
                        if let next = snap.activeStreamID {
                            // 服务端确认这一轮还活着：更新目标流、让外层循环重新订阅。
                            //
                            // 原实现只写 `recovered = true` 就退出内层重试循环，
                            // 外层 `while` 随即结束、函数返回、`streamTask` 在 defer 里
                            // 被清空——**之后再没有任何人订阅这条流**。表现就是提示停在
                            // 「连接中断，正在恢复后台状态」，服务端仍在推帧、客户端一帧
                            // 收不到，用户只能自己去刷新。
                            //
                            // 这里改成更新 `active` 并重置重试预算，然后 `continue`
                            // 让外层循环用新 id 重新 `streamNativeTurn`（从 `lastEventID`
                            // 续传）。不能调 `attach`：那会新建 streamTask 并推进 revision，
                            // 让当前这个循环的收尾逻辑全部失效。
                            active = next
                            // 不重置 `retries`：GET 预算是整轮共享的，
                            // 重订阅只换目标流，不该凭空多给三次核对机会。
                            recovered = true
                            RuntimeLogRecorder.shared.record(.info, "stream", "recovered stream=\(next)")
                            // 只重订阅一次。
                            //
                            // 服务端可能一直报着 active 却一帧都推不出来（run 已死、
                            // 终态没落盘）。若允许无限重订阅，外层 while 会「重新 stream →
                            // 立刻 EOF → 再 GET → 再重订阅」死循环，界面永远停在
                            // 「正在恢复」，用户永远等不到结果。
                            //
                            // 一次足够：真活着的流重订后必然有帧进来（那帧会清掉
                            // 恢复提示并让循环正常推进）；一帧都没有就说明这个 id 是死的，
                            // 交给下面的耗尽分支落定成待核对态。
                            // 重订阅本身不消耗 GET 预算：`retries` 只统计「确认存活」
                            // 的尝试次数。上限用 `resubscribed` 单独计，与 GET 预算正交，
                            // 这样「服务端报 active 但推不出帧」最终会收敛，而不是无限循环。
                            resubscribed += 1
                            guard resubscribed <= 3 else {
                                RuntimeLogRecorder.shared.record(.error, "stream",
                                    "resubscribe gave no frames stream=\(next)")
                                transition(to: .idle)
                                uncertain = true
                                notice = "连接反复中断，无法确认这一轮是否结束。点「核对状态」确认后即可继续；不会重复发送。"
                                return
                            }
                            break
                        } else {
                            // P0：没有 active stream 不等于「这轮已完成」。
                            //
                            // 服务端可能仍在跑，只是这次 GET 没返回活跃 id（写盘/路由
                            // 的瞬时不一致，或 run 刚结束但终态还没落到历史里）。原来这里
                            // 直接 `transition(to: .idle)` 并返回，绕过完成计数与队列 flush
                            // 判定：一旦误判，`canSend` 变真，排队的那条会被自动发出，
                            // 造成两个轮次并发。
                            //
                            // 恢复路径手里没有 `done`/`stream_end` 帧，所以必须由快照
                            // 自己证实「上一轮确实结束了」。证实不了就停在待核对态，
                            // 不自动续发——宁可让用户点一下，也不要静默重复执行。
                            if !uncertain && activeTurnRecovery == nil && snap.confirmsRunFinished(afterRawIndex: activeTurnHistoryBoundary) {
                                error = nil
                                notice = nil
                                transition(to: .idle)
                                return
                            }
                            error = nil
                            notice = "连接已恢复，但无法确认上一轮是否结束。已暂停自动发送，请核对后再继续。"
                            transition(to: .idle)
                            uncertain = true
                            return
                        }
                    } catch {
                        guard generation == revision, !Task.isCancelled else { return }
                        if handleAuthenticationFailure(error) { return }
                        self.error = error.localizedDescription
                    }
                }
                if !recovered {
                    RuntimeLogRecorder.shared.record(.error, "stream", "recover exhausted retries=\(retries)")
                    // 预算耗尽：本轮仍未确认结束，退回静止态但置 uncertain 锁住发送。
                    transition(to: .idle)
                    uncertain = true
                    // 文案只说用户能做的事。
                    //
                    // 原文案是「自动恢复已达上限，请刷新核对后台状态；不会自动重发消息」——
                    // 「后台状态」对用户不是可操作的概念（他看不到服务端在跑什么），
                    // 「刷新」也不是这里的动作（重连是自动的）。真正要表达的是：
                    // 连接断过、这一轮到底结束没有不确定、点一下核对就能确认、不会重复执行。
                    notice = "连接中断过，这一轮是否已结束还不确定。点「核对状态」确认后即可继续；不会重复发送。"
                    return
                }
            }
        }
    }


    func resumeForeground() async {
        // STOP remains STOP across background transitions. Only a read-only
        // run probe may resolve it; a general refresh would erase its phase.
        if stopping {
            suspended = false
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
            return
        }
        // 前台已有流连接就不打断它；后台断开后仅 GET 恢复，绝不重发。
        if streamTask != nil { return }
        await refresh(silent: !transcript.messages.isEmpty, preserveLoadedOlder: true)
        noteRunRecoveryState()
    }

    /// A-07：`resetReconciling` 默认 true，保留「普通刷新会清掉忙碌标志」的既有语义。
    /// `reconcilePending()` 必须传 false —— 它自己持有 `reconciling` 并在 defer 里清，
    /// 否则这里一进来就把标志抹掉，连点「核对」会并发发起多个 GET 互相打断。
    func refresh(silent: Bool = false, preserveLoadedOlder: Bool = false,
                 resetReconciling: Bool = true) async {
        if stopping {
            // A manual status check must not convert STOP into an ordinary
            // history load or accidentally reopen ordinary sending.
            suspended = false
            await verifyPendingStop()
            if stopping { scheduleStopStatusPolling() }
            return
        }
        if submitting { resumeRequested = true; return }
        guard !loading, !syncing else { return }
        publishTask?.cancel()
        publishTask = nil
        activeRunProbeTask?.cancel()
        activeRunProbeTask = nil
        activeRunProbeRunID = nil
        revision &+= 1
        streamTask?.cancel()
        streamTask = nil
        // A-07：只有普通刷新才清标志；核对流程自己管理这个生命周期。
        // 相位上：清掉「核对中」就退回 idle（接着 load 会再置 loading/syncing）。
        if resetReconciling { reconciling = false }
        if case .reconnecting = phase { transition(to: .idle) }
        await load(silent: silent, preserveLoadedOlder: preserveLoadedOlder,
                   allowWhileReconciling: !resetReconciling)
    }

    func disconnect() {
        automaticReconciliationTask?.cancel()
        automaticReconciliationTask = nil
        automaticReconciliationTicket = nil
        suspended = true
        flush()
        if let historyStore { Task { await historyStore.flush() } }
        resumeRequested = false
        publishTask?.cancel()
        publishTask = nil
        activeRunProbeTask?.cancel()
        activeRunProbeTask = nil
        activeRunProbeRunID = nil
        revision &+= 1
        streamTask?.cancel()
        streamTask = nil
        stopStatusPollTask?.cancel()
        stopStatusPollTask = nil
        stopStatusPollTicket = nil
        // 离开会话页：连接暂停。`suspended` 是与相位正交的独立事实，表达
        // 「这台设备不再接收帧」；相位按「这一步在等什么」分别落定：
        //
        // - `.submitting` / `.stopping`：**原样保留**。它们等的是 POST 响应和服务端
        //   确认，与收不收帧无关。清掉 `.submitting` 会让 `load()` 里那条
        //   `if submitting { resumeRequested = true; return }` 失效——重进页面时
        //   会并发发起第二个 GET，而 POST 一落地又补一次，两个请求互相推进
        //   revision，最终谁的历史都留不下来。
        // - `.streaming` / `.reconnecting`：保留 running，只撤「已连上」。
        //   服务端那一轮并没有因为本机离开页面就结束。
        // - `.loading` / `.syncing`：必须回到 `.idle`。上面已经推进了 revision，
        //   被取消的在途 GET 不会再回来收尾（它的 defer 因 generation 失配跳过），
        //   相位就会永久卡在 `.loading`，后续 refresh 的 `guard !loading, !syncing`
        //   会把所有请求挡在门外。
        // - `.cached`：保留。磁盘历史还在屏幕上，`applySnapshot` 靠它判断
        //   要丢弃过期的 model/usage 元数据。
        switch phase {
        case .submitting, .stopping, .cached, .needsLogin:
            break
        case .streaming, .reconnecting:
            transition(to: .streaming(connected: false))
        case .idle, .loading, .syncing:
            transition(to: .idle)
        }
    }
}
