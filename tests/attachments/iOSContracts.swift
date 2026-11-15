import Foundation
import SwiftUI

// Compile-only app boundary stand-in. No existing/shared sources are compiled here.
@MainActor final class HermesAPI: HermesBackend {
    struct Requests { let baseURL: URL }
    var chatRequests: Requests { Requests(baseURL:URL(string:"https://host.example/")!) }
    var capabilities: BackendCapabilities { .webUI }
    var attachmentBaseURL: URL { chatRequests.baseURL }
    var webConsoleBaseURL: URL { chatRequests.baseURL }

    func authStatus() async throws -> AuthStatus { throw URLError(.notConnectedToInternet) }
    func login(password: String) async throws {}
    func availableModels() async throws -> ModelCatalog { throw URLError(.notConnectedToInternet) }
    func performNative(_ request: URLRequest) async throws -> Data { throw URLError(.notConnectedToInternet) }
    func uploadAttachment(_ request: URLRequest,
                          onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
    func syncCookiesToWebKit() async {}
    func syncCookiesFromWebKit() async {}

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        throw URLError(.notConnectedToInternet)
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
    func startNativeTurn(sessionID: String, text: String,
                         attachments: [ChatAttachmentPayload]) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
    func stopNativeTurn(streamID: String) async throws {}
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        throw URLError(.notConnectedToInternet)
    }
    func approveNativeTurn(runID: String, choice: String, requestID: String?) async throws -> String? {
        throw URLError(.notConnectedToInternet)
    }
    func clarifyNativeTurn(runID: String, answer: String, requestID: String,
                           executionGeneration: Int) async throws -> String? {
        throw URLError(.notConnectedToInternet)
    }

    func sessions() async throws -> [SessionSummary] { throw URLError(.notConnectedToInternet) }
    func createSession(title: String?, model: String?) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
    func renameSession(sessionID: String, title: String) async throws {}
    func setSessionPinned(sessionID: String, pinned: Bool) async throws {}
    func setSessionArchived(sessionID: String, archived: Bool) async throws {}
    func deleteSession(sessionID: String) async throws {}
    func forkSession(sessionID: String, keepCount: Int?) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
    func setSessionModel(sessionID: String, model: String, provider: String?) async throws {}
}

@MainActor func verifyAttachmentUIBoundary(api: HermesAPI, attachment: UploadedAttachment) throws {
    let model = AttachmentComposerModel(
        api: api, sessionID: "s",
        draftStore: ChatDraftStore(instanceID: "test", accountScope: "test", sessionID: "s"))
    let _: Bool = model.canSend
    let _: [UploadedAttachment] = try model.payload(for:"s")
    model.reset(sessionID:"next")
    let _: AttachmentComposerBar = AttachmentComposerBar(model:model, isLocked:false)
    let loader = AttachmentPreviewLoader(policy:try AttachmentPreviewPolicy(baseURL:api.chatRequests.baseURL))
    let _: SecureAttachmentPreview = SecureAttachmentPreview(attachment:attachment, sessionID:"s", loader:loader)
    // History attachment strip: images get fixed-height thumbnails, files get cards.
    let strip = AttachmentStrip(paths:["/state/a.png","/state/文档.pdf"], name:"m", baseURL:api.chatRequests.baseURL, sessionID:"s")
    let _: AttachmentStrip = strip
    let _: [HistoryAttachment] = HistoryAttachment.parse(["/state/a.png","https://tracker.invalid/x.png"], baseURL:api.chatRequests.baseURL)
    // File download path for Quick Look / Share, independent of raster MIME.
    let downloader = AttachmentFileDownloader(policy:try AttachmentPreviewPolicy(baseURL:api.chatRequests.baseURL))
    let _ = downloader
}
