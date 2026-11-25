import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared STOP transport classification. Only an exact HTTP response can
/// report a rejected request; timeouts and network failures remain unknown.
enum ChatStopHTTPError: Error {
    case rejected(Int)
}

struct SSEFrame: Sendable {
    var event: String
    var data: String
    var id: String?
}

/// A server-authoritative snapshot of controls currently blocking a Run.
/// nil on ChatSnapshot means the Gateway did not provide this capability;
/// an empty frame list means it explicitly reported no pending controls.
struct GatewayPendingControlSnapshot: Sendable {
    let frames: [SSEFrame]
    let hasIncompleteControl: Bool
}

/// 一条等待用户补充信息的请求（clarify）。
///
/// 与 `ChatPendingApproval` 的区别不是文案而是合同：审批答复 `choice`（服务端白名单），
/// clarify 答复 `answer`（任意文本，选项也由服务端解析）；审批带 `request_id`，
/// clarify 还多一个 `execution_generation` 必须原样带回，否则服务端 400 `invalid_params`。
///
/// agent 在等这个答复时是**真的阻塞**，不回答就一直等到超时——所以这张卡片必须可操作，
/// 不能像以前那样只显示一句「请在 WebUI 处理」。
///
/// 定义在 `ChatCore.swift` 而不是 `NativeChatModel.swift`：它由 SSE 帧解析出来，
/// 而 `gatewaybackend` 套件只编译本文件、不编译模型；放在模型里会让那个套件
/// 「cannot find type 'ChatPendingClarify' in scope」。
struct ChatPendingClarify: Identifiable, Codable, Equatable {
    let id: String
    let runID: String
    /// 服务端的 `prompt_id`，答复时当 `request_id` 发回去。
    let requestID: String
    /// 服务端用它校验「答复的是不是当前这一代执行」，缺了必 400。
    let executionGeneration: Int
    let question: String
    /// 空数组表示开放式提问，只需一个输入框。
    let choices: [String]
    let multiSelect: Bool

    var isOpenEnded: Bool { choices.isEmpty }

