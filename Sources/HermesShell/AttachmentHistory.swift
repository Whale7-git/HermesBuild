import Foundation

/// 附件请求的认证方式。
///
/// WebUI 用登录 cookie（由 `HTTPCookieStorage` 自动附加），网关只认
/// `Authorization: Bearer`（见 `api_server._check_auth`：它完全不看 cookie）。
/// 附件下载器原先只带 cookie，于是网关实例每次下载都 401。
///
/// 定义在这个文件里是因为它是唯一同时被 `appstate`（带 `HermesBackend`、
/// 不带附件模型）与 `attachments`（带附件模型、不带 `HermesBackend`）
/// 两个编译清单包含的文件。放到任何一边都会让另一边「cannot find type in scope」。
struct AttachmentAuthorization: Sendable, Equatable {
    /// Bearer identity must survive a temporarily missing/empty API key.
    /// A nil header alone must never downgrade a Gateway to WebUI cookie mode.
    var header: String?
    var requiresBearer: Bool = false

    static let cookieOnly = AttachmentAuthorization(header: nil, requiresBearer: false)

    static func bearer(_ token: String) -> AttachmentAuthorization {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentAuthorization(header: trimmed.isEmpty ? nil : "Bearer \(trimmed)",
                                       requiresBearer: true)
    }
}

struct ChatAttachmentPayload: Equatable, Codable {
    let name: String
    let path: String
    let mime: String
    let size: Int
    let isImage: Bool

    init(name: String, path: String, mime: String, size: Int, isImage: Bool) {
        self.name = name; self.path = path; self.mime = mime; self.size = size; self.isImage = isImage
    }

    var jsonObject: [String: Any] {
        ["name": name, "path": path, "mime": mime, "size": size, "is_image": isImage]
    }
}

/// Extraction is metadata-only: external URLs are returned but NEVER fetched here.
/// Unsupported: data/base64 image blocks and full CommonMark nested destination parsing.
enum AttachmentHistory {
    /// 正则只编译一次。总览页每次渲染都会对整份 catalog 调用 `paths`，
    /// 在循环里编译模式会把滚动/搜索拖成 O(条目数) 的正则编译。
    private static let attachmentPatterns: [NSRegularExpression] = [
        #"MEDIA:([^\s\)\]]+)"#,
        #"!\[[^\]\n]*\]\(<?([^\s\)<>]+)>?(?:\s+\"[^\"]*\")?\)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Only attachment syntax in actual prose is eligible for discovery.
    /// Examples in Markdown quotes, fenced code, indented code and inline code
    /// must never become downloadable files (or trigger authenticated requests).
    /// Structured attachment metadata is handled separately and is untouched.
    private static func extractableSource(_ text: String) -> String {
        var fence: Character?
        var fenceWidth = 0
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let spaces = line.prefix(while: { $0 == " " }).count
            let trimmed = line.dropFirst(spaces)
            if trimmed.first == ">" { return "" }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let width = trimmed.prefix(while: { $0 == marker }).count
                if width >= 3 {
                    if fence == nil {
                        fence = marker
                        fenceWidth = width
                        return ""
                    }
                    if fence == marker && width >= fenceWidth {
                        fence = nil
                        fenceWidth = 0
                        return ""
                    }
                }
            }
            if fence != nil || spaces >= 4 { return "" }
            return excludingInlineCode(String(line))
        }.joined(separator: "\n")
    }

    private static func excludingInlineCode(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.utf8.count)
        var index = raw.startIndex
        var activeTicks: Int?
        while index < raw.endIndex {
            if raw[index] == "`" {
                var next = index
                while next < raw.endIndex, raw[next] == "`" {
                    next = raw.index(after: next)
                }
                let width = raw.distance(from: index, to: next)
                if activeTicks == nil { activeTicks = width }
                else if activeTicks == width { activeTicks = nil }
                result.append(contentsOf: repeatElement(" ", count: width))
                index = next
            } else {
                result.append(activeTicks == nil ? raw[index] : " ")
                index = raw.index(after: index)
            }
        }
        return result
    }

    static func paths(content: Any?, attachments: Any?) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in:.whitespacesAndNewlines), !value.isEmpty,
                  value.utf8.count <= 8192, !value.hasPrefix("//"),
                  !value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { return }
            if let scheme = URLComponents(string:value)?.scheme?.lowercased(), !["https", "http"].contains(scheme) { return }
            if seen.insert(value).inserted { result.append(value) }
        }
        for entry in (attachments as? [Any] ?? []).prefix(100) {
            if let text = entry as? String { add(text) }
            else if let entry = entry as? [String:Any] {
                add((entry["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entry["name"] as? String ?? entry["filename"] as? String)
            }
        }
        func scan(_ text: String) {
            // Keep work bounded for malformed/untrusted transcripts.
            let text = Self.extractableSource(String(text.prefix(1_048_576)))
            for expression in attachmentPatterns {
                let range = NSRange(text.startIndex..., in:text)
                for match in expression.matches(in:text, range:range).prefix(100) {
                    if let range = Range(match.range(at:1), in:text) { add(String(text[range])) }
                }
            }
        }
        if let text = content as? String { scan(text) }
        for part in (content as? [[String:Any]] ?? []).prefix(100) {
            switch part["type"] as? String {
            case "text", "input_text", "output_text": if let text = part["text"] as? String { scan(text) }
            case "image_url", "input_image":
                add((part["image_url"] as? [String:Any])?["url"] as? String ?? part["image_url"] as? String)
            case "image":
                if let source = part["source"] as? [String:Any], source["type"] as? String == "url" { add(source["url"] as? String) }
            default: break
            }
        }
        return result
    }
}

