import Foundation

/// 工具组的折叠文案。只做展示，不改 `ChatTool` 结构、不改分组规则。
enum ChatToolSummary {
    struct Item: Equatable {
        let name: String
        let done: Bool
        let isError: Bool
    }

    /// 摘要：按名称合并计数，只显示最近两组，其余折成 `+N`。
    /// 例：`terminal ×2 · read_file`；`read_file · write_file +2`。
    static func summary(_ items: [Item], allowsRunning: Bool = false) -> String {
        guard !items.isEmpty else { return "" }
        if allowsRunning, let active = items.last(where: { !$0.done && !$0.isError }) {
            return active.name
        }
        var counts: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            counts[item.name, default: 0] += 1
            lastSeen[item.name] = index
        }
        let ordered = counts.keys.sorted { (lastSeen[$0] ?? 0) < (lastSeen[$1] ?? 0) }
        let shown = ordered.suffix(2)
        let hidden = ordered.dropLast(shown.count).reduce(0) { $0 + (counts[$1] ?? 0) }
        let parts: [String] = shown.map { name in
            let count = counts[name] ?? 1
            return count > 1 ? "\(name) ×\(count)" : name
        }
        let joined = parts.joined(separator: " · ")
        // `+N` 是折叠计数，不是第三个分组，不能再用分组分隔符连接。
        return hidden > 0 ? joined + " +\(hidden)" : joined
    }

    /// A compact status line used when an execution needs attention.
    /// A tool that hasn't reported done/error is never declared successful.
    /// Do not describe these as the terminal status of the whole Run.
    static func statusLine(_ items: [Item], allowsRunning: Bool = false) -> String {
        var success = 0
        var failed = 0
        var unresolved = 0
        for item in items {
            if item.isError { failed += 1 }
            else if item.done { success += 1 }
            else { unresolved += 1 }
        }
        guard failed > 0 || unresolved > 0 else { return "" }
        var labels: [String] = []
        if success > 0 { labels.append("\(success) 成功") }
        if failed > 0 { labels.append("\(failed) 失败") }
        if unresolved > 0 {
            labels.append("\(unresolved) \(allowsRunning ? "执行中" : "待核对")")
        }
        return labels.joined(separator: " · ")
    }

    /// 折叠态标题：用用户语言说明结果，不把失败合并成"完成"。
    static func title(_ items: [Item], allowsRunning: Bool = false) -> String {
        guard !items.isEmpty else { return "" }
        let failures = items.filter(\.isError).count
        let settled = items.filter { $0.done || $0.isError }.count
        if allowsRunning, settled < items.count {
            // A failed earlier tool does not hide the currently running one.
            let failuresLabel = failures > 0 ? " · \(failures) 个失败" : ""
            return "工具进度 \(settled)/\(items.count)\(failuresLabel)"
        }
        if failures > 0 { return "\(items.count) 项 · \(failures) 个失败" }
        if items.contains(where: { !$0.done }) { return "\(items.count) 项 · 状态待核对" }
        return "已完成 \(items.count) 项操作"
    }
}

/// Stable, readable disclosure labels for a full Hermes execution segment.
/// Only presentation changes: all messages/tool calls remain in the timeline
/// and are available through the existing expansion bindings.
enum ChatExecutionPresentation {
    static func title(messageCount: Int, toolItems: [ChatToolSummary.Item],
                      allowsRunning: Bool) -> String {
        let failures = toolItems.filter(\.isError).count
        if allowsRunning, let active = toolItems.last(where: { !$0.done && !$0.isError }) {
            let suffix = failures > 0 ? " · \(failures) 项失败" : ""
            return "正在执行 · \(active.name)\(suffix)"
        }
        if failures > 0 { return "执行过程 · \(failures) 项失败" }
        if toolItems.contains(where: { !$0.done }) {
            // A disconnected run is neither visibly running nor verified as
            // completed. Do not paint it as a green successful process.
            return "执行过程 · 状态待核对"
        }
        let steps = messageCount + toolItems.count
        return steps == 0 ? "执行过程" : "已执行 \(steps) 个步骤"
    }

    static func detail(messageCount: Int, toolItems: [ChatToolSummary.Item],
                       allowsRunning: Bool) -> String {
        if toolItems.isEmpty { return messageCount > 0 ? "思考与中间回复" : "" }
        let toolSummary = ChatToolSummary.summary(toolItems, allowsRunning: allowsRunning)
        return messageCount > 0 ? "中间回复 · \(toolSummary)" : toolSummary
    }
}

 
/// Immutable, grapheme-safe page index for large tool parameters/results.
/// Build once off-main when the reader opens. Search uses the complete source,
/// not the preview or one visible page, and keeps UTF-16 coordinates for UIKit.
struct ToolPayloadIndex: Sendable {
    struct Page: Sendable {
        let range: Range<String.Index>
        let utf16Start: Int
        let utf16Length: Int
    }
    struct Match: Sendable {
        let page: Int
        let location: Int
        let length: Int
        let nextOffset: Int
        let spansPages: Bool
    }

    let text: String
    let pages: [Page]
    private let totalUTF16: Int

    init(text: String, pageSize: Int = 16_000) {
        self = Self.build(text: text, pageSize: pageSize, isCancelled: { false })!
    }

    private init(text: String, pages: [Page], totalUTF16: Int) {
        self.text = text
        self.pages = pages
        self.totalUTF16 = totalUTF16
    }

    static func build(text: String, pageSize: Int = 16_000,
                      isCancelled: () -> Bool) -> Self? {
        let size = max(1, pageSize)
        var start = text.startIndex
        var offset = 0
        var result: [Page] = []
        while start < text.endIndex {
            guard !isCancelled() else { return nil }
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            let length = text[start..<end].utf16.count
            result.append(Page(range: start..<end, utf16Start: offset, utf16Length: length))
            offset += length
            start = end
        }
        if result.isEmpty {
            result.append(Page(range: text.startIndex..<text.endIndex, utf16Start: 0, utf16Length: 0))
        }
        guard !isCancelled() else { return nil }
        return Self(text: text, pages: result, totalUTF16: offset)
    }

    func pageText(_ index: Int) -> String {
        let safe = min(max(0, index), pages.count - 1)
        return String(text[pages[safe].range])
    }

    func find(_ query: String, after offset: Int = 0,
              isCancelled: () -> Bool = { false }) -> Match? {
        guard !isCancelled() else { return nil }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf16.count <= 512, totalUTF16 > 0 else { return nil }
        let source = text as NSString
        let start = min(max(0, offset), totalUTF16)
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var found = source.range(of: term, options: options,
            range: NSRange(location: start, length: totalUTF16 - start))
        guard !isCancelled() else { return nil }
        if found.location == NSNotFound && start > 0 {
            found = source.range(of: term, options: options,
                range: NSRange(location: 0, length: totalUTF16))
        }
        guard !isCancelled(), found.location != NSNotFound, found.length > 0 else { return nil }
        // Binary search the containing page using the indexed UTF-16 offsets.
        var lo = 0, hi = pages.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pages[mid].utf16Start <= found.location { lo = mid }
            else { hi = mid - 1 }
        }
        let page = pages[lo]
        let local = found.location - page.utf16Start
        let length = min(found.length, page.utf16Length - local)
        return Match(page: lo, location: local, length: length,
            nextOffset: NSMaxRange(found), spansPages: length < found.length)
    }
}
