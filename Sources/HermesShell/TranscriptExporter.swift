import Foundation

/// 会话导出选项。默认带上工具与用量，不导出 reasoning。
///
/// `includeReasoning` 目前是「预留开关」：`ChatMessage` 没有 reasoning 字段，
/// 拿不到就不编造，打开该选项也只是空操作（等数据结构补上字段再接）。
struct TranscriptExportOptions: Equatable, Sendable {
    var includeTools = true
    var includeReasoning = false
    var includeUsage = true
}

struct TranscriptDocument: Equatable {
    let markdown: String
    let messageCount: Int
    let toolCount: Int
}

struct TranscriptExportContext: Sendable {
    var hasUnloadedHistory = false
    var cached = false
    var generating = false
    var completeHistory = false
    var partialReason: String? = nil
}

/// 只依赖 Foundation：不碰 SwiftUI/UIKit，也不碰 ChatTimeline，
/// 这样离线单测可以直接 `swiftc ChatCore.swift TranscriptExporter.swift`。
enum TranscriptExporter {
    /// 标题为空（含纯空白）时的兜底。
    static let placeholderTitle = "未命名会话"
    /// 单个工具结果的字节上限；超出后截断并标注原始长度。
    static let resultByteLimit = 8192

    // MARK: - 会话

    static func document(title: String,
                         messages: [ChatMessage],
                         tools: [ChatTool],
                         usage: ChatUsage?,
                         options: TranscriptExportOptions = .init(),
                         context: TranscriptExportContext = .init()) -> TranscriptDocument {
        let heading = normalizedTitle(title)
        var blocks: [String] = [
            "# \(heading)\n> 导出于 \(stamp(Date()))"
        ]
        if context.completeHistory, context.partialReason == nil, !context.cached, !context.generating {
            blocks.append("> 导出范围：已分页获取至会话起点，共 \(messages.count) 条消息。")
            blocks.append("> 此文件按导出期间读取的服务端历史生成，不含未确认的本地消息或此后新增内容；附件仅为引用信息。")
        } else if context.partialReason != nil {
            blocks.append("> 导出范围：本次已获取 \(messages.count) 条消息，属于部分历史。")
        } else {
            blocks.append("> 导出范围：仅含当前已加载的 \(messages.count) 条消息；不保证包含完整会话。")
        }
        if let reason = context.partialReason {
            blocks.append("> 部分导出：\(reason.replacingOccurrences(of: "\n", with: " "))。")
        }
        if context.hasUnloadedHistory { blocks.append("> 更早历史尚未全部载入，本文件为部分导出。") }
        if context.cached { blocks.append("> 数据来自本地缓存，尚未联网核对。") }
        if context.generating { blocks.append("> 导出时仍在生成，回答与工具结果可能尚未完成。") }

        for message in messages {
            blocks.append(messageBlock(message, generating: context.generating && message.role == "assistant" && message.sourceIndex == nil))
            guard options.includeTools else { continue }
            for tool in tools where tool.afterMessageID == message.id {
                blocks.append(toolBlock(tool))
            }
        }

        if options.includeTools {
            // 没有归属（或锚点已不在本次导出里）的工具集中放到文末。
            let known = Set(messages.map { $0.id })
            let orphans = tools.filter { tool in
                guard let anchor = tool.afterMessageID else { return true }
                return !known.contains(anchor)
            }
            if !orphans.isEmpty {
                blocks.append("## 工具调用")
                blocks.append(contentsOf: orphans.map { toolBlock($0) })
            }
        }

        if options.includeUsage, let usage, let section = usageBlock(usage) {
            blocks.append(section)
        }

        return TranscriptDocument(markdown: blocks.joined(separator: "\n\n") + "\n",
                                  messageCount: messages.count,
                                  toolCount: options.includeTools ? tools.count : 0)
    }

    // MARK: - 单条消息

