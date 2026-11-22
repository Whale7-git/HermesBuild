import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AttachmentError: LocalizedError, Equatable {
    /// `tooMany` 与 `tooLarge` 必须分开：数量满额时说「超过大小限制」会让用户
    /// 反复压缩图片而问题依旧，因为他们需要的是删掉一个附件。
    case invalidMetadata, invalidMultipart, tooMany, tooLarge, unsafeURL, unsupportedPreview, uploadFailed, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "附件信息无效"
        case .invalidMultipart: return "附件名称、类型或上传边界无效"
        case .tooMany: return "附件数量已达上限，请先移除一个再添加"
        case .tooLarge: return "附件超过大小限制（包含上传封装）"
        case .uploadFailed: return "附件上传失败，原始草稿已保留；检查网络后重试发送"
        case .unsafeURL: return "已阻止非当前实例的附件请求"
        case .unsupportedPreview: return "此文件类型不支持安全图片预览"
        case .http(let code): return code == 401 ? "登录已失效，请重新登录" : "附件请求失败（HTTP \(code)）"
        }
    }
}

/// UI-facing preview diagnosis. Never print URLs, opaque paths, API keys,
/// response bodies or raw transport errors from a private attachment request.
enum AttachmentImageFailurePresentation {
    static func reason(for error: Error) -> String {
        if let failure = error as? AttachmentError {
            switch failure {
            case .http(401), .http(403): return "无权读取此附件，请检查当前实例登录状态"
            case .http(404): return "服务器找不到附件文件"
            case .http(let status): return "附件请求失败（HTTP \(status)）"
            case .unsafeURL: return "附件来源或路径未通过安全校验"
            case .unsupportedPreview: return "服务器未返回受支持的图片格式"
            case .tooLarge: return "图片超过预览大小限制"
            case .uploadFailed: return "附件上传失败"
            case .invalidMetadata, .invalidMultipart, .tooMany:
                return "附件元数据不完整"
            }
        }
        if let failure = error as? URLError {
            switch failure.code {
            case .timedOut: return "附件请求超时"
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络连接中断"
            case .cannotFindHost, .cannotConnectToHost:
                return "无法连接附件服务器"
            default: return "附件网络请求失败"
            }
        }
        return "无法读取图片，请重试"
    }
}

/// 附件文件名的唯一清洗入口。
///
/// 三处调用（multipart 头、下载落盘、服务端字段解析）必须行为一致，否则会出现
/// 「上传叫 A、下载叫 B」或某一条路径漏过滤的情况。这里只做纯字符串处理，不碰文件系统。
enum AttachmentFilenameSanitizer {
    /// 会改变显示或落盘语义的不可见字符：Cc（控制符）与 Cf（格式符）。
    /// U+202E（RLO）能把 `exe.txt` 显示成 `txt.exe`，落盘前必须替换掉；
    /// U+200B（零宽空格）、U+FEFF（BOM）、U+2066-2069（bidi 隔离）同理。
    ///
    /// 这里按 Unicode 通用类别判定而不是维护清单：Cf 里还有 U+00AD（软连字符）、
    /// U+2060（word joiner）、U+E0020-U+E007F（标签字符，可以拼出「看得见开头、
    /// 看不见结尾」的伪造文件名）等，清单法必然漏掉一部分。也不依赖
    /// `CharacterSet.controlCharacters`——它的内容随平台实现变化（Apple 与 corelibs
    /// 并不一致），按类别判定才能保证三处调用在同一份名单上。
    ///
    /// 不保留 U+200D（ZWJ）：它是 Cf，留着会让 `createDestination` 的平台相关
    /// 守卫在 Apple 上拒收整个文件，代价比 emoji 名字被拆开更大。
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    /// 取最后一个路径分量。`\` 与 `/` 都当分隔符：服务端可能回传 Windows 风格路径，
    /// 而落盘时 `createDestination` 明确拒绝 `\`（F-54）。
    static func lastComponent(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// 字符替换 + 按 UTF-8 字节截断。`escapingQuotes` 用于 multipart 头：
    /// 服务端解析器不认 quoted-pair，双引号会提前结束 filename 字段。
    /// `preserveExtension` 只对文件名有意义；MIME 里的 `.` 不是扩展名，必须关掉。
    ///
    /// 先做 NFC 归一化：同一个文件名可能有组合式（`e` + U+0301）与预组合式（`é`）
    /// 两种编码，不归一化就会出现「同名不同字节」，去重与扩展名判断都会分叉。
    /// 这里刻意不用 NFKC——兼容分解会把 `．`（U+FF0E）之类折成 `.`，可能在上层
    /// 已做完 `..` 段检查之后才合成出新的路径分隔符/父目录段。
    static func sanitize(_ value: String, maxBytes: Int,
                         escapingQuotes: Bool = true,
                         preserveExtension: Bool = true) -> String {
        let mapped = value.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> String in
            if isInvisible(scalar) { return "_" }
            if escapingQuotes && scalar == "\"" { return "_" }
            return String(scalar)
        }.joined()
        return truncateUTF8(mapped, maxBytes: maxBytes, preserveExtension: preserveExtension)
    }

    /// 按 UTF-8 字节截断（避免 ENAMETOOLONG），并尽量保留扩展名以便按类型打开。
    /// 以 Character 迭代，不会切断 emoji 或组合字符；扩展名只出现一次。
    static func truncateUTF8(_ value: String, maxBytes: Int, preserveExtension: Bool = true) -> String {
        guard maxBytes > 0 else { return "" }
        guard value.utf8.count > maxBytes else { return value }
        let ext = preserveExtension ? (value as NSString).pathExtension : ""
        let stem = preserveExtension ? (value as NSString).deletingPathExtension : value
        // 没有可用主干（如 ".png"）时不拆扩展名，直接按字节截。
        let suffix = ext.isEmpty || stem.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        let source = suffix.isEmpty ? value : stem
        let budget = maxBytes - suffix.utf8.count
        var kept = ""
        var used = 0
        for character in source {
            let width = String(character).utf8.count
            if used + width > budget { break }
            kept.append(character)
            used += width
        }
        // 一个字符都放不下时返回空串，交给调用方按「无效名字」拒绝，
        // 不要硬塞一个超预算的字符。
        return kept.isEmpty ? "" : kept + suffix
    }

    /// multipart 头里的文件名：只取叶子，不因 `..` 段拒绝（那只是头里的字符串）。
    static func headerLeaf(_ raw: String) -> String? {
        let safe = sanitize(lastComponent(raw), maxBytes: 200)
        guard !safe.isEmpty, !safe.allSatisfy({ $0 == "." }) else { return nil }
        return safe
    }

    /// 可落盘的叶子名：拒绝任何 `.` / `..` 段与空结果，再清洗字符（F-75/F-76）。
    /// 落盘不转义双引号：它是合法文件名字符，`createDestination` 也不拒绝。
    static func safeLeaf(_ raw: String) -> String? {
        let components = raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else { return nil }
        let safe = sanitize(components.last.map(String.init) ?? "", maxBytes: 200, escapingQuotes: false)
        guard !safe.isEmpty, !safe.allSatisfy({ $0 == "." }) else { return nil }
        return safe
    }
}

struct AttachmentMultipart: Sendable {
    /// Deployed default limits the entire HTTP body, not only the file bytes.
    static let defaultMaxBytes = 20 * 1024 * 1024
    let body: Data
    let boundary: String

