import Foundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { print("FAIL: \(label)"); exit(1) }
}
let cal = Calendar(identifier: .gregorian)
func msg(_ id: Int, _ role: String = "assistant", _ stamp: Double? = 1700000000) -> ChatMessage {
    ChatMessage(id: "m\(id)", role: role, content: "正文 \(id)", timestamp: stamp, sourceIndex: id)
}
// The integration chooses a pure-prepend model like MessengerDemo.swift.
// This is OUR invariant, not an assertion that the library cannot update cells.
// build41 起会插入跨天/间隔分隔行；分隔行随窗口边界变化，属于展示装饰，
// 因此前置不变式只在「消息 + 工具」内容行上成立。
func contentRows(_ rows: [ChatRow]) -> [ChatRow] {
    rows.filter {
        switch $0.kind {
        case .message, .tools, .process: return true
        case .day, .time, .notice: return false
        }
    }
}
func verifyPrepend(_ old: [ChatMessage], _ full: [ChatMessage], label: String) {
    let a = contentRows(ChatTimeline.build(messages: old, tools: [], calendar: cal))
    let b = contentRows(ChatTimeline.build(messages: full, tools: [], calendar: cal))
    check(Array(b.suffix(a.count)) == a, "\(label): existing rows remain an exact suffix")
    check(b.count == full.count, "\(label): no synthetic content rows")
    check(Set(b.map(\.id)).count == b.count, "\(label): unique row IDs")
}
verifyPrepend([msg(2), msg(3)], [msg(0), msg(1), msg(2), msg(3)], label: "same speaker same second")
verifyPrepend([msg(2, "user"), msg(3)], [msg(0), msg(1), msg(2, "user"), msg(3)], label: "speaker change")
verifyPrepend([msg(2, "assistant", nil)], [msg(0, "assistant", nil), msg(2, "assistant", nil)], label: "no timestamp")
verifyPrepend([msg(2, "user", 1700100000)], [msg(0), msg(2, "user", 1700100000)], label: "cross day")
var conversation: [ChatMessage] = []
for i in 0..<240 { conversation.append(msg(i, i % 3 == 0 ? "user" : "assistant", 1700000000 + Double(i) * 31)) }
for start in stride(from: 230, through: 10, by: -10) {
    verifyPrepend(Array(conversation[start...]), Array(conversation[(start-10)...]), label: "page \(start)")
}
let snapshot = try ChatSnapshot(data: Data("""
{"session":{"session_id":"s","_messages_offset":40,"messages":[
 {"role":"user","content":"查天气","timestamp":1700000000},
 {"role":"assistant","content":"我来查","timestamp":1700000000,"tool_calls":[{"id":"t1","function":{"name":"search","arguments":"{}"}}]},
 {"role":"tool","tool_call_id":"t1","content":"晴"},
 {"role":"assistant","content":"今天晴","timestamp":1700000000}
]}}
""".utf8))
check(Set(snapshot.messages.map(\.id)).count == 3, "same timestamp messages are distinct before display/merge")
check(snapshot.messages.map(\.sourceIndex) == [40,41,43], "raw source indices include tool results")
check(snapshot.tools.first?.afterMessageID == snapshot.messages[1].id, "tool anchor survives parsing")
let rows = ChatTimeline.build(messages: snapshot.messages, tools: snapshot.tools, calendar: cal)
check(rows.map(\.id).count == 4, "three messages and one anchored tool run")
check({ if case .tools = rows[2].kind { return true }; return false }(), "tools remain between commentary and final")
let texts = rows.compactMap { row -> String? in if case .message(let m) = row.kind { return m.content }; return nil }
check(texts == ["查天气","我来查","今天晴"], "message order preserved")
check(!rows[1].showsCopy && rows[3].showsCopy, "only last assistant segment exposes reply copy")
check(ChatTimeline.replyText(endingAt: snapshot.messages[2].id, messages: snapshot.messages) == "我来查\n\n今天晴", "reply copy includes all loaded segments, not only final segment")
let oldRows = ChatTimeline.build(messages: Array(snapshot.messages.suffix(2)), tools: snapshot.tools)
check(Array(rows.suffix(oldRows.count)) == oldRows, "tools preserve pure prepend when earlier user is loaded")
var live = ChatTranscript()
try live.apply(SSEFrame(event: "token", data: "{\"text\":\"查\"}", id: "1"))
try live.apply(SSEFrame(event: "tool", data: "{\"tid\":\"t\",\"name\":\"search\"}", id: "2"))
try live.apply(SSEFrame(event: "token", data: "{\"text\":\"结果\"}", id: "3"))
check(live.messages.count == 2, "live text after a tool is a separate segment")
check(live.tools[0].afterMessageID == live.messages[0].id, "live tool stays anchored")
let runningTool = ChatTool(id: "t", name: "read", args: "", result: "", done: false, isError: false, afterMessageID: "m0")
let pending = ChatTimeline.build(messages: [msg(0)], tools: [runningTool])
check(!pending[0].showsCopy, "no final copy while tool run follows")
let deferred = ChatTimeline.build(messages: [msg(1)], tools: [runningTool])
check(deferred.map(\.id) == ["m-m1"], "explicit anchor outside loaded window defers its tool")
let loaded = ChatTimeline.build(messages: [msg(0), msg(1)], tools: [runningTool])
check(Array(loaded.suffix(deferred.count)) == deferred, "loading tool anchor prepends without changing existing B")
check(loaded.map(\.id) == ["m-m0", "tools-t", "m-m1"], "deferred tool appears immediately after newly loaded anchor")
var unanchoredTool = runningTool
unanchoredTool.afterMessageID = nil
let orphan = ChatTimeline.build(messages: [msg(1)], tools: [unanchoredTool])
check(orphan.map(\.id) == ["m-m1", "orphan-tools-t"], "nil-anchor tools remain visible at tail")
check(ChatTimeline.build(messages: [], tools: [runningTool]).isEmpty, "no loaded anchor means no anchored tool row")
check(ChatTimeline.build(messages: [], tools: [unanchoredTool]).count == 1, "nil-anchor tools remain visible even without messages")
let sessionLevelJSON = #"{"session":{"session_id":"sl","messages":[{"role":"user","content":"问题"},{"role":"assistant","content":"最终回答"}],"tool_calls":[{"id":"k9","name":"terminal","args":"{}","result":"ok","done":true}]}}"#
let sessionLevel = try ChatSnapshot(data: Data(sessionLevelJSON.utf8))
check(sessionLevel.tools.first?.afterMessageID == nil,
      "unattributed session-level tool_calls stay unanchored, never invented from the window")
