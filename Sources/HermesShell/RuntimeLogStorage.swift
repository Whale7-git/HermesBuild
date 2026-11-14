import Foundation

struct RuntimeLogBuffer<Element> {
    private var storage: [Element?]
    private var start = 0
    private(set) var count = 0

    init(capacity: Int) { storage = Array(repeating: nil, count: max(1, capacity)) }
    mutating func append(_ value: Element) {
        if count < storage.count { storage[(start + count) % storage.count] = value; count += 1 }
        else { storage[start] = value; start = (start + 1) % storage.count }
    }
    var elements: [Element] { (0..<count).compactMap { storage[(start + $0) % storage.count] } }
}

enum RuntimeLogStorage {
    // A burst of failed requests may flush concurrently. Serialize the entire
    // replacement + retention pass so two writers cannot each keep a full quota.
    private static let lock = NSLock()

    /// 写盘失败一律向调用方抛出，并额外写一行 stderr：诊断日志是失败现场的唯一留底，
    /// 静默吞掉会让「日志里什么都没有」和「确实没出错」无法区分（F-71）。
    /// 被拒绝的入参（文件名不合规、超过字节上限）只是不写入，不算错误。
    static func save(_ data: Data, in directory: URL, filename: String,
                     maxFiles: Int = 8, maxBytes: Int = 2 * 1024 * 1024) throws {
        lock.lock()
        defer { lock.unlock() }
        guard filename.hasPrefix("runtime-log-"), filename.hasSuffix(".txt"),
              filename == (filename as NSString).lastPathComponent,
              data.count <= maxBytes else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: directory.appendingPathComponent(filename),
                           options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            #endif
        } catch {
            // 抛给调用方之外，再往 stderr 留一行：日志写入本身失败时，
            // 这正是唯一还能落地的诊断（不弹 UI、不递归写日志）。
            Self.reportWriteFailure(error, filename: filename, directory: directory)
            throw error
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let candidates = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .compactMap { url -> (url: URL, size: Int, date: Date)? in
                // 可忽略：单个文件读不到属性就跳过，不影响本次写入结果。
                guard url.lastPathComponent.hasPrefix("runtime-log-"), url.pathExtension == "txt",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date }
        var retained = 0
        for (index, candidate) in candidates.enumerated() {
            if index >= max(0, maxFiles) || candidate.size > maxBytes - retained {
                // 可忽略：本次写入已成功，清理旧文件失败只会多占一点空间。
                try? manager.removeItem(at: candidate.url)
            } else { retained += candidate.size }
        }
    }

    /// 日志写盘失败时的兜底诊断：直接写 stderr，不经过日志系统本身（避免递归）。
    /// 这条 stderr 写入本身失败时已无处上报，只能忽略。
    private static func reportWriteFailure(_ error: Error, filename: String, directory: URL) {
        let line = "runtime-log write failed: \(filename) in \(directory.path): \(error.localizedDescription)\n"
        _ = try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}

/// Pure value scope used to partition runtime logs per account/session.
/// `key` encodes the tuple as JSON before base64 so distinct triples can never
/// collide (a delimiter-joined string could); it depends on no other file.
struct RuntimeLogScope: Hashable, Codable, Sendable {
    let instanceID: String
    let accountScope: String
    let sessionID: String

    var key: String { Self.encodedTuple([instanceID, accountScope, sessionID]) }

    /// Opaque account namespace for persisted filenames. Unlike a prefix of the
    /// base64 tuple, it includes both complete identity components.
    var accountFileKey: String {
        Self.fileKey(Self.encodedData([instanceID, accountScope]))
    }

    var scopeFileKey: String { Self.fileKey(Data(key.utf8)) }

    /// 三元组 → base64 JSON。正常路径与历史键逐字节一致（日志文件名不变）；
    /// `[String]` 编码实际不会失败，但这里不用 `try!`：失败时退回长度前缀编码，
    /// 仍是单射，只是那一条日志落在另一个命名空间（读不到旧文件，不会串号）。
    private static func encodedTuple(_ values: [String]) -> String {
        encodedData(values).base64EncodedString()
    }

    private static func encodedData(_ values: [String]) -> Data {
        if let data = try? JSONEncoder().encode(values) { return data }
        let fallback = values.map { "\($0.utf8.count):\($0)" }.joined()
        return Data(("len:" + fallback).utf8)
    }

    private static func fileKey(_ data: Data) -> String {
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 7809847782465536322
        for byte in data {
            first = (first ^ UInt64(byte)) &* 1099511628211
            second = (second ^ UInt64(byte)) &* 14029467366897019727
        }
        return String(format: "%016llx%016llx", first, second)
    }
}

/// Explicit, opt-in gate for diagnostic log submission.
enum RuntimeLogUploadPolicy {
    static let defaultEnabled = false
    static func shouldSubmit(enabled: Bool, scopeMatches: Bool) -> Bool {
        enabled && scopeMatches
    }
}
