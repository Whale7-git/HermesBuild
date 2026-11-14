import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 会话列表分页的边界参数。
///
/// 这些数字以前散在 `all()` 里（`0..<100`、`200`），改动时容易被误当成「随便挑的」。
/// 集中命名后，每个上限的含义和它对应的请求量都能一眼对上。
///
/// 不设 `private`：离线测试（`tests/gatewaybackend`）与本文件同处一个编译单元，
/// 断言要引用同一个常量，否则常量改了测试还按老数字断言，等于没锁住。
/// 业务代码不应依赖它。
enum GatewaySessionPaging {
    /// 每页条数。线上 API 会把 limit 夹到 200，并且会把置顶行补在页外。
    static let pageSize = 200

    /// 整次 `sessions()` 最多发多少次分页请求（F-78）。
    ///
    /// 这是**唯一的翻页上限**：原来写死 `for page in 0..<100`，只能保证「最多 100 页」，
    /// 而每页条数由服务端决定。异常网关只要让 `has_more` 恒真、每页只回 1 条，
    /// 100 页就是 100 次往返却只拿到 100 个会话——请求数被放大而收益极小。
    /// 现在改成按**请求数**计预算：每翻一页花 1 个额度，额度用尽就抛 429。
    /// 这样无论服务端每页回多少条，客户端发出的请求数都有硬上限。
    ///
    /// 120 的取值：正常账号 1~3 页就收敛；即使每页只有 50 条（服务端主动夹小），
    /// 也能拉到 6,000 个会话，远超手机端实际需要。
    static let maxRequests = 120

    /// 本次加载的会话条数上限。
    ///
    /// 与 `maxRequests` 是两个不同的维度：请求数管「往返多少次」，条数管「内存里放多少」。
    /// 服务端每页回满 200 条时，20,000 条会在 100 页左右触顶，比请求预算更早生效。
    static let maxSessions = 20_000

    /// 单次翻页的超时。列表页数据量小，卡住 20 秒已经说明网络有问题，
    /// 不能让一次翻页把整轮列表刷新拖到 URLSession 的 30 秒默认值上。
    ///
    /// 直接改 `URLRequest.timeoutInterval`：请求层（`GatewayRequests`）不是本组
    /// 的改动范围，而 `URLSession` 本来就按这个字段生效，不需要新增参数。
    static let pageTimeout: TimeInterval = 20

    /// 连续多少页「原始行全是过滤行」就停止翻页。
    /// 没有这个上限，异常网关只要让 `has_more` 恒真就能把客户端钉在翻页循环里。
    static let maxFullyFilteredPages = 5
}

enum GatewaySessionReader {
    /// The deployed API clamps limit to 200 and backfills pinned rows outside the page.
    @MainActor
    static func all(requests: GatewayRequests, load: (URLRequest) async throws -> Data) async throws -> [SessionSummary] {
        var result: [SessionSummary] = []
        var seen = Set<String>()
        let size = GatewaySessionPaging.pageSize
        // 连续「整页都是过滤行」的页数。
        var filteredPages = 0
        // F-78：整次列表刷新已发出的分页请求数。这是唯一的翻页上限——
        // 不再用「固定页数」兜底，否则服务端把每页条数夹小就能放大请求数。
        var requestsSpent = 0
        // 已经翻过的页数。offset 必须按「页」算（`page * size`），不能按请求数：
        // 整页都是过滤行时服务端也前进了，页码要跟着走。
        var page = 0

        while true {
            try Task.checkCancellation()

            // 请求预算先于任何一次网络往返检查：超预算就不再发请求，直接报错。
            guard requestsSpent < GatewaySessionPaging.maxRequests else {
                // 用 429 而不是 413：这里的语义是「往返次数太多」，不是「会话太多」，
                // 稍后重试是合理的恢复动作。
                throw APIError.http(
                    429,
                    "会话列表分页超过 \(GatewaySessionPaging.maxRequests) 次请求仍未收敛，请稍后重试")
            }
            requestsSpent += 1

            var request = try requests.sessions(limit: size, offset: page * size)
            request.timeoutInterval = GatewaySessionPaging.pageTimeout
            page += 1
            let data = try await load(request)

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["data"] as? [Any] else { throw APIError.badResponse }
            let rows = try GatewayDecode.sessions(data)
            let new = rows.filter { seen.insert($0.sessionId).inserted }
            result.append(contentsOf: new)
            let hasMore = root["has_more"] as? Bool ?? (raw.count >= size)
            // 已经拿到完整列表就先返回：正好卡在上限上的完整列表不该被判成超限。
            if !hasMore { return result }
            // 条数上限与请求上限是两个维度：请求没超但内存先撑不住时，同样必须
            // 拒绝返回不完整列表。
            guard result.count < GatewaySessionPaging.maxSessions else {
                throw APIError.http(
                    413,
                    "会话超过本次加载上限（\(GatewaySessionPaging.maxSessions) 条），未返回不完整结果")
            }

            if rows.isEmpty {
                // F-46：本页原始条数 > 0 却一条都没留下，说明整页都是
                // `is_internal_child` / `hidden` 的过滤行。服务端确实前进了，
                // 不能当成「分页没有前进」抛错，否则一遇到子代理密集的账号
                // 整份会话列表就加载失败。继续翻下一页即可。
                //
                // 但要有上限（F-78）：连续 5 页全过滤就当作已到尾部，避免异常网关
                // 用恒真的 `has_more` 把客户端钉在请求循环里。
                guard !raw.isEmpty else {
                    // 原始条数为 0 而 has_more 为真，是服务端自相矛盾的数据。
                    // 这里仍按「没有前进」处理：静默返回半份列表比报错更难排查。
                    throw GatewayDecodeError.malformed("会话分页没有前进，请刷新重试")
                }
                filteredPages += 1
                guard filteredPages < GatewaySessionPaging.maxFullyFilteredPages else {
                    // The server explicitly says more pages exist. Returning
                    // success here silently loses every later visible session.
                    throw GatewayDecodeError.malformed(
                        "连续 \(GatewaySessionPaging.maxFullyFilteredPages) 页都是隐藏会话，列表未读取完整；请稍后重试")
                }
                continue
            }
            filteredPages = 0

            // 解码出了行，但一条新的都没有：服务端在原地返回同一页。
            // 继续翻只会无限重复，必须报错，否则会静默少返回会话。
            guard !new.isEmpty else {
                throw GatewayDecodeError.malformed("会话分页没有前进，请刷新重试")
            }
        }
    }
}
