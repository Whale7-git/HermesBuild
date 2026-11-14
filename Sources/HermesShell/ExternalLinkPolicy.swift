import Foundation

/// 外部链接的打开策略。
///
/// 历史消息里的附件路径可能是绝对 URL。图片走无凭据的图片加载器，
/// 但**非图片的外部文件不自动下载**——那会引入任意 URL 的请求面。
/// 这里只回答一个更窄的问题：能不能交给系统浏览器打开。
///
/// 只有 `http` / `https` 且带主机的地址算可打开。`file:`、`javascript:`、
/// 自定义 scheme 一律拒绝：把它们交给系统打开，等于让消息内容决定跳转目标。
enum ExternalLinkPolicy {
    static func openableURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func canOpen(_ raw: String) -> Bool { openableURL(raw) != nil }
}
