import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WebUI 的已部署 HTTP 合同；不携带 API_SERVER_KEY，继续使用用户登录 cookie。
struct ChatRequests {
    let baseURL: URL

    /// 不带 body 的请求构造：path 与 query 都来自本文件的常量，URL 合成在实践上
    /// 不可能失败。这里不做 `try!`：合成失败时退化为同一路由但丢掉 query，
    /// 由服务端返回参数错误，调用方能感知，而不是崩溃或静默打到别的端点。
    private func get(_ path: String, query: [URLQueryItem]) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            // 服务端 parse_qs 按 form-urlencoded 解码，字面 + 必须转义。
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            if let composed = parts.url { url = composed }
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    func make(_ path:String, query:[URLQueryItem] = [], body:[String:Any]? = nil) throws -> URLRequest {
        var r = get(path, query: query)
        if let body {
            r.httpMethod = "POST"
            r.httpBody = try JSONSerialization.data(withJSONObject:body)
            r.setValue("application/json", forHTTPHeaderField:"Content-Type")
        }
        return r
    }

    func history(sessionID:String,before:Int? = nil) -> URLRequest {
        var q = [URLQueryItem(name:"session_id",value:sessionID), URLQueryItem(name:"msg_limit",value:"60"), URLQueryItem(name:"resolve_model",value:"0")]
        if let before { q.append(URLQueryItem(name:"msg_before",value:String(before))) }
        return get("api/session", query: q)
    }
    /// 服务端把纯字符串附件归一化成 `{name, path:"", mime:""}`，
    /// path 为空就拿不到文件，所以必须传完整对象。
    func start(sessionID:String,text:String,attachments:[ChatAttachmentPayload] = []) throws -> URLRequest {
        try make("api/chat/start",body:[
            "session_id":sessionID,
            "message":text,
            "attachments":attachments.map(\.jsonObject)
        ])
    }
    func newSession() throws -> URLRequest {
        try make("api/session/new",body:["worktree":false])
    }
    func cancel(streamID:String) -> URLRequest {
        get("api/chat/cancel", query: [URLQueryItem(name:"stream_id",value:streamID)])
    }
    /// 运行中追加引导（steer）：不打断当前轮，服务端在下一个工具结果边界注入。
    /// 失败时服务端返回 `{accepted:false, fallback:"..."}`，调用方必须据此降级，
    /// 不能假定这条已经送达。
    func steer(sessionID:String,text:String) throws -> URLRequest {
        try make("api/chat/steer",body:["session_id":sessionID,"text":text])
    }
    func stream(streamID:String,lastEventID:String? = nil) -> URLRequest {
        var q = [URLQueryItem(name:"stream_id",value:streamID)]
        if let lastEventID {
            q.append(URLQueryItem(name:"after_event_id",value:lastEventID))
        }
        var r = get("api/chat/stream", query: q)
        r.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        r.setValue(lastEventID,forHTTPHeaderField:"Last-Event-ID")
        r.timeoutInterval = 300
        return r
    }

    // MARK: - 会话与模型管理（与 WebUI 同一批已部署路由）

    func models() -> URLRequest {
        get("api/models", query: [])
    }

    /// 会话级模型切换；provider 传模型目录里的 provider_id。
    func sessionModel(sessionID:String,model:String,provider:String?) throws -> URLRequest {
        var body: [String:Any] = ["session_id":sessionID, "model":model]
        if let provider, !provider.isEmpty { body["model_provider"] = provider } else { body["model_provider"] = NSNull() }
        return try make("api/session/update",body:body)
    }

    func rename(sessionID:String,title:String) throws -> URLRequest {
        try make("api/session/rename",body:["session_id":sessionID,"title":title])
    }

    func pin(sessionID:String,pinned:Bool) throws -> URLRequest {
        try make("api/session/pin",body:["session_id":sessionID,"pinned":pinned])
    }

    func archive(sessionID:String,archived:Bool) throws -> URLRequest {
        try make("api/session/archive",body:["session_id":sessionID,"archived":archived])
    }

    func deleteSession(sessionID:String) throws -> URLRequest {
        try make("api/session/delete",body:["session_id":sessionID])
    }

    /// 从当前会话复制出一段新会话；keepCount 为保留的消息条数，nil 表示全部。
    func branch(sessionID:String,keepCount:Int?,title:String?) throws -> URLRequest {
        var body: [String:Any] = ["session_id":sessionID]
        if let keepCount { body["keep_count"] = keepCount }
        if let title, !title.isEmpty { body["title"] = title }
        return try make("api/session/branch",body:body)
    }
}
