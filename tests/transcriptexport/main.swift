import Foundation

// 纯 Foundation 断言：不依赖 XCTest，也不依赖 SwiftUI/UIKit。
// 运行方式（容器内）：swiftc Sources/HermesShell/ChatCore.swift \
//   Sources/HermesShell/TranscriptExporter.swift tests/transcriptexport/main.swift

var problems: [String] = []
var failures = 0
var total = 0

func check(_ condition: Bool, _ message: String) {
    if !condition { problems.append(message) }
}

func test(_ number: Int, _ name: String, _ body: () -> Void) {
    problems.removeAll()
    body()
    total += 1
    if problems.isEmpty {
        print("TRANSCRIPTEXPORT \(number) PASS \(name)")
    } else {
        failures += 1
        print("TRANSCRIPTEXPORT \(number) FAIL \(name)")
        for problem in problems { print("  - \(problem)") }
    }
}

// MARK: - 解析辅助（只认本导出器写出的固定形状）

/// 取某个 `## ` / `### ` 小节的正文，遇到下一个标题行为止。
func sectionBody(_ heading: String, in markdown: String) -> String? {
    let lines = markdown.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0 == heading }) else { return nil }
    var collected: [String] = []
    var index = start + 1
    while index < lines.count {
        let line = lines[index]
        if line.hasPrefix("#") { break }
        collected.append(line)
        index += 1
    }
    return collected.joined(separator: "\n")
}

/// 去掉小节开头的空行与 `*时间*` 行、结尾的空行，剩下的就是正文。
func messageBody(_ heading: String, in markdown: String) -> String? {
    guard let raw = sectionBody(heading, in: markdown) else { return nil }
    var lines = raw.components(separatedBy: "\n")
    while let first = lines.first, first.isEmpty || (first.hasPrefix("*") && first.hasSuffix("*")) {
        lines.removeFirst()
    }
    while let last = lines.last, last.isEmpty {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

/// 若整段被同长度的反引号围栏包住，返回围栏内的内容（校验围栏长度 >= 3）。
func unwrapFence(_ block: String) -> String? {
    let lines = block.components(separatedBy: "\n")
    guard lines.count >= 3,
          let first = lines.first,
          first.count >= 3,
          first.allSatisfy({ $0 == "`" }),
          lines.last == first else { return nil }
    return lines.dropFirst().dropLast().joined(separator: "\n")
}

func lines(of text: String) -> [String] { text.components(separatedBy: "\n") }

// MARK: - 固定测试数据

let userMessage = ChatMessage(id: "m1", role: "user", content: "你好")
let assistantMessage = ChatMessage(id: "m2", role: "assistant", content: "在的")

// 1. 基本两消息
test(1, "基本两消息") {
    let doc = TranscriptExporter.document(title: "会话", messages: [userMessage, assistantMessage],
                                          tools: [], usage: nil)
    check(doc.messageCount == 2, "messageCount == 2，实际 \(doc.messageCount)")
    check(doc.toolCount == 0, "toolCount == 0，实际 \(doc.toolCount)")
    check(doc.markdown.hasPrefix("# 会话\n> 导出于 "), "标题与导出行在最前面")
    check(doc.markdown.contains("## 你"), "有「你」小节")
    check(doc.markdown.contains("## Hermes"), "有「Hermes」小节")
    check(doc.markdown.contains("你好"), "用户正文保留")
    check(doc.markdown.contains("在的"), "助手正文保留")
    let userRange = doc.markdown.range(of: "## 你")
    let hermesRange = doc.markdown.range(of: "## Hermes")
    check(userRange != nil && hermesRange != nil && userRange!.lowerBound < hermesRange!.lowerBound,
          "用户消息在助手消息之前")
}

// 2. 标题为空
test(2, "标题为空") {
    let blank = TranscriptExporter.document(title: "", messages: [userMessage], tools: [], usage: nil)
    check(blank.markdown.hasPrefix("# \(TranscriptExporter.placeholderTitle)\n"), "空标题用「未命名会话」")
    let spaces = TranscriptExporter.document(title: "   ", messages: [userMessage], tools: [], usage: nil)
    check(spaces.markdown.hasPrefix("# 未命名会话\n"), "纯空白标题同样兜底")
}

// 3. 时间 nil 省略
test(3, "时间 nil 省略") {
    let plain = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: nil)
    let plainLines = lines(of: plain.markdown)
    if let heading = plainLines.firstIndex(of: "## 你") {
        check(plainLines[heading + 1].isEmpty, "timestamp 为 nil 时标题下一行是空行")
        check(plainLines[heading + 2] == "你好", "空行之后直接是正文")
    } else {
        check(false, "缺少「## 你」标题")
    }
    var timed = userMessage
    timed.timestamp = 1_700_000_000
    let exported = TranscriptExporter.document(title: "t", messages: [timed], tools: [], usage: nil)
    let timedLines = lines(of: exported.markdown)
    if let heading = timedLines.firstIndex(of: "## 你") {
        let next = timedLines[heading + 1]
        check(next.hasPrefix("*") && next.hasSuffix("*"), "有 timestamp 时输出斜体时间行")
        check(timedLines[heading + 2].isEmpty, "时间行之后是空行")
    } else {
        check(false, "缺少「## 你」标题")
    }
}

// 4. 围栏注入：正文含 ``` 时导出后可被重新解析
test(4, "围栏注入") {
    let content = "看代码：\n```swift\nlet a = 1\n```\n结束"
    var message = userMessage
    message.content = content
    let markdown = TranscriptExporter.markdown(for: message)
    guard let body = messageBody("## 你", in: markdown) else {
        check(false, "找不到「## 你」正文")
        return
    }
    check(body.hasPrefix("````"), "正文套了至少 4 个反引号的外层围栏")
    if let inner = unwrapFence(body) {
        check(inner == content, "拆掉外层围栏后可完整还原原文")
    } else {
        check(false, "外层围栏不成对")
    }
    check(body.contains("\n```swift\n"), "内层 3 反引号代码块原样保留")
}

// 5. 工具插入位置
test(5, "工具插入位置") {
    let tool = ChatTool(id: "t1", name: "search", args: "{\"q\":\"hi\"}", result: "ok",
                        done: true, isError: false, afterMessageID: "m1")
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage, assistantMessage],
                                          tools: [tool], usage: nil)
    check(doc.toolCount == 1, "toolCount == 1，实际 \(doc.toolCount)")
    guard let userRange = doc.markdown.range(of: "## 你"),
          let toolRange = doc.markdown.range(of: "### 工具 · search"),
          let hermesRange = doc.markdown.range(of: "## Hermes") else {
        check(false, "缺少必需的标题行")
        return
    }
    check(userRange.lowerBound < toolRange.lowerBound, "工具在锚点消息之后")
    check(toolRange.lowerBound < hermesRange.lowerBound, "工具在下一条消息之前")
}