    /// 解析一帧 `clarify`。解析失败返回 nil，调用方退回普通提示，
    /// 绝不能让一张看不懂的卡片占着屏幕。
    static func make(from frame: SSEFrame, runID: String?) -> ChatPendingClarify? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8)))
                as? [String: Any] else { return nil }
        let question = ["question", "message", "description"]
            .compactMap { object[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let question else { return nil }
        // request_id 与 execution_generation 是答复的硬前置：没有它们发不出去，
        // 与其留一张点了会 400 的卡片，不如不认这一帧。
        guard let requestID = (object["request_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !requestID.isEmpty else { return nil }
        guard let generation = object["execution_generation"] as? Int else { return nil }
        var seen = Set<String>()
        let choices = ((object["choices"] as? [Any])?.compactMap { $0 as? String } ?? [])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let multi = object["multi_select"] as? Bool ?? false
        return ChatPendingClarify(
            id: requestID,
            runID: runID ?? "",
            requestID: requestID,
            executionGeneration: generation,
            question: question,
            choices: choices,
            multiSelect: multi)
    }
}

/// Feed one decoded line at a time, including empty delimiter lines.
struct SSEParser {
    private var event = "message"
    private var data: [String] = []
    private var lastID: String?

    mutating func feed(line: String) -> SSEFrame? {
        var line = line
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty {
            defer { event = "message"; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEFrame(event: event, data: data.joined(separator: "\n"), id: lastID)
        }
        let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pair[0])
        var value = pair.count > 1 ? String(pair[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" { event = value.isEmpty ? "message" : value }
        if field == "data" { data.append(value) }
        if field == "id", !value.contains("\u{0}") { lastID = value }
        return nil
    }
}

/// 本地气泡的投递三态。服务端历史（以及任何持久化快照）恒为 `confirmed`，
/// 只有「先出气泡再请求」的本地行才会经历 submitting / accepted / unconfirmed。
enum ChatDeliveryState: String, Codable, Equatable, Sendable {
    case confirmed
    case submitting
    case accepted
    case unconfirmed
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var role: String
    var content: String
    var timestamp: Double? = nil
    /// Index in the server raw transcript, including invisible tool rows.
    var sourceIndex: Int? = nil
    /// 历史里带的附件路径（同源 file/raw 才可预览）。
    var attachmentPaths: [String] = []
    /// Render provenance explicitly instead of showing internal notifications as user prompts.
    var displayKind: String? = nil
    /// `var` + 默认值：memberwise init 的既有五参构造保持可用。
    var delivery: ChatDeliveryState = .confirmed
}

/// Presentation-only classification of a protocol-wrapped OOB delivery.
/// The original message is NEVER rewritten, deleted, or changed for copy/Fork.
/// Only a server-labelled notification may be collapsed; its exact balanced
/// envelope is presentation-only. Pasted OOB text stays a normal user message.
enum ChatBackgroundEnvelope {
    static let closingMarker = "[/OUT-OF-BAND USER MESSAGE]"

    static func userBody(_ message: ChatMessage) -> String? {
        // A raw history index is an ordering fact, not a trust credential.
        // Neither a user's pasted envelope nor a persisted quoted envelope
        // can prove that it came from the Hermes background channel.
        guard message.role == "user",
              message.displayKind?.lowercased() == "internal_notification" else {
            return nil
        }
        let raw = message.content
        // A backend-labelled notification may have a protocol envelope.
        // Remove only an exact balanced wrapper for presentation; preserve
        // the original ChatMessage and its content for export and debugging.
        guard raw.hasPrefix("[OUT-OF-BAND USER MESSAGE —"),
              raw.hasSuffix(closingMarker),
              let headerEnd = raw.range(of: "]\n") else { return nil }
        let end = raw.index(raw.endIndex, offsetBy: -closingMarker.count)
        guard headerEnd.upperBound <= end else { return nil }
        return String(raw[headerEnd.upperBound..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A message can arrive with zero-width characters, BOMs or control marks that
/// survive a whitespace trim but render as an empty assistant block. Keep the
/// original content byte-for-byte; only presentation and reply copying ask this
/// predicate whether there is something a person can actually see.
enum ChatRenderableText {
    static func hasVisibleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard !scalar.properties.isWhitespace else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format:
                return false
            default:
                return true
            }
        }
    }
}

/// 时间线里的系统提示行（对齐 Conduit 的 `HermesRoomNoticeItem`）：一轮的收尾结果
/// —— 被取消 / 失败 / 被中断 / 预算耗尽。它作为稳定的行渲染进消息流，而不是藏进
/// 顶部那条易失的 notice/error 字符串里。`failure`/`notice` 仍驱动状态栏，这里只负责
/// 「这条回复到底怎么结束的」在对话里留一条可见的、可回看的记录。
enum ChatNoticeKind: String, Codable, Equatable, Sendable {
    case cancelled
    case failed
    case interrupted
    case workLimit
    case stopped
}

struct ChatNotice: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: ChatNoticeKind
    var message: String
    var timestamp: Double? = nil
}

struct ChatTool: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var args: String
    var result: String
    var done: Bool
    var isError: Bool
    var afterMessageID: String? = nil
    /// Set ONLY for a display-only disk snapshot whose result was too large to
    /// cache. A real empty Gateway result keeps this nil. No fetch API is
    /// inferred from the existence of this marker.
    var uncachedResultBytes: Int? = nil
    var uncachedArgsBytes: Int? = nil
}

struct ChatStreamingTailSnapshot: Equatable {
    let messages: [ChatMessage]
    let tools: [ChatTool]
    let notices: [ChatNotice]
    let running: Bool
    let toolsAreLive: Bool
    let transcriptRevision: UInt64
    let transcriptStructureRevision: UInt64
}

enum ChatStreamingTailProof {
    /// Revision plus the unchanged structure generation proves every row before
    /// the tail is unchanged. The remaining checks keep the tail replaceable
    /// without rebuilding the full timeline.
    static func canReplaceTail(from previous: ChatStreamingTailSnapshot,
                               to next: ChatStreamingTailSnapshot) -> Bool {
        guard next.transcriptRevision > previous.transcriptRevision,
              next.transcriptStructureRevision == previous.transcriptStructureRevision,
              previous.tools == next.tools,
              previous.notices == next.notices,
              previous.running == next.running,
              previous.toolsAreLive == next.toolsAreLive,
              previous.messages.count == next.messages.count,
              previous.messages.count > 0,
              let oldLast = previous.messages.last,
              let newLast = next.messages.last,
              oldLast.id == newLast.id,
              oldLast.role == newLast.role,
              oldLast.sourceIndex == newLast.sourceIndex,
              oldLast.timestamp == newLast.timestamp,
              oldLast.attachmentPaths == newLast.attachmentPaths,
              oldLast.displayKind == newLast.displayKind,
              oldLast.content != newLast.content || oldLast.delivery != newLast.delivery,
              ChatRenderableText.hasVisibleContent(newLast.content)
                || !newLast.attachmentPaths.isEmpty else {
            return false
        }
        return true
    }
}

enum ChatCoreError: Error, LocalizedError {
    case malformed(String)
    case server(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let description): return "Invalid chat protocol: \(description)"
        case .server(let description): return description
        }
    }
}

private func contentText(_ value: Any?) -> String {
    if let text = value as? String { return text }
    guard let parts = value as? [[String: Any]] else { return "" }
    return parts.compactMap { part -> String? in
        guard (part["type"] as? String) == "text" else { return nil }
        return part["text"] as? String
    }.joined()
}

private func displayValue(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let text = value as? String { return text }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
          let text = String(data: data, encoding: .utf8) else { return "" }
    return text
}

private func doubleValue(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String, let d = Double(s) { return d }
    return nil
}

/// Identity must survive pagination: the same row fetched with a different
/// `msg_before` window has to produce the same ID, or loading older pages
/// duplicates rows that are already on screen.
private func stableMessageID(_ row: [String: Any], sessionID: String, index: Int) -> String {
    if let value = row["message_id"] as? String, !value.isEmpty { return value }
    if let value = row["id"] as? String, !value.isEmpty { return value }
    if let number = row["id"] as? NSNumber { return "\(sessionID):id:\(number.intValue)" }
    // Timestamps are not unique (one turn can write several rows in one second).
    // index is _messages_offset + raw index, stable across pagination windows.
    return "\(sessionID):message:\(index)"
}

private func historyTool(_ row: [String: Any], fallbackID: String) -> ChatTool {
    ChatTool(
        id: row["tid"] as? String ?? row["id"] as? String ?? row["tool_call_id"] as? String ?? fallbackID,
        name: row["name"] as? String ?? "Tool",
        args: displayValue(row["args"]),
        result: displayValue(row["result"] ?? row["snippet"] ?? row["preview"]),
        done: row["done"] as? Bool ?? false,
        isError: row["is_error"] as? Bool ?? false
    )
}

private func mergeTool(_ incoming: ChatTool, into tools: inout [ChatTool]) {
    guard let index = tools.firstIndex(where: { $0.id == incoming.id }) else {
        tools.append(incoming)
        return
    }
    if incoming.name != "Tool" { tools[index].name = incoming.name }
    if !incoming.args.isEmpty { tools[index].args = incoming.args }
    if !incoming.result.isEmpty { tools[index].result = incoming.result }
    if let anchor = incoming.afterMessageID { tools[index].afterMessageID = anchor }
    tools[index].done = tools[index].done || incoming.done
    tools[index].isError = tools[index].isError || incoming.isError
}

/// 服务端计数；nil 表示未报告，0 不冒充“上下文用了 0%”。
struct ChatUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var promptTokens: Int?
    var contextLength: Int?
    var cost: Double?
    var estimated: Bool
    init(fields: [String: Any]) {
        // 业务上界 1e15：只要 fraction*100（最坏 1e14）远小于 Int.max 即可，
        // 避免渲染百分比时 Int(_:) trap；更大的值（如 1e18）视为未报告。
        let maxTokens = 1_000_000_000_000_000.0
        func positive(_ names: [String]) -> Int? {
            for name in names {
                if let n = doubleValue(fields[name]), n.isFinite, n > 0, n <= maxTokens { return Int(n) }
            }
            return nil
        }
        inputTokens = positive(["input_tokens", "prompt_tokens"])
        outputTokens = positive(["output_tokens", "completion_tokens"])
        promptTokens = positive(["last_prompt_tokens"])
        contextLength = positive(["context_length"])
        cost = doubleValue(fields["estimated_cost"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        estimated = fields["last_prompt_tokens_estimated"] as? Bool ?? false
    }
    var contextFraction: Double? {
        guard let promptTokens, let contextLength, contextLength > 0 else { return nil }
        let fraction = Double(promptTokens) / Double(contextLength)
        return fraction.isFinite ? fraction : nil
    }
    /// 服务端是否报告过任何用量数字。
    ///
    /// 用量只在轮次收尾时写入，所以它是「这一轮确实结束了」的旁证。
    /// 注意 `estimated` 单独不算：它只说明计数是估算的，不代表有数值。
    var hasReportedValues: Bool {
        inputTokens != nil || outputTokens != nil || promptTokens != nil
            || contextLength != nil || cost != nil
    }
    /// 缺省字段不能抹掉 done.usage 已报告的计数。
    func merging(_ newer: ChatUsage) -> ChatUsage {
        var result = self
        result.inputTokens = newer.inputTokens ?? inputTokens
        result.outputTokens = newer.outputTokens ?? outputTokens
        result.contextLength = newer.contextLength ?? contextLength
        result.cost = newer.cost ?? cost
        if let prompt = newer.promptTokens { result.promptTokens = prompt; result.estimated = newer.estimated }
        return result
    }
}

/// 编辑/重生成均创建分支，不删除源历史；keepCount 使用原始消息坐标。
struct MessageForkPlan: Equatable {
    let keepCount: Int
    let text: String
    let sourceMessageID: String
    let sendImmediately: Bool
    /// 历史附件是服务端引用，编辑/重生成分支需原样带回，不能重新上传。
    /// `var` 带默认值才能进 memberwise init，旧的四参调用保持兼容。
    var attachmentPaths: [String] = []
    static func edit(messageID: String, messages: [ChatMessage]) throws -> Self {
        guard let message = messages.first(where: { $0.id == messageID }),
              message.role == "user", let index = message.sourceIndex else {
            throw ChatCoreError.server("消息位置未确认，请刷新后重试。")
        }
        return Self(keepCount: index, text: message.content, sourceMessageID: message.id, sendImmediately: false, attachmentPaths: message.attachmentPaths)
    }
    static func regenerate(messageID: String, messages: [ChatMessage]) throws -> Self {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].role == "assistant",
              let user = messages[..<index].last(where: { $0.role == "user" }), let offset = user.sourceIndex else {
            throw ChatCoreError.server("尚未加载对应的问题，请加载更早消息或刷新。")
        }
        return Self(keepCount: offset, text: user.content, sourceMessageID: user.id, sendImmediately: true, attachmentPaths: user.attachmentPaths)
    }
}

/// A failed status lookup never proves that a server Run has ended.
enum ActiveRunEvidence: Equatable, Sendable {
    case active(String)
    case absent
    case unknown
}

struct ChatSnapshot: Sendable {
    let sessionID: String
    let messages: [ChatMessage]
    let tools: [ChatTool]
    let activeStreamID: String?
    let activeRunEvidence: ActiveRunEvidence
    let olderOffset: Int
    let readOnly: Bool
    let messagesTruncated: Bool
    /// Exclusive end of this raw history window, including invisible tool rows.
    let rawMessageEndIndex: Int
    /// 会话当前模型；历史接口带 model 字段，缺省时为 nil（不是空串）。
    let model: String?
    /// Provider of the session model when the server reports it; nil means the
    /// client cannot tell two same-named models apart.
    let modelProvider: String?
    let usage: ChatUsage
    let gatewayPendingControls: GatewayPendingControlSnapshot?

    init(data: Data, runStatusUnknown: Bool = false,
         gatewayPendingControls: GatewayPendingControlSnapshot? = nil) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatCoreError.malformed("expected object")
        }
        if let error = root["error"], !(error is NSNull), !(error as? String == "") {
            throw ChatCoreError.server(error as? String ?? "Server returned an error")
        }
        guard let session = (root["session"] ?? root) as? [String: Any],
              let id = session["session_id"] as? String, !id.isEmpty,
              let rows = session["messages"] as? [[String: Any]] else {
            throw ChatCoreError.malformed("expected session_id and messages array")
        }
        if let calls = session["tool_calls"], !(calls is NSNull), !(calls is [[String: Any]]) {
            throw ChatCoreError.malformed("expected tool_calls array")
        }
        sessionID = id
        self.gatewayPendingControls = gatewayPendingControls
        let offset = max(0, session["_messages_offset"] as? Int ?? 0)
        guard offset <= Int.max - rows.count else {
            throw ChatCoreError.malformed("history offset exceeds supported range")
        }
        olderOffset = offset
        rawMessageEndIndex = offset + rows.count
        messagesTruncated = session["_messages_truncated"] as? Bool ?? false
        readOnly = session["read_only"] as? Bool ?? false
        let rawModel = (session["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        model = (rawModel?.isEmpty ?? true) ? nil : rawModel
        let rawProvider = (session["model_provider"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        modelProvider = (rawProvider?.isEmpty ?? true) ? nil : rawProvider
        let active = (session["active_stream_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        activeStreamID = active?.isEmpty == false ? active : nil
        if runStatusUnknown {
            activeRunEvidence = .unknown
        } else if let activeStreamID {
            activeRunEvidence = .active(activeStreamID)
        } else {
            activeRunEvidence = .absent
        }
        usage = ChatUsage(fields: session)
        messages = rows.enumerated().compactMap { index, row in
            let role = row["role"] as? String ?? ""
            guard role == "assistant" || role == "user" else { return nil }
            let text = contentText(row["content"])
            let paths = AttachmentHistory.paths(content: row["content"], attachments: row["attachments"])
            guard ChatRenderableText.hasVisibleContent(text) || !paths.isEmpty else { return nil }
            let messageID = stableMessageID(row, sessionID: id, index: offset + index)
            return ChatMessage(id: messageID, role: role, content: text, timestamp: doubleValue(row["timestamp"]),
                               sourceIndex: offset + index, attachmentPaths: paths,
                               displayKind: row["display_kind"] as? String)
        }
        var cards: [ChatTool] = []
        // A flat session-level tool list has no turn ownership. Only a
        // matching tool-result row in the loaded history proves its position.
        var provenAnchors: [String: String] = [:]
        var ambiguousToolIDs = Set<String>()
        for (index, row) in (session["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            mergeTool(historyTool(row, fallbackID: "\(id):tool:\(offset):\(index)"), into: &cards)
        }
        var lastVisibleMessageID:String?
        let visibleIDs = Set(messages.map(\.id))
        for (index, row) in rows.enumerated() {
            let messageID = stableMessageID(row, sessionID: id, index: offset + index)
            let role = row["role"] as? String
            // Tool rows are never in messages; also check role explicitly so
            // a duplicate external message ID cannot promote a tool result.
            if (role == "user" || role == "assistant"), visibleIDs.contains(messageID) {
                lastVisibleMessageID = messageID
            }
            if role == "assistant" {
                for (callIndex, call) in (row["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                    var normalized = call
                    if let function = call["function"] as? [String: Any] {
                        normalized["name"] = function["name"]
                        normalized["args"] = function["arguments"]
                    }
                    var card = historyTool(normalized, fallbackID: "\(id):message:\(offset + index):tool:\(callIndex)")
                    card.afterMessageID = lastVisibleMessageID
                    mergeTool(card, into: &cards)
                }
            } else if role == "tool" {
                let toolID = row["tool_call_id"] as? String ?? row["tid"] as? String
                    ?? "\(id):message:\(offset + index):tool-result"
                let result = row["result"].map(displayValue) ?? contentText(row["content"])
                mergeTool(ChatTool(id: toolID, name: row["name"] as? String ?? "Tool", args: "",
                                   result: result, done: true, isError: row["is_error"] as? Bool ?? false), into: &cards)
                if !toolID.isEmpty, let anchor = lastVisibleMessageID {
                    // Reused tool IDs with conflicting local positions do not
                    // prove a unique owner. Leave those entries unattributed.
                    if let previous = provenAnchors[toolID], previous != anchor {
                        ambiguousToolIDs.insert(toolID)
                    } else {
                        provenAnchors[toolID] = anchor
                    }
                }
            }
        }
        // A session-level entry may borrow an anchor only from a matching
        // tool-result row with an unambiguous, visible local predecessor.
        // Otherwise keep the nil anchor; never guess from the last reply.
        for index in cards.indices where cards[index].afterMessageID == nil {
            let toolID = cards[index].id
            if !ambiguousToolIDs.contains(toolID), let anchor = provenAnchors[toolID] {
                cards[index].afterMessageID = anchor
            }
        }
        tools = cards
    }

    /// 快照能否自证「上一轮确实结束了」。
    ///
    /// 只在**断线恢复**路径使用：那时手里没有 `done` / `stream_end` 帧，
    /// 而 `activeStreamID == nil` 本身不构成完成证据——服务端可能仍在跑，
    /// 只是这次 GET 没返回活跃 id。没有别的证据就自动续发队列，会让两个
    /// 轮次并发执行。
    ///
    /// 判定规则（任一成立即可）：
    /// 1. 末条可见消息是 assistant —— 说明这一轮至少产出了最终回答，
    ///    且服务端已把 `active_stream_id` 摘掉（否则上面那个分支会先命中）。
    /// 2. 会话带 `usage` 且已有 assistant 消息 —— 用量只在轮次收尾时写入。
    ///
    /// 两个条件都拿不到时返回 false：宁可让用户点一下「继续」，
    /// 也不要静默重发一条可能已经在跑的消息。
    /// Stricter evidence for the *current* turn during reconnect. In particular,
    /// an older assistant response plus a temporarily missing active run ID
    /// cannot complete this turn or unlock a queued POST.
    func confirmsRunFinished(afterRawIndex boundary: Int?) -> Bool {
        guard activeRunEvidence == .absent, let boundary else { return false }
        let fresh = messages.filter { message in
            guard let sourceIndex = message.sourceIndex else { return false }
            return sourceIndex >= boundary
        }
        guard fresh.contains(where: { $0.role == "user" }) else { return false }
        return fresh.last?.role == "assistant"
    }

    var confirmsRunFinished: Bool {
        guard activeRunEvidence == .absent else { return false }
        guard let last = messages.last else { return false }
        if last.role == "assistant" { return true }
        // 末条是用户消息但已有用量：这一轮的收尾记录已落地。
        return !messages.isEmpty && usage.hasReportedValues
    }
}

enum RunTerminalStatus: String, Codable, Equatable, Sendable {
    case completed, failed, cancelled, interrupted

    var notice: String {
        switch self {
        case .completed: return "后台任务已完成，服务端历史已重新同步。"
        case .failed: return "后台任务执行失败，已同步现有历史；请查看任务错误。"
        case .cancelled: return "后台任务已取消，已同步现有历史。"
        case .interrupted: return "后台任务已中断，已同步现有历史。"
        }
    }
}

/// Protocol evidence is distinct from transport termination. In particular,
/// an untyped error or explicit unknown status cannot authorize retirement.
enum RunTerminalEvidence {
    static func explicitlyEmptyReply(_ frame: SSEFrame) -> Bool {
        guard outcome(of: frame) == .completed,
              let body = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any] else { return false }
        return body["empty_output"] as? Bool == true
    }

    static func outcome(of frame: SSEFrame) -> RunTerminalStatus? {
        let body = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any]
        let status = (body?["status"] as? String)?.lowercased()
        switch frame.event {
        case "done": return .completed // caller validates the snapshot identity first
        case "cancel":
            let message = body?["message"] as? String
            return status == "interrupted" || message == "interrupted" || message == "partial"
                ? .interrupted : .cancelled
        case "stream_end":
            if status == "work_limit" { return .interrupted }
            if let status { return RunTerminalStatus(rawValue: status) }
            // Legacy WebUI stream_end has no status. It can end the transport
            // but cannot prove a successful Run or authorize queued dispatch.
            return nil
        case "apperror", "error":
            return status == "failed" ? .failed : nil
        default: return nil
        }
    }
}

/// One final-history evidence policy used by all transport/status owners.
/// The exact receipt cannot be replaced by another Run's evidence.
enum RunFinalizer {
    static func canSettle(_ pages: [ChatSnapshot], sessionID: String,
                          runID: String, receipt: ActiveTurnRecovery?,
                          outcome: RunTerminalStatus,
                          requireReply: Bool) -> Bool {
        guard let newest = pages.first, newest.sessionID == sessionID,
              newest.activeRunEvidence == .absent, !newest.readOnly else { return false }
        if let receipt, receipt.runID != runID { return false }
        if outcome != .completed { return true }
        if let receipt {
            return receipt.confirmsCompletion(in: pages,
                allowEmptyReply: !requireReply &&
                    (receipt.terminalAllowsEmptyReply == true || receipt.commandAllowsEmptyReply == true))
        }
        return !requireReply
    }
}

/// A post-acceptance receipt for the latest turn, distinct from PendingSend.
/// Stored in a protected, per-account/session file. An active run ID is never
/// evidence that its associated POST can be replayed.
struct ActiveTurnRecovery: Codable, Equatable {
    let runID: String
    let historyEnd: Int?
    let knownIDs: Set<String>
    let text: String
    let attachmentPaths: Set<String>
    /// Exact Run/Session terminal evidence survives a failed final GET and
    /// server-side status expiry. Optional for pre-build232 receipts.
    var terminalStatus: RunTerminalStatus? = nil
    var terminalAllowsEmptyReply: Bool? = nil
    var commandAllowsEmptyReply: Bool? = nil

    /// A single GET can cover the entire turn, or only the newest 60 raw
    /// records. Keep identical evidence rules for both cases.
    func confirmsCompletion(in snap: ChatSnapshot) -> Bool {
        confirmsCompletion(in: [snap])
    }

    /// Read-only proof from a contiguous suffix, newest page first. Tool rows
    /// occupy raw indexes but aren't rendered; never treat a gap as proof that
    /// there was only one user submission after the accepted POST.
    func confirmsCompletion(in pages: [ChatSnapshot], allowEmptyReply: Bool = false) -> Bool {
        guard let newest = pages.first, let oldest = pages.last,
              let historyEnd, newest.activeRunEvidence == .absent, !newest.readOnly,
              oldest.olderOffset <= historyEnd else { return false }
        for index in pages.indices {
            let page = pages[index]
            guard page.sessionID == newest.sessionID,
                  page.activeRunEvidence == .absent, !page.readOnly else { return false }
            if index > 0 {
                let later = pages[index - 1]
                guard page.rawMessageEndIndex == later.olderOffset,
                      page.olderOffset < later.olderOffset else { return false }
            }
        }
        let fresh = pages.reversed().flatMap { $0.messages }.filter {
            guard let index = $0.sourceIndex else { return false }
            return index >= historyEnd && !knownIDs.contains($0.id)
                && ChatBackgroundEnvelope.userBody($0) == nil
        }
        let newUsers = fresh.filter { $0.role == "user" }
        guard newUsers.count == 1, let sent = newUsers.first,
              sent.content == text, Set(sent.attachmentPaths) == attachmentPaths,
              let sentIndex = sent.sourceIndex else { return false }
        if allowEmptyReply && fresh.last?.id == sent.id { return true }
        guard let last = fresh.last, last.role == "assistant",
              let replyIndex = last.sourceIndex, replyIndex > sentIndex else { return false }
        return true
    }
}

/// A terminal SSE frame may precede the authoritative final history row.
/// Do not replace a visibly streamed reply with stale history. This policy
/// uses the immutable accepted-POST receipt rather than guessing from the
/// existence of an unrelated assistant message.
enum ChatFinalHistoryGate {
    static func canReplace(_ snapshot: ChatSnapshot, sessionID: String,
                           receipt: ActiveTurnRecovery?,
                           streamedAssistantPresent: Bool,
                           expectedRunID: String? = nil) -> Bool {
        guard snapshot.sessionID == sessionID, !snapshot.readOnly,
              snapshot.activeRunEvidence == .absent else { return false }
        guard streamedAssistantPresent else { return true }
        // A different accepted turn in the same Session cannot authorize
        // replacing this Run's still-visible SSE text with final history.
        if let expectedRunID, receipt?.runID != expectedRunID { return false }
        return receipt?.confirmsCompletion(in: snapshot) == true
    }
}

private func streamErrorDescription(_ data: String) -> String {
    guard let payload = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else {
        return data.isEmpty ? "Stream error" : data
    }
    let nested = payload["error"] as? [String: Any]
    var parts: [String] = []
    for value in [payload["label"], payload["message"], payload["error"] as? String,
                  nested?["message"], payload["hint"]] {
        if let text = value as? String, !text.isEmpty, !parts.contains(text) { parts.append(text) }
    }
    return parts.isEmpty ? "Stream error" : parts.joined(separator: "\n")
}

/// A value represents exactly one stream. Create a fresh value for a new turn;
/// retain the same value when reconnecting to that stream.
struct ChatTranscript: Codable {
    /// Monotonic for this transcript value. Every array assignment or mutation
    /// advances it; a replacement transcript resets to zero, so callers must
    /// also require `next > previous`.
    private(set) var transcriptRevision: UInt64 = 0
    /// Changes whenever message/tool/notice structure changes. Tail content
    /// updates deliberately do not advance it.
    private(set) var transcriptStructureRevision: UInt64 = 0
    var messages: [ChatMessage] {
        get { storage.messages }
        set {
            storage.messages = newValue
            if !updatingStreamingTail {
                transcriptRevision &+= 1
                transcriptStructureRevision &+= 1
            }
        }
        _modify {
            var value = storage.messages
            storage.messages = []
            yield &value
            storage.messages = value
            if !updatingStreamingTail {
                transcriptRevision &+= 1
                transcriptStructureRevision &+= 1
            }
        }
    }
    var tools: [ChatTool] {
        get { storage.tools }
        set {
            storage.tools = newValue
            transcriptRevision &+= 1
            transcriptStructureRevision &+= 1
        }
        _modify {
            var value = storage.tools
            storage.tools = []
            yield &value
            storage.tools = value
            transcriptRevision &+= 1
            transcriptStructureRevision &+= 1
        }
    }
    /// 本轮收尾产生的通知行；`var` + 默认值不破坏既有 memberwise 调用。
    var notices: [ChatNotice] {
        get { storage.notices }
        set {
            storage.notices = newValue
            transcriptRevision &+= 1
            transcriptStructureRevision &+= 1
        }
        _modify {
            var value = storage.notices
            storage.notices = []
            yield &value
            storage.notices = value
            transcriptRevision &+= 1
            transcriptStructureRevision &+= 1
        }
    }
    var usage: ChatUsage? {
        get { storage.usage }
        set { storage.usage = newValue }
    }
    var contextStatus: String? {
        get { storage.contextStatus }
        set { storage.contextStatus = newValue }
    }
    var reasoning: String {
        get { storage.reasoning }
        set { storage.reasoning = newValue }
    }
    var terminal: Bool {
        get { storage.terminal }
        set { storage.terminal = newValue }
    }
    var failure: String? {
        get { storage.failure }
        set { storage.failure = newValue }
    }
    var notice: String? {
        get { storage.notice }
        set { storage.notice = newValue }
    }
    var lastEventID: String? {
        get { storage.lastEventID }
        set { storage.lastEventID = newValue }
    }

    private struct Storage: Codable {
        var messages: [ChatMessage] = []
        var tools: [ChatTool] = []
        var notices: [ChatNotice] = []
        var usage: ChatUsage?
        var contextStatus: String?
        var reasoning: String = ""
        var terminal: Bool = false
        var failure: String?
        var notice: String?
        var lastEventID: String?
    }
    private var storage = Storage()
    private var streamingMessageID: String?
    /// 流式消息在 `messages` 里的下标。每条 token 都做 `firstIndex(where:)` 是
    /// O(n) 线性查找，2000 行时每秒数万次字符串比较且跑在主线程。缓存下标后
    /// 只在数组结构变化（append/重建）时失效。
    private var streamingMessageIndex: Int?
    // Do not publish a blank assistant segment just because an SSE delta
    // contains a newline. Preserve the prefix until real text arrives.
    private var pendingWhitespace = ""
    private var seenEventIDs: Set<String> = []
    private var approvalRequestID: String?
    private var updatingStreamingTail = false

    /// A cursor is resumable only when the projection includes that event
    /// and the exact deduplication and streaming-tail state.
    func canResume(at cursor: String) -> Bool {
        !terminal && !cursor.isEmpty && lastEventID == cursor && seenEventIDs.contains(cursor) &&
            (streamingMessageID == nil || messages.contains { $0.id == streamingMessageID })
    }

    mutating func apply(_ frame: SSEFrame) throws {
        defer { transcriptRevision &+= 1 }
        if let id = frame.id, !id.isEmpty, seenEventIDs.contains(id) { return }
        if terminal {
            if let id = frame.id {
                lastEventID = id
                if !id.isEmpty { seenEventIDs.insert(id) }
            }
            return
        }
        switch frame.event {
        case "context_status":
            if let payload = try JSONSerialization.jsonObject(with: Data(frame.data.utf8)) as? [String: Any],
               let prefill = payload["prefill"] as? [String: Any] {
                contextStatus = prefill["status"] as? String
            }
        case "token", "reasoning":
            guard let payload = try JSONSerialization.jsonObject(with: Data(frame.data.utf8)) as? [String: Any],
                  let text = payload["text"] as? String else {
                throw ChatCoreError.malformed("\(frame.event) requires text")
            }
            if frame.event == "reasoning" {
                reasoning += text
            } else if !text.isEmpty {
                if let id = streamingMessageID {
                    // 优先用缓存下标；下标失效（数组被重建）时才回退线性查找。
                    if let cached = streamingMessageIndex, cached < messages.count,
                       messages[cached].id == id {
                        appendStreamingText(text, at: cached)
                    } else if let index = messages.firstIndex(where: { $0.id == id }) {
                        streamingMessageIndex = index
                        appendStreamingText(text, at: index)
                    } else {
                        streamingMessageID = nil
                        streamingMessageIndex = nil
                        pendingWhitespace += text
                    }
                } else if !ChatRenderableText.hasVisibleContent(text) {
                    pendingWhitespace += text
                } else {
                    let id = "streaming:\(UUID().uuidString)"
                    streamingMessageID = id
                    messages.append(ChatMessage(id: id, role: "assistant", content: pendingWhitespace + text, timestamp: Date().timeIntervalSince1970))
                    streamingMessageIndex = messages.count - 1
                    pendingWhitespace = ""
                }
            }
        case "tool", "tool_complete":
            guard let payload = try JSONSerialization.jsonObject(with: Data(frame.data.utf8)) as? [String: Any],
                  let name = payload["name"] as? String, !name.isEmpty else {
                throw ChatCoreError.malformed("\(frame.event) requires name")
            }
            let explicitID = payload["tid"] as? String
            let complete = frame.event == "tool_complete"
            if !complete {
                streamingMessageID = nil
                streamingMessageIndex = nil
                pendingWhitespace = "" // A tool boundary ends this text segment.
            }
            let index: Int?
            if let id = explicitID {
                index = tools.firstIndex(where: { $0.id == id })
            } else if complete {
                // Without an explicit id, a name is only safe when it identifies
                // one unresolved call. Never guess the most recent same-name
                // tool; completed and historical calls remain untouched.
                let candidates = tools.indices.filter {
                    tools[$0].name == name && !tools[$0].done
                }
                index = candidates.count == 1 ? candidates[0] : nil
            } else {
                index = nil
            }
            let args = displayValue(payload["args"])
            if let index {
                tools[index].name = name
                if !args.isEmpty && args != "{}" { tools[index].args = args }
                if let preview = payload["preview"], !(preview is NSNull) {
                    tools[index].result = displayValue(preview)
                }
                tools[index].done = tools[index].done || complete
                tools[index].isError = tools[index].isError || (payload["is_error"] as? Bool ?? false)
            } else {
                // 锚点决定这组工具在时间线里的位置。
                //
                // 原来一律用 `messages.last?.id`。这在「工具跑在回答之前」时没问题，
                // 但流式里 `tool` 帧到达时通常已经有一段文本落地，`messages.last`
                // 就是**那段正文**——工具于是被挂在回答后面，一轮写完时时间线底部
                // 残留一行「已完成 N 项操作」。
                //
                // 工具的语义是「这一轮里发生的事」，应当排在本轮用户消息之后、
                // 回答正文之前。所以优先锚到最后一条 **user** 消息；只有本轮没有
                // user 消息（续跑、恢复等）时才退回最后一条消息。
                let anchor = messages.last(where: { $0.role == "user" })?.id ?? messages.last?.id
                tools.append(ChatTool(id: explicitID ?? "stream-tool:\(UUID().uuidString)", name: name,
                                      args: args, result: displayValue(payload["preview"]), done: complete,
                                      isError: payload["is_error"] as? Bool ?? false,
                                      afterMessageID: anchor))
            }
        case "replay_truncated":
            // A lost SSE replay window is a recovery hint, not a Run failure.
            // Preserve any already-rendered assistant text and pending approval
            // notice until scoped GET proves the actual terminal state.
            if notice == nil {
                notice = "回复续传窗口已过期，后台状态需重新核对。"
            }
        case "approval", "clarify":
            let payload = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any] ?? [:]
            approvalRequestID = frame.event == "approval" ? payload["request_id"] as? String : nil
            let detail = payload["question"] as? String ?? payload["description"] as? String
                ?? payload["message"] as? String ?? "Continue in WebUI."
            notice = "\(frame.event == "approval" ? "需要审批" : "需要澄清")：\(detail)"
        case "approval_resolved":
            if let payload = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any],
               let requestID = payload["request_id"] as? String, !requestID.isEmpty,
               requestID == approvalRequestID {
                notice = nil
                approvalRequestID = nil
            }
        case "done":
            if let payload = try? JSONSerialization.jsonObject(with: Data(frame.data.utf8)) as? [String: Any],
               let counters = payload["usage"] as? [String: Any] {
                usage = ChatUsage(fields: counters)
            }
            let snapshot = try ChatSnapshot(data: Data(frame.data.utf8))
            messages = snapshot.messages
            tools = snapshot.tools
            streamingMessageID = nil
            streamingMessageIndex = nil
            terminal = true
        case "cancel", "stream_end":
            if frame.event == "cancel" {
                notice = "服务端已取消本轮。"
                let message = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8)))
                    .flatMap { $0 as? [String: Any] }?["message"] as? String
                appendNotice(message == "interrupted" ? .interrupted : .cancelled,
                             "回复已停止。", id: frame.id)
            }
            if frame.event == "stream_end",
               let payload = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any] {
                // done 才带 messages，但不代表只有 done 能带计数：只发收尾帧的
                // 后端（网关 runs）没有快照可用，计数只能从这里拿。
                if let counters = payload["usage"] as? [String: Any] {
                    usage = ChatUsage(fields: counters)
                }
                if let status = payload["status"] as? String,
                   ["failed", "error"].contains(status.lowercased()) {
                    failure = "回复以 \(status) 结束。"
                    appendNotice(.failed, "回复以 \(status) 结束。", id: frame.id)
                } else if let status = payload["status"] as? String,
                          status.lowercased() == "work_limit" {
                    appendNotice(.workLimit, "本轮已到服务端预算上限，回复到此为止。", id: frame.id)
                } else if let status = payload["status"] as? String,
                          status.lowercased() == "unknown" {
                    // 服务端没给明确的 completed 布尔：不能宣称正常完成，
                    // 给一条中性提示，让用户知道这轮可能不完整。
                    appendNotice(.failed, "服务端未返回明确的完成状态，本轮可能不完整。", id: frame.id)
                }
            }
            // 任何终态都要清掉流式游标：网关用 stream_end 收尾，只清 done 会让
            // 下一轮的增量继续追加到上一轮那条消息上。
            streamingMessageID = nil
            streamingMessageIndex = nil
            terminal = true
        case "apperror", "error":
            let description = streamErrorDescription(frame.data)
            failure = description
            appendNotice(.failed, description, id: frame.id)
            streamingMessageID = nil
            streamingMessageIndex = nil
            terminal = true
        default: break
        }
        if let id = frame.id {
            lastEventID = id
            if !id.isEmpty { seenEventIDs.insert(id) }
        }
    }

    /// 终态帧只会进来一次（`terminal` 置位后 apply 直接短路），所以这里 append 天然去重；
    /// id 用帧 id 兜底，重连续传不会重复加行。
    private mutating func appendNotice(_ kind: ChatNoticeKind, _ message: String, id: String?) {
        notices.append(ChatNotice(id: id ?? "notice-\(kind.rawValue)-\(UUID().uuidString)",
                                  kind: kind, message: message,
                                  timestamp: Date().timeIntervalSince1970))
    }

    private mutating func appendStreamingText(_ text: String, at index: Int) {
        updatingStreamingTail = true
        defer { updatingStreamingTail = false }
        messages[index].content += text
    }

    /// 用户主动停止：不经 SSE 帧，由 `stop()` 直接调用。
    /// 同一轮只记一条，重复调用不会叠加。
    mutating func appendStopNotice() {
        guard !notices.contains(where: { $0.kind == .stopped }) else { return }
        appendNotice(.stopped, "你已停止本轮回复。", id: nil)
    }
}