    init(sessionID: String, filename: String, mime: String, data: Data,
         boundary: String = "Hermes-" + UUID().uuidString, maxBytes: Int = defaultMaxBytes) throws {
        let allowedBoundary = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let mimePattern = #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#
        guard !sessionID.isEmpty, !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.unicodeScalars.allSatisfy({ allowedBoundary.contains($0) }),
              mime.range(of: mimePattern, options: .regularExpression) != nil else { throw AttachmentError.invalidMultipart }
        guard maxBytes > 0, data.count <= maxBytes else { throw AttachmentError.tooLarge }
        // Deployed parser uses filename="([^"]*)", so quoted-pair escaping is NOT safe.
        guard let safe = AttachmentFilenameSanitizer.headerLeaf(filename) else { throw AttachmentError.invalidMultipart }
        let marker = Data(("--" + boundary).utf8)
        guard data.range(of: marker) == nil, !sessionID.contains("--" + boundary), !safe.contains("--" + boundary) else { throw AttachmentError.invalidMultipart }
        var encoded = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"session_id\"\r\n\r\n\(sessionID)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\nContent-Type: \(mime)\r\n\r\n").utf8)
        guard encoded.count <= maxBytes - data.count else { throw AttachmentError.tooLarge }
        encoded.append(data)
        let tail = Data(("\r\n--\(boundary)--\r\n").utf8)
        guard tail.count <= maxBytes - encoded.count else { throw AttachmentError.tooLarge }
        encoded.append(tail)
        self.body = encoded
        self.boundary = boundary
    }

    func request(baseURL: URL, route: String = "api/upload",
                 authorization: AttachmentAuthorization = .cookieOnly) throws -> URLRequest {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw AttachmentError.unsafeURL }
        // 路由由后端声明：WebUI 是 `api/upload`，网关是 `v1/files`（attachments 插件）。
        // 写死任一个都会让另一种后端 404，所以由 `HermesBackend.attachmentUploadRoute` 决定。
        var request = URLRequest(url: baseURL.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 认证必须与路由同源：网关的 `/v1/files` 只认 `Authorization: Bearer`
        // （`api_server._check_auth` 完全不看 cookie），WebUI 的 `api/upload` 靠 cookie。
        // 原先这里不带任何认证头，于是纯网关实例的上传必然 401——而预览路径
        // 早就按 `attachmentPreviewAuthorization` 分好了，只有上传这一跳漏了。
        if let header = authorization.header {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

enum AttachmentUploadState: Equatable, Sendable {
    case queued
    case uploading(Double)
    case ready(UploadedAttachment)
    case failed(String)
}

struct AttachmentDraft: Identifiable, Sendable {
    let id: UUID
    let name: String
    let mime: String
    /// 原始字节。上传成功后会释放（置空）以回收内存。图片重新编辑时按需
    /// 从服务端读取原图，不再让整批图片常驻到会话结束。
    /// `fileprivate(set)`：只有同文件的 `AttachmentBatch` 能清空它。
    fileprivate(set) var data: Data
    /// 字节数在构造时固定下来，释放 `data` 后容量核算与界面显示仍要它。
    let byteCount: Int
    fileprivate(set) var state: AttachmentUploadState = .queued
    fileprivate var attempt: UUID?
    /// 编辑后替换过字节：重新上传时用不同文案，避免看起来像「没生效」。
    fileprivate(set) var reuploading = false

    init(id: UUID, name: String, mime: String, data: Data, declaredByteCount: Int? = nil) {
        self.id = id
        self.name = name
        self.mime = mime
        self.data = data
        self.byteCount = declaredByteCount ?? data.count
    }

    /// 服务端已有副本后，本地字节一律释放。图片编辑会通过
    /// `AttachmentPreviewLoader` 重新取得原图；上传失败或排队时字节仍在。
    var releasesBytesAfterUpload: Bool { true }

    var canResumeUpload: Bool {
        switch state {
        case .queued, .failed: return !data.isEmpty
        default: return false
        }
    }
}

/// Durable composer state. It deliberately excludes cookies, bearer tokens,
/// upload attempts and progress. Uploads restart from their original bytes
/// after process recreation; completed uploads retain only the server reference.
struct PersistedAttachmentDraft: Codable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
        case pending
        case ready(UploadedAttachment)
    }

    let id: UUID
    let name: String
    let mime: String
    let byteCount: Int
    let data: Data
    let state: State
    let reuploading: Bool
}

struct PersistedAttachmentBatch: Codable, Equatable, Sendable {
    let version: Int
    let sessionID: String
    let items: [PersistedAttachmentDraft]

    static let currentVersion = 1
}

