import Foundation

enum SSEFrameBudgetError: LocalizedError {
    case oversized
    var errorDescription: String? { "回复事件过大，连接已关闭，请刷新核对历史。" }
}

/// A line limit alone permits an unbounded event made of many short data lines.
/// 单帧上限之外还需要**整轮累计**上限：N 个 1MiB 的 delta 帧各自合法，
/// 但会把流式正文无限追加进内存并每 40ms 全量重发，最终耗尽 CPU/内存。
struct SSEFrameBudget {
    private let limit: Int
    private let streamLimit: Int
    private var eventBytes = 0
    private var lineBytes = 0
    private var lastWasCR = false
    private var totalBytes = 0

    init(maxBytes: Int = 8_388_608, maxStreamBytes: Int = 67_108_864) {
        limit = max(1, maxBytes)
        streamLimit = max(limit, maxStreamBytes)
    }

    mutating func consume(_ byte: UInt8) throws {
        totalBytes += 1
        guard totalBytes <= streamLimit else { throw SSEFrameBudgetError.oversized }
        if byte == 10 {
            let delimiter = lineBytes == 0 || (lineBytes == 1 && lastWasCR)
            lineBytes = 0
            lastWasCR = false
            if delimiter { eventBytes = 0; return }
        } else {
            lineBytes += 1
            lastWasCR = byte == 13
        }
        eventBytes += 1
        guard eventBytes <= limit else { throw SSEFrameBudgetError.oversized }
    }
}