/// 传输进度。放在这里而不是 `AttachmentModels.swift`：`HermesBackend` 与
/// `GatewayTransport` 的签名都要用它，而 `gatewaybackend` / `appstate`
/// 两个套件编译那两个协议却**不**编译 `AttachmentModels.swift`——放在附件文件里
/// 会让这两个套件报 `cannot find type 'AttachmentTransferProgress' in scope`。
struct AttachmentTransferProgress: Sendable, Equatable {
    let receivedBytes: Int
    let expectedBytes: Int?

    /// `nil` 表示不知道总量（chunked / 服务端未给 Content-Length）。
    /// 这时不要编百分比——编出来的进度条会在中途乱跳，比不显示更糟。
    var fraction: Double? {
        guard let expectedBytes else { return nil }
        guard expectedBytes > 0 else { return 1 }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

/// 上传请求体的字节级进度。
///
/// 上传此前完全没有进度：`URLSession.data(for:)` 只给最终 `Data`，
/// 于是界面只能写「正在上传…」。改用 `uploadTask` + 会话级 delegate 后
/// 能拿到 `didSendBodyData`，但 delegate 是整个 session 共享的，
/// 并发上传必须按 `taskIdentifier` 分发，否则两个附件的进度会互相覆盖。
final class AttachmentUploadProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: @Sendable (AttachmentTransferProgress) -> Void] = [:]
    private var expected: [Int: Int] = [:]

