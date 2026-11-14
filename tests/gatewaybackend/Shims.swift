import Foundation
import FoundationNetworking

protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
enum APIError: Error { case badResponse, http(Int, String) }

// Only the separate WebUI fallback is a stub. Tests execute the real gateway backend,
// requests, transport contract, recovery store, decoder and pagination coordinator.
@MainActor final class HermesAPI: ObservableObject, NativeChatService {
    static var modelReads = 0
    let chatRequests: ChatRequests
    init(baseURL: String) { chatRequests = ChatRequests(baseURL: URL(string: baseURL)!) }
    func performNative(_ r: URLRequest) async throws -> Data { throw APIError.badResponse }
    func availableModels() async throws -> ModelCatalog { Self.modelReads += 1; throw APIError.badResponse }
    func authStatus() async throws -> AuthStatus { throw APIError.badResponse }
    func login(password: String) async throws {}
    func syncCookiesToWebKit() async {}
    func syncCookiesFromWebKit() async {}
    func sessions() async throws -> [SessionSummary] { [] }
    func createNativeSession() async throws -> String { "stub" }
    func renameSession(sessionID: String, title: String) async throws {}
    func setSessionPinned(sessionID: String, pinned: Bool) async throws {}
    func setSessionArchived(sessionID: String, archived: Bool) async throws {}
    func deleteSession(sessionID: String) async throws {}
    func branchSession(sessionID: String, keepCount: Int?, title: String?) async throws -> String { "stub" }
    func setSessionModel(sessionID: String, model: String, provider: String?) async throws {}
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot { throw APIError.badResponse }
    func uploadAttachment(_ request: URLRequest,
                          onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> Data {
        throw APIError.badResponse
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String { throw APIError.badResponse }
    func stopNativeTurn(streamID: String) async throws {}
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {}
}
