import Foundation

struct ChatReadingPosition: Codable, Equatable {
    var rowID: String
    var offsetInRow: Double
    var following: Bool
    var savedAt: Date = Date()
    var isValid: Bool {
        !rowID.isEmpty && rowID.utf8.count <= 2048 && offsetInRow.isFinite
            && offsetInRow >= 0 && savedAt.timeIntervalSince1970.isFinite
    }
}

/// Local geometry only; contains no message text, cookies or server mutations.
struct ChatReadingPositionStore {
    private let defaults: UserDefaults
    private let key: String
    init(instanceID: String, accountScope: String, sessionID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "HermesNative.reading.v1." + Self.encodedTuple([instanceID, accountScope, sessionID])
    }

    /// 三元组键片段：正常路径与历史 `JSONEncoder` 输出逐字节一致；
    /// 编码失败（实际不会发生）时退回单射的长度前缀编码，不崩溃。
    private static func encodedTuple(_ values: [String]) -> String {
        if let data = try? JSONEncoder().encode(values) { return data.base64EncodedString() }
        let fallback = values.map { "\($0.utf8.count):\($0)" }.joined()
        return "len:" + Data(fallback.utf8).base64EncodedString()
    }
    func load() -> ChatReadingPosition? {
        // 纯展示缓存：读不出或格式不符就当「没有记录」，可忽略（不影响任何消息内容）。
        guard let data = defaults.data(forKey: key), data.count <= 8192,
              let value = try? JSONDecoder().decode(ChatReadingPosition.self, from: data),
              value.isValid else { return nil }
        return value
    }
    func save(_ position: ChatReadingPosition) {
        // 编码失败只丢一个滚动锚点，下次进入会话顶多回到顶部，可忽略。
        guard position.isValid, let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key)
    }

    /// 删除这一条的阅读位置。会话删除后旧锚点已无意义，
    /// 留着会让「恢复上次阅读位置」指向一条不存在的消息。
    func remove() {
        defaults.removeObject(forKey: key)
    }

    /// 删除某实例 + 账号下的全部阅读位置（清空缓存、切换账号）。
    static func removeAll(instanceID: String, accountScope: String,
                          defaults: UserDefaults = .standard) {
        for name in defaults.dictionaryRepresentation().keys {
            guard name.hasPrefix(prefix) else { continue }
            let encoded = String(name.dropFirst(prefix.count))
            // 可忽略：解析不出来的键不属于本模块格式，跳过即可。
            guard let data = Data(base64Encoded: encoded),
                  let tuple = try? JSONDecoder().decode([String].self, from: data),
                  tuple.count >= 2, tuple[0] == instanceID, tuple[1] == accountScope else { continue }
            defaults.removeObject(forKey: name)
        }
    }

    private static let prefix = "HermesNative.reading.v1."
}

/// Per-message offset for the full-screen answer reader. This is deliberately
/// separate from the transcript anchor: closing the reader must not move the
/// conversation list underneath it.
struct ChatReaderPosition: Codable, Equatable {
    let offset: Double
    let progress: Double
    let viewportWidth: Double
    let contentFingerprint: UInt64
    let updatedAt: Double

    var isValid: Bool {
        offset.isFinite && offset >= 0
            && progress.isFinite && (0...1).contains(progress)
            && viewportWidth.isFinite && viewportWidth > 0
            && updatedAt.isFinite && updatedAt >= 0
    }

    private enum CodingKeys: String, CodingKey {
        case offset, progress, viewportWidth, contentFingerprint, updatedAt
    }

    init(offset: Double, progress: Double, viewportWidth: Double,
         contentFingerprint: UInt64, updatedAt: Double) {
        self.offset = offset
        self.progress = progress
        self.viewportWidth = viewportWidth
        self.contentFingerprint = contentFingerprint
        self.updatedAt = updatedAt
    }

    /// Build126 stored only `offset` and `updatedAt`. Decode those records so
    /// upgrades do not fail the whole bucket; the missing fingerprint then
    /// makes them ineligible for restoration until the user scrolls once.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offset = try values.decode(Double.self, forKey: .offset)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        viewportWidth = try values.decodeIfPresent(Double.self, forKey: .viewportWidth) ?? 0
        contentFingerprint = try values.decodeIfPresent(UInt64.self, forKey: .contentFingerprint) ?? 0
    }
}

/// Deterministic across process launches. Swift's Hasher is intentionally
/// randomized, so it cannot be persisted as an identity.
enum ChatReadingFingerprint {
    static func fnv1a(_ text: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }
}

enum ChatReaderPositionRestorePolicy {
    static func targetOffset(_ position: ChatReaderPosition, maximumOffset: Double,
                             viewportWidth: Double, content: String) -> Double? {
        guard position.isValid, viewportWidth.isFinite, viewportWidth > 0,
              maximumOffset.isFinite, maximumOffset >= 0,
              position.contentFingerprint == ChatReadingFingerprint.fnv1a(content)
        else { return nil }
        let widthDifference = abs(viewportWidth - position.viewportWidth)
        let sameLayout = widthDifference <= 1
            || widthDifference <= max(viewportWidth, position.viewportWidth) * 0.02
        let value = sameLayout ? position.offset : position.progress * maximumOffset
        return min(maximumOffset, max(0, value))
    }
}

struct ChatReaderPositionStore {
    private let defaults: UserDefaults
    private let key: String
    private let clock: () -> Date

    init(instanceID: String, accountScope: String, sessionID: String,
         defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        key = "HermesNative.reader.v1." + Self.encodedTuple(
            [instanceID, accountScope, sessionID])
    }