/// Value-state is independently tested; completion must match both chip and upload attempt.
struct AttachmentBatch: Sendable {
    private(set) var sessionID: String
    private(set) var items: [AttachmentDraft] = []
    let maxCount: Int
    let maxTotalBytes: Int
    init(sessionID: String, maxCount: Int = 8, maxTotalBytes: Int = 40 * 1024 * 1024) {
        self.sessionID = sessionID
        self.maxCount = maxCount
        self.maxTotalBytes = maxTotalBytes
    }
    var canSend: Bool { items.allSatisfy { if case .ready = $0.state { return true }; return false } }
    mutating func append(name: String, mime: String, data: Data) throws -> UUID {
        guard !sessionID.isEmpty, !name.isEmpty, !mime.isEmpty else { throw AttachmentError.invalidMetadata }
        guard items.count < maxCount else { throw AttachmentError.tooMany }
        guard data.count <= AttachmentMultipart.defaultMaxBytes,
              data.count <= maxTotalBytes - items.reduce(0, { $0 + $1.byteCount }) else {
            throw AttachmentError.tooLarge
        }
        let id = UUID()
        items.append(AttachmentDraft(id:id, name:name, mime:mime, data:data))
        return id
    }
    mutating func begin(_ id: UUID) throws -> UUID {
        guard let index = items.firstIndex(where:{$0.id == id}) else { throw AttachmentError.invalidMetadata }
        switch items[index].state {
        case .queued, .failed: break
        default: throw AttachmentError.invalidMetadata
        }
        guard !items[index].data.isEmpty else { throw AttachmentError.invalidMetadata }
        let attempt = UUID()
        items[index].attempt = attempt
        items[index].state = .uploading(0)
        return attempt
    }
    private func current(_ id: UUID, attempt: UUID) -> Int? {
        items.firstIndex { item in
            guard item.id == id, item.attempt == attempt else { return false }
            if case .uploading = item.state { return true }
            return false
        }
    }
    mutating func progress(_ id: UUID, attempt: UUID, fraction: Double) {
        guard fraction.isFinite, let index = current(id, attempt:attempt), case .uploading(let previous) = items[index].state else { return }
        items[index].state = .uploading(max(previous, min(1, max(0, fraction))))
    }
    mutating func complete(_ id: UUID, attempt: UUID, attachment: UploadedAttachment) {
        guard let index = current(id, attempt:attempt) else { return }
        items[index].state = .ready(attachment)
        // 服务端已有副本，本地不再需要原始字节。图片编辑时再按需下载，
        // 否则 8 个 20MB 附件会常驻到会话结束。
        if items[index].releasesBytesAfterUpload { items[index].data = Data() }
    }
    mutating func fail(_ id: UUID, attempt: UUID, message: String) {
        guard let index = current(id, attempt:attempt) else { return }
        items[index].state = .failed(message)
    }
    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    /// Re-arm a failed upload without issuing a network request before send.
    mutating func requeue(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .failed = items[index].state,
              !items[index].data.isEmpty else { throw AttachmentError.invalidMetadata }
        items[index].attempt = nil
        items[index].state = .queued
    }
    /// Cancellation does not imply the transport has stopped. Invalidate its
    /// attempt but retain the local bytes for explicit retry on the next send.
    mutating func suspendUploading() {
        for index in items.indices {
            if case .uploading = items[index].state {
                items[index].attempt = nil
                items[index].state = .queued
            }
        }
    }
    /// Replace atomically: a failed edit must leave the original ready payload
    /// intact, and an old upload attempt must never complete the edited chip.
    mutating func replace(_ id: UUID, name: String, mime: String, data: Data) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !name.isEmpty, !mime.isEmpty, !data.isEmpty else { throw AttachmentError.invalidMetadata }
        let others = items.filter { $0.id != id }.reduce(0) { $0 + $1.byteCount }
        guard data.count <= AttachmentMultipart.defaultMaxBytes,
              data.count <= maxTotalBytes - others else { throw AttachmentError.tooLarge }
        items[index] = AttachmentDraft(id: id, name: name, mime: mime, data: data)
        items[index].reuploading = true
    }
    mutating func reset(sessionID: String) { self.sessionID = sessionID; items.removeAll() }

    /// P1：恢复一批**已在服务端**的附件（用于编辑队列项时回填）。
    ///
    /// 队列项里的 `ChatAttachmentPayload` 是已经上传完成的，手里有它的
    /// `path`/`name`/`size`——没有本地字节，也不需要重新上传。直接构造成
    /// `.ready` 状态的草稿，`payload(for:)` 会原样取出，编辑后再次发送时
    /// 附件引用不丢。
    ///
    /// 服务端引用包含 size，恢复后应维持展示与配额字节数；
    /// 本机 Data 仍为空，表明不持有原始文件字节。
    mutating func restoreReady(_ payloads: [ChatAttachmentPayload]) {
        for p in payloads {
            guard items.count < maxCount else { return }
            // Server-provided metadata must not undermine quota calculations.
            guard p.size >= 0, p.size <= AttachmentMultipart.defaultMaxBytes,
                  p.size <= maxTotalBytes - items.reduce(0, { $0 + $1.byteCount }) else { continue }
            let uploaded = UploadedAttachment(name: p.name, path: p.path,
                                              size: p.size, mime: p.mime,
                                              isImage: p.isImage)
            var draft = AttachmentDraft(id: UUID(), name: p.name, mime: p.mime,
                                        data: Data(), declaredByteCount: p.size)
            draft.state = .ready(uploaded)
            items.append(draft)
        }
    }

    var persistedValue: PersistedAttachmentBatch {
        PersistedAttachmentBatch(
            version: PersistedAttachmentBatch.currentVersion,
            sessionID: sessionID,
            items: items.map { item in
                let state: PersistedAttachmentDraft.State
                switch item.state {
                case .ready(let uploaded):
                    state = .ready(uploaded)
                case .queued, .uploading, .failed:
                    // An interrupted process cannot own the old upload task.
                    // Retain its verified local bytes and queue one new upload.
                    state = .pending
                }
                return PersistedAttachmentDraft(
                    id: item.id, name: item.name, mime: item.mime,
                    byteCount: item.byteCount, data: item.data, state: state,
                    reuploading: item.reuploading)
            })
    }

    mutating func restorePersisted(_ value: PersistedAttachmentBatch) throws {
        guard value.version == PersistedAttachmentBatch.currentVersion,
              value.sessionID == sessionID,
              value.items.count <= maxCount,
              Set(value.items.map(\.id)).count == value.items.count else {
            throw AttachmentError.invalidMetadata
        }
        var restored: [AttachmentDraft] = []
        var totalBytes = 0
        for persisted in value.items {
            guard !persisted.name.isEmpty, !persisted.mime.isEmpty,
                  persisted.byteCount >= 0,
                  persisted.byteCount <= AttachmentMultipart.defaultMaxBytes,
                  persisted.data.count <= persisted.byteCount,
                  persisted.byteCount <= maxTotalBytes - totalBytes else {
                throw AttachmentError.tooLarge
            }
            totalBytes += persisted.byteCount
            var item = AttachmentDraft(
                id: persisted.id, name: persisted.name, mime: persisted.mime,
                data: persisted.data, declaredByteCount: persisted.byteCount)
            item.reuploading = persisted.reuploading
            switch persisted.state {
            case .ready(let uploaded):
                guard uploaded.name == persisted.name, uploaded.mime == persisted.mime,
                      uploaded.size == persisted.byteCount else {
                    throw AttachmentError.invalidMetadata
                }
                item.state = .ready(uploaded)
                if item.releasesBytesAfterUpload { item.data = Data() }
            case .pending:
                guard !persisted.data.isEmpty else { throw AttachmentError.invalidMetadata }
                item.state = .queued
            }
            restored.append(item)
        }
        items = restored
    }

    func payload(for sessionID: String) throws -> [UploadedAttachment] {
        guard self.sessionID == sessionID, canSend else { throw AttachmentError.invalidMetadata }
        return items.compactMap { if case .ready(let attachment) = $0.state { return attachment }; return nil }
    }
}

enum AttachmentKind: Equatable, Sendable {
    case image, video, audio, pdf, spreadsheet, archive, document, other
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .archive: return "archivebox"
        case .document: return "doc"
        case .other: return "doc"
        }
    }
    static func classify(name: String, mime: String) -> AttachmentKind {
        let type = mime.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if type.hasPrefix("image/") {
            // SVG and other non-raster images are not natively rendered inline.
            let raster = AttachmentPreviewPolicy.rasterMIMEs.contains(type)
            return raster ? .image : .other
        }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        if type == "application/pdf" { return .pdf }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "xls", "xlsx", "numbers", "csv", "tsv": return .spreadsheet
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": return .archive
        case "doc", "docx", "txt", "md", "rtf", "pages", "ppt", "pptx", "key": return .document
        default: return .other
        }
    }
    /// Raster MIME for a path extension, when it is a natively-previewable image.
    static func mime(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return ""
        }
    }
    static func rasterImage(name: String) -> Bool {
        !mime(forPathExtension: (name as NSString).pathExtension).isEmpty
    }
}


enum AttachmentRouteFallback {
    /// Only route-compatibility failures permit the legacy endpoint. Auth,
    /// transport, decoding and size errors must keep their original meaning.
    static func allows(_ error: Error) -> Bool {
        guard case AttachmentError.http(let code) = error else { return false }
        return [404, 405, 501].contains(code)
    }
}

