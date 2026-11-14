import Foundation

/// 网关模式下的会话搜索与归档筛选。
///
/// 网关只提供 `GET /api/sessions` 与 `PATCH /api/sessions/{id} {"archived":true}`，
/// 没有 WebUI 的 `/api/search` 与 `/api/sessions/archived`。所以这两个入口在网关
/// 模式下改成客户端本地完成：全量拉一次列表（调用方按 `last_active` 排好），搜索
/// 按标题 + 预览模糊匹配，归档按 `archived` 字段筛。
///
/// 这里的成员全部是纯函数：不发网络请求、不抛错、不缓存。产出的
/// `[SessionSummary]` 直接喂给 `SessionSearchResponse.hits` 的 `session` 字段与
/// `ArchivedSessionPage.sessions`，不另造返回类型。
enum GatewaySessionFilter {

    /// 取命中词两侧各留多少个字符。按 Character 计，不会切坏多字节字符。
    private static let snippetPadding = 24

    /// 本地搜索：按标题与预览模糊匹配，大小写不敏感。
    ///
    /// - query 前后空白裁掉；切词后为空（空查询、纯空白）返回空结果，
    ///   绝不返回全部——列表页本身就能看全部。
    /// - 多关键词 AND：每个词都要在标题或预览任意一处出现（两边可以分别命中）。
    /// - 排序：至少命中一个词在标题的排在只有预览命中的之前；同一组内保持传入顺序。
    /// - `limit <= 0` 返回空数组。
    static func search(_ sessions: [SessionSummary], query: String, limit: Int = 50) -> [SessionSummary] {
        guard limit > 0 else { return [] }
        let terms = searchTerms(query)
        guard !terms.isEmpty else { return [] }

        var titleHits: [SessionSummary] = []
        var previewHits: [SessionSummary] = []
        titleHits.reserveCapacity(min(limit, sessions.count))
        previewHits.reserveCapacity(min(limit, sessions.count))

        for session in sessions {
            let title = (session.title ?? "").lowercased()
            let preview = (session.preview ?? "").lowercased()
            var hitInTitle = false
            var matchedAll = true
            for term in terms {
                if !title.isEmpty, title.contains(term) {
                    hitInTitle = true
                } else if !preview.isEmpty, preview.contains(term) {
                    continue
                } else {
                    matchedAll = false
                    break
                }
            }
            guard matchedAll else { continue }
            if hitInTitle {
                titleHits.append(session)
            } else {
                previewHits.append(session)
            }
        }

        // 两组各自保持传入顺序；只在拼接后截断，避免某一组被提前削掉。
        return Array((titleHits + previewHits).prefix(limit))
    }

    /// 归档筛：`archived == true` 的那些，按 updatedAt 倒序（新的在前）。
    ///
    /// updatedAt 缺失（或解析成 nil）的排最后；时间相同按传入顺序稳定排列。
    ///
    /// **现状（F-50）：生产代码没有调用点。** 网关没有归档列表接口
    /// （`GatewayBackend.archivedSessions` 直接抛 501），会话列表也不做归档折叠，
    /// 所以只有离线测试在用。保留是因为删掉会让 `tests/gateway` 编译失败，
    /// 且网关将来补上归档列表时这里是现成的筛选口径。
    static func archived(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions
            .filter { $0.archived == true }
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.updatedDate?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
                let right = rhs.element.updatedDate?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
                if left == right { return lhs.offset < rhs.offset }
                return left > right
            }
            .map(\.element)
    }

    /// 非归档筛：`archived != true` 的那些（含 `nil`，老数据没这个字段算未归档），
    /// 保持传入顺序。
    static func active(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter { $0.archived != true }
    }

    /// 按空白切词并统一小写。用 `Character.isWhitespace` 而不是 ASCII 空格，
    /// 所以全角空格与换行也能正确分段。
    private static func searchTerms(_ query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }
}

extension GatewaySessionFilter {

    /// 取一段包含首个命中词的预览片段，命中词两侧各留约 24 个字符，
    /// 两端被截断时补 "…"。没有预览或预览里没有命中时返回 nil。
    ///
    /// 截断全部走 `String.Index` 与 Character 偏移，不会把中文/emoji 切坏。
    static func snippet(for session: SessionSummary, query: String) -> String? {
        guard let preview = session.preview, !preview.isEmpty else { return nil }
        let terms = searchTerms(query)
        guard !terms.isEmpty else { return nil }

        var first: Range<String.Index>?
        for term in terms {
            // 直接在原串上做 caseInsensitive 查找：返回的下标属于 preview 自己。
            // 先 lowercased 再拿偏移量回原串切，遇到大小写折叠变长的字符会错位。
            guard let found = preview.range(of: term, options: .caseInsensitive,
                                           range: nil, locale: nil) else { continue }
            if let current = first, current.lowerBound <= found.lowerBound { continue }
            first = found
        }
        guard let hit = first else { return nil }

        let start = preview.index(hit.lowerBound, offsetBy: -snippetPadding,
                                  limitedBy: preview.startIndex) ?? preview.startIndex
        let end = preview.index(hit.upperBound, offsetBy: snippetPadding,
                                limitedBy: preview.endIndex) ?? preview.endIndex
        let core = preview[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        let head = start > preview.startIndex ? "…" : ""
        let tail = end < preview.endIndex ? "…" : ""
        return head + core + tail
    }
}