    private static func encodedTuple(_ values: [String]) -> String {
        if let data = try? JSONEncoder().encode(values) { return data.base64EncodedString() }
        let fallback = values.map { "\($0.utf8.count):\($0)" }.joined()
        return "len:" + Data(fallback.utf8).base64EncodedString()
    }

    func position(messageID: String, content: String) -> ChatReaderPosition? {
        guard let data = defaults.data(forKey: key), data.count <= 64 * 1024,
              let values = try? JSONDecoder().decode([String: ChatReaderPosition].self, from: data),
              let value = values[messageID], value.isValid,
              value.contentFingerprint == ChatReadingFingerprint.fnv1a(content)
        else { return nil }
        return value
    }

    func save(offset: Double, maximumOffset: Double, viewportWidth: Double,
              messageID: String, content: String) {
        guard !messageID.isEmpty, messageID.utf8.count <= 2048,
              offset.isFinite, offset >= 0,
              maximumOffset.isFinite, maximumOffset >= 0,
              viewportWidth.isFinite, viewportWidth > 0 else { return }
        var values: [String: ChatReaderPosition] = [:]
        if let data = defaults.data(forKey: key), data.count <= 64 * 1024,
           let decoded = try? JSONDecoder().decode([String: ChatReaderPosition].self, from: data) {
            values = decoded
        }
        let newestExisting = values.values
            .map(\.updatedAt)
            .filter { $0.isFinite && $0 >= 0 }
            .max() ?? 0
        let now = clock().timeIntervalSince1970
        let updatedAt = now.isFinite && now >= 0
            ? max(now, newestExisting + 0.001)
            : newestExisting + 0.001
        let progress = maximumOffset > 0 ? min(1, max(0, offset / maximumOffset)) : 0
        values[messageID] = ChatReaderPosition(
            offset: min(offset, maximumOffset), progress: progress,
            viewportWidth: viewportWidth,
            contentFingerprint: ChatReadingFingerprint.fnv1a(content),
            updatedAt: updatedAt)
        if values.count > 64 {
            values = values
                .sorted {
                    if $0.value.updatedAt != $1.value.updatedAt {
                        return $0.value.updatedAt > $1.value.updatedAt
                    }
                    return $0.key < $1.key
                }
                .prefix(64)
                .reduce(into: [:]) { $0[$1.key] = $1.value }
        }
        // The read path rejects payloads above 64 KiB. IDs can be long, so the
        // entry count alone is not enough to guarantee that this stays loadable.
        var compacted: [String: ChatReaderPosition] = [:]
        for (name, value) in values.sorted(by: {
            if $0.value.updatedAt != $1.value.updatedAt {
                return $0.value.updatedAt > $1.value.updatedAt
            }
            return $0.key < $1.key
        }) {
            var candidate = compacted
            candidate[name] = value
            guard let encoded = try? JSONEncoder().encode(candidate),
                  encoded.count <= 64 * 1024 else { break }
            compacted = candidate
        }
        guard !compacted.isEmpty, let data = try? JSONEncoder().encode(compacted) else { return }
        defaults.set(data, forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }

    static func removeAll(instanceID: String, accountScope: String,
                          defaults: UserDefaults = .standard) {
        let prefix = "HermesNative.reader.v1."
        for name in defaults.dictionaryRepresentation().keys {
            guard name.hasPrefix(prefix) else { continue }
            let encoded = String(name.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: encoded),
                  let tuple = try? JSONDecoder().decode([String].self, from: data),
                  tuple.count >= 2, tuple[0] == instanceID,
                  tuple[1] == accountScope else { continue }
            defaults.removeObject(forKey: name)
        }
    }
}

/// 纯策略，不依赖 UIKit/SwiftUI：只有页面处于前台激活、可见、未跟随尾部且未取消时，
/// 才恢复阅读锚点。前台恢复应重新 load() 最新锚点，而不是复用页面初始化时读取的旧快照
/// （initialReadingPosition），因为期间历史窗口可能已经变化、旧锚点可能已失效或指向错误位置。
enum ReadingRestorePolicy {
    static func shouldRestoreAnchor(active: Bool, visible: Bool, following: Bool, cancelled: Bool) -> Bool {
        active && visible && !following && !cancelled
    }
}

/// 首屏「上次读到」提示所需的最小数据，纯值类型，不依赖视图层。
struct ReadingResumeSummary: Equatable, Sendable {
    let timestamp: Date
    let preview: String
}

/// 与消息模型解耦的轻量行快照。
///
/// 本文件与 ChatConversationSearch.swift、ChatViewportLayout.swift 一起被
/// `conversationreading` 组单独编译，看不到 ChatCore.swift 里的 ChatMessage，
/// 因此这里只接收视图层映射出来的 (rowID, timestamp, text)，不 import ChatCore。
struct ReadingResumeMessage: Equatable, Sendable {
    let rowID: String
    let timestamp: Date?
    let text: String
}

/// 纯函数摘要：按锚点的 rowID 找到对应行，去掉换行后截断成一行预览。
/// 锚点缺失、行已被裁掉、行没有时间戳或正文为空时返回 nil（不展示空提示）。
enum ReadingResumeSummaryBuilder {
    static func make(position: ChatReadingPosition?, messages: [ReadingResumeMessage],
                     maxLength: Int = 40) -> ReadingResumeSummary? {
        guard maxLength > 0, let position,
              let message = messages.first(where: { $0.rowID == position.rowID }),
              let timestamp = message.timestamp else { return nil }
        let flattened = message.text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        // prefix 以 Character（扩展字形簇）计数，不会切断 emoji 或组合字符。
        let preview = String(flattened.prefix(maxLength))
        guard !preview.isEmpty else { return nil }
        return ReadingResumeSummary(timestamp: timestamp, preview: preview)
    }
}
