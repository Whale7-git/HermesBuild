import Foundation

/// An item is a stored message (or an anchored tool run), never a viewport boundary.
/// Like MessengerDemo, older history adds a prefix; no day/time items migrate on paging.
struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        // 跨天用 .day，同一天但间隔达到 groupWindow 用 .time；两者都由 build() 插入，
        // 行 id 分别带 "day-"/"time-" 前缀，不会与消息/工具行冲突。
        case day(Date)
        case time(Date)
        case message(ChatMessage)
        case tools([ChatTool])
        case process(ChatProcessGroup)
        case notice(ChatNotice)
    }
    var id: String
    var kind: Kind
    var showsSender: Bool = false
    var isContinuation: Bool = false
    var showsCopy: Bool = false
    /// Presentation-only turn identity. It does not replace the message or row
    /// id, so pagination anchors and selection remain keyed by their old IDs.
    var turnID: String? = nil
    /// 投递三态透传：视图据此在用户气泡下渲染状态小字；非消息行恒为 `confirmed`。
    var delivery: ChatDeliveryState = .confirmed

    /// 组首/续条是「窗口内相邻关系」派生的展示状态：翻页 prepend 会让边界行
    /// 在组首与续条之间切换。若把它算进行相等性，滚动层的差分会把这种切换
    /// 当成内容变化，破坏 prepend 的锚点稳定（tests/timeline 的 suffix 不变量）。
    /// 行身份由 id + kind 决定，视图每次拿到新行值仍会正确渲染表头。
    static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
            && lhs.showsCopy == rhs.showsCopy && lhs.delivery == rhs.delivery
    }
}

/// Stable revision stamp for a single timeline projection. The owning
/// projection changes the version whenever it publishes a new items array.
/// It avoids a second O(history) element comparison in UIKit's snapshot path.
struct ChatTimelineItemsStamp: Equatable {
    let owner: UUID
    let version: UInt64
}

enum ChatTimelineItemsEquality {
    static func equal(_ lhs: [ChatRowItem], stamp lhsStamp: ChatTimelineItemsStamp?,
                      _ rhs: [ChatRowItem], stamp rhsStamp: ChatTimelineItemsStamp?) -> Bool {
        // A proven identical revision from the SAME projection means content
        // is identical. Different/missing owners fall back to exact value
        // equality, including synthetic snapshots used by standalone tests.
        if let lhsStamp, let rhsStamp, lhsStamp == rhsStamp { return true }
        if let lhsStamp, let rhsStamp, lhsStamp.owner == rhsStamp.owner {
            return false // the same projection has issued a new array
        }
        return lhs == rhs
    }
}

struct ChatRowItem: Identifiable, Equatable {
    let row: ChatRow
    let isStreaming: Bool
    var toolsAreLive = false
    var id: String { row.id }
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.row == rhs.row,
              lhs.row.showsSender == rhs.row.showsSender,
              lhs.row.isContinuation == rhs.row.isContinuation,
              lhs.row.turnID == rhs.row.turnID else { return false }
        guard case .message = lhs.row.kind else { return lhs.toolsAreLive == rhs.toolsAreLive }
        return lhs.isStreaming == rhs.isStreaming
    }

    /// Streaming content can update one visible message without changing the
    /// row structure. Keep sender grouping, copy placement and every preceding
    /// row exactly as built; only the changed message payload is replaced.
    func replacingMessage(_ message: ChatMessage) -> Self {
        guard case .message(let current) = row.kind, current.id == message.id else {
            return self
        }
        var nextRow = row
        nextRow.kind = .message(message)
        nextRow.delivery = message.delivery
        return ChatRowItem(row: nextRow, isStreaming: isStreaming,
                           toolsAreLive: toolsAreLive)
    }

    /// Tool progress and completion do not change row identity or grouping.
    /// Replace the changed tool payload in place so a 2,000-row projection is
    /// not rebuilt for every `tool_started` / `tool_completed` event.
    func replacingTools(_ tools: [ChatTool], allTools: [ChatTool]? = nil,
                        toolsAreLive: Bool? = nil) -> Self? {
        var nextRow = row
        switch row.kind {
        case .tools:
            nextRow.kind = .tools(tools)
        case .process(let group):
            let anchors = Set(group.messages.map(\.id))
            nextRow.kind = .process(ChatProcessGroup(
                messages: group.messages,
                tools: (allTools ?? tools).filter { tool in
                    tool.afterMessageID.map(anchors.contains) == true
                }))
        default:
            return nil
        }
        return ChatRowItem(row: nextRow, isStreaming: isStreaming,
                           toolsAreLive: toolsAreLive ?? self.toolsAreLive)
    }
}

