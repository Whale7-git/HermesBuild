import Foundation
#if canImport(FoundationNetworking)
// `URLError` 在 Linux 的 corelibs-foundation 里由 FoundationNetworking 提供。
import FoundationNetworking
#endif

/// 任何能报告 HTTP 状态码的错误。
///
/// 用协议而不是直接 `as? APIError`：`APIError` 定义在 `HermesAPI.swift`，
/// 而本文件要能被只编译模型层的离线套件单独构建。把依赖收成「谁有状态码
/// 谁遵循这个协议」，两边都不用知道对方的类型。
protocol HTTPStatusProviding {
    var httpStatusHint: Int? { get }
}

/// `GET /api/sessions/{id}/messages` 失败的性质。
///
/// 这个区分不是为了措辞好看，而是为了让「锁」只落在该落的地方：
///
/// - `uncertain` 的语义是**「POST 结果待核对」**（见 `ChatFacts.uncertain`）。
///   它进 `allowsNewTurn` / `allowsSteer` / `allowsResend` 的 guard，是一道硬闸。
/// - 一次历史 GET 超时**不包含任何关于 POST 是否被受理的信息**。把它塞进
///   `uncertain` 会让「网络抖了一下」和「消息可能已经发出去了」变成同一个状态，
///   然后用同一把锁锁死发送。用户侧的观感就是「读不进来也发不出去，只能手动刷新」。
///
/// 所以：暂时性失败只保留「内容不是最新」这一事实，交给自动退避重试去恢复；
/// 只有确定性失败才允许把会话钉进待核对态。
enum HistoryLoadFailure: Equatable {
    /// 超时、断连、DNS/连接失败、5xx、429、408。重试有意义，且幂等（GET）。
    case transient
    /// 认证、会话不存在、契约不合法。重试无用，重复请求只会加重问题。
    case permanent

    static func classify(_ error: Error) -> HistoryLoadFailure {
        if let code = (error as? HTTPStatusProviding)?.httpStatusHint {
            // 5xx 是服务端暂时性故障；408/429 明确表示「稍后再来」。
            // 其余 4xx（含 404 会话不存在、400 参数不合法）重试无意义。
            return isTransientStatus(code) ? .transient : .permanent
        }
        if let url = error as? URLError {
            return classify(urlCode: url.code)
        }
        // URLSession 在部分平台把网络错误包成 NSError；只按 domain + code 判断，
        // 不猜 underlying error 的层级。
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, let code = URLError.Code(rawValue: ns.code) {
            return classify(urlCode: code)
        }
        // 包括 `APIError.badResponse`（没有状态码）与任何不认识的错误：
        // 宁可保守锁定，也不要用重试去掩盖一个真缺陷。
        return .permanent
    }

    private static func isTransientStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }

    private static func classify(urlCode: URLError.Code) -> HistoryLoadFailure {
        switch urlCode {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed,
             .dataNotAllowed,
             .callIsActive,
             .internationalRoamingOff,
             .resourceUnavailable,
             .cannotLoadFromNetwork:
            return .transient
        default:
            // 包括 .cancelled —— 取消不是失败，调用方本来就该丢弃这次结果。
            return .permanent
        }
    }
}