let sessionLevelRows = ChatTimeline.build(messages: sessionLevel.messages, tools: sessionLevel.tools)
check(sessionLevelRows.map(\.id).last == "orphan-tools-k9",
      "unattributed tools render at the tail rather than being pinned to a guessed anchor")

/* A flat tool_call can be located only when the same tool_call_id appears in
   an actual result row in the loaded history window. Do not invent a turn. */
let provenJSON = #"""
{"session":{"session_id":"proven","messages":[
 {"role":"user","content":"检查代码"},
 {"role":"tool","tool_call_id":"k1","content":"检查成功"},
 {"role":"assistant","content":"发现一处问题"}
],"tool_calls":[{"id":"k1","name":"terminal","args":"{}","result":"检查成功","done":true}]}}
"""#
let provenSnapshot = try ChatSnapshot(data: Data(provenJSON.utf8))
check(provenSnapshot.messages.count == 2, "tool result rows never become chat messages")
check(provenSnapshot.tools.count == 1, "matching tool result and session call merge by tool id")
check(provenSnapshot.tools.first?.afterMessageID == provenSnapshot.messages[0].id,
      "a matching tool result proves the preceding visible user anchor")
let provenRows = ChatTimeline.build(messages: provenSnapshot.messages, tools: provenSnapshot.tools)
check(provenRows.map(\.id).last != "orphan-tools-k1",
      "proven session tool renders at its anchor, not below the completed reply")

// A visible assistant commentary segment may precede the tool result. The
// proof is the preceding visible message, not necessarily the user question.
let commentaryJSON = #"""
{"session":{"session_id":"commentary","messages":[
 {"role":"user","content":"分析"},
 {"role":"assistant","content":"正在执行检查"},
 {"role":"tool","tool_call_id":"k2","content":"ok"},
 {"role":"assistant","content":"检查完成"}
],"tool_calls":[{"id":"k2","name":"terminal","done":true}]}}
"""#
let commentarySnapshot = try ChatSnapshot(data: Data(commentaryJSON.utf8))
check(commentarySnapshot.tools.first?.afterMessageID == commentarySnapshot.messages[1].id,
      "tool results after assistant commentary anchor after that visible segment")
check(ChatTimeline.build(messages: commentarySnapshot.messages, tools: commentarySnapshot.tools)
      .map(\.id).last != "orphan-tools-k2",
      "intermediate commentary does not force the tool card below the final reply")

let mismatchJSON = #"""
{"session":{"session_id":"mismatch","messages":[
 {"role":"user","content":"问题"},
 {"role":"tool","tool_call_id":"other-id","content":"ok"},
 {"role":"assistant","content":"回答"}
],"tool_calls":[{"id":"k9","name":"terminal","done":true}]}}
"""#
let mismatchSnapshot = try ChatSnapshot(data: Data(mismatchJSON.utf8))
check(mismatchSnapshot.tools.first(where: { $0.id == "k9" })?.afterMessageID == nil,
      "a different tool_call_id never proves ownership of a session-level call")

let pageStartJSON = #"""
{"session":{"session_id":"page","_messages_offset":40,"messages":[
 {"role":"tool","tool_call_id":"k3","content":"result from earlier page"},
 {"role":"assistant","content":"回答"}
],"tool_calls":[{"id":"k3","name":"terminal","done":true}]}}
"""#
let pageStartSnapshot = try ChatSnapshot(data: Data(pageStartJSON.utf8))
check(pageStartSnapshot.tools.first?.afterMessageID == nil,
      "a tool result before the first visible message cannot anchor outside its page")

let repeatedIDJSON = #"""
{"session":{"session_id":"duplicate","messages":[
 {"role":"user","content":"第一轮"},
 {"role":"tool","tool_call_id":"k4","content":"first"},
 {"role":"assistant","content":"中间回复"},
 {"role":"tool","tool_call_id":"k4","content":"second"},
 {"role":"assistant","content":"最终回复"}
],"tool_calls":[{"id":"k4","name":"terminal","done":true}]}}
"""#
let repeatedID = try ChatSnapshot(data: Data(repeatedIDJSON.utf8))
check(repeatedID.tools.first?.afterMessageID == nil,
      "a repeated tool id with conflicting visible anchors stays unanchored")

// 流式工具必须锚在本轮 user 消息上，不能锚在已经落地的回答正文上。
// 否则一轮写完时时间线顺序会变成「回答 → 工具行」，底部多出一条
// 「已完成 N 项操作」，读起来像回复的尾巴。
var anchorProbe = ChatTranscript()
anchorProbe.messages = [ChatMessage(id: "u1", role: "user", content: "问题", timestamp: 1)]
try anchorProbe.apply(SSEFrame(event: "token", data: "{\"text\":\"回答正文\"}", id: "a1"))
try anchorProbe.apply(SSEFrame(event: "tool", data: "{\"tid\":\"k1\",\"name\":\"terminal\"}", id: "a2"))
check(anchorProbe.tools.first?.afterMessageID == "u1",
      "streaming tool anchors to the turn's user message, not the reply body")
let anchoredRows = ChatTimeline.build(messages: anchorProbe.messages, tools: anchorProbe.tools)
check(anchoredRows.map(\.id).first == "m-u1" && anchoredRows.map(\.id).last != "tools-k1",
      "tool row never trails the finished reply")
// Parse the same raw rows from overlapping pages: identity includes absolute offset,
// never a traversal-order suffix. Do not pretend a timestamp alone is unique.
func parse(_ offset: Int, _ values: [String]) throws -> ChatSnapshot {
    let messages = values.map { ["role":"assistant", "content":$0, "timestamp":1] as [String: Any] }
    let root: [String: Any] = ["session": ["session_id":"s", "_messages_offset":offset, "messages":messages]]
    return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: root))
}
let latest = try parse(10, ["B","C"])
let expanded = try parse(9, ["A","B","C"])
check(latest.messages.map(\.id) == Array(expanded.messages.suffix(2)).map(\.id), "timestamp fallback IDs survive overlapping windows")
check(Set(expanded.messages.map(\.id)).count == 3, "timestamp collisions never erase messages at model merge")
check(ChatPresentation.isCollapsible(String(repeating: "字", count: 3000)), "long replies can collapse")
check(!ChatPresentation.isCollapsible("短"), "short replies do not collapse")
check(ChatPresentation.collapsedPreview(String(repeating:"字",count:3000)).count == 2401, "preview bound")
let segmentedReply = [msg(301, "user"), msg(302), msg(303), msg(304, "user"), msg(305)]
check(ChatTimeline.replyRange(containing: "m303", messages: segmentedReply) == 1...2,
      "any assistant continuation resolves the complete reply")
check(ChatTimeline.replyText(endingAt: "m302", messages: segmentedReply) == "正文 302\n\n正文 303",
      "copying from an earlier segment still returns the complete reply")
check(ChatTimeline.replyAnchor(for: "m302", messages: segmentedReply) == "m303",
      "every segment in a reply resolves to one stable reader anchor")
check(ChatPresentation.replyActionsVisible(isStreaming: false, showsCopy: false,
                                           isCollapsible: true),
      "a non-final long segment keeps its reader and fold actions")
check(!ChatPresentation.replyActionsVisible(isStreaming: true, showsCopy: true,
                                            isCollapsible: false),
      "streaming rows never expose completed-message actions")
let timestampedSegments = [
    msg(311, "user"), msg(312), msg(313), msg(314, "assistant", 1700000600),
    msg(315, "user"), msg(316),
]
check(ChatTimeline.replyRange(containing: "m313", messages: timestampedSegments) == 1...3,
      "a continuation stays in one reply even when the next segment starts a new time group")

// Build48: tools must not turn blank SSE deltas into avatar-only messages.
var whitespaceLive = ChatTranscript()
whitespaceLive.messages = [msg(100, "user")]
func delta(_ text: String, id: String) throws -> SSEFrame {
    SSEFrame(event: "token", data: String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self), id: id)
}
try whitespaceLive.apply(delta("\n  ", id: "blank-1"))
check(whitespaceLive.messages.count == 1, "blank prefix does not create a published assistant row")
try whitespaceLive.apply(SSEFrame(event: "tool", data: #"{"tid":"a","name":"terminal"}"#, id: "tool-a"))
try whitespaceLive.apply(delta("\n", id: "blank-2"))
try whitespaceLive.apply(SSEFrame(event: "tool", data: #"{"tid":"b","name":"terminal"}"#, id: "tool-b"))
check(whitespaceLive.messages.count == 1, "multiple whitespace/tool rounds produce no blank message blocks")
check(whitespaceLive.tools.map(\.afterMessageID) == ["m100", "m100"], "consecutive tool steps share the real preceding message anchor")
let progressRows = ChatTimeline.build(messages: whitespaceLive.messages, tools: whitespaceLive.tools)
check(progressRows.count == 2, "user plus a single combined tool progress row")
check({ if case .tools(let t) = progressRows.last?.kind { return t.map(\.id) == ["a", "b"] }; return false }(), "all tool details retained in execution order")
try whitespaceLive.apply(delta("\n    ", id: "indent"))
try whitespaceLive.apply(delta("code", id: "text"))
check(whitespaceLive.messages.last?.content == "\n    code", "leading newlines and code indentation survive buffering")
try whitespaceLive.apply(delta("\n", id: "after-text"))
check(whitespaceLive.messages.last?.content == "\n    code\n", "whitespace inside a real message is preserved")
check(whitespaceLive.tools.map(\.afterMessageID) == ["m100", "m100"], "new response text cannot relocate existing tools")

var blank1 = msg(102); blank1.content = "\n "
var blank2 = msg(103); blank2.content = "\t"
var tool1 = runningTool; tool1.id = "legacy-a"; tool1.afterMessageID = blank1.id
var tool2 = runningTool; tool2.id = "legacy-b"; tool2.afterMessageID = blank2.id
let legacy = ChatTimeline.build(messages: [msg(101, "user"), blank1, blank2, msg(104)], tools: [tool1, tool2])
check(legacy.map(\.id) == ["m-m101", "tools-legacy-a", "m-m104"], "legacy whitespace anchors hide without losing either tool")
check({ if case .tools(let t) = legacy[1].kind { return t.count == 2 }; return false }(), "legacy consecutive blank tool steps coalesce")
var imageOnly = blank1; imageOnly.attachmentPaths = ["/opaque/photo.png"]
check(ChatTimeline.build(messages: [imageOnly], tools: []).count == 1, "attachment-only assistant rows remain visible")
check(rows[1].showsSender && !rows[3].showsSender && rows[3].isContinuation, "one assistant identity across commentary/tool/final")
let missingTimes = ChatTimeline.build(messages: [msg(201, "assistant", nil), msg(202, "assistant", nil), msg(203, "user", nil), msg(204, "assistant", nil)], tools: [])
check(missingTimes.map(\.showsSender) == [true, false, true, true], "missing timestamps do not repeat assistant identity; a user starts a new turn")
var boundary = missingTimes[1]
boundary.showsSender = true; boundary.isContinuation = false
check(boundary == missingTimes[1], "message identity remains stable at a paging boundary")
check(ChatRowItem(row: boundary, isStreaming: false) != ChatRowItem(row: missingTimes[1], isStreaming: false), "host snapshots remeasure changed sender presentation after prepend")
check(ChatTimeline.replyText(endingAt: "m104", messages: [msg(101, "user"), blank1, blank2, msg(104)]) == "正文 104", "reply copy excludes ghost whitespace segments")
let historicalTools = try ChatSnapshot(data: Data(#"{"session":{"session_id":"tools","messages":[{"role":"user","content":"question"},{"role":"assistant","content":"\n","tool_calls":[{"id":"a","function":{"name":"terminal","arguments":"{}"}}]},{"role":"tool","tool_call_id":"a","content":"ok"},{"role":"assistant","content":" ","tool_calls":[{"id":"b","function":{"name":"terminal","arguments":"{}"}}]},{"role":"tool","tool_call_id":"b","content":"ok"},{"role":"assistant","content":"answer"}]}}"#.utf8))
let historicalRows = ChatTimeline.build(messages: historicalTools.messages, tools: historicalTools.tools)
check(historicalRows.count == 3, "reloaded history agrees with live compact tool structure")
check(historicalTools.tools.count == 2 && historicalTools.tools.allSatisfy(\.done), "history keeps both completed tool results")

// Reply sharing and process copying are pure transcript projections.
var firstProcess = msg(1041)
firstProcess.content = "先检查"
var blankProcess = msg(1042)
blankProcess.content = "\u{200B}"
var finalProcess = msg(1043)
finalProcess.content = "最终回答"
let processCopy = ChatTimeline.replyProcessText(
    endingAt: finalProcess.id,
    messages: [msg(1040, "user"), firstProcess, blankProcess, finalProcess])
check(processCopy == "先检查\n\n最终回答",
      "copy process includes visible assistant segments in order and excludes the user prompt")
check(ChatTimeline.replyProcessText(
    endingAt: msg(1044, "user").id,
    messages: [msg(1044, "user")]) == "",
      "copy process never treats a user message as a reply")

var firstQuestion = msg(1050, "user")
firstQuestion.content = "第一问"
var hiddenQuestion = msg(1051, "user")
hiddenQuestion.content = "\u{200B}"
var attachmentQuestion = msg(1052, "user")
attachmentQuestion.content = ""
attachmentQuestion.attachmentPaths = ["/attachments/photo.jpg"]
var lastQuestion = msg(1053, "user")
lastQuestion.content = "最后一问"
let navigation = ChatTimeline.navigationNodes(
    messages: [firstQuestion, msg(1054), hiddenQuestion,
               attachmentQuestion, msg(1055), lastQuestion],
    limit: 2)
check(navigation.map(\.messageID) == [attachmentQuestion.id, lastQuestion.id],
      "message navigation keeps only visible user rows, preserves order and applies its cap")
check(navigation[0].preview == "附件消息",
      "attachment-only navigation rows receive an explicit preview")

var navigationQuestion = msg(1061, "user")
navigationQuestion.content = "带工具的问题"
var navigationAnswer = msg(1062)
navigationAnswer.content = "最终回答"
var navigationTool = ChatTool(id: "nav-tool", name: "terminal", args: "", result: "",
                              done: true, isError: false, afterMessageID: navigationAnswer.id)
let navigationNotice = ChatNotice(id: "nav-notice", kind: .failed,
                                  message: "执行失败", timestamp: 1700000001)
let landmarks = ChatTimeline.navigationNodes(
    messages: [navigationQuestion, navigationAnswer],
    tools: [navigationTool], notices: [navigationNotice], limit: 300)
check(landmarks.contains { $0.kind == .question && $0.messageID == navigationQuestion.id },
      "rich navigation keeps the user question")
check(landmarks.contains { $0.kind == .answer && $0.messageID == navigationAnswer.id },
      "rich navigation includes visible assistant answers")
check(landmarks.contains { $0.kind == .tools && $0.preview.contains("terminal") },
      "rich navigation includes an anchored tool group")
check(landmarks.contains { $0.kind == .terminalNotice && $0.preview == "执行失败" },
      "rich navigation includes terminal errors")

// Build121 streaming fast path: a content-only tail update changes exactly one
// row and preserves all precomputed presentation metadata.
let stableTail = ChatTimeline.build(
    messages: [msg(1059, "user"), msg(1060)],
    tools: []).map { ChatRowItem(row: $0, isStreaming: $0.id == "m-m1060") }
var changedTailMessage = msg(1060)
changedTailMessage.content = "增长后的正文"
let fastTail = stableTail.map {
    $0.id == "m-m1060" ? $0.replacingMessage(changedTailMessage) : $0
}
check(fastTail.map(\.id) == stableTail.map(\.id),
      "tail replacement preserves row identities")
check({ if case .message(let value) = fastTail.last?.row.kind {
    return value.content == "增长后的正文"
}; return false }(), "tail replacement updates message content")
check(fastTail.last?.row.showsCopy == stableTail.last?.row.showsCopy
        && fastTail.last?.isStreaming == true,
      "tail replacement preserves copy and streaming presentation")

// Build122 tool fast path: payload changes update the same process row.
var fastChangingTool = runningTool
fastChangingTool.id = "fast-tool"
fastChangingTool.afterMessageID = "m1070"
var toolRows = ChatTimeline.build(messages: [msg(1069, "user"), msg(1070)],
                                  tools: [fastChangingTool])
    .map { ChatRowItem(row: $0, isStreaming: false,
                       toolsAreLive: $0.id.hasPrefix("tools-")) }
var completedTool = fastChangingTool
completedTool.done = true
completedTool.result = "ok"
let toolIndex = toolRows.firstIndex(where: {
    if case .tools = $0.row.kind { return true }; return false
})!
toolRows[toolIndex] = toolRows[toolIndex].replacingTools(
    [completedTool], toolsAreLive: false)!
check(toolRows.map(\.id) == ChatTimeline.build(
    messages: [msg(1069, "user"), msg(1070)], tools: [completedTool]).map(\.id),
      "tool replacement preserves row identities")
check({ if case .tools(let tools) = toolRows[toolIndex].row.kind {
    return tools == [completedTool]
}; return false }(), "tool replacement updates completion and result in place")
check(!toolRows[toolIndex].toolsAreLive,
      "a completed final tool clears liveness without changing row identity")

// Unicode-only invisibility must not create a Hermes header. Keep punctuation,
// emoji and combining marks renderable; an attachment-only row stays visible.
check(!ChatRenderableText.hasVisibleContent("\u{200B}\u{200C}\u{200D}\u{FEFF}\u{0000}\t\n"), "zero-width, BOM and controls are invisible")
check(ChatRenderableText.hasVisibleContent("。"), "punctuation remains visible")
check(ChatRenderableText.hasVisibleContent("👩‍💻"), "emoji remains visible")
check(ChatRenderableText.hasVisibleContent("e\u{301}"), "combining text remains visible")
check(ChatRenderableText.hasVisibleContent("**"), "Markdown punctuation remains visible")
var invisibleAssistant = msg(350)
invisibleAssistant.content = "\u{200B}\u{FEFF}\u{200C}"
var anchoredTool = runningTool; anchoredTool.id = "after-invisible"; anchoredTool.afterMessageID = invisibleAssistant.id
let invisibleRows = ChatTimeline.build(messages: [msg(349, "user"), invisibleAssistant, msg(351)],
                                      tools: [anchoredTool])
check(invisibleRows.map(\.id) == ["m-m349", "tools-after-invisible", "m-m351"], "invisible assistant is omitted and its tool is re-anchored")
check(invisibleRows.filter { row in if case .message = row.kind { return true }; return false }.compactMap(\.turnID) == ["m349", "m349"],
      "user and visible assistant share one stable turn identity")

// Consecutive tool anchors in one turn become one process row even if a
// visually empty assistant segment sits between them. A real assistant segment
// splits the row, and a new user message always starts a new turn.
var blankBetweenTools = msg(361)
blankBetweenTools.content = "\u{200B}"
var firstSameTurnTool = runningTool; firstSameTurnTool.id = "turn-a"; firstSameTurnTool.afterMessageID = "m362"
var secondSameTurnTool = runningTool; secondSameTurnTool.id = "turn-b"; secondSameTurnTool.afterMessageID = blankBetweenTools.id
let sameTurnToolRows = ChatTimeline.build(messages: [msg(360, "user"), msg(362), blankBetweenTools, msg(363)], tools: [firstSameTurnTool, secondSameTurnTool])
let sameTurnGroups = sameTurnToolRows.compactMap { row -> [String]? in
    if case .tools(let tools) = row.kind { return tools.map(\.id) }
    return nil
}
check(sameTurnGroups == [["turn-a", "turn-b"]], "consecutive tool anchors coalesce once per turn")
let sameTurnAssistantHeaders = sameTurnToolRows.filter { row in
    if case .message(let message) = row.kind {
        return message.role == "assistant" && row.showsSender
    }
    return false
}
check(sameTurnAssistantHeaders.count == 1, "one user turn displays one assistant header")

var visibleBetween = msg(373)
var thirdTool = runningTool; thirdTool.id = "turn-c"; thirdTool.afterMessageID = visibleBetween.id
var firstSplitTool = runningTool; firstSplitTool.id = "turn-a"; firstSplitTool.afterMessageID = "m371"
let splitToolRows = ChatTimeline.build(messages: [msg(370, "user"), msg(371), msg(372), visibleBetween],
                                      tools: [firstSplitTool, thirdTool])
let splitGroups = splitToolRows.compactMap { row -> [String]? in
    if case .tools(let tools) = row.kind { return tools.map(\.id) }
    return nil
}
check(splitGroups == [["turn-a"], ["turn-c"]], "visible assistant text splits tool groups")
check(splitGroups.flatMap { $0 }.count == 2, "tool failure and status detail is not dropped by coalescing")

// 终态通知行（对齐 Conduit 的 notice item）：cancel/失败/预算上限作为行渲染，而不是藏在字符串里。
var ended = ChatTranscript()
try ended.apply(SSEFrame(event: "cancel", data: #"{"message":"cancelled"}"#, id: "n1"))
check(ended.notices.count == 1 && ended.notices[0].kind == .cancelled, "cancel produces one cancelled notice")
let noticeRows = ChatTimeline.build(messages: [msg(500)], tools: [], notices: ended.notices)
check(noticeRows.map(\.id) == ["m-m500", "notice-n1"], "terminal notice projects after the last message")
check(contentRows(noticeRows).map(\.id) == ["m-m500"], "notice rows are not content rows")

// P0-14：通知行参与 showsCopy 判定。之前 notice 在 copy 循环之后才 append，
// `case .some(.notice)` 是不可达死代码，终态回复拿不到复制入口。
check(noticeRows.first?.showsCopy == true, "a reply ending in a terminal notice still exposes reply copy")
let noNoticeRows = ChatTimeline.build(messages: [msg(500)], tools: [], notices: [])
check(noNoticeRows.first?.showsCopy == true, "the same reply without a notice also exposes copy (baseline)")

// 5 种终态都要能落成通知行并保留复制入口（原先只有 .cancelled 有 1 条断言）。
for kind in [ChatNoticeKind.cancelled, .failed, .interrupted, .workLimit, .stopped] {
    let notice = ChatNotice(id: "n-\(kind.rawValue)", kind: kind, message: "x")
    let projected = ChatTimeline.build(messages: [msg(600)], tools: [], notices: [notice])
    check(projected.map(\.id) == ["m-m600", "notice-n-\(kind.rawValue)"],
          "\(kind.rawValue) notice projects as a trailing row")
    check(projected.first?.showsCopy == true,
          "\(kind.rawValue) notice keeps the reply-copy action")
}

// 通知行位于两轮之间时，只应给上一轮收尾，不能把下一轮也标记成已结束。
let betweenRows = ChatTimeline.build(
    messages: [msg(700), msg(701, "user")],
    tools: [],
    notices: [ChatNotice(id: "n-between", kind: .failed, message: "x")])
check(betweenRows.first?.showsCopy == true,
      "a mid-stream notice still closes the reply above it")
// 位置也是契约：通知行一律 append 在整个消息列表之后，不会插进两轮之间
// 把消息顺序切开（否则分页 prepend 的 suffix 不变量会随轮次位置漂移）。
check(betweenRows.map(\.id) == ["m-m700", "m-m701", "notice-n-between"],
      "a mid-stream notice projects after every message row, never between turns")
check(betweenRows.last.map(\.id) == "notice-n-between" && contentRows(betweenRows).count == 2,
      "the notice row is the tail and stays out of the content rows")

// 收尾只给紧邻它的那一段：同一轮里的前一段不能因为后面有通知行也拿到复制入口。
func messageCopies(_ rows: [ChatRow]) -> [Bool] {
    rows.compactMap { row -> Bool? in
        if case .message = row.kind { return row.showsCopy }
        return nil
    }
}
let multiSegment = ChatTimeline.build(
    messages: [msg(710), msg(711)],
    tools: [],
    notices: [ChatNotice(id: "n-tail", kind: .workLimit, message: "x")])
check(messageCopies(multiSegment) == [false, true],
      "a trailing notice closes only the last assistant segment")

// 带通知行时的 prepend 不变式：加载更早一页只能前置，旧行（含通知行）必须仍是精确后缀。
func rowsWithNotice(_ messages: [ChatMessage]) -> [ChatRow] {
    ChatTimeline.build(messages: messages, tools: [],
                       notices: [ChatNotice(id: "n-prepend", kind: .cancelled, message: "x")])
}
let noticeOld = rowsWithNotice([msg(721)])
let noticeFull = rowsWithNotice([msg(719), msg(720), msg(721)])
check(Array(noticeFull.suffix(noticeOld.count)) == noticeOld,
      "notices keep the pure-prepend invariant when an earlier page loads")
check(noticeFull.last.map(\.id) == "notice-n-prepend",
      "the notice row stays the tail after prepend")
check(Set(noticeFull.map(\.id)).count == noticeFull.count,
      "notice row ids never collide with message row ids")

// A-01：历史轮次以「已完成工具」结尾时也应有复制入口（不能一律当作工具还在跑）。
let doneTool = ChatTool(id: "t-done", name: "read", args: "", result: "ok", done: true,
                        isError: false, afterMessageID: "m800")
let histToolRows = ChatTimeline.build(messages: [msg(800)], tools: [doneTool])
check(histToolRows.first?.showsCopy == true,
      "a reply ending in a completed tool run still exposes reply copy")
let liveTool = ChatTool(id: "t-live", name: "read", args: "", result: "", done: false,
                        isError: false, afterMessageID: "m801")
let liveToolRows = ChatTimeline.build(messages: [msg(801)], tools: [liveTool])
check(liveToolRows.first?.showsCopy == false,
      "a reply ending in a running tool run exposes no copy")

// Earlier assistant segments and their tools become one process disclosure;
// the final answer remains a normal message with its original id.
let processMessages = [msg(900, "user"), msg(901), msg(902), msg(903),
                       msg(904, "user"), msg(905)]
let processTools = [
    ChatTool(id: "p1", name: "search", args: "{}", result: "ok", done: true,
             isError: false, afterMessageID: "m901"),
    ChatTool(id: "p2", name: "read", args: "{}", result: "ok", done: true,
             isError: false, afterMessageID: "m902")
]
let processRows = ChatTimeline.build(messages: processMessages, tools: processTools,
                                     completeTurnIDs: ["m900"])
check(processRows.map(\.id) == ["m-m900", "process-m901", "m-m903",
                                "m-m904", "m-m905"],
      "intermediate assistant segments become one process row before the final answer")
check(processRows.compactMap { row -> [String]? in
    if case .process(let group) = row.kind { return group.tools.map(\.id) }
    return nil
} == [["p1", "p2"]], "process row retains tool order and both message anchors")
check(processRows.compactMap { row -> [String]? in
    if case .process(let group) = row.kind { return group.messages.map(\.id) }
    return nil
} == [["m901", "m902"]], "process row retains every intermediate assistant body")
var finalAnchoredTool = processTools[1]
finalAnchoredTool.id = "final-anchor"
finalAnchoredTool.afterMessageID = "m903"
let oneProcessRows = ChatTimeline.build(
    messages: [msg(900, "user"), msg(901), msg(902), msg(903)],
    tools: [processTools[0], finalAnchoredTool], completeTurnIDs: ["m900"])
let oneProcessGroups = oneProcessRows.compactMap { row -> ChatProcessGroup? in
    if case .process(let group) = row.kind { return group }
    return nil
}
check(oneProcessGroups.count == 1, "one user turn emits one process summary")
check(oneProcessGroups.first?.tools.map(\.id) == ["p1", "final-anchor"],
      "the single process summary retains final-anchor tool details")
check(!oneProcessRows.contains(where: {
    if case .tools = $0.kind { return true }
    return false
}), "tool details are not duplicated outside the process summary")
let blankProcessAnchor = ChatMessage(id: "blank-process", role: "assistant", content: "",
                                     timestamp: 1700000000, sourceIndex: 902)
var blankAnchoredTool = processTools[1]
blankAnchoredTool.afterMessageID = blankProcessAnchor.id
let processWithBlankAnchor = ChatTimeline.build(
    messages: [msg(900, "user"), msg(901), msg(902), blankProcessAnchor, msg(903)],
    tools: [processTools[0], blankAnchoredTool], completeTurnIDs: ["m900"])
check(processWithBlankAnchor.compactMap { row -> [String]? in
    if case .process(let group) = row.kind { return group.tools.map(\.id) }
    return nil
} == [["p1", "p2"]], "process row keeps tools anchored through an invisible body")
check(processRows.first(where: {
    if case .message(let message) = $0.kind { return message.id == "m903" }
    return false
}) != nil, "final assistant message keeps its original id")
let oneSegment = ChatTimeline.build(messages: [msg(910, "user"), msg(911)], tools: processTools)
check(oneSegment.map(\.id) == ["m-m910", "m-m911"],
      "a single assistant segment stays a normal message")
check(oneSegment.last?.showsCopy == true,
      "single-segment reply still owns its final copy action")
let openTail = ChatTimeline.build(messages: [msg(920, "user"), msg(921), msg(922)],
                                  tools: processTools, running: true)
check(openTail.map(\.id) == ["m-m920", "process-m921", "m-m922"],
      "a live reply folds completed commentary while its growing tail stays visible")
check(openTail.compactMap { row -> [String]? in
    if case .process(let group) = row.kind { return group.messages.map(\.id) }
    return nil
} == [["m921"]], "live commentary remains available in the process disclosure")
var liveToolDuringFold = ChatTool(
    id: "live-fold-tool", name: "terminal", args: "{}", result: "",
    done: false, isError: false, afterMessageID: "m921")
let liveToolFold = ChatTimeline.build(
    messages: [msg(920, "user"), msg(921), msg(922)],
    tools: [liveToolDuringFold], running: true)
let liveFoldGroup = liveToolFold.compactMap { row -> ChatProcessGroup? in
    if case .process(let group) = row.kind { return group }
    return nil
}.first
check(liveFoldGroup?.tools.map(\.id) == ["live-fold-tool"],
      "a live process disclosure keeps its running tool anchored")
liveToolDuringFold.done = true
liveToolDuringFold.result = "ok"
let completedLiveFold = ChatTimeline.build(
    messages: [msg(920, "user"), msg(921), msg(922)],
    tools: [liveToolDuringFold], running: true)
check(completedLiveFold.map(\.id) == liveToolFold.map(\.id),
      "tool completion updates the existing process row without changing row identity")
var siblingFoldTool = liveToolDuringFold
siblingFoldTool.id = "live-fold-sibling"
siblingFoldTool.done = true
siblingFoldTool.result = "already done"
var processItems = ChatTimeline.build(
    messages: [msg(920, "user"), msg(921), msg(922)],
    tools: [siblingFoldTool, liveToolDuringFold], running: true)
    .map { ChatRowItem(row: $0, isStreaming: false,
                       toolsAreLive: $0.id == "process-m921") }
let processIndex = processItems.firstIndex(where: { $0.id == "process-m921" })!
var completedFirstOnly = siblingFoldTool
completedFirstOnly.result = "still done"
processItems[processIndex] = processItems[processIndex].replacingTools(
    [completedFirstOnly],
    allTools: [completedFirstOnly, liveToolDuringFold],
    toolsAreLive: true)!
check({ if case .process(let group) = processItems[processIndex].row.kind {
    return group.tools.map(\.id) == [siblingFoldTool.id, liveToolDuringFold.id]
}; return false }(),
      "a fast tool update preserves every sibling anchored to the process group")
let processPrefix = ChatTimeline.build(
    messages: Array(processMessages.suffix(2)), tools: processTools)
check(processPrefix.map(\.id) == ["m-m904", "m-m905"],
      "loading only the final two rows has no incomplete process grouping")
check(Array(processRows.suffix(processPrefix.count)) == processPrefix,
      "loading earlier messages keeps process rows as an exact suffix")
let assistantOnlyPrefix = ChatTimeline.build(messages: [msg(940), msg(941)], tools: [])
check(assistantOnlyPrefix.map(\.id) == ["m-m940", "m-m941"],
      "assistant-only history windows never fabricate a completed user turn")
let processTailWithFinal = ChatTimeline.build(
    messages: [msg(900, "user"), msg(901), msg(902), msg(903)],
    tools: processTools, completeTurnIDs: ["m900"])
check(processTailWithFinal.last.map { row in
    if case .message(let message) = row.kind { return message.id == "m903" }
    return false
} == true, "final assistant message keeps its original id")

// build160: a projection revision is only valid for its owning instance.
// Two separate conversation objects can have the same numeric revision.
let identityOwner = UUID()
let anotherIdentityOwner = UUID()
let firstIdentity = ChatTimelineItemsStamp(owner: identityOwner, version: 100)
let matchingIdentity = ChatTimelineItemsStamp(owner: identityOwner, version: 100)
let nextIdentity = ChatTimelineItemsStamp(owner: identityOwner, version: 101)
let unrelatedIdentity = ChatTimelineItemsStamp(owner: anotherIdentityOwner, version: 100)
let comparisonRows = (0..<2_000).map { count in
    ChatRowItem(row: ChatRow(id: "m-\(count)", kind: .message(msg(count))),
                isStreaming: false)
}
var singleChanged = comparisonRows
var growingLast = msg(1_999)
growingLast.content = "新增加的流式正文"
singleChanged[1_999] = singleChanged[1_999].replacingMessage(growingLast)
check(ChatTimelineItemsEquality.equal(comparisonRows, stamp: firstIdentity,
                                     comparisonRows, stamp: matchingIdentity),
      "equal revision from the same projection bypasses redundant deep comparison")
check(!ChatTimelineItemsEquality.equal(comparisonRows, stamp: firstIdentity,
                                      singleChanged, stamp: nextIdentity),
      "new projection revision triggers an update for a tail token")
check(!ChatTimelineItemsEquality.equal(comparisonRows, stamp: firstIdentity,
                                      singleChanged, stamp: unrelatedIdentity),
      "different owning projections cannot validate each other's content")
check(ChatTimelineItemsEquality.equal(comparisonRows, stamp: nil,
                                     comparisonRows, stamp: nil),
      "synthetic snapshots without an identity still use exact content equality")
check(!ChatTimelineItemsEquality.equal(comparisonRows, stamp: nil,
                                      singleChanged, stamp: nil),
      "synthetic snapshots with changed content remain distinguishable")
check(ChatTimelineItemsEquality.equal(comparisonRows, stamp: firstIdentity,
                                     comparisonRows, stamp: unrelatedIdentity),
      "different owners with unchanged content remain equal by value")

print("TIMELINE_PASS \(checks) assertions (data invariants only, not UIKit scrolling)")