    /// 单条消息：用于「复制这条为 Markdown」；不含标题与用量。
    static func markdown(for message: ChatMessage, tools: [ChatTool] = []) -> String {
        var blocks = [messageBlock(message)]
        for tool in tools where tool.afterMessageID == message.id {
            blocks.append(toolBlock(tool))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - 消息

    private static func normalizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholderTitle : trimmed
    }

    private static func senderLabel(_ role: String) -> String {
        role.lowercased() == "user" ? "你" : "Hermes"
    }

    private static func messageBlock(_ message: ChatMessage, generating: Bool = false) -> String {
        var lines = ["## \(senderLabel(message.role))"]
        if let timestamp = message.timestamp {
            lines.append("*\(stamp(Date(timeIntervalSince1970: timestamp)))*")
        }
        switch message.delivery {
        case .confirmed: break
        case .submitting: lines.append("> 投递状态：提交中，送达尚未确认。")
        case .accepted: lines.append("> 投递状态：服务端已受理，尚未与历史核对。")
        case .unconfirmed: lines.append("> 投递状态：结果待核对，可能尚未送达。")
        }
        if generating { lines.append("> 回答状态：生成中，以下内容尚未完成。") }
        lines.append("")
        lines.append(bodyBlock(message.content))
        if !message.attachmentPaths.isEmpty {
            lines.append("")
            lines.append("**附件清单（引用信息，不含文件本体）**")
            for path in message.attachmentPaths {
                let leaf = URLComponents(string: path)?.path.components(separatedBy: "/").last ?? path
                let name = leaf.isEmpty ? "未命名附件" : leaf
                let ext = (name as NSString).pathExtension
                let kind = ext.isEmpty ? "类型未提供" : "扩展名：\(ext.lowercased())；MIME 未提供"
                lines.append("- \(name.replacingOccurrences(of: "\n", with: " "))（\(kind)）")
                lines.append(codeBlock(path))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 正文原样输出；一旦里面有 ``` 及更长的连续反引号，就整体套一层更长的围栏，
    /// 保证「导出 → 再解析」拿到的是同一段文本，而不是被截断的代码块。
    private static func bodyBlock(_ content: String) -> String {
        let text = content.trimmingCharacters(in: .newlines)
        let longest = longestBacktickRun(in: text)
        guard longest >= 3 else { return text }
        let fence = String(repeating: "`", count: longest + 1)
        return "\(fence)\n\(text)\n\(fence)"
    }

    // MARK: - 工具

    private static func toolBlock(_ tool: ChatTool) -> String {
        let name = tool.name.isEmpty ? "Tool" : tool.name
        let status = tool.isError ? "失败" : tool.done ? "已完成" : "进行中"
        let result = truncatedResult(tool.result)
        return [
            "### 工具 · \(name)",
            "状态：\(status)",
            "",
            "**参数**",
            "",
            codeBlock(tool.args),
            "",
            "**结果**",
            "",
            codeBlock(result)
        ].joined(separator: "\n")
    }

    /// 结果超过上限时按 UTF-8 字节截断：逐字节回退到合法边界，绝不切半个字符。
    private static func truncatedResult(_ text: String) -> String {
        let bytes = Data(text.utf8)
        let original = bytes.count
        guard original > resultByteLimit else { return text }
        var end = resultByteLimit
        while end > 0 {
            if let prefix = String(data: Data(bytes.prefix(end)), encoding: .utf8) {
                return prefix + truncationNote(original: original)
            }
            end -= 1
        }
        return "…（已截断，原长 \(original) 字节）"
    }

    private static func truncationNote(original: Int) -> String {
        "\n…（已截断，原长 \(original) 字节）"
    }

    private static func codeBlock(_ text: String) -> String {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }

    /// 正文与工具输出里最长的一段连续反引号；用于挑一个不会被内容打断的围栏。
    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    // MARK: - 用量

    private static func usageBlock(_ usage: ChatUsage) -> String? {
        var items: [String] = []
        if let input = usage.inputTokens {
            items.append("- 输入：\(number(input)) tokens")
        }
        if let output = usage.outputTokens {
            items.append("- 输出：\(number(output)) tokens")
        }
        if let input = usage.inputTokens, let output = usage.outputTokens {
            items.append("- 合计：\(number(input + output)) tokens")
        }
        if let prompt = usage.promptTokens {
            items.append("- 最近提示：\(number(prompt)) tokens\(usage.estimated ? "（估算）" : "")")
        }
        if let context = usage.contextLength {
            items.append("- 上下文上限：\(number(context)) tokens")
        }
        if let cost = usage.cost {
            items.append("- 费用：\(costText(cost))")
        }
        guard !items.isEmpty else { return nil }
        return (["## 用量"] + items).joined(separator: "\n")
    }

    /// 千分位固定用 en_US_POSIX，避免不同机器语言环境导出不同数字。
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static func number(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func costText(_ value: Double) -> String {
        value < 1 ? String(format: "%.4f", value) : String(format: "%.2f", value)
    }

    // MARK: - 时间

    /// 固定 zh_CN + 公历 + 当前时区；测试只断言带 `*`，不断言具体时刻。
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }
}