    func register(_ task: URLSessionTask, expectedBytes: Int,
                  handler: @escaping @Sendable (AttachmentTransferProgress) -> Void) {
        lock.lock()
        handlers[task.taskIdentifier] = handler
        expected[task.taskIdentifier] = expectedBytes
        lock.unlock()
    }

    func unregister(_ task: URLSessionTask) {
        lock.lock()
        handlers.removeValue(forKey: task.taskIdentifier)
        expected.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        lock.lock()
        let handler = handlers[task.taskIdentifier]
        let fallback = expected[task.taskIdentifier]
        lock.unlock()
        guard let handler else { return }
        // 系统给的 expected 有时是 -1（chunked）；退回请求体长度。
        let total = totalBytesExpectedToSend > 0 ? Int(totalBytesExpectedToSend) : fallback
        handler(AttachmentTransferProgress(receivedBytes: Int(totalBytesSent), expectedBytes: total))
    }
}

/// 带进度的一次上传。两个 backend 共用：WebUI 与网关的上传路由不同，
/// 但「发请求体、报字节进度、等响应」这一段完全一样。
enum AttachmentUploadTransport {
    /// Cancellation can arrive before the manually created URLSession task exists.
    private final class UploadCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var completion: UploadCompletion?
        func install(_ value: UploadCompletion) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            completion = value
            return true
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let value = completion
            lock.unlock()
            value?.cancel()
        }
    }

    /// - Returns: 响应体与 HTTP 状态。
    static func send(_ request: URLRequest,
                     session: URLSession,
                     relay: AttachmentUploadProgressRelay,
                     onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?)
        async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let expected = request.httpBody?.count ?? 0
        let cancellation = UploadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                if let onProgress, expected > 0 {
                    relay.register(task, expectedBytes: expected, handler: onProgress)
                }
                let box = UploadCompletion(relay: relay, task: task, continuation: continuation)
                task.delegate = box
                if cancellation.install(box) {
                    task.resume()
                } else {
                    box.cancel()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// 每个任务一个 box：`URLSessionTask.delegate` 是任务级的，
    /// 既拿到了字节回调，也不会与共享 session 的其他请求串扰。
    private final class UploadCompletion: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let relay: AttachmentUploadProgressRelay
        private let task: URLSessionDataTask
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var body = Data()
        private var response: HTTPURLResponse?
        private let lock = NSLock()

        init(relay: AttachmentUploadProgressRelay, task: URLSessionDataTask,
             continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            self.relay = relay
            self.task = task
            self.continuation = continuation
        }

        func cancel() {
            task.cancel()
            relay.unregister(task)
            take()?.resume(throwing: CancellationError())
        }

        // An upload's per-task delegate must refuse 30x before any Bearer/body redirect.
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        private func take() -> CheckedContinuation<(Data, HTTPURLResponse), Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = continuation
            continuation = nil
            return value
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            relay.urlSession(session, task: task, didSendBodyData: bytesSent,
                             totalBytesSent: totalBytesSent,
                             totalBytesExpectedToSend: totalBytesExpectedToSend)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            self.response = response as? HTTPURLResponse
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); body.append(data); lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            relay.unregister(task)
            let http: HTTPURLResponse?
            let payload: Data
            lock.lock(); http = response; payload = body; lock.unlock()
            guard let continuation = take() else { return }
            if let error {
                continuation.resume(throwing: error)
            } else if let http {
                continuation.resume(returning: (payload, http))
            } else {
                // 用 URLError 而不是附件层的错误类型：ChatCore 是零依赖基座，
                // 被 core/sessionops 等不编译附件模型的套件共享，引用
                // `AttachmentError` 会让那些套件直接编译失败。
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