/// A contiguous run of earlier assistant segments and their anchored tools.
/// The final assistant segment stays a normal message; every intermediate body
/// is retained so expanding the disclosure does not discard visible content.
struct ChatProcessGroup: Equatable {
    let messages: [ChatMessage]
    let tools: [ChatTool]
}

/// Presentation-only process grouping. It never changes message ids, source
/// indices, pagination or reply-copy payloads.
enum ChatProcessPlan {
    struct Result: Equatable {
        let groupsByAnchor: [String: ChatProcessGroup]
        let foldedMessageIDs: Set<String>
        let finalMessageIDs: Set<String>
        let completeTurnIDs: Set<String>
    }

    /// A step is foldable only when a later visible assistant segment exists in
    /// the same turn. A single assistant segment remains a normal message even
    /// when tools follow it, preserving its selection and full-height layout.
    static func make(messages: [ChatMessage], tools: [ChatTool], running: Bool = false,
                     completeTurnIDs: Set<String> = [],
                     toolsByAnchor: [String: [ChatTool]]? = nil) -> Result {
        let visible = messages.filter { message in
            message.role != "assistant" || !message.attachmentPaths.isEmpty
                || ChatRenderableText.hasVisibleContent(message.content)
        }
        let turnIDs = ChatTimeline.turnIDs(for: messages)
        let resolvedTools = toolsByAnchor ?? Dictionary(
            grouping: tools.compactMap { tool -> (String, ChatTool)? in
                guard let anchor = tool.afterMessageID else { return nil }
                return (anchor, tool)
            }, by: \.0).mapValues { $0.map(\.1) }
        let userTurnIDs = Set(visible.compactMap { message in
            message.role == "user" ? turnIDs[message.id] : nil
        })
        var lastAssistantByTurn: [String: String] = [:]
        // Only a later user message closes a turn. A history window can start
        // or end in the middle of a reply; its edge assistant rows stay normal
        // messages, so loading an earlier page can only prepend rows.
        for message in visible where message.role == "assistant" {
            if let turn = turnIDs[message.id] { lastAssistantByTurn[turn] = message.id }
        }
        // Completion is supplied by the projection, which protects turns that
        // first appeared at a paging boundary. This keeps process grouping a
        // pure function of explicitly observed turn boundaries; a standalone
        // timeline build must never infer completion from where its window ends.
        let completedTurns = completeTurnIDs.intersection(userTurnIDs)

        // Completed history keeps using the explicit completion boundary. The
        // live turn may fold earlier segments before completion: otherwise a
        // long-running agent alternates between headers, prose and tool rows
        // until the turn finishes, and only then collapses into the intended
        // quiet disclosure. The last segment always stays a normal message, so
        // the live answer keeps growing in place and keeps its text selection.
        //
        // Only assistant rows without attachments are folded. Attachments
        // remain normal rows because their preview, save and share controls
        // cannot be represented by a Markdown disclosure.
        var groupsByAnchor: [String: ChatProcessGroup] = [:]
        var foldedMessageIDs = Set<String>()
        var currentMessages: [ChatMessage] = []
        var currentTurn: String?
        func flushGroup() {
            guard let first = currentMessages.first, currentTurn != nil else {
                currentMessages = []
                currentTurn = nil
                return
            }
            let ids = Set(currentMessages.map(\.id))
            groupsByAnchor[first.id] = ChatProcessGroup(
                messages: currentMessages,
                tools: currentMessages.flatMap { resolvedTools[$0.id] ?? [] })
            foldedMessageIDs.formUnion(ids)
            currentMessages = []
            currentTurn = nil
        }
        for message in visible {
            let turn = turnIDs[message.id]
            let liveFold = running && turn == turnIDs[visible.last?.id ?? ""]
            let foldable = message.role == "assistant"
                && message.attachmentPaths.isEmpty
                && turn.map {
                    userTurnIDs.contains($0)
                        && (completedTurns.contains($0) || liveFold)
                        && lastAssistantByTurn[$0] != message.id
                } == true
            if foldable, let turn {
                if currentTurn != turn { flushGroup() }
                currentTurn = turn
                currentMessages.append(message)
            } else {
                flushGroup()
            }
        }
        flushGroup()

        // Index each anchored tool once. Previously every eligible turn scanned
        // the full tool array and searched all process groups and visible rows,
        // making structural rebuilds quadratic in long multi-turn sessions.
        var resolvedAnchorByToolID: [String: String] = [:]
        for (anchor, group) in toolsByAnchor ?? resolvedTools {
            for tool in group where resolvedAnchorByToolID[tool.id] == nil {
                resolvedAnchorByToolID[tool.id] = anchor
            }
        }
        let eligibleTurnIDs = completedTurns.union(
            running ? Set([turnIDs[visible.last?.id ?? ""]].compactMap { $0 }) : [])
        var toolsByTurn: [String: [ChatTool]] = [:]
        for tool in tools {
            guard let anchor = resolvedAnchorByToolID[tool.id],
                  let turnID = turnIDs[anchor], eligibleTurnIDs.contains(turnID) else { continue }
            toolsByTurn[turnID, default: []].append(tool)
        }
        // The first visible assistant and first process group in transcript
        // order are stable across reloads; Dictionary iteration order is not.
        var firstAssistantByTurn: [String: String] = [:]
        var firstGroupByTurn: [String: String] = [:]
        for message in visible {
            guard let turnID = turnIDs[message.id], eligibleTurnIDs.contains(turnID) else { continue }
            if message.role == "assistant", firstAssistantByTurn[turnID] == nil {
                firstAssistantByTurn[turnID] = message.id
            }
            if groupsByAnchor[message.id] != nil, firstGroupByTurn[turnID] == nil {
                firstGroupByTurn[turnID] = message.id
            }
        }
        for turnID in eligibleTurnIDs {
            let turnTools = toolsByTurn[turnID] ?? []
            if let anchor = firstGroupByTurn[turnID], let existing = groupsByAnchor[anchor] {
                groupsByAnchor[anchor] = ChatProcessGroup(messages: existing.messages,
                                                         tools: turnTools)
            } else if !turnTools.isEmpty, let anchor = firstAssistantByTurn[turnID] {
                groupsByAnchor[anchor] = ChatProcessGroup(messages: [], tools: turnTools)
            }
        }
        return Result(groupsByAnchor: groupsByAnchor,
                      foldedMessageIDs: foldedMessageIDs,
                      finalMessageIDs: Set(lastAssistantByTurn.values),
                      completeTurnIDs: completedTurns)
    }
}

