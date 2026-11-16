import Foundation

struct SessionSummary: Identifiable, Decodable, Hashable {
    let sessionId: String
    var title: String?
    var updatedAt: Double?
    let createdAt: Double?
    let messageCount: Int?
    let profile: String?
    let source: String?
    var archived: Bool?
    var pinned: Bool?
    let preview: String?
    var isStreaming: Bool?
    var model: String?
    let workspace: String?

    var id: String { sessionId }

    /// 服务端确认后的本地同步，避免整表刷新才看到改名/置顶/换模型。
    func withTitle(_ value: String) -> SessionSummary {
        var copy = self; copy.title = value; return copy
    }
    func withPinned(_ value: Bool) -> SessionSummary {
        var copy = self; copy.pinned = value; return copy
    }
    func withModel(_ value: String) -> SessionSummary {
        var copy = self; copy.model = value; return copy
    }

    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未命名会话" : t
    }

    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        return Date(timeIntervalSince1970: updatedAt > 1_000_000_000_00 ? updatedAt / 1000 : updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case messageCount = "message_count"
        case profile
        case source
        case archived
        case pinned
        case preview
        case isStreaming = "is_streaming"
        case model
        case workspace
    }
}

/// /api/sessions 可能直接返回数组，也可能包一层（sessions / data / items）。
struct SessionListEnvelope: Decodable {
    let sessions: [SessionSummary]

    init(from decoder: Decoder) throws {
        if let arr = try? [SessionSummary](from: decoder) {
            sessions = arr
            return
        }
        let c = try decoder.container(keyedBy: Key.self)
        for k in [Key.sessions, .data, .items] {
            if let arr = try? c.decode([SessionSummary].self, forKey: k) {
                sessions = arr
                return
            }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "会话列表缺少有效的数组或 sessions/data/items 字段"))
    }

    enum Key: String, CodingKey { case sessions, data, items }
}

struct AuthStatus: Decodable {
    let authEnabled: Bool?
    let loggedIn: Bool?
    let passwordAuthEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case authEnabled = "auth_enabled"
        case loggedIn = "logged_in"
        case passwordAuthEnabled = "password_auth_enabled"
    }
}

/// 一个实例的后端形态。
///
/// - `webui`：原有的 WebUI 通道（cookie 登录，附件 + 模型目录 + 会话全在这边）。
/// - `gateway`：直连 Hermes 网关（Bearer API key）。会话与聊天走网关，
///   只有附件上传和模型目录回落到配套的 WebUI（见 `webuiBaseURL`）。
enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case webui
    case gateway

    var id: String { rawValue }

    var label: String {
        switch self {
        case .webui: return "WebUI"
        case .gateway: return "网关直连"
        }
    }

    var hint: String {
        switch self {
        case .webui: return "浏览器同款通道，附件与模型目录都在这边"
        case .gateway: return "直连 Hermes 网关，分支会带上完整历史"
        }
    }
}

struct HermesInstance: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    /// 后端形态。老实例解码时缺这个键 → webui，保证升级不改变既有行为。
    var backend: BackendKind = .webui
    /// 网关模式的 Bearer 密钥。WebUI 模式不用。
    var apiKey: String = ""
    /// 网关模式下附件上传与模型目录的回落地址（必须是 WebUI）。
    /// 留空则该网关实例不支持附件与模型目录。
    var webuiBaseURL: String = ""
    /// 网关容器里对应 WebUI `~/.hermes` 的路径。
    ///
    /// 两个容器挂的是同一个宿主机目录，但挂载点不同：WebUI 是
    /// `/home/hermeswebui/.hermes`，官方镜像的网关是 `/opt/data`。附件上传
    /// 返回的是 WebUI 侧绝对路径，原样交给 agent 会指向一个不存在的文件，
    /// 所以发送前要换前缀。Hermes 官方 docker 布局下这个默认值即可。
    var gatewayDataPath: String = ""

    /// 实例地址非法时的占位地址：`.invalid` 是保留域名，永远解析失败。
    /// 用它替代任何真实主机，确保配置损坏时不会把密钥静默发往第三方。
    static let invalidPlaceholderBaseURL = "https://invalid.invalid"

    init(id: UUID = UUID(), name: String, baseURL: String,
         backend: BackendKind = .webui, apiKey: String = "", webuiBaseURL: String = "",
         gatewayDataPath: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.backend = backend
        self.apiKey = apiKey
        self.webuiBaseURL = webuiBaseURL
        self.gatewayDataPath = gatewayDataPath
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, backend, apiKey, webuiBaseURL, gatewayDataPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        // 老版本没有这三个键：缺 backend 一律当 webui，保持原行为不变。
        backend = try c.decodeIfPresent(BackendKind.self, forKey: .backend) ?? .webui
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        webuiBaseURL = try c.decodeIfPresent(String.self, forKey: .webuiBaseURL) ?? ""
        gatewayDataPath = try c.decodeIfPresent(String.self, forKey: .gatewayDataPath) ?? ""
    }
}

