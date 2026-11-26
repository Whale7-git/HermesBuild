import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 直连 Hermes 网关的请求构造（`Authorization: Bearer`）。
///
/// 与 `ChatRequests` 的差别只在认证与路由：网关没有 WebUI 的登录 cookie，
/// 每条请求都必须带 API key；会话/运行因此走另一套 `/api/sessions`、`/v1/runs`。
enum GatewayRequestError: LocalizedError {
    case invalidBaseURL, invalidID, invalidReasoningEffort, invalidApprovalRequest

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "网关地址无效：仅支持 http/https，且不能带用户信息、查询或片段"
        case .invalidID: return "会话或运行标识无效"
        case .invalidReasoningEffort: return "无效的推理强度，消息未提交"
        case .invalidApprovalRequest: return "审批缺少服务端请求标识或执行代次，未发送"
        }
    }
}

struct GatewayRequests {
    let baseURL: URL
    let apiKey: String

    // MARK: - 会话

    func sessions(limit: Int = 100, offset: Int = 0) throws -> URLRequest {
        try make("api/sessions", query: [
            URLQueryItem(name: "limit", value: String(max(1, limit))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ])
    }

    /// `order=latest` 表示 offset 从最新一条开始往前数（服务端倒序分页）。
    func messages(sessionID: String, limit: Int, offset: Int, order: String = "latest") throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        return try make("api/sessions/\(id)/messages", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: order)
        ])
    }

    /// 单个会话的元数据。用 `message_count` 把 offset 分页换算成绝对消息索引。
    func session(sessionID: String) throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        return try make("api/sessions/\(id)")
    }

    /// 网关要求 POST 带 JSON 体，空对象也照发，避免服务端按表单分支解析。
    func createSession(title: String? = nil, model: String? = nil) throws -> URLRequest {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let model { body["model"] = model }
        return try make("api/sessions", body: body)
    }

    /// 只放非 nil 的键：PATCH 的语义是「没提到的字段不动」，
    /// 传 `NSNull` 会被当成显式清空。
    func patchSession(sessionID: String, title: String?, pinned: Bool?, archived: Bool?) throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let pinned { body["pinned"] = pinned }
        if let archived { body["archived"] = archived }
        return try make("api/sessions/\(id)", body: body, method: "PATCH")
    }

    func deleteSession(sessionID: String) throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        return try make("api/sessions/\(id)", method: "DELETE")
    }

    /// `keepCount` 目前只是参数占位：网关的 fork 是整段复制，服务端没有截断字段，
    /// 所以它既不进 body 也不进 query。等网关补上截断能力，改这里即可，调用方不动。
    func fork(sessionID: String, keepCount: Int?) throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        return try make("api/sessions/\(id)/fork", body: [:])
    }

    func setModel(sessionID: String, model: String, provider: String?) throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        var body: [String: Any] = ["model": model]
        if let provider { body["provider"] = provider }
        return try make("api/sessions/\(id)/model", body: body)
    }

    // MARK: - 运行

    func startRun(sessionID: String, text: String) throws -> URLRequest {
        try startRun(sessionID: sessionID, text: text, model: nil, provider: nil)
    }

    func startRun(sessionID: String, text: String, model: String?, provider: String?,
                  reasoningEffort: String? = nil) throws -> URLRequest {
        let id = try Self.validatedID(sessionID)
        var body: [String: Any] = ["input": text, "session_id": id]
        if let model, !model.isEmpty { body["model"] = model }
        if let provider, !provider.isEmpty { body["provider"] = provider }
        if let reasoningEffort {
            guard ReasoningEffortPolicy.allowed(reasoningEffort) else {
                throw GatewayRequestError.invalidReasoningEffort
            }
            body["model_options"] = ["reasoning_effort": reasoningEffort]
        }
        return try make("v1/runs", body: body)
    }

    /// 事件流：长连接按 600 秒超时，且必须显式声明 `text/event-stream`。
    /// `lastEventID` 既放 `Last-Event-ID` 头，也放 `?last_seq=` 查询 —— 网关两条通道都认，
    /// 重连时哪边先被代理改写都还能续上。10 分钟足够一次长工具调用，又不会永久挂住。
    func runEvents(runID: String, lastEventID: String?) throws -> URLRequest {
        let id = try Self.validatedID(runID)
        let resume = lastEventID.flatMap { $0.isEmpty ? nil : $0 }
        var query: [URLQueryItem] = []
        if let resume { query.append(URLQueryItem(name: "last_seq", value: resume)) }
        var request = try make("v1/runs/\(id)/events", query: query, timeout: 600)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let resume { request.setValue(resume, forHTTPHeaderField: "Last-Event-ID") }
        return request
    }

    func stopRun(runID: String) throws -> URLRequest {
        let id = try Self.validatedID(runID)
        return try make("v1/runs/\(id)/stop", body: [:])
    }

    func runStatus(runID: String) throws -> URLRequest {
        let id = try Self.validatedID(runID)
        return try make("v1/runs/\(id)")
    }

    func advertisedCapabilities() throws -> URLRequest {
        try make("v1/capabilities")
    }

    func resolveUnknownRun(_ offer: UnknownRunResolutionOffer) throws -> URLRequest {
        let id = try Self.validatedID(offer.runID)
        guard !offer.admissionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              offer.executionGeneration >= 0 else { throw GatewayRequestError.invalidID }
        return try make("v1/runs/\(id)/resolve-unknown", body: [
            "admission_id": offer.admissionID,
            "execution_generation": offer.executionGeneration
        ])
    }

    /// 运行中追加输入，不打断当前轮；服务端在下一个边界注入。
    func steerRun(runID: String, text: String) throws -> URLRequest {
        let id = try Self.validatedID(runID)
        return try make("v1/runs/\(id)/steer", body: ["input": text])
    }

    /// 完整模型目录。`/v1/models` 只给一个 `hermes-agent` 占位，真正可用的是这个。
    func modelOptions() throws -> URLRequest {
        try make("api/model/options")
    }

    /// 回答网关的审批请求。
    ///
    /// Canonical approval responses require the exact prompt ID and execution
    /// generation. An identityless request could approve another pending tool.
    func approveRun(runID: String, choice: String, requestID: String,
                    executionGeneration: Int) throws -> URLRequest {
        let id = try Self.validatedID(runID)
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              executionGeneration >= 0 else { throw GatewayRequestError.invalidApprovalRequest }
        let body: [String: Any] = [
            "choice": choice, "request_id": requestID,
            "execution_generation": executionGeneration
        ]
        return try make("v1/runs/\(id)/approval", body: body)
    }

    /// 回答网关的补充信息请求（clarify）。
    ///
    /// 与审批**不是同一个合同**：服务端的 `respond_run` 有硬校验
    /// `set(body) != {'request_id', 'execution_generation', field}`，
    /// 字段名是 `answer` 而不是 `choice`，而且 `execution_generation` 必填
    /// （取自 `clarify.request` 帧的 `execution_generation`）。少一个字段、
    /// 多一个字段、或字段名写成 `choice`，一律 400 `invalid_params`。
    ///
    /// `answer` 就是用户输入的原始文本或所选选项的文字——**所有解析都在服务端**
    /// （`_coerce_text_response` 认编号、认标签、认 `1,3` 多选），客户端不需要
    /// 也不应该自己做映射，否则与服务端口径不一致时会答错选项。
    func clarifyRun(runID: String, answer: String, requestID: String,
                    executionGeneration: Int) throws -> URLRequest {
        let id = try Self.validatedID(runID)
        let body: [String: Any] = [
            "request_id": requestID,
            "execution_generation": executionGeneration,
            "answer": answer,
        ]
        return try make("v1/runs/\(id)/clarify", body: body)
    }

    // MARK: - 构造

    /// 唯一的出口：路径分段、查询转义、认证头都在这里统一。
    ///
    /// 路径按 `/` 拆开逐段 `appendPathComponent`：整串传进去会被当成一个组件，
    /// `api/sessions/x` 会变成 `api%2Fsessions%2Fx`。
    private func make(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                      method: String? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        var url = try Self.validatedBase(baseURL)
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GatewayRequestError.invalidBaseURL
        }
        if !query.isEmpty {
            parts.queryItems = query
            // 服务端按 form-urlencoded 解码，字面 + 必须转义成 %2B。
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let finalURL = parts.url else { throw GatewayRequestError.invalidBaseURL }
        var request = URLRequest(url: finalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - 校验

    /// 标识会拼进路径，所以必须挡掉分隔符与控制字符，否则 `/` 会多出一段路径，
    /// `\r\n` 会把 header 折成两条。
    private static let forbiddenIDScalars = CharacterSet(charactersIn: "/?#\\\r\n\0")

    private static func validatedID(_ value: String) throws -> String {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { forbiddenIDScalars.contains($0) }) else {
            throw GatewayRequestError.invalidID
        }
        return value
    }

    private static func validatedBase(_ url: URL) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw GatewayRequestError.invalidBaseURL
        }
        return url
    }
}

/// 分页只做纯计算，脱离网络也能单测。
enum GatewayPaging {
    /// 客户端语义：已有 `loadedCount` 条时，下一次要 `pageSize` 条，offset 就是已加载数。
    static func nextOffset(loadedCount: Int) -> Int {
        Swift.max(0, loadedCount)
    }

    /// 页大小夹在 `1...max`；`default`/`max` 与关键字、全局函数同名，因此加反引号并显式写 `Swift.max`。
    static func pageSize(`default`: Int = 60, max: Int = 200) -> Int {
        Swift.min(Swift.max(1, `default`), Swift.max(1, max))
    }
}
