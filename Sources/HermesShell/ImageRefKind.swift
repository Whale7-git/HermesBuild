import Foundation

/// 正文图片引用的纯分类逻辑（仅 Foundation，可离线测试）。
/// UI 层（InlineImages.swift / AttachmentStrip.swift）只调用这里，不再各写一份。
enum InlineImageKind {
    /// 从 URL/路径取扩展名，忽略 query 与 fragment。
    static func pathExtension(_ raw: String) -> String {
        var value = raw
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        return (value as NSString).pathExtension.lowercased()
    }

    /// 是否是可直接内联显示的栅格图片。
    static func isRaster(_ raw: String) -> Bool {
        !AttachmentKind.mime(forPathExtension: pathExtension(raw)).isEmpty
    }

    static func isHTTP(_ raw: String) -> Bool {
        guard let scheme = URL(string: raw)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// 非 http(s) 的显式 scheme（file:/javascript: 等）必须拒绝，不能当本地路径请求。
    static func hasUnsafeScheme(_ raw: String) -> Bool {
        guard let scheme = URL(string: raw)?.scheme, !scheme.isEmpty else { return false }
        let lowered = scheme.lowercased()
        return lowered != "http" && lowered != "https"
    }
}


/// External Markdown images may be attacker-controlled. Reject direct
/// loopback/LAN literals and local-only hostnames even after the user taps.
/// This is a URL-level guard, not a guarantee against DNS rebinding.
enum ExternalInlineImageURLPolicy {
    static func mayRequest(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty,
              url.user == nil, url.password == nil else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "localhost.localdomain"
            || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".lan") || host.hasSuffix(".internal") {
            return false
        }
        // Direct IPv6 literals are blocked until a fully parsed public-address
        // policy is available. Do not accidentally permit ::1 or ULA forms.
        if host.contains(":") { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // URL clients may interpret hex, octal or short dotted numbers as
        // loopback addresses; reject ambiguous forms, not valid public IPv4.
        if labels.contains(where: { $0.lowercased().hasPrefix("0x") }) { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard labels.count == 4 else { return false }
            let octets = labels.compactMap { Int($0) }
            guard octets.count == 4,
                  octets.allSatisfy({ (0...255).contains($0) }),
                  zip(labels, octets).allSatisfy({ String($0.1) == String($0.0) })
                  else { return false }
            let a = octets[0], b = octets[1]
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
                || (a == 100 && (64...127).contains(b))
                || (a == 198 && (18...19).contains(b)))
        }
        return true
    }
}