// 6. includeTools=false 不出现工具
test(6, "includeTools=false") {
    let tool = ChatTool(id: "t1", name: "search", args: "a", result: "r", done: true, isError: false)
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [tool],
                                          usage: nil,
                                          options: TranscriptExportOptions(includeTools: false))
    check(!doc.markdown.contains("### 工具"), "关闭后不输出工具小节")
    check(!doc.markdown.contains("## 工具调用"), "关闭后也不输出文末工具汇总")
    check(doc.toolCount == 0, "关闭后 toolCount == 0")
}

// 7. 超长 result 截断并标注
test(7, "超长 result 截断") {
    let long = String(repeating: "x", count: 9000)
    let tool = ChatTool(id: "t1", name: "cat", args: "", result: long,
                        done: true, isError: false, afterMessageID: "m1")
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [tool], usage: nil)
    check(!doc.markdown.contains(long), "9000 字节原文不再整段出现")
    check(doc.markdown.contains(String(repeating: "x", count: TranscriptExporter.resultByteLimit)),
          "保留满 8192 字节")
    check(doc.markdown.contains(String(repeating: "x", count: TranscriptExporter.resultByteLimit + 1)) == false,
          "没有多留一个字节")
    check(doc.markdown.contains("…（已截断，原长 9000 字节）"), "标注原始长度")
}

// 8. 截断不切断 emoji
test(8, "截断不切断 emoji") {
    let result = "abcde" + String(repeating: "🙂", count: 3000)
    let tool = ChatTool(id: "t1", name: "blob", args: "", result: result,
                        done: true, isError: false, afterMessageID: "m1")
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [tool], usage: nil)
    check(!doc.markdown.contains("\u{FFFD}"), "没有出现替换字符")
    check(doc.markdown.contains("abcde" + String(repeating: "🙂", count: 2046) + "\n…（已截断，原长 12005 字节）"),
          "回退到完整 emoji 边界后截断")
}

