import Foundation
import WebKit

/// 与 WebUI 后端通信。
///
/// 关键：WKWebView 的 cookie 存在它自己的 `WKWebsiteDataStore` 里，
/// 和 URLSession 用的 `HTTPCookieStorage.shared` 是**互相隔离**的。
/// 所以登录拿到 cookie 之后必须手动同步进 WebKit，否则 WebView 打开
/// /session/<id> 会看不到登录态被踢回登录页；反过来如果在网页里登录了，
/// 也要能把 cookie 读回 URLSession。
@MainActor
final class HermesAPI: ObservableObject, NativeChatService {
    private let base: URL
    private let session: URLSession

    init(baseURL: String) {
        self.base = URL(string: baseURL)!
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 20
        // waitsForConnectivity 下只设请求超时不够：离线时请求会一直等网络。
        // 资源级超时保证最终失败并给出错误，而不是无限转圈。
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg,
                                  delegate: RedirectRejector(),
                                  delegateQueue: nil)
        // P1：上传专用 session。`AttachmentMultipart` 给请求设了 120s 空闲超时，
        // 但共享 session 的 `timeoutIntervalForResource`（30s）是「整次传输总时限、
        // 永不重置」，会先把上传掐断——慢网下大文件永远传不完。
        // 上传走独立 session，resource 上限提到 120s，与请求级一致。
        let uploadCfg = URLSessionConfiguration.default
        uploadCfg.httpCookieStorage = HTTPCookieStorage.shared
        uploadCfg.httpShouldSetCookies = true
        uploadCfg.waitsForConnectivity = true
        uploadCfg.timeoutIntervalForRequest = 120
        uploadCfg.timeoutIntervalForResource = 120
        self.uploadSession = URLSession(configuration: uploadCfg,
                                        delegate: RedirectRejector(),
                                        delegateQueue: nil)
        // 流式专用 session。
        //
        // `timeoutIntervalForResource` 是「整次传输总时限、永不重置」，共享 session
        // 上是 30s。SSE 连接是一条**长期**传输：一轮长回复动辄几分钟，30 秒后
        // 系统直接掐断连接，客户端于是进入「连接中断，正在恢复」的循环，长回复
        // 永远收不完整。`timeoutIntervalForRequest` 管的是「多久没收到任何字节」，
        // 对流式正合适——服务端持续推帧就不会超时；真卡死时才失败。
        //
        // 资源上限放到 1 小时：这是「兜底不至于无限挂住」，不是期望的轮次长度。
        let streamCfg = URLSessionConfiguration.default
        streamCfg.httpCookieStorage = HTTPCookieStorage.shared
        streamCfg.httpShouldSetCookies = true
        streamCfg.waitsForConnectivity = true
        streamCfg.timeoutIntervalForRequest = 60
        streamCfg.timeoutIntervalForResource = 3600
        self.streamSession = URLSession(configuration: streamCfg,
                                        delegate: RedirectRejector(),
                                        delegateQueue: nil)
    }

    private let streamSession: URLSession

    private let uploadSession: URLSession

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func authStatus() async throws -> AuthStatus {
        let (data, _) = try await session.data(for: request("api/auth/status"))
        return try JSONDecoder().decode(AuthStatus.self, from: data)
    }

    func login(password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        let (data, resp) = try await session.data(for: request("api/auth/login", method: "POST", body: body))
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        await syncCookiesToWebKit()
    }

    func sessions() async throws -> [SessionSummary] {
        let (data, http) = try await get("api/sessions")
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(SessionListEnvelope.self, from: data).sessions
    }

    func post(_ path: String, body: Data?) async throws -> Data {
        var (data, resp) = try await session.data(for: request(path, method: "POST", body: body))
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            await syncCookiesFromWebKit()
            (data, resp) = try await session.data(for: request(path, method: "POST", body: body))
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var (data, resp) = try await session.data(for: request(path))
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            // 可能是在 WebView 里登录的：把 WebKit 的 cookie 捞回来重试一次
            await syncCookiesFromWebKit()
            (data, resp) = try await session.data(for: request(path))
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        return (data, http)
    }

    // MARK: - Native chat (same authenticated WebUI HTTP surface)

    var chatRequests: ChatRequests { ChatRequests(baseURL: base) }

    func performNative(_ request: URLRequest) async throws -> Data {
        var (data, response) = try await session.data(for: request)
        // 与 get/post 一致：登录可能在 WebKit 里完成，cookie 还没同步过来。
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            await syncCookiesFromWebKit()
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
            throw APIError.http(http.statusCode, obj?["error"] as? String ?? "请求失败")
        }
        return data
    }

    /// P1：上传走专用 session，resource 上限 120s。
    ///
    /// 共享 session 的 `timeoutIntervalForResource` 只有 30s，是「整次传输总时限、
    /// 永不重置」——`AttachmentMultipart` 设的 120s 请求级空闲超时挡不住它，
    /// 慢网下大文件一定被掐断。这里用独立 session，两级上限对齐。
    func uploadAttachment(_ request: URLRequest,
                          onProgress: (@Sendable (AttachmentTransferProgress) -> Void)? = nil) async throws -> Data {
        let relay = AttachmentUploadProgressRelay()
        let session = URLSession(configuration: uploadSession.configuration,
                                 delegate: relay, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var (data, http) = try await AttachmentUploadTransport.send(request, session: session,
                                                                   relay: relay, onProgress: onProgress)
        if http.statusCode == 401 {
            await syncCookiesFromWebKit()
            (data, http) = try await AttachmentUploadTransport.send(request, session: session,
                                                                    relay: relay, onProgress: onProgress)
        }
        guard (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
            throw APIError.http(http.statusCode, obj?["error"] as? String ?? "上传失败")
        }
        return data
    }

    func history(sessionID:String, before:Int? = nil) async throws -> ChatSnapshot {
        try ChatSnapshot(data: await performNative(chatRequests.history(sessionID:sessionID,before:before)))
    }

    func createNativeSession() async throws -> String {
        let data = try await performNative(chatRequests.newSession())
        let snapshot = try ChatSnapshot(data:data)
        guard !snapshot.sessionID.isEmpty else { throw APIError.badResponse }
        return snapshot.sessionID
    }

    func startNativeTurn(sessionID:String, text:String) async throws -> String {
        try await startNativeTurn(sessionID: sessionID, text: text, attachments: [])
    }

    func startNativeTurn(sessionID:String, text:String, attachments:[ChatAttachmentPayload]) async throws -> String {
        let data = try await performNative(chatRequests.start(sessionID:sessionID,text:text,attachments:attachments))
        guard let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let streamID = obj["stream_id"] as? String, !streamID.isEmpty else {
            throw APIError.badResponse
        }
        if let actual = obj["session_id"] as? String, actual != sessionID {
            throw APIError.http(409,"服务器切换了会话，请刷新列表后打开续接会话；客户端不会自动重发。")
        }
        return streamID
    }

    func stopNativeTurn(streamID:String) async throws {
        let data = try await performNative(chatRequests.cancel(streamID:streamID))
        guard let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              obj["ok"] as? Bool == true, obj["cancelled"] as? Bool == true else {
            throw APIError.http(409,"服务器尚未确认停止，请刷新状态后重试。")
        }
    }

    /// 运行中追加引导。返回 nil 表示服务端已受理；返回字符串是降级原因，
    /// 调用方据此提示用户「这条没进去」，不能当作已送达。
    func steerNativeTurn(sessionID:String, text:String) async throws -> String? {
        let data = try await performNative(chatRequests.steer(sessionID:sessionID,text:text))
        guard let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw APIError.badResponse
        }
        if obj["accepted"] as? Bool == true { return nil }
        // fallback 是服务端给出的具体原因（no_cached_agent / not_running / stream_dead …）。
        if let fallback = obj["fallback"] as? String, !fallback.isEmpty { return fallback }
        return "unsupported"
    }

    func streamNativeTurn(streamID:String,lastEventID:String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
        let (bytes,response) = try await streamSession.bytes(for:chatRequests.stream(streamID:streamID,lastEventID:lastEventID))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode,"无法连接回复流") }
        guard http.value(forHTTPHeaderField:"Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw APIError.badResponse
        }
        // 逐字节 IO 与分行放到 nonisolated 上下文，避免 token 级读取抢占主线程。
        try await Self.parseEventStream(bytes, onFrame: onFrame)
    }

    /// 逐字节读 SSE 并按空行切帧。刻意 `nonisolated`：`HermesAPI` 是 `@MainActor`，
    /// 若把这段留在类内，流式期间每一行解析都会占用主线程，滚动掉帧。
    ///
    /// EOF 时把未以空行结尾的残余行也喂给解析器（F-49）：WebUI 流的最后一帧
    /// 常常没有结尾空行，不 flush 会丢掉带 `done`/usage 的收尾帧。
    nonisolated static func parseEventStream(
        _ bytes: URLSession.AsyncBytes,
        onFrame: (SSEFrame) async throws -> Bool
    ) async throws {
        var line = Data()
        var parser = SSEParser()
        var budget = SSEFrameBudget()
        for try await byte in bytes {
            try Task.checkCancellation()
            try budget.consume(byte)
            if byte == 10 {
                let raw = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let frame = parser.feed(line: raw), try await onFrame(frame) { return }
            } else {
                guard line.count < 8_388_608 else { throw APIError.http(413, "回复帧过大") }
                line.append(byte)
            }
        }
        // EOF：补一个空行，让解析器吐出最后一帧。
        if !line.isEmpty {
            let raw = String(decoding: line, as: UTF8.self)
            _ = parser.feed(line: raw)
            if let frame = parser.feed(line: ""), try await onFrame(frame) { return }
        } else if let frame = parser.feed(line: ""), try await onFrame(frame) {
            return
        }
        // EOF 不是完成标志；调用者必须看到 done/cancel/stream_end。
    }

    // MARK: - 会话与模型管理

    /// 可用模型目录。失败抛出，不静默返回空目录冒充“没有模型”。
    func availableModels() async throws -> ModelCatalog {
        try ModelCatalog(data: await performNative(chatRequests.models()))
    }

    func setSessionModel(sessionID:String, model:String, provider:String?) async throws {
        _ = try await performNative(chatRequests.sessionModel(sessionID:sessionID,model:model,provider:provider))
    }

    func renameSession(sessionID:String, title:String) async throws {
        _ = try await performNative(chatRequests.rename(sessionID:sessionID,title:title))
    }

    func setSessionPinned(sessionID:String, pinned:Bool) async throws {
        _ = try await performNative(chatRequests.pin(sessionID:sessionID,pinned:pinned))
    }

    func setSessionArchived(sessionID:String, archived:Bool) async throws {
        _ = try await performNative(chatRequests.archive(sessionID:sessionID,archived:archived))
    }

    func deleteSession(sessionID:String) async throws {
        _ = try await performNative(chatRequests.deleteSession(sessionID:sessionID))
    }

    /// 返回新会话 ID。
    /// 已部署的分支接口回的是扁平对象 `{session_id,title,parent_session_id}`，
    /// 不是 `{session:{...}}`；两种形态都接受，两种都不是就报错，不猜。
    func branchSession(sessionID:String, keepCount:Int?, title:String?) async throws -> String {
        let data = try await performNative(chatRequests.branch(sessionID:sessionID,keepCount:keepCount,title:title))
        guard let newID = BranchResponse.sessionID(from: data) else { throw APIError.badResponse }
        return newID
    }

    // MARK: - Cookie 桥接

    func requiresAuthentication(after error: Error) -> Bool {
        if case APIError.http(401, _) = error { return true }
        return false
    }

    /// URLSession 登录后 → 写进 WKWebView
    func syncCookiesToWebKit() async {
        let cookies = HTTPCookieStorage.shared.cookies(for: base) ?? []
        guard !cookies.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies {
            await store.setCookie(c)
        }
    }

    /// WKWebView 里登录过 → 读回 URLSession
    func syncCookiesFromWebKit() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let host = base.host ?? ""
        for c in cookies where CookieDomainPolicy.matches(c.domain, host: host) {
            HTTPCookieStorage.shared.setCookie(c)
        }
    }

    /// 清掉该实例域下所有 cookie（URLSession + WebKit）。退出/切换/删除实例
    /// 必须调用，否则旧身份残留会导致换账号后仍带着上一条登录态。
    func clearCookies() {
        let host = base.host ?? ""
        if let cookies = HTTPCookieStorage.shared.cookies {
            for c in cookies where CookieDomainPolicy.matches(c.domain, host: host) {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
        if let webCookies = HTTPCookieStorage.shared.cookies(for: base) {
            for c in webCookies { HTTPCookieStorage.shared.deleteCookie(c) }
        }
        // P1：按 host 过滤 WebKit 站点数据，不再全站清空。
        //
        // 原实现 `removeData(ofTypes: allWebsiteDataTypes, modifiedSince: .distantPast)`
        // 把**所有站点**的所有数据（其他实例的 cookie、localStorage、IndexedDB）
        // 一并删掉——切换实例会把另一个实例的登录态也毁掉。WebKit 没有
        // 「按域名前缀删」的 API，正确做法是 `fetchDataRecords` 后按
        // `displayName` 匹配过滤，只删属于本实例 host 的那部分。
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { record in
                CookieDomainPolicy.matches(record.displayName, host: host)
            }
            guard !mine.isEmpty else { return }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             for: mine) { }
        }
    }
}

/// 拒绝一切 HTTP 30x：WebUI 回落通道会 POST 密码与附件字节，重定向可把它们
/// 转发到第三方域。网关通道已有 `GatewayRedirectPolicy`，这里补齐回落侧。
private final class RedirectRejector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum APIError: LocalizedError, HTTPStatusProviding {
    case badResponse
    case http(Int, String)

    /// 让 `HistoryLoadFailure` 不必认识本类型就能判断「这是不是暂时性故障」。
    var httpStatusHint: Int? {
        if case let .http(code, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "服务器响应异常"
        case let .http(code, _):
            // Keep protocol details in the typed error, never render an
            // arbitrary server body (which may contain sensitive data).
            switch code {
            case 401: return "登录已失效，请重新登录"
            case 403: return "当前账号没有此操作的权限"
            case 404: return "找不到请求的内容"
            case 408: return "请求超时，请稍后重试"
            case 409: return "服务端状态已变化，请重新同步"
            case 413: return "发送的内容过大，请缩减后重试"
            case 429: return "请求过于频繁，请稍后重试"
            case 500...599: return "服务暂时不可用，请稍后重试"
            default: return "服务未能处理这次请求，请稍后重试"
            }
        }
    }
}
