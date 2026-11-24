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

/// `GET /api/sessions/{id}/messages` 失败的性质，用来决定**要不要自动补读**。
///
/// 它不决定「能不能发送」。读取失败一律意味着服务端状态未知，因此
/// `uncertain` 照旧置位、发送照旧锁住——这是既有安全契约，不经本次改动。
///
/// 本次要修的缺陷是另一半：`uncertain` 只在一次成功的 `applySnapshot` 里解除，
/// 而 `load` 失败后**没有任何重试**。于是一次网络抖动就把会话钉在
/// 「已显示本地历史，联网核对成功前不能发送」，直到用户手动刷新或重进会话。
///
/// 区分两类失败，让锁的时长匹配失败的性质：
///
/// - `transient`：超时、断连、DNS/连接失败、5xx、429、408。幂等 GET 重试有意义，
///   所以按 2s/5s/12s 退避补读，成功即解除锁定。
/// - `permanent`：认证、会话不存在、契约不合法。重试只会放大问题，
///   交给用户处理（重新登录 / 换会话）。
enum HistoryLoadFailure: Equatable {
    case transient
    case permanent

    static func classify(_ error: Error) -> HistoryLoadFailure {
        if let code = (error as? HTTPStatusProviding)?.httpStatusHint {
            // 5xx 是服务端暂时性故障；408/429 明确表示「稍后再来」。
            // 其余 4xx（含 404 会话不存在、400 参数不合法）重试无意义。
            return isTransientStatus(code) ? .transient : .permanent
        }
        if let url = error as? URLError {
            return classify(urlCodeRawValue: url.code.rawValue)
        }
        // URLSession 在部分平台把网络错误包成 NSError；只按 domain + code 判断，
        // 不猜 underlying error 的层级。
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return classify(urlCodeRawValue: ns.code)
        }
        // 包括 `APIError.badResponse`（没有状态码）与任何不认识的错误：
        // 宁可不动、交给用户，也不要用重试去掩盖一个真缺陷。
        return .permanent
    }

    private static func isTransientStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }

    /// `GET /v1/runs/{id}/events` 返回 404/410：这条 run 的 SSE transport
    /// 已被服务端回收，**不是**网络故障。
    ///
    /// 服务端有两个不对称的保留期（`api_server.py`）：
    /// `_RUN_STREAM_TTL = 300`（SSE 缓冲，从 run 创建起算）与
    /// `_RUN_STATUS_TTL = 3600`（终态 status）。所以存在长达近一小时的窗口：
    /// status 仍可查、history 仍可能报 `active_stream_id`，但订阅它必然 404。
    ///
    /// 这正是「长回答执行很久之后卡住」的机制——回合越长，越容易在客户端
    /// 掉线（锁屏/切后台/网络切换）时跨过那 5 分钟，等回来时 transport 已经没了。
    /// 客户端把它当成重连失败去重试订阅，就会一直撞在同一堵墙上。
    static func isRunTransportGone(_ error: Error) -> Bool {
        guard let code = (error as? HTTPStatusProviding)?.httpStatusHint else { return false }
        return code == 404 || code == 410
    }

    /// 按 `URLError` 的原始码判断。
    ///
    /// 用 Int 原始码而不是 `URLError.Code`：macOS 的
    /// `URLError.Code(rawValue:)` 返回**非可选**值，`if let` 在那里直接编译失败
    /// （`initializer for conditional binding must have Optional type`），
    /// 而 Linux corelibs 上又是可选的。按 Int 比较两边都能过。
    private static func classify(urlCodeRawValue: Int) -> HistoryLoadFailure {
        switch urlCodeRawValue {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorDataNotAllowed,
             NSURLErrorCallIsActive,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorResourceUnavailable,
             NSURLErrorCannotLoadFromNetwork:
            return .transient
        default:
            // 包括 NSURLErrorCancelled（-999）—— 取消不是失败，调用方本来就该
            // 丢弃这次结果，绝不能靠重试把它「救」回来。
            return .permanent
        }
    }
}
