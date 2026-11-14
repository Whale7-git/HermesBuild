import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 具备搜索/归档能力的后端。单独一个协议，避免把 SessionDiscoveryService
/// 拖进只需要「聊天 + 会话列表」的实现（也让 AppState 的离线测试不必引入它）。
@MainActor protocol DiscoveryProviding: AnyObject {
    /// 网关没有搜索/归档端点，未配置回落 WebUI 时为 nil。
    var discovery: SessionDiscoveryService? { get }
}

@MainActor protocol SessionDiscoveryService {
    func searchSessions(query: String) async throws -> SessionSearchResponse
    func archivedSessions(offset: Int, limit: Int) async throws -> ArchivedSessionPage
}

@MainActor struct SessionListService: SessionDiscoveryService {
    let requests: ChatRequests
    let perform: (URLRequest) async throws -> Data

    func searchSessions(query: String) async throws -> SessionSearchResponse {
        try SessionSearchResponse(data: await perform(requests.searchSessions(query: query)))
    }

    func archivedSessions(offset: Int, limit: Int) async throws -> ArchivedSessionPage {
        try ArchivedSessionPage(data: await perform(requests.archivedSessions(offset: offset, limit: limit)))
    }
}

#if canImport(WebKit)
extension HermesAPI: DiscoveryProviding {
    /// 协议要求可选：WebUI 实例永远有；网关实例回落到配套 WebUI 时才给。
    var discovery: SessionDiscoveryService? { discoveryService }
}

extension HermesAPI {
    /// Reuse the API's authenticated URLSession via its internal transport, not a second session.
    var discoveryService: SessionListService {
        SessionListService(requests: chatRequests) { request in
            // performNative already synchronizes cookies and retries one 401.
            // Wrapping it in another retry doubles requests after auth expires.
            try await self.performNative(request)
        }
    }
}
#endif

extension ChatRequests {
    /// depth=0 is explicitly supported by the deployed route: scan the full transcript.
    func searchSessions(query: String) throws -> URLRequest {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw SessionDiscoveryError.invalidRequest }
        return try make("api/sessions/search", query: [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "content", value: "1"),
            URLQueryItem(name: "depth", value: "0"),
            URLQueryItem(name: "all_profiles", value: "0")
        ])
    }

    /// Only archived rows have a deployed pagination contract; active rows remain unpaged.
    func archivedSessions(offset: Int, limit: Int) throws -> URLRequest {
        guard (0...200_000).contains(offset), (1...2000).contains(limit) else { throw SessionDiscoveryError.invalidRequest }
        return try make("api/sessions", query: [
            URLQueryItem(name: "include_archived", value: "1"),
            URLQueryItem(name: "archived_offset", value: String(offset)),
            URLQueryItem(name: "archived_limit", value: String(limit)),
            URLQueryItem(name: "all_profiles", value: "0")
        ])
    }
}

/// 能力缺失时的占位实现：明确抛错，绝不静默返回空列表冒充「没有搜索结果」。
@MainActor
struct UnavailableDiscoveryService: SessionDiscoveryService {
    func searchSessions(query: String) async throws -> SessionSearchResponse {
        throw SessionDiscoveryError.unsupported
    }
    func archivedSessions(offset: Int, limit: Int) async throws -> ArchivedSessionPage {
        throw SessionDiscoveryError.unsupported
    }
}