// 9. 空会话
test(9, "空会话") {
    let doc = TranscriptExporter.document(title: "空", messages: [], tools: [], usage: nil)
    check(doc.messageCount == 0, "messageCount == 0")
    check(doc.toolCount == 0, "toolCount == 0")
    let exported = lines(of: doc.markdown).filter { !$0.isEmpty }
    check(exported.count == 3, "标题、导出时间与范围说明，实际 \(exported.count) 行")
    check(exported.first == "# 空", "第一行是标题")
    check(!doc.markdown.contains("## "), "没有消息小节")
}

// 10. usage 开关
test(10, "usage 开关") {
    let usage = ChatUsage(fields: [
            "input_tokens": 1200,
            "output_tokens": 34,
            "last_prompt_tokens": 900,
            "context_length": 200_000,
            "estimated_cost": 0.0123
        ])
    let on = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: usage)
    check(on.markdown.contains("## 用量"), "includeUsage 默认开启")
    check(on.markdown.contains("- 输入：1,200 tokens"), "输入计数固定千分位")
    check(on.markdown.contains("- 输出：34 tokens"), "输出计数")
    check(on.markdown.contains("- 合计：1,234 tokens"), "合计为输入 + 输出")
    check(on.markdown.contains("- 最近提示：900 tokens"), "最近提示计数")
    check(on.markdown.contains("- 上下文上限：200,000 tokens"), "上下文上限")
    check(on.markdown.contains("- 费用：0.0123"), "费用保留四位小数")
    let off = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: usage,
                                          options: TranscriptExportOptions(includeUsage: false))
    check(!off.markdown.contains("## 用量"), "关闭后没有用量小节")
    check(!off.markdown.contains("输入："), "关闭后没有用量条目")
    let empty = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [],
                                            usage: ChatUsage(fields: [:]))
    check(!empty.markdown.contains("## 用量"), "用量全空时不写空小节")
}

// 11. 单条导出不含顶级标题
test(11, "单条导出") {
    var message = assistantMessage
    message.timestamp = 1_700_000_000
    let tool = ChatTool(id: "t1", name: "read", args: "p", result: "r", done: true,
                        isError: false, afterMessageID: "m2")
    let markdown = TranscriptExporter.markdown(for: message, tools: [tool])
    check(!lines(of: markdown).contains(where: { $0.hasPrefix("# ") }), "没有 `# ` 顶级标题")
    check(!markdown.contains("> 导出于"), "没有导出行")
    check(!markdown.contains("## 用量"), "没有用量小节")
    check(markdown.hasPrefix("## Hermes\n"), "直接从消息小节省略")
    check(markdown.contains("在的"), "正文在")
    check(markdown.contains("### 工具 · read"), "锚定到本条的工具一起带出")
    let other = ChatTool(id: "t2", name: "other", args: "", result: "", done: true,
                         isError: false, afterMessageID: "m1")
    check(!TranscriptExporter.markdown(for: message, tools: [other]).contains("### 工具 · other"),
          "其它消息的工具不带出")
}

// 12. 中文与未闭合围栏
test(12, "中文与未闭合围栏") {
    let content = "中文 ``` 未闭合"
    var message = userMessage
    message.content = content
    let markdown = TranscriptExporter.markdown(for: message)
    guard let body = messageBody("## 你", in: markdown) else {
        check(false, "找不到正文")
        return
    }
    check(body.hasPrefix("````"), "未闭合的 3 反引号被 4 反引号围栏包住")
    check(unwrapFence(body) == content, "拆围栏后中文原文完整")
    check(markdown.contains("中文"), "中文内容未丢失")
}

// 13. 工具失败状态
test(13, "工具失败状态") {
    let failed = ChatTool(id: "t1", name: "shell", args: "exit 1", result: "boom",
                          done: true, isError: true, afterMessageID: "m1")
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [failed], usage: nil)
    check(doc.markdown.contains("### 工具 · shell"), "工具标题")
    check(doc.markdown.contains("状态：失败"), "失败状态")
    check(!doc.markdown.contains("状态：已完成"), "失败时不写已完成")
    let ok = ChatTool(id: "t2", name: "shell", args: "echo", result: "ok",
                      done: true, isError: false, afterMessageID: "m1")
    let okDoc = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [ok], usage: nil)
    check(okDoc.markdown.contains("状态：已完成"), "成功状态")
}

