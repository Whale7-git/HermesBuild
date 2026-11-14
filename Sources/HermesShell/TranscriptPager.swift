import Foundation

enum TranscriptPagerError: LocalizedError {
    case authenticationRequired
    case empty(String)
    var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "登录状态已失效，请重新登录后导出。"
        case .empty(let reason): return "未取得可导出的历史：\(reason)"
        }
    }
}

/// Independent read-only pagination. Never changes NativeChatModel's buffer,
/// its 800-message window, cursor, stream connection or reading anchor.
enum TranscriptPager {
    struct Limits: Sendable {
        var pages = 40
        var bytes = 8 * 1024 * 1024
    }
    struct Progress: Equatable, Sendable {
        var pages = 0
        var messages = 0
    }
    struct Result: Sendable {
        let messages: [ChatMessage]
        let tools: [ChatTool]
        let usage: ChatUsage?
        let pages: Int
        let retainedBytes: Int
        /// nil only after reaching the beginning through contiguous pages.
        let partialReason: String?
        var complete: Bool { partialReason == nil }
    }

    @MainActor static func fetch(sessionID: String, limits: Limits = .init(),
        history: @MainActor (Int?) async throws -> ChatSnapshot,
        onProgress: @MainActor (Progress) -> Void = { _ in }) async throws -> Result {
        var messages: [String: ChatMessage] = [:]
        var tools: [String: ChatTool] = [:]
        var toolOrder: [String] = []
        var usage: ChatUsage?
        var pages = 0
        var bytes = 0
        var cursor: Int?
        var reason: String?
        onProgress(.init())
        while true {
            try Task.checkCancellation()
            guard pages < max(0, limits.pages) else { reason = "达到历史分页上限"; break }
            let snapshot: ChatSnapshot
            do { snapshot = try await history(cursor) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if case TranscriptPagerError.authenticationRequired = error { throw error }
                if pages == 0 { throw error }
                reason = "获取更早历史失败：\(error.localizedDescription)"
                break
            }
            try Task.checkCancellation()
            guard snapshot.sessionID == sessionID else { reason = "历史会话标识不一致"; break }
            guard snapshot.activeStreamID == nil else { reason = "会话正在生成，历史尚未稳定"; break }
            if let cursor {
                guard snapshot.olderOffset < cursor, snapshot.rawMessageEndIndex == cursor else {
                    reason = "历史分页边界发生变化，未能确认连续性"; break
                }
            }

            // Stage a complete page before committing it. A budget/mismatch
            // cannot leave a half-page falsely described as complete history.
            var pageMessages: [ChatMessage] = []
            var stagedMessages: [String: ChatMessage] = [:]
            var pageTools: [ChatTool] = []
            var delta = 0
            var conflict = false
            for message in snapshot.messages {
                guard message.delivery == .confirmed, message.sourceIndex != nil,
                      !message.id.hasPrefix("local-"), !message.id.hasPrefix("streaming:") else { continue }
                if let previous = messages[message.id] ?? stagedMessages[message.id] {
                    if previous != message { conflict = true; break }
                } else {
                    pageMessages.append(message)
                    stagedMessages[message.id] = message
                    delta += cost(message)
                }
            }
            if conflict { reason = "导出期间历史消息发生变化"; break }
            for tool in snapshot.tools {
                let merged = merge(newer: tools[tool.id], older: tool)
                delta += cost(merged) - (tools[tool.id].map(cost) ?? 0)
                pageTools.append(merged)
            }
            guard delta <= max(0, limits.bytes) - bytes else { reason = "达到历史内容大小上限"; break }
            for message in pageMessages { messages[message.id] = message }
            for tool in pageTools {
                if tools[tool.id] == nil { toolOrder.append(tool.id) }
                tools[tool.id] = tool
            }
            bytes += delta
            pages += 1
            if usage == nil { usage = snapshot.usage }
            onProgress(.init(pages: pages, messages: messages.count))
            if snapshot.olderOffset == 0 {
                if snapshot.messagesTruncated { reason = "服务端仍标记历史被截断" }
                break
            }
            cursor = snapshot.olderOffset
        }
        try Task.checkCancellation()
        if messages.isEmpty, let reason { throw TranscriptPagerError.empty(reason) }
        let ordered = messages.values.sorted {
            let left = $0.sourceIndex ?? Int.max, right = $1.sourceIndex ?? Int.max
            return left == right ? $0.id < $1.id : left < right
        }
        return Result(messages: ordered, tools: toolOrder.compactMap { tools[$0] }, usage: usage,
                      pages: pages, retainedBytes: bytes, partialReason: reason)
    }

    private static func cost(_ message: ChatMessage) -> Int {
        256 + message.id.utf8.count + message.content.utf8.count
            + message.attachmentPaths.reduce(0) { $0 + $1.utf8.count }
    }
    private static func cost(_ tool: ChatTool) -> Int {
        256 + tool.id.utf8.count + tool.name.utf8.count + tool.args.utf8.count + tool.result.utf8.count
            + (tool.afterMessageID?.utf8.count ?? 0)
    }
    private static func merge(newer: ChatTool?, older: ChatTool) -> ChatTool {
        guard var value = newer else { return older }
        if value.name == "Tool" || value.name.isEmpty { value.name = older.name }
        if value.args.isEmpty { value.args = older.args }
        if value.result.isEmpty { value.result = older.result }
        if value.afterMessageID == nil { value.afterMessageID = older.afterMessageID }
        value.done = value.done || older.done
        value.isError = value.isError || older.isError
        return value
    }
}