enum ChatTimeline {
    /// Resolve the complete assistant reply that owns a message row. This is
    /// intentionally separate from `replyText`: a continuation segment still
    /// needs a reader entry, while the turn-level copy/share action must keep
    /// returning the complete assistant response.
    static func replyRange(containing id: String,
                           messages: [ChatMessage]) -> ClosedRange<Int>? {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == "assistant" else { return nil }
        let turns = turnIDs(for: messages)
        let turnID = turns[id]
        func sameTurn(_ message: ChatMessage) -> Bool {
            guard message.role == "assistant" else { return false }
            guard let turnID else { return true }
            return turns[message.id] == turnID
        }
        var first = index
        while first > 0 && sameTurn(messages[first - 1]) {
            first -= 1
        }
        var last = index
        while last + 1 < messages.count && sameTurn(messages[last + 1]) {
            last += 1
        }
        return first...last
    }

    /// Stable and unique at every visible assistant row. A non-final
    /// continuation uses the assistant row after it, so both rows resolve to
    /// the same complete turn without depending on which segment was tapped.
    static func replyAnchor(for id: String, messages: [ChatMessage]) -> String {
        guard let range = replyRange(containing: id, messages: messages) else { return id }
        let final = messages[range].last(where: {
            ChatRenderableText.hasVisibleContent($0.content)
        })
        return final?.id ?? messages[range.upperBound].id
    }

