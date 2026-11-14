import Foundation
import SwiftUI

// Compile-only app boundary stand-in. No existing/shared sources are compiled here.
@MainActor final class HermesAPI {
    struct Requests { let baseURL: URL }
    var chatRequests: Requests { Requests(baseURL:URL(string:"https://host.example/")!) }
    func performNative(_ request: URLRequest) async throws -> Data { throw URLError(.notConnectedToInternet) }
}

@MainActor func verifyAttachmentUIBoundary(api: HermesAPI, attachment: UploadedAttachment) throws {
    let model = AttachmentComposerModel(api:api, sessionID:"s")
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