extension SessionSummary {
    /// 刚新建、列表尚未刷新的会话占位，避免打开聊天时闪回列表。
    static func placeholder(id: String) -> SessionSummary {
        SessionSummary(sessionId: id, title: "新会话", updatedAt: Date().timeIntervalSince1970,
                       createdAt: nil, messageCount: nil, profile: nil, source: nil,
                       archived: false, pinned: false, preview: nil, isStreaming: nil,
                       model: nil, workspace: nil)
    }
}

/// /api/models 的分组形态：groups[].{provider, provider_id, models[].{id,label}}。
/// 只取客户端真正需要的三件事：展示名、模型 id、切模型时要回的 provider_id。
struct ModelOption: Identifiable, Equatable {
    let model: String
    let providerID: String?
    let label: String
    let providerLabel: String
    var id: String { (providerID ?? "") + "/" + model }
}

/// /api/session/branch 的响应解析。
/// 已部署版本回扁平 `{session_id,title,parent_session_id}`；也接受包一层
/// `{session:{session_id}}` 的形态。两者都不是就返回 nil，由调用方报错，
/// 不猜也不伪造新会话 ID。
enum BranchResponse {
    static func sessionID(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for candidate in [(root["session"] as? [String: Any])?["session_id"], root["session_id"]] {
            if let value = candidate as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}

/// 模型目录的可读错误；不依赖聊天协议层的错误类型。
enum ModelCatalogError: Error, LocalizedError {
    case malformed
    case server(String)
    var errorDescription: String? {
        switch self {
        case .malformed: return "模型目录格式无法识别"
        case .server(let text): return text
        }
    }
}

struct ModelCatalog: Equatable {
    let activeProvider: String?
    let defaultModel: String?
    let options: [ModelOption]

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.malformed
        }
        if let error = root["error"], !(error is NSNull), !(error as? String == "") {
            throw ModelCatalogError.server(error as? String ?? "模型目录读取失败")
        }
        activeProvider = root["active_provider"] as? String
        defaultModel = root["default_model"] as? String
        var list: [ModelOption] = []
        var seen = Set<String>()
        // 缺少 groups 字段是格式损坏，绝不能当成空目录成功；
        // {"groups":[]} 才是合法的空目录。
        guard let groups = root["groups"] as? [[String: Any]] else { throw ModelCatalogError.malformed }
        for group in groups {
            let providerID = group["provider_id"] as? String
            let providerLabel = (group["provider"] as? String) ?? (providerID ?? "")
            for entry in (group["models"] as? [[String: Any]] ?? []) {
                guard let raw = entry["id"] as? String else { continue }
                let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else { continue }
                let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
                let option = ModelOption(model: model, providerID: providerID,
                                         label: label, providerLabel: providerLabel)
                // 同一模型可能出现在多个 provider 下；按 provider+model 去重，
                // 但不能只按 model 去重，否则会丢掉落回 provider。
                guard seen.insert(option.id).inserted else { continue }
                list.append(option)
            }
        }
        options = list
    }

    /// 当前会话模型在目录里对应的那一项，用于给输入栏显示真实标签。
    func option(matching model: String?, provider: String?) -> ModelOption? {
        guard let model, !model.isEmpty else { return nil }
        if let provider, !provider.isEmpty {
            // An explicit provider must NEVER silently resolve to a model
            // offered by a different provider.
            return options.first { $0.model == model && ($0.providerID ?? "") == provider }
        }
        let candidates = options.filter { $0.model == model }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
