import Foundation
import FoundationNetworking

// 与真实错误同形的替身：只提供状态码，不引入整个 API 层。
// 真实构建里 `APIError` 通过 `HermesAPI.swift` 的 extension 遵循同一协议。
struct HTTPFailure: Error, HTTPStatusProviding {
    let code: Int?
    var httpStatusHint: Int? { code }
}

// 最小断言框架，与仓库其它离线套件保持同一风格：不依赖 XCTest。
var failures: [String] = []
var checks = 0

func expectKind(_ error: Error, _ expected: HistoryLoadFailure, _ label: String) {
    checks += 1
    let actual = HistoryLoadFailure.classify(error)
    if actual != expected {
        failures.append("\(label): expected \(expected), got \(actual)")
    }
}

// MARK: - 暂时性失败：幂等 GET 重试有意义

expectKind(URLError(.timedOut), .transient, "URLError.timedOut")
expectKind(URLError(.networkConnectionLost), .transient, "URLError.networkConnectionLost")
expectKind(URLError(.notConnectedToInternet), .transient, "URLError.notConnectedToInternet")
expectKind(URLError(.cannotConnectToHost), .transient, "URLError.cannotConnectToHost")
expectKind(URLError(.cannotFindHost), .transient, "URLError.cannotFindHost")
expectKind(URLError(.dnsLookupFailed), .transient, "URLError.dnsLookupFailed")
expectKind(URLError(.secureConnectionFailed), .transient, "URLError.secureConnectionFailed")
expectKind(URLError(.dataNotAllowed), .transient, "URLError.dataNotAllowed")
expectKind(URLError(.resourceUnavailable), .transient, "URLError.resourceUnavailable")
expectKind(URLError(.cannotLoadFromNetwork), .transient, "URLError.cannotLoadFromNetwork")
expectKind(URLError(.internationalRoamingOff), .transient, "URLError.internationalRoamingOff")

expectKind(HTTPFailure(code: 503), .transient, "http 503")
expectKind(HTTPFailure(code: 500), .transient, "http 500")
expectKind(HTTPFailure(code: 599), .transient, "http 599")
expectKind(HTTPFailure(code: 429), .transient, "http 429")
expectKind(HTTPFailure(code: 408), .transient, "http 408")

// MARK: - 确定性失败：重试无用，保持原有锁定语义

expectKind(HTTPFailure(code: 404), .permanent, "http 404")
expectKind(HTTPFailure(code: 400), .permanent, "http 400")
expectKind(HTTPFailure(code: 403), .permanent, "http 403")
expectKind(HTTPFailure(code: 401), .permanent, "http 401")
// 无状态码（真实实现里的 badResponse）不能当成暂时性故障重试。
expectKind(HTTPFailure(code: nil), .permanent, "no status code")
// 取消不是失败：调用方本来就该丢弃这次结果，绝不能靠重试去「救」它。
expectKind(URLError(.cancelled), .permanent, "URLError.cancelled")
// 不认识的错误类型按确定性处理：宁可保守锁定，也不要用重试掩盖真缺陷。
expectKind(NSError(domain: "custom", code: 1), .permanent, "unknown error")

// MARK: - 被封成 NSError 的网络错误同样要认出来

expectKind(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
           .transient, "NSError NSURLErrorTimedOut")
expectKind(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
           .transient, "NSError NSURLErrorNotConnectedToInternet")

// MARK: - run transport 已回收：404/410 是确定性结论，不是网络故障

checks += 1
if !HistoryLoadFailure.isRunTransportGone(HTTPFailure(code: 404)) {
    failures.append("404 must be treated as a gone transport")
}
checks += 1
if !HistoryLoadFailure.isRunTransportGone(HTTPFailure(code: 410)) {
    failures.append("410 must be treated as a gone transport")
}
for code in [500, 502, 429, 408, 401, 403, 400] {
    checks += 1
    if HistoryLoadFailure.isRunTransportGone(HTTPFailure(code: code)) {
        failures.append("http \(code) must NOT be treated as a gone transport")
    }
}
checks += 1
if HistoryLoadFailure.isRunTransportGone(URLError(.timedOut)) {
    failures.append("a timeout must NOT be treated as a gone transport")
}

// MARK: - 分类必须无副作用（同一错误连续判断结果一致）

let sample = URLError(.timedOut)
checks += 1
if HistoryLoadFailure.classify(sample) != HistoryLoadFailure.classify(sample) {
    failures.append("classify is not stable across calls")
}

if failures.isEmpty {
    print("PASS historyfailure (\(checks) checks)")
} else {
    for failure in failures { print("FAIL historyfailure: \(failure)") }
    exit(1)
}