/// A successful URL is leased to its UI consumer until remove(). The registry
/// protects active downloads and presented files from the janitor. A new app
/// process has no old leases, so abandoned directories can be reclaimed.
enum AttachmentDownloadFiles {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var active = Set<String>()
    }
    private static let registry = Registry()
    private static var root: URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("HermesDownloads", isDirectory: true).standardizedFileURL
    }

    static func createDestination(leaf: String) throws -> URL {
        guard !leaf.isEmpty, leaf != ".", leaf != "..",
              !leaf.contains("/"), !leaf.contains("\\"),
              !leaf.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AttachmentError.invalidMetadata
        }
        return try registry.lock.withLock {
            let manager = FileManager.default
            guard !isSymlink(root) else { throw AttachmentError.unsafeURL }
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            registry.active.insert(directory.path)
            return directory.appendingPathComponent(leaf)
        }
    }

    /// Accept only a direct file in this module's UUID directory. Never follow
    /// caller-supplied symlinks or delete a URL from a picker/share destination.
    static func remove(_ url: URL) {
        registry.lock.withLock {
            guard url.isFileURL else { return }
            let normalized = url.standardizedFileURL
            let directory = normalized.deletingLastPathComponent()
            guard !isSymlink(root), directory.deletingLastPathComponent() == root,
                  UUID(uuidString: directory.lastPathComponent) != nil,
                  !isSymlink(directory), !isSymlink(normalized) else { return }
            registry.active.remove(directory.path)
            // 可忽略：目录清理失败只会让 tmp 多占一点空间，下次启动的 purge 会再试。
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 清理上次进程遗留的下载目录。
    ///
    /// 正常流程会在分享结束时删掉目录，但进程被杀、崩溃或用户在分享面板里
    /// 直接划掉 App 时来不及执行，`tmp/HermesDownloads` 会越积越多（单份可能是
    /// 几十 MB 的原图或导出文件）。启动时扫一遍，只保留本次进程正在用的目录。
    ///
    /// 只删本模块自己的 UUID 目录，不跟随符号链接，`keeping` 里的名字受保护。
    /// 返回删除的目录数，便于诊断日志与测试断言。
    @discardableResult
    static func purge(root overrideRoot: URL? = nil, keeping: Set<String> = []) -> Int {
        registry.lock.withLock {
            let manager = FileManager.default
            let target = overrideRoot ?? root
            guard !isSymlink(target) else { return 0 }
            // 可忽略：目录不存在或读不了就当没有遗留目录，清理是尽力而为。
            let entries = (try? manager.contentsOfDirectory(at: target,
                                                            includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var removed = 0
            for entry in entries {
                let name = entry.lastPathComponent
                // 只处理 UUID 目录：其它文件（含旧版扁平文件）交给 cleanupExpired。
                guard UUID(uuidString: name) != nil, !keeping.contains(name) else { continue }
                guard !isSymlink(entry) else { continue }
                // 可忽略：读不到属性就跳过这一项，不阻断其它目录的清理。
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDirectory else { continue }
                // 本进程正在使用的目录绝不删除。
                guard !registry.active.contains(entry.path) else { continue }
                if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
            }
            return removed
        }
    }

    /// Run off the main actor. Pinned URLs are never evicted, even when their
    /// previews outlive the age/byte budget. Legacy flat files are unleased.
    static func cleanupExpired(maxAge: TimeInterval = 24 * 60 * 60,
                               maxTotalBytes: Int64 = 128 * 1024 * 1024) {
        registry.lock.withLock {
            let manager = FileManager.default
            guard !isSymlink(root) else { return }
            // 可忽略：列目录失败只是本轮没东西可清，不影响预览/下载。
            let files = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let entries = files.compactMap { entry -> (URL, Date, Int64, Bool)? in
                // 可忽略：读不到属性的条目直接跳过，本轮不参与配额计算。
                guard !isSymlink(entry), let attrs = try? manager.attributesOfItem(atPath: entry.path) else { return nil }
                let directory = attrs[.type] as? FileAttributeType == .typeDirectory
                guard directory ? UUID(uuidString: entry.lastPathComponent) != nil : attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
                let size: Int64
                if directory {
                    // 可忽略：单个子项大小读不到就按 0 计，配额只是近似上限。
                    size = ((try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []).reduce(0) { total, child in
                        guard !isSymlink(child) else { return total }
                        return total + ((try? manager.attributesOfItem(atPath: child.path)[.size] as? NSNumber)?.int64Value ?? 0)
                    }
                } else { size = (attrs[.size] as? NSNumber)?.int64Value ?? 0 }
                return (entry, attrs[.modificationDate] as? Date ?? .distantPast, size, registry.active.contains(entry.path))
            }.sorted { $0.1 < $1.1 }
            var total = entries.reduce(Int64(0)) { $0 + $1.2 }
            for (entry, modified, size, active) in entries where !active {
                if -modified.timeIntervalSinceNow >= max(0, maxAge) || total > max(0, maxTotalBytes) {
                    if (try? manager.removeItem(at: entry)) != nil { total -= size }
                }
            }
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        // 可忽略：读不到属性时按「不是符号链接」处理；真正敏感的判断都在
        // createDestination 里用抛错版本复核，这里只用于跳过清理候选。
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

/// 把调用方传入的 `URLSessionConfiguration` 复制并加固成专用会话配置。
///
/// `copy()` 的静态类型是 `Any`，历史实现用 `as!` 强转。它实际上只会返回同一个类，
/// 但强转崩溃没有收益：失败时退回全新的 `.ephemeral`——那正是下面要加固成的目标形态
/// （无 cookie、无凭据、无缓存），不会引入凭据泄漏，也不会让上传/下载直接不可用。
enum AttachmentSessionConfiguration {
    static func hardened(_ configuration: URLSessionConfiguration,
                         requestTimeout: TimeInterval,
                         resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let config = (configuration.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return config
    }
}


/// Attaches exactly one credential mechanism to an internal file request.
/// Cookies are scoped by host/path, not TCP port: a WebUI login cookie can be
/// visible to a Gateway on the same host with a different port. Bearer traffic
/// must therefore never forward ambient WebUI cookies.
enum AttachmentRequestAuthentication {
    static func apply(to request: inout URLRequest,
                      authorization: AttachmentAuthorization,
                      cookies: [HTTPCookie]) {
        // Clear accidental inherited headers before selecting one mechanism.
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        if authorization.requiresBearer {
            if let header = authorization.header {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            // A missing API key means an unauthenticated Gateway request, not
            // permission to fall back to a same-host WebUI session cookie.
            return
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}

/// Writes any bounded, same-origin raw file to a temp file for Quick Look / Share.
/// Distinct from the inline-image preview: no raster MIME requirement, streams to disk.
struct AttachmentFileDownloader: Sendable {
    let policy: AttachmentPreviewPolicy
    private let configuration: URLSessionConfiguration
    private let cookieStorage: HTTPCookieStorage
    init(policy: AttachmentPreviewPolicy, configuration: URLSessionConfiguration = .ephemeral,
         cookieStorage: HTTPCookieStorage = .shared) {
        self.policy = policy
        self.configuration = AttachmentSessionConfiguration.hardened(configuration,
                                                                     requestTimeout: 60,
                                                                     resourceTimeout: 120)
        self.cookieStorage = cookieStorage
    }
    /// 服务端文件名 → 可落盘的叶子名。`\` 先归一为 `/`（服务端可能回传 Windows
    /// 风格路径，而 `createDestination` 拒绝 `\`，否则这类文件永远下载失败，F-54）；
    /// 再拒绝 `..`/`.` 段、过滤 bidi 等不可见字符、按 UTF-8 字节截断（F-75/F-76）。
    static func safeLeaf(_ name: String) -> String? {
        AttachmentFilenameSanitizer.safeLeaf(name)
    }
    func download(sessionID: String, path: String, name: String,
                  progress: (@Sendable (AttachmentTransferProgress) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard let leaf = Self.safeLeaf(name) else { throw AttachmentError.invalidMetadata }
        if policy.authorization.requiresBearer {
            // Gateway origin has a native download endpoint; avoid WebUI probes.
            return try await fetch(policy.gatewayFileRequest(path: path), leaf: leaf, progress: progress)
        }
        // 路由顺序：WebUI 的 `/api/media` → `/api/file/raw` → 网关的 `/v1/files/by-path`。
        //
        // 前两条是 WebUI 的既有链路，语义必须原样保留（403/401 不降级，只有 404/405/501
        // 才换路由）。纯网关实例没有前两条，两次 404 之后由第三条兜底——把网关路由
        // 放在最后，而不是最前，是为了不改变 WebUI 实例的既有行为。
        do {
            return try await fetch(policy.mediaRequest(sessionID: sessionID, path: path), leaf: leaf, progress: progress)
        } catch {
            try Task.checkCancellation()
            guard AttachmentRouteFallback.allows(error) else { throw error }
        }
        do {
            return try await fetch(policy.downloadRequest(sessionID: sessionID, path: path, name: name), leaf: leaf, progress: progress)
        } catch {
            try Task.checkCancellation()
            guard AttachmentRouteFallback.allows(error) else { throw error }
            return try await fetch(policy.gatewayFileRequest(path: path), leaf: leaf, progress: progress)
        }
    }

    private func fetch(_ base: URLRequest, leaf: String,
                       progress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> URL {
        try Task.checkCancellation()
        var request = base
        guard let url = request.url, policy.allows(url) else { throw AttachmentError.unsafeURL }
        AttachmentRequestAuthentication.apply(to: &request, authorization: policy.authorization,
                                              cookies: cookieStorage.cookies(for: url) ?? [])
        let destination = try AttachmentDownloadFiles.createDestination(leaf: leaf)
        let transfer = AttachmentFileTransfer(policy: policy, destination: destination, progress: progress)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: { transfer.cancel() }
        do { try Task.checkCancellation() }
        catch { AttachmentDownloadFiles.remove(result); throw error }
        return result
    }
}

private final class AttachmentFileTransfer: AttachmentRedirectGuard, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: AttachmentPreviewPolicy
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received = 0
    private var expected: Int?
    private var lastProgress = 0.0
    private let progress: (@Sendable (AttachmentTransferProgress) -> Void)?
    private var finished = false
    init(policy: AttachmentPreviewPolicy, destination: URL,
         progress: (@Sendable (AttachmentTransferProgress) -> Void)?) {
        self.policy = policy
        self.destination = destination
        self.progress = progress
    }
    func start(request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<URL, Error>) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let shouldStart = lock.withLock {
            guard !finished else { return false }
            self.continuation = continuation
            self.session = session
            self.task = task
            return true
        }
        if shouldStart { task.resume() }
        else { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        let values = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URLSession?, FileHandle?)? in
            guard !finished else { return nil }
            finished = true
            let values = (continuation, session, handle)
            continuation = nil; session = nil; task = nil; handle = nil
            return values
        }
        guard let values else { return }
        values.2?.closeFile()
        values.1?.invalidateAndCancel()
        if case .failure = result { AttachmentDownloadFiles.remove(destination) }
        else { progress?(AttachmentTransferProgress(receivedBytes: received, expectedBytes: expected)) }
        values.0?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, let url = http.url, policy.allows(url) else { throw AttachmentError.unsafeURL }
            guard http.statusCode == 200 else { throw AttachmentError.http(http.statusCode) }
            try policy.validateDownloadResponse(size: Int(response.expectedContentLength))
            let opened = lock.withLock { () -> Bool in
                guard !finished else { return false }
                do {
                    _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
                    self.handle = try FileHandle(forWritingTo: destination)
                    expected = response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
                    return true
                } catch { return false }
            }
            guard opened else { throw AttachmentError.invalidMetadata }
            progress?(AttachmentTransferProgress(receivedBytes: 0, expectedBytes: response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil))
            completionHandler(.allow)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result = lock.withLock { () -> (Error?, AttachmentTransferProgress?) in
            guard !finished else { return (nil, nil) }
            guard data.count <= AttachmentMultipart.defaultMaxBytes - received else { return (AttachmentError.tooLarge, nil) }
            do {
                guard let handle else { return (AttachmentError.invalidMetadata, nil) }
                try handle.write(contentsOf: data)
                received += data.count
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 0.1 {
                    lastProgress = now
                    return (nil, AttachmentTransferProgress(receivedBytes: received, expectedBytes: expected))
                }
                return (nil, nil)
            } catch { return (error, nil) }
        }
        if let event = result.1 { progress?(event) }
        if let error = result.0 { finish(.failure(error)) }
    }
    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let accepted = lock.withLock { handle != nil }
        finish(accepted ? .success(destination) : .failure(AttachmentError.invalidMetadata))
    }
}

/// Called only with an explicit user-selected file URL, off the main actor.
enum AttachmentFileImport {
    static func read(_ url: URL, maxBytes: Int = AttachmentMultipart.defaultMaxBytes) throws -> Data {
        guard url.isFileURL, maxBytes > 0 else { throw AttachmentError.invalidMetadata }
        #if os(iOS) || os(macOS)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        let values = try url.resourceValues(forKeys:[.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AttachmentError.invalidMetadata }
        if let size = values.fileSize, size > maxBytes { throw AttachmentError.tooLarge }
        let handle = try FileHandle(forReadingFrom:url)
        // 可忽略：关闭只读句柄失败不影响已读出的字节。
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount:65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= maxBytes - data.count else { throw AttachmentError.tooLarge }
            data.append(chunk)
        }
        return data
    }
}

/// Upload execution is injectable; the app adapter uses HermesAPI.performNative.
@MainActor final class AttachmentUploadCoordinator {
    /// 第三个参数报上传进度（0...1）。实现方按需转成 `batch.progress`。
    /// 进度回调必须 `@escaping`：上传实现在 `URLSession` 的 delegate 线程上
    /// 回调它，生命周期超出闭包体，非逃逸会在 Release 编译报
    /// `escaping closure captures non-escaping parameter`。
    typealias Upload = @MainActor (String, AttachmentDraft,
                                   @escaping @MainActor (Double) -> Void) async throws -> UploadedAttachment
    private(set) var batch: AttachmentBatch
    var onChange: (@MainActor (AttachmentBatch) -> Void)?
    private let upload: Upload
    /// Only two multipart bodies may be built/sent concurrently. Eight large
    /// drafts already consume the composer byte budget; eight parallel uploads
    /// could double it in transport buffers and overwhelm a weak network.
    private let maxConcurrentUploads = 2
    /// Bytes retained by requests that have not completed transport teardown.
    /// A large upload may occupy the full byte budget by itself.
    private let maxInFlightBytes = 24 * 1024 * 1024
    private var waiting: [UUID] = []
    private var tasks: [UUID: (attempt: UUID, byteCount: Int, task: Task<Void, Never>)] = [:]
    init(sessionID: String, upload: @escaping Upload) {
        self.batch = AttachmentBatch(sessionID:sessionID)
        self.upload = upload
    }
    deinit {
        for value in tasks.values { value.task.cancel() }
    }
    /// Draft selection is local only. No gateway file is created until send.
    @discardableResult func add(name: String, mime: String, data: Data) throws -> UUID {
        let id = try batch.append(name:name, mime:mime, data:data)
        onChange?(batch)
        return id
    }
    /// UI retry just re-arms the draft. It must not eagerly upload a file that
    /// the user may delete or abandon before sending.
    func retry(_ id: UUID) throws {
        guard let draft = batch.items.first(where: { $0.id == id }) else {
            throw AttachmentError.invalidMetadata
        }
        if case .failed = draft.state { try batch.requeue(id) }
        else if case .queued = draft.state { return }
        else { throw AttachmentError.invalidMetadata }
        onChange?(batch)
    }
    /// The only entry point for upload transport. A failed or cancelled attempt
    /// never submits a chat POST; ready file references survive an upload retry.
    func prepareForSend(sessionID: String) async throws -> [UploadedAttachment] {
        guard batch.sessionID == sessionID else { throw AttachmentError.invalidMetadata }
        for draft in batch.items {
            if case .failed = draft.state { try batch.requeue(draft.id) }
            if draft.canResumeUpload && !waiting.contains(draft.id) && tasks[draft.id] == nil {
                waiting.append(draft.id)
            }
        }
        startQueuedIfPossible()
        let deadline = Date().addingTimeInterval(135)
        while true {
            try Task.checkCancellation()
            guard batch.sessionID == sessionID else { throw AttachmentError.invalidMetadata }
            if batch.canSend { return try batch.payload(for: sessionID) }
            if batch.items.contains(where: { if case .failed = $0.state { return true }; return false }) {
                throw AttachmentError.uploadFailed
            }
            if Date() > deadline {
                cancelUploads()
                throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
    }
    /// Leave durable bytes queued after navigation/cancellation; late callbacks
    /// cannot make old attempts ready or overwrite another conversation.
    func cancelUploads() {
        for task in tasks.values { task.task.cancel() }
        waiting.removeAll()
        batch.suspendUploading()
        onChange?(batch)
    }
    private func startQueuedIfPossible() {
        while tasks.count < maxConcurrentUploads, !waiting.isEmpty {
            let id = waiting[0]
            // A replacement can share an ID with a still-in-flight cancelled
            // transport. Never overwrite its task record or its memory charge.
            guard tasks[id] == nil else { break }
            guard let draft = batch.items.first(where: { $0.id == id }) else {
                waiting.removeFirst()
                continue
            }
            let occupied = tasks.values.reduce(0) { $0 + $1.byteCount }
            guard draft.byteCount <= maxInFlightBytes - occupied else { break }
            waiting.removeFirst()
            let attempt: UUID
            do { attempt = try batch.begin(id) } catch { continue }
            let sessionID = batch.sessionID
            onChange?(batch)
            let task = Task { [weak self, upload] in
                do {
                    let attachment = try await upload(sessionID, draft) { [weak self] fraction in
                        self?.batch.progress(id, attempt: attempt, fraction: fraction)
                        if let self { self.onChange?(self.batch) }
                    }
                    try Task.checkCancellation()
                    self?.batch.complete(id, attempt: attempt, attachment: attachment)
                } catch {
                    if !(error is CancellationError || Task.isCancelled) {
                        self?.batch.fail(id, attempt: attempt, message: error.localizedDescription)
                    }
                }
                // A cancelled/removed request cannot reclaim a slot or
                // mutate the batch of a subsequent session.
                if let self, self.tasks[id]?.attempt == attempt {
                    self.tasks.removeValue(forKey: id)
                    self.startQueuedIfPossible()
                }
                if let self { self.onChange?(self.batch) }
            }
            tasks[id] = (attempt, draft.byteCount, task)
        }
    }
    func replace(_ id: UUID, name: String, mime: String, data: Data) throws {
        try batch.replace(id, name: name, mime: mime, data: data)
        waiting.removeAll { $0 == id }
        // A cancelled URLSession may still be in flight until its completion.
        // Keep its slot occupied and queue the replacement after it exits.
        if let old = tasks[id] {
            old.task.cancel()
        }
        // Editing a draft must not issue a new upload before send.
        onChange?(batch)
    }
    func remove(_ id: UUID) {
        waiting.removeAll { $0 == id }
        // Cancellation is asynchronous; do not free a slot before the old
        // transport finishes, or the effective in-flight cap is bypassed.
        tasks[id]?.task.cancel()
        batch.remove(id)
        startQueuedIfPossible()
        onChange?(batch)
    }
    func reset(sessionID: String) {
        for value in tasks.values { value.task.cancel() }
        // Old-session requests continue to occupy slots until they exit.
        // A new session must not exceed the shared transport budget.
        waiting.removeAll()
        batch.reset(sessionID: sessionID)
        onChange?(batch)
    }
    /// P1：恢复一批已在服务端的附件引用（编辑队列项时调用）。
    /// 见 `AttachmentBatch.restoreReady` 的语义说明。
    func restoreReady(_ payloads: [ChatAttachmentPayload]) {
        batch.restoreReady(payloads)
        onChange?(batch)
    }
    func restorePersisted(_ value: PersistedAttachmentBatch) throws {
        try batch.restorePersisted(value)
        // Restore bytes and ready references only. Cold foreground restore may
        // re-upload on the NEXT explicit send, never on merely opening a chat.
        onChange?(batch)
    }
}

/// Dedicated preview session: no URL cache, no credential storage, no automatic cookies,
/// no redirects. Only a cookie snapshot for the already-approved internal URL is attached.
struct AttachmentPreviewLoader: Sendable {
    let policy: AttachmentPreviewPolicy
    private let configuration: URLSessionConfiguration
    private let cookieStorage: HTTPCookieStorage
    init(policy: AttachmentPreviewPolicy, configuration: URLSessionConfiguration = .ephemeral,
         cookieStorage: HTTPCookieStorage = .shared) {
        self.policy = policy
        self.configuration = AttachmentSessionConfiguration.hardened(configuration,
                                                                     requestTimeout: 30,
                                                                     resourceTimeout: 60)
        self.cookieStorage = cookieStorage
    }
    func imageData(sessionID: String, attachment: UploadedAttachment,
                   progress: (@Sendable (AttachmentTransferProgress) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        // Validate the supplied image metadata before constructing either route.
        let raw = try policy.request(sessionID:sessionID, attachment:attachment)
        if policy.authorization.requiresBearer {
            return try await fetch(policy.gatewayFileRequest(path: attachment.path), progress: progress)
        }
        var media = try policy.mediaRequest(sessionID:sessionID, path:attachment.path)
        media.setValue("image/*", forHTTPHeaderField:"Accept")
        do { return try await fetch(media, progress: progress) }
        catch {
            try Task.checkCancellation()
            guard AttachmentRouteFallback.allows(error) else { throw error }
            return try await fetch(raw, progress: progress)
        }
    }

    private func fetch(_ base: URLRequest,
                       progress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> Data {
        try Task.checkCancellation()
        var request = base
        guard let url = request.url, policy.allows(url) else { throw AttachmentError.unsafeURL }
        AttachmentRequestAuthentication.apply(to: &request, authorization: policy.authorization,
                                              cookies: cookieStorage.cookies(for: url) ?? [])
        let transfer = AttachmentImageTransfer(policy:policy, progress:progress)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request:request, configuration:configuration, continuation:continuation)
            }
        } onCancel: { transfer.cancel() }
        try Task.checkCancellation()
        return data
    }
}

/// External images never receive ambient cookies, credentials or caller config
/// headers. Redirects are refused and bytes are capped while they arrive.
struct RemoteImageDataLoader: Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = AttachmentSessionConfiguration.hardened(configuration,
                                                                     requestTimeout: 20,
                                                                     resourceTimeout: 40)
    }

    func data(for url: URL,
              progress: (@Sendable (AttachmentTransferProgress) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw AttachmentError.unsafeURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let transfer = AttachmentImageTransfer(expectedURL: url, progress: progress)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: { transfer.cancel() }
        try Task.checkCancellation()
        return data
    }
}

class AttachmentRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Declare the task-completion witness here so subclasses override it dynamically.
    // Otherwise a subclass silently inherits URLSessionTaskDelegate's no-op default.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Delegate state is lock-protected because task cancellation may race delegate callbacks.
private final class AttachmentImageTransfer: AttachmentRedirectGuard, URLSessionDataDelegate, @unchecked Sendable {
    private let validate: @Sendable (URLResponse) throws -> Void
    private let progress: (@Sendable (AttachmentTransferProgress) -> Void)?
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var accepted = false
    private var expected: Int?
    private var lastProgress = 0.0
    init(policy: AttachmentPreviewPolicy, progress: (@Sendable (AttachmentTransferProgress) -> Void)?) {
        self.progress = progress
        validate = { response in
            guard let http = response as? HTTPURLResponse, let url = http.url, policy.allows(url) else { throw AttachmentError.unsafeURL }
            guard http.statusCode == 200 else { throw AttachmentError.http(http.statusCode) }
            try policy.validateResponse(mime:http.value(forHTTPHeaderField:"Content-Type"), size:0)
        }
    }
    init(expectedURL: URL, progress: (@Sendable (AttachmentTransferProgress) -> Void)?) {
        self.progress = progress
        validate = { response in
            func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
            guard let http = response as? HTTPURLResponse, let url = http.url,
                  url.scheme?.lowercased() == expectedURL.scheme?.lowercased(),
                  url.host?.lowercased() == expectedURL.host?.lowercased(), port(url) == port(expectedURL),
                  url.user == nil, url.password == nil else { throw AttachmentError.unsafeURL }
            guard http.statusCode == 200 else { throw AttachmentError.http(http.statusCode) }
            let mime = http.value(forHTTPHeaderField:"Content-Type")?.split(separator:";").first?
                .trimmingCharacters(in:.whitespaces).lowercased() ?? ""
            guard AttachmentPreviewPolicy.rasterMIMEs.contains(mime) else { throw AttachmentError.unsupportedPreview }
        }
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<Data, Error>) {
        let session = URLSession(configuration:configuration, delegate:self, delegateQueue:nil)
        let task = session.dataTask(with:request)
        let shouldStart = lock.withLock {
            guard !finished else { return false }
            self.continuation = continuation
            self.session = session
            self.task = task
            return true
        }
        if shouldStart { task.resume() }
        else { session.invalidateAndCancel(); continuation.resume(throwing:CancellationError()) }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Data, Error>) {
        let values = lock.withLock { () -> (CheckedContinuation<Data, Error>?, URLSession?)? in
            guard !finished else { return nil }
            finished = true
            let values = (continuation, session)
            continuation = nil
            session = nil
            task = nil
            buffer.removeAll()
            return values
        }
        guard let values else { return }
        values.1?.invalidateAndCancel()
        values.0?.resume(with:result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            try validate(response)
            let length = response.expectedContentLength
            guard length <= AttachmentMultipart.defaultMaxBytes else { throw AttachmentError.tooLarge }
            let allow = lock.withLock {
                if finished { return false }
                accepted = true
                expected = length >= 0 ? Int(length) : nil
                return true
            }
            if allow { progress?(AttachmentTransferProgress(receivedBytes: 0, expectedBytes: length >= 0 ? Int(length) : nil)) }
            completionHandler(allow ? .allow : .cancel)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result = lock.withLock { () -> (Bool, AttachmentTransferProgress?) in
            guard !finished else { return (false, nil) }
            guard data.count <= AttachmentMultipart.defaultMaxBytes - buffer.count else { return (true, nil) }
            buffer.append(data)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.1 {
                lastProgress = now
                return (false, AttachmentTransferProgress(receivedBytes: buffer.count, expectedBytes: expected))
            }
            return (false, nil)
        }
        if let event = result.1 { progress?(event) }
        if result.0 { finish(.failure(AttachmentError.tooLarge)) }
    }
    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let result = lock.withLock { accepted ? Result<Data, Error>.success(buffer) : .failure(AttachmentError.unsupportedPreview) }
        if case .success(let data) = result { progress?(AttachmentTransferProgress(receivedBytes: data.count, expectedBytes: expected)) }
        finish(result)
    }
}

/// Allows ONLY this instance's raw-file endpoint. Never feed arbitrary Markdown URLs to it.
struct AttachmentPreviewPolicy: Sendable {
    let baseURL: URL
    /// 该实例的认证方式；WebUI 留空（走 cookie），网关带 Bearer。
    let authorization: AttachmentAuthorization
    static let rasterMIMEs: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif", "image/tiff", "image/bmp"]

    init(baseURL: URL, authorization: AttachmentAuthorization = .cookieOnly) throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              !baseURL.path.split(separator: "/").contains("..") else { throw AttachmentError.unsafeURL }
        self.baseURL = baseURL
        self.authorization = authorization
    }
    func allows(_ url: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        let allowedPaths = [
            baseURL.appendingPathComponent("api/file/raw").path,
            baseURL.appendingPathComponent("api/media").path,
            // 网关自带 Files API（attachments 插件）：按绝对路径取字节。
            baseURL.appendingPathComponent("v1/files/by-path").path,
        ]
        return url.scheme?.lowercased() == baseURL.scheme?.lowercased()
            && url.host?.lowercased() == baseURL.host?.lowercased() && port(url) == port(baseURL)
            && url.user == nil && url.password == nil && url.fragment == nil
            && allowedPaths.contains(url.path)
    }

    /// Normalize only an already-approved absolute media/raw link. The caller
    /// rebuilds a request with its captured current session, never the link's
    /// session_id. Arbitrary same-origin pages and external URLs stay URLs.
    func internalFilePath(from raw: String) -> String? {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: raw), let url = components.url, allows(url) else { return nil }
        let paths = (components.queryItems ?? []).filter { $0.name == "path" }
        guard paths.count == 1, let path = paths.first?.value, !path.isEmpty,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.hasPrefix("//"), URLComponents(string: path)?.scheme == nil else { return nil }
        return path
    }

    /// 拒绝任何 `..` 段：服务端把 path 直接拼进文件系统路径，`../` 会越出附件根目录。
    /// 同时检查百分号编码形式（`%2e%2e`、`%2E%2E`），否则编码一次就能绕过（F-75）。
    private static func containsParentTraversal(_ path: String) -> Bool {
        func hasDotDotSegment(_ value: String) -> Bool {
            value.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: false)
                .contains { $0 == ".." }
        }
        if hasDotDotSegment(path) { return true }
        if let decoded = path.removingPercentEncoding, decoded != path, hasDotDotSegment(decoded) { return true }
        return false
    }

    private func opaqueFilePath(_ raw: String) throws -> String {
        if let path = internalFilePath(from: raw) {
            guard !Self.containsParentTraversal(path) else { throw AttachmentError.unsafeURL }
            return path
        }
        guard !raw.isEmpty, !raw.hasPrefix("//"), URLComponents(string: raw)?.scheme == nil,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !Self.containsParentTraversal(raw) else { throw AttachmentError.unsafeURL }
        return raw
    }

    /// 三处请求构造共用的 URL 组装：query 里的字面 `+` 必须转义成 `%2B`。
    /// `URLComponents` 对已校验的 baseURL 实际不会返回 nil，但这里仍按可恢复错误
    /// 处理（不写 `!`），失败统一报 `unsafeURL`，而不是崩溃。
    private func composeRequest(route: String, items: [URLQueryItem],
                                accept: String, timeout: TimeInterval) throws -> URLRequest {
        guard var parts = URLComponents(url: baseURL.appendingPathComponent(route),
                                        resolvingAgainstBaseURL: false) else { throw AttachmentError.unsafeURL }
        parts.queryItems = items
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, allows(url) else { throw AttachmentError.unsafeURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    func request(sessionID: String, attachment: UploadedAttachment) throws -> URLRequest {
        guard !sessionID.isEmpty else { throw AttachmentError.invalidMetadata }
        guard attachment.isImage, Self.rasterMIMEs.contains(attachment.mime.lowercased()) else { throw AttachmentError.unsupportedPreview }
        let path = try opaqueFilePath(attachment.path)
        return try composeRequest(route: "api/file/raw",
                                  items: [URLQueryItem(name:"session_id", value:sessionID),
                                          URLQueryItem(name:"path", value:path)],
                                  accept: "image/*", timeout: 30)
    }
    func validateResponse(mime: String?, size: Int) throws {
        let type = mime?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard Self.rasterMIMEs.contains(type) else { throw AttachmentError.unsupportedPreview }
        guard size >= 0, size <= AttachmentMultipart.defaultMaxBytes else { throw AttachmentError.tooLarge }
    }

    /// A downloadable file is any bounded byte stream on this instance's raw route.
    /// Unlike the inline-image preview, no raster MIME requirement applies.
    func downloadRequest(sessionID: String, path: String, name: String) throws -> URLRequest {
        guard !sessionID.isEmpty, !path.isEmpty else { throw AttachmentError.invalidMetadata }
        let path = try opaqueFilePath(path)
        return try composeRequest(route: "api/file/raw",
                                  items: [URLQueryItem(name: "session_id", value: sessionID),
                                          URLQueryItem(name: "path", value: path)],
                                  accept: "application/octet-stream", timeout: 60)
    }
    func validateDownloadResponse(size: Int) throws {
        // URLResponse uses -1 when no Content-Length is available. Delegate data
        // callbacks enforce the same cap for chunked/unknown-length transfers.
        guard size >= -1, size <= AttachmentMultipart.defaultMaxBytes else { throw AttachmentError.tooLarge }
    }

    /// `/api/media` 路由：能取到 agent 产物（`/opt/data/...`），而 `file/raw` 只认
    /// workspace 与会话附件目录。服务器的敏感路径黑名单对两者都生效。
    /// `inline=1` 让服务器按 inline 返回，避免被强制当作 attachment。
    func mediaRequest(sessionID: String, path: String) throws -> URLRequest {
        guard !sessionID.isEmpty, !path.isEmpty else { throw AttachmentError.invalidMetadata }
        let path = try opaqueFilePath(path)
        return try composeRequest(route: "api/media",
                                  items: [URLQueryItem(name: "path", value: path),
                                          URLQueryItem(name: "session_id", value: sessionID)],
                                  accept: "application/octet-stream", timeout: 60)
    }

    /// 网关 Files API 的按路径下载：`GET /v1/files/by-path?path=<绝对路径>`。
    ///
    /// 纯网关实例没有 `/api/file/raw` 与 `/api/media`（那是 WebUI 的端点），
    /// 附件和历史里的文件只能走这里。路径白名单与 `..` 校验沿用同一套规则。
    func gatewayFileRequest(path: String) throws -> URLRequest {
        guard !path.isEmpty else { throw AttachmentError.invalidMetadata }
        let path = try opaqueFilePath(path)
        return try composeRequest(route: "v1/files/by-path",
                                  items: [URLQueryItem(name: "path", value: path)],
                                  accept: "application/octet-stream", timeout: 60)
    }
}

/// Upload returns `filename`; chat/start consumes `name`. Keep the server path opaque.
struct UploadedAttachment: Codable, Equatable, Sendable {
    let name: String
    let path: String
    let size: Int
    let mime: String
    let isImage: Bool

    enum CodingKeys: String, CodingKey {
        case name, path, size, mime
        case isImage = "is_image"
    }
    private struct UploadResponse: Decodable {
        let filename: String
        let path: String
        /// 老 WebUI 的 `/api/upload` 回 `size`；网关的 OpenAI Files API 回 `bytes`。两者取其一。
        let size: Int?
        let bytes: Int?
        let mime: String
        let is_image: Bool?

        /// 统一成客户端内部的字节数；缺字段时按 0 处理（后续仍有上限校验兜底）。
        var byteCount: Int { size ?? bytes ?? 0 }
    }
    /// 仅用于从历史消息里已知的路径构造预览请求；不参与上传。
    init(name: String, path: String, size: Int, mime: String, isImage: Bool) {
        self.name = name; self.path = path; self.size = size; self.mime = mime; self.isImage = isImage
    }

    init(data: Data) throws {
        let response = try JSONDecoder().decode(UploadResponse.self, from: data)
        guard !response.filename.isEmpty, !response.path.isEmpty, response.byteCount >= 0,
              !response.mime.isEmpty, !response.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AttachmentError.invalidMetadata }
        // filename/mime 来自服务端，仍需裁剪长度与控制字符，避免流入 multipart/UI。
        let safeName = Self.sanitizeFilename(response.filename, maxLength: 200)
        let safeMime = Self.sanitizeMime(response.mime, maxLength: 128)
        guard !safeName.isEmpty, !safeMime.isEmpty, !safeName.allSatisfy({ $0 == "." }) else { throw AttachmentError.invalidMetadata }
        name = safeName
        path = response.path
        size = response.byteCount
        mime = safeMime
        // 网关按字节嗅探给出 is_image；老 WebUI 一定有该字段，缺失时按 MIME 兜底。
        isImage = response.is_image ?? safeMime.lowercased().hasPrefix("image/")
    }

    /// 服务端 filename 的保守清洗：控制符与 bidi/零宽字符换下划线，按 UTF-8 字节
    /// 截断并保留扩展名（下载/打开时按类型识别要用）。与 multipart 头、下载落盘
    /// 共用同一个清洗器，避免三条路径行为分叉。
    private static func sanitizeFilename(_ value: String, maxLength: Int) -> String {
        AttachmentFilenameSanitizer.sanitize(value, maxBytes: maxLength,
                                             escapingQuotes: false, preserveExtension: true)
    }

    /// MIME 不是文件名：不转义双引号（合法的 subtype 字符），也不拆「扩展名」。
    private static func sanitizeMime(_ value: String, maxLength: Int) -> String {
        AttachmentFilenameSanitizer.sanitize(value, maxBytes: maxLength,
                                             escapingQuotes: false, preserveExtension: false)
    }
}


extension ChatAttachmentPayload {
    init(uploaded: UploadedAttachment) {
        self.init(name: uploaded.name, path: uploaded.path, mime: uploaded.mime,
                  size: uploaded.size, isImage: uploaded.isImage)
    }
}
