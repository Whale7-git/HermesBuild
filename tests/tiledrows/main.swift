import Foundation
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message:String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

// ScrollView + LazyVStack 靠 ForEach 的 id diff。这里锁住"行的身份与内容分开"这条契约：
// 只有内容真变才该触发重绘，否则每吐一个字都会重排整表。

// 1) 同样的消息 + 同样的流式标记 → 相等（避免无意义刷新）
let msg = ChatMessage(id: "a1", role: "assistant", content: "你好", timestamp: 1)
let rowMsg = ChatRow(id: "m-a1", kind: .message(msg), showsSender: true, isContinuation: false)
let a = ChatRowItem(row: rowMsg, isStreaming: false)
let b = ChatRowItem(row: rowMsg, isStreaming: false)
expect(a == b, "identical rows must compare equal so ForEach skips the cell")

// 2) 流式标记变化 → 不相等（尾部气泡要重画）
let streaming = ChatRowItem(row: rowMsg, isStreaming: true)
expect(a != streaming, "toggling streaming must invalidate the cell")

// 3) 正文变化 → 不相等
var grown = msg; grown.content = "你好，世界"
let rowGrown = ChatRow(id: "m-a1", kind: .message(grown), showsSender: true, isContinuation: false)
expect(a != ChatRowItem(row: rowGrown, isStreaming: false), "streaming text growth must invalidate the cell")

// 4) 身份由行 id 决定：同日分割、工具组也要能参与 diff
let day = ChatRow(id: "day-a1", kind: .day(Date(timeIntervalSince1970: 0)))
expect(ChatRowItem(row: day, isStreaming: false).id == "day-a1", "day divider keeps its row id")

let tool = ChatTool(id: "t1", name: "read_file", args: "{}", result: "ok", done: true, isError: false)
let group = ChatRow(id: "t-a1", kind: .tools([tool]))
expect(ChatRowItem(row: group, isStreaming: false) == ChatRowItem(row: group, isStreaming: true),
       "tool rows ignore the streaming flag")

// 5) 行内容变化必须穿透到 ChatRow 的相等性（否则 diff 看不出更新）
let toolRunning = ChatTool(id: "t1", name: "read_file", args: "{}", result: "", done: false, isError: false)
expect(ChatRow(id: "t-a1", kind: .tools([tool])) != ChatRow(id: "t-a1", kind: .tools([toolRunning])),
       "tool completion must make the row unequal")

// 6) 顺序固定：id 不随内容变化，否则 prepend 会被误判成大量 insert+remove
var reordered = [ChatRowItem(row: rowMsg, isStreaming: false), ChatRowItem(row: day, isStreaming: false)]
expect(reordered.map(\.id) == ["m-a1", "day-a1"], "row ids are stable and order-preserving")
reordered.reverse()
expect(Set(reordered.map(\.id)) == ["m-a1", "day-a1"], "reorder keeps the same id set so diff sees moves only")


let complete = [ChatToolSummary.Item(name: "terminal", done: true, isError: false),
                .init(name: "read_file", done: true, isError: false)]
expect(ChatExecutionPresentation.title(messageCount: 2, toolItems: complete,
                                       allowsRunning: false) == "已执行 4 个步骤",
       "process summary counts messages and tools without removing detail")
expect(ChatExecutionPresentation.detail(messageCount: 2, toolItems: complete,
                                        allowsRunning: false).contains("中间回复"),
       "collapsed process retains a disclosure summary")
let active = [ChatToolSummary.Item(name: "terminal", done: false, isError: false)]
expect(ChatExecutionPresentation.title(messageCount: 0, toolItems: active,
                                       allowsRunning: true).contains("terminal"),
       "active tool process must remain visibly running")
let failure = [ChatToolSummary.Item(name: "terminal", done: true, isError: true)]
expect(ChatExecutionPresentation.title(messageCount: 0, toolItems: failure,
                                       allowsRunning: false).contains("失败"),
       "failed tool process must not show as completed")
expect(ChatExecutionPresentation.title(messageCount: 0, toolItems: [],
                                       allowsRunning: false) == "执行过程",
       "empty process has a graceful stable label")
print("TILED_ROWS_PASS \(checks) assertions")