    /// Resolve on tap, not in item equality: loading an earlier reply segment
    /// changes clipboard payload, but must not resize/reconfigure the tail cell.
    static func replyText(endingAt id: String, messages: [ChatMessage]) -> String {
        guard let range = replyRange(containing: id, messages: messages) else { return "" }
        return messages[range].map(\.content)
            .filter(ChatRenderableText.hasVisibleContent)
            .joined(separator: "\n\n")
    }

    /// The complete assistant turn through the final row, excluding the user
    /// prompt. This backs the explicit "copy entire process" action without
    /// changing normal reply copying or text selection.
    static func replyProcessText(endingAt id: String, messages: [ChatMessage]) -> String {
        guard let end = messages.firstIndex(where: { $0.id == id }),
              messages[end].role == "assistant" else { return "" }
        var start = end
        while start > 0, messages[start - 1].role != "user" {
            start -= 1
        }
        let body = messages[start...end].map(\.content)
            .filter(ChatRenderableText.hasVisibleContent)
            .joined(separator: "\n\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stable landmarks for long conversations. The target is always an
    /// existing row id, so navigation never mutates history or depends on the
    /// current viewport window.
    static func navigationNodes(messages: [ChatMessage],
                                tools: [ChatTool] = [],
                                notices: [ChatNotice] = [],
                                limit: Int = 300) -> [ChatNavigationNode] {
        guard limit > 0 else { return [] }
        let rows = build(messages: messages, tools: tools, notices: notices)
        let users = messages.enumerated().compactMap { index, message -> ChatNavigationNode? in
            guard message.role == "user",
                  ChatRenderableText.hasVisibleContent(message.content)
                    || !message.attachmentPaths.isEmpty else { return nil }
            let preview = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatNavigationNode(
                id: "m-\(message.id)", messageID: message.id,
                preview: preview.isEmpty ? "附件消息" : String(preview.prefix(100)),
                timestamp: message.timestamp, ordinal: index, kind: .question)
        }
        let questionIDs = Set(users.map(\.id))
        let supporting = rows.enumerated().compactMap { index, row -> ChatNavigationNode? in
            switch row.kind {
            case .message(let message):
                guard message.role == "assistant",
                      ChatRenderableText.hasVisibleContent(message.content)
                        || !message.attachmentPaths.isEmpty else { return nil }
                let preview = message.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatNavigationNode(
                    id: row.id, messageID: message.id,
                    preview: preview.isEmpty ? "最终回答" : String(preview.prefix(100)),
                    timestamp: message.timestamp, ordinal: index, kind: .answer)
            case .tools(let group):
                guard !group.isEmpty else { return nil }
                let items = group.map { ChatToolSummary.Item(
                    name: $0.name, done: $0.done, isError: $0.isError) }
                let title = ChatToolSummary.title(items)
                let summary = ChatToolSummary.summary(items)
                return ChatNavigationNode(
                    id: row.id, messageID: row.id,
                    preview: summary.isEmpty ? title : "\(title) · \(summary)",
                    timestamp: nil, ordinal: index, kind: .tools)
            case .process(let group):
                let items = group.tools.map { ChatToolSummary.Item(
                    name: $0.name, done: $0.done, isError: $0.isError) }
                let title = ChatToolSummary.title(items)
                let summary = ChatToolSummary.summary(items)
                return ChatNavigationNode(
                    id: row.id, messageID: row.id,
                    preview: summary.isEmpty ? title : "\(title) · \(summary)",
                    timestamp: nil, ordinal: index, kind: .tools)
            case .notice(let notice):
                return ChatNavigationNode(
                    id: row.id, messageID: row.id,
                    preview: notice.message, timestamp: notice.timestamp,
                    ordinal: index, kind: .terminalNotice)
            case .day, .time:
                return nil
            }
        }
        // Preserve the question-only API contract exactly: a small explicit
        // cap still means "the newest N questions". The chat UI asks for the
        // richer landmark mode explicitly.
        if limit <= 200 {
            return Array(users.suffix(limit))
        }
        let questionLimited = Array(users.suffix(limit))
        let supportingLimited = Array(supporting.suffix(limit))
        let result = questionLimited + supportingLimited.filter { !questionIDs.contains($0.id) }
        return result.sorted { $0.ordinal < $1.ordinal }
    }

    static func build(messages: [ChatMessage], tools: [ChatTool], notices: [ChatNotice] = [],
                      calendar: Calendar = .current,
                      running: Bool = false,
                      completeTurnIDs: Set<String> = []) -> [ChatRow] {
        var rows: [ChatRow] = []
        // Tool anchoring and turn membership must be derived from the complete
        // loaded transcript before rows are projected. A window that starts
        // below a user message still keeps that turn's stable user id instead of
        // promoting the first assistant segment to a new turn.
        let messagesByID = Dictionary(messages.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let anchorTurnIDs = turnIDs(for: messages)
        var turnIDs = anchorTurnIDs
        let displayMessages = messages.filter { message in
            message.role != "assistant" || !message.attachmentPaths.isEmpty
                || ChatRenderableText.hasVisibleContent(message.content)
        }
        let visibleIDs = Set(displayMessages.map(\.id))
        let visible = visibleIDs
        // Legacy blank streaming segments may still be tool anchors. Resolve
        // them to the preceding visible row, matching the history parser.
        var blankAnchors: [String: String] = [:]
        var blankWithoutPredecessor = Set<String>()
        var preceding: String?
        for message in messages {
            if visible.contains(message.id) { preceding = message.id }
            else if let preceding { blankAnchors[message.id] = preceding }
            else { blankWithoutPredecessor.insert(message.id) }
        }
        var byAnchor: [String: [ChatTool]] = [:]
        var trailing: [ChatTool] = []
        var seenTools = Set<String>()
        for tool in tools where seenTools.insert(tool.id).inserted {
            if let anchor = tool.afterMessageID {
                // A stored anchor outside this loaded window is deferred, never
                // rendered as a trailing orphan. Loading it later only prepends
                // the anchor and its tools, without moving tools or changing B.
                let resolved = visible.contains(anchor) ? anchor : blankAnchors[anchor]
                if let resolved {
                    byAnchor[resolved, default: []].append(tool)
                    if let message = messagesByID[resolved],
                       let turnID = anchorTurnIDs[message.id] {
                        turnIDs[resolved] = turnID
                    }
                }
                else if blankWithoutPredecessor.contains(anchor) { trailing.append(tool) }
            } else { trailing.append(tool) }
        }
        let processPlan = ChatProcessPlan.make(
            messages: messages, tools: tools, running: running,
            completeTurnIDs: completeTurnIDs, toolsByAnchor: byAnchor)
        let processToolIDs = Set(processPlan.groupsByAnchor.values.flatMap {
            $0.tools.map(\.id)
        })
        // Consecutive tool runs in the same turn are one quiet process row.
        // A visible assistant segment or a new user message always breaks it.
        var coalescedByAnchor: [String: [ChatTool]] = [:]
        var emittedAnchorByTurn: [String: [String]] = [:]
        var lastToolIDByTurn: [String: String] = [:]
        for message in displayMessages {
            guard let turnID = anchorTurnIDs[message.id] else { continue }
            guard let group = byAnchor[message.id] else { continue }
            let anchor = message.id
            // Only a blank legacy anchor can extend a preceding tool group.
            // Any visible body row is a process boundary, even if it belongs to
            // the same turn. The user row is not adjacent to these tools here.
            if byAnchor[message.id] != nil, message.role != "user",
               !ChatRenderableText.hasVisibleContent(message.content), message.attachmentPaths.isEmpty,
               let previousID = lastToolIDByTurn[turnID],
               var previous = coalescedByAnchor[previousID] {
                previous.append(contentsOf: group)
                coalescedByAnchor[previousID] = previous
                emittedAnchorByTurn[turnID]?.removeAll { $0 == anchor }
            } else {
                coalescedByAnchor[anchor] = group
                emittedAnchorByTurn[turnID, default: []].append(anchor)
            }
            lastToolIDByTurn[turnID] = anchor
        }
        // Dictionary order is not stable; walk the original message order and
        // only emit a coalesced group at the first anchor that contributed.
        let emittedToolAnchors = Set(emittedAnchorByTurn.values.flatMap { $0 })
            .subtracting(processPlan.foldedMessageIDs)
        var seenMessages = Set<String>()
        var previous: ChatMessage?
        for message in displayMessages where seenMessages.insert(message.id).inserted {
            let date = message.timestamp.map { Date(timeIntervalSince1970: $0) }
            // User messages delimit assistant turns; a tool step or missing
            // timestamp does not introduce a new assistant identity.
            let turnID = turnIDs[message.id]
            var isContinuation = previous?.role == "assistant" && message.role == "assistant"
            if let group = processPlan.groupsByAnchor[message.id] {
                rows.append(ChatRow(id: "process-\(message.id)", kind: .process(group)))
            }
            if let previous,
               let previousDate = previous.timestamp.map({ Date(timeIntervalSince1970: $0) }),
               let date {
                let gap = date.timeIntervalSince(previousDate)
                if !calendar.isDate(date, inSameDayAs: previousDate) {
                    // 跨天：分隔行自己承担日期，组内时间小字不再重复。
                    rows.append(ChatRow(id: "day-\(message.id)", kind: .day(calendar.startOfDay(for: date))))
                } else if gap >= ChatPresentation.groupWindow {
                    rows.append(ChatRow(id: "time-\(message.id)", kind: .time(date)))
                } else {
                    isContinuation = previous.role == message.role
                }
            }
            if processPlan.foldedMessageIDs.contains(message.id) {
                // The process row owns both this segment and its anchored tools.
            } else {
                rows.append(ChatRow(id: "m-\(message.id)", kind: .message(message),
                                    // 组首才显示头像/名字/时间；用户消息连续两条同理。
                                    showsSender: !isContinuation, isContinuation: isContinuation,
                                    turnID: turnID, delivery: message.delivery))
            }
            previous = message
            if emittedToolAnchors.contains(message.id),
               let group = coalescedByAnchor[message.id]?.filter({
                   !processToolIDs.contains($0.id)
               }),
               let first = group.first {
                rows.append(ChatRow(id: "tools-\(first.id)", kind: .tools(group)))
            }
        }
        if let first = trailing.first {
            rows.append(ChatRow(id: "orphan-tools-\(first.id)", kind: .tools(trailing)))
        }
        func nextSignificantIndex(after index: Int, in rows: [ChatRow]) -> Int? {
            var next = index + 1
            while next < rows.count {
                switch rows[next].kind {
                case .time, .day: next += 1
                default: return next
                }
            }
            return nil
        }
        // 终态通知行（失败/取消/打断/预算上限）挂在整段消息之后，像 Conduit 的
        // notice 一样留在对话流里，而不是一闪而过的顶部提示。
        //
        // **必须**在下面的 showsCopy 计算之前 append：否则 `nextSignificantKind`
        // 永远看不到 `.notice`，`case .some(.notice)` 就是不可达死代码，
        // 终态回复拿不到复制入口。
        for notice in notices {
            rows.append(ChatRow(id: "notice-\(notice.id)", kind: .notice(notice)))
        }
        // A reply can contain commentary/tool/final segments. Only its last message
        // gets a reply-copy action, and it copies all loaded assistant segments.
        for i in rows.indices {
            guard case .message(let message) = rows[i].kind else { continue }
            if message.role == "user" { continue }
            // Time/day separators are decoration between two replies; they must
            // not hide the trailing action row of the reply above them.
            let endsReply: Bool
            if let nextIndex = nextSignificantIndex(after: i, in: rows) {
                switch rows[nextIndex].kind {
                case .message(let value):
                    endsReply = value.role == "user"
                case .notice:
                    // 终态通知行（失败/取消/打断/预算上限/停止）= 这轮已经结束。
                    endsReply = true
                case .tools(let tools):
                    // 工具全部完成 **且** 它确实是本轮最后一行，才算收尾。
                    // 若工具后面还有 assistant 正文，这一段只是中间过程，
                    // 复制按钮应留给最后那段（否则会同时冒出多个复制入口）。
                    let isTrailing = nextSignificantIndex(after: nextIndex, in: rows) == nil
                    endsReply = isTrailing && tools.allSatisfy(\.done)
                case .process:
                    // A process row is always followed by the final assistant
                    // segment in the same turn. It never closes the reply.
                    endsReply = false
                case .day, .time:
                    endsReply = false
                }
            } else {
                endsReply = true
            }
            if endsReply {
                rows[i].showsCopy = true
            }
        }
        return rows
    }

    static func turnIDs(for messages: [ChatMessage]) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var pendingAssistantID: String?
        for message in messages {
            if message.role == "user" {
                current = message.id
                pendingAssistantID = nil
                result[message.id] = message.id
            } else {
                let visible = !message.attachmentPaths.isEmpty
                    || ChatRenderableText.hasVisibleContent(message.content)
                if current == nil, pendingAssistantID == nil, visible {
                    pendingAssistantID = message.id
                    current = message.id
                }
                if let current { result[message.id] = current }
            }
        }
        return result
    }
}

/// Persistent per-item fold/expand state, keyed by row id. Now lives in the view's
/// @State dictionary, independent of viewport position.
struct ChatCellState: Equatable {
    var collapsed = false
    var toolsExpanded = false
    var processExpanded = false
    var expandedToolIDs: Set<String> = []
}

struct ChatNavigationNode: Identifiable, Equatable {
    let id: String
    let messageID: String
    let preview: String
    let timestamp: Double?
    /// Original order in the loaded transcript; used only for stable sorting.
    let ordinal: Int
    var kind: ChatNavigationKind = .question
}

enum ChatNavigationKind: String, CaseIterable, Identifiable {
    case question
    case answer
    case tools
    case terminalNotice

    var id: String { rawValue }
    var title: String {
        switch self {
        case .question: return "问题"
        case .answer: return "最终回答"
        case .tools: return "工具过程"
        case .terminalNotice: return "异常与终态"
        }
    }
    var icon: String {
        switch self {
        case .question: return "questionmark.bubble"
        case .answer: return "text.bubble"
        case .tools: return "wrench.and.screwdriver"
        case .terminalNotice: return "exclamationmark.bubble"
        }
    }
}

enum ChatPresentation {
    static let collapseLimit = 2400
    // Fixed per-message spacing: deliberately independent of the loaded window.
    // 与 AppTheme.groupGap 同值；这里保留纯值版本，ChatCore 侧测试不依赖 SwiftUI。
    static let groupSpacing: Double = 8
    static let groupWindow: TimeInterval = 600
    static func showsCopy(for row: ChatRow) -> Bool { row.showsCopy }
    static func showsTimeLabel(for row: ChatRow) -> Bool {
        if case .message(let message) = row.kind { return message.timestamp != nil }
        return false
    }
    static func topSpacing(for row: ChatRow) -> Double {
        if case .tools = row.kind { return 2 }
        if case .process = row.kind { return 2 }
        return groupSpacing
    }
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle().hour().minute()
        style.locale = Locale(identifier: "zh_CN")
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let clock = date.formatted(style)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        return dayLabel(calendar.startOfDay(for: date), now: now, calendar: calendar) + " " + clock
    }

    static func isCollapsible(_ text: String) -> Bool {
        text.count > collapseLimit
    }

    static func collapsedPreview(_ text: String) -> String {
        guard text.count > collapseLimit else { return text }
        return String(text.prefix(collapseLimit)) + "…"
    }

    static func replyActionsVisible(isStreaming: Bool, showsCopy: Bool,
                                    isCollapsible: Bool) -> Bool {
        !isStreaming && (showsCopy || isCollapsible)
    }

    /// Compact relative age for session rows ("3m", "昨天").
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))小时" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "昨天" }
        if days < 7 { return "\(days)天" }
        var style = Date.FormatStyle().month(.defaultDigits).day()
        if Calendar.current.component(.year, from: date) != Calendar.current.component(.year, from: now) {
            style = style.year()
        }
        style.locale = Locale(identifier: "zh_CN")
        return date.formatted(style)
    }

    /// Day separator label in Chinese, relative for today/yesterday.
    static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) { return "昨天" }
        // FormatStyle uses Foundation's cached formatter machinery instead of
        // allocating a DateFormatter on every streaming-driven view update.
        var style = Date.FormatStyle().month(.defaultDigits).day()
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            style = style.weekday(.wide)
        } else {
            style = style.year()
        }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = Locale(identifier: "zh_CN")
        return day.formatted(style)
    }
}