// 14. options 默认值
test(14, "options 默认值") {
    let options = TranscriptExportOptions()
    check(options == TranscriptExportOptions(includeTools: true, includeReasoning: false, includeUsage: true),
          "默认 工具开 / reasoning 关 / 用量开")
    check(TranscriptExportOptions(includeTools: false) == TranscriptExportOptions(includeTools: false,
                                                                                 includeReasoning: false,
                                                                                 includeUsage: true),
          "只改一个开关不影响其它默认值")
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage],
                                          tools: [], usage: nil, options: .init())
    check(doc.markdown.contains("## 你"), "默认参数可省略")
}

test(15, "导出明确限定范围与缓存状态") {
    let doc = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: nil,
        context: .init(hasUnloadedHistory: true, cached: true, generating: true))
    check(doc.markdown.contains("仅含当前已加载的 1 条消息"), "写入实际已加载条数")
    check(doc.markdown.contains("本文件为部分导出"), "更早历史未加载时标注部分")
    check(doc.markdown.contains("来自本地缓存"), "离线内容不声称已核对")
    check(doc.markdown.contains("导出时仍在生成"), "生成中的导出是快照")
}
test(16, "投递状态与新附件引用不会丢失") {
    for state in [ChatDeliveryState.submitting, .accepted, .unconfirmed] {
        var message = userMessage
        message.delivery = state
        message.attachmentPaths = ["/attachments/报告.pdf", "https://example.com/raw/photo.HEIC?token=not-a-mime"]
        let doc = TranscriptExporter.document(title: "t", messages: [message], tools: [], usage: nil)
        check(doc.markdown.contains("投递状态："), "每种本地消息状态都写出")
        check(doc.markdown.contains("报告.pdf") && doc.markdown.contains("扩展名：pdf"), "附件名称和扩展名")
        check(doc.markdown.contains("MIME 未提供") && !doc.markdown.contains("application/pdf"), "不凭扩展名编造服务端 MIME")
        check(doc.markdown.contains("引用信息，不含文件本体"), "引用不冒充文件备份")
        if state == .unconfirmed { check(doc.markdown.contains("可能尚未送达"), "未知结果不冒充已送达") }
        if state == .accepted { check(doc.markdown.contains("服务端已受理"), "已受理区别于未知") }
    }
}
test(17, "流式回答和进行中工具状态") {
    let tool = ChatTool(id: "live", name: "search", args: "", result: "partial", done: false, isError: false)
    let doc = TranscriptExporter.document(title: "t", messages: [assistantMessage], tools: [tool], usage: nil,
                                          context: .init(generating: true))
    check(doc.markdown.contains("回答状态：生成中"), "未落入历史的实时回答标注未完成")
    check(doc.markdown.contains("状态：进行中"), "未完成工具不冒充完成")
    check(!doc.markdown.contains("状态：已完成"), "无错误完成标记")
}

test(18, "完整分页与部分历史分别标注") {
    let complete = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: nil,
        context: .init(completeHistory: true))
    check(complete.markdown.contains("已分页获取至会话起点，共 1 条消息"), "只有成功到起点才说明完整范围")
    check(!complete.markdown.contains("不保证包含完整会话"), "完整结果不混用已加载提示")
    let partial = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: nil,
        context: .init(partialReason: "达到分页上限"))
    check(partial.markdown.contains("属于部分历史") && partial.markdown.contains("达到分页上限"), "保留部分原因")
    check(!partial.markdown.contains("已分页获取至会话起点"), "不把上限当成完整")
    let invalidComplete = TranscriptExporter.document(title: "t", messages: [userMessage], tools: [], usage: nil,
        context: .init(cached: true, generating: true, completeHistory: true))
    check(!invalidComplete.markdown.contains("已分页获取至会话起点"), "缓存或生成中不能声称完整")
}

if failures == 0 {
    print("TRANSCRIPTEXPORT_ALL_PASS \(total) tests")
} else {
    print("TRANSCRIPTEXPORT_FAIL \(failures)/\(total)")
    exit(1)
}
