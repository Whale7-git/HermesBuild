import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GET-only loopback fixtures; no upload or production HTTP.
@MainActor func runPreviewTests() async throws {
    let base = URL(string:ProcessInfo.processInfo.environment["ATTACHMENT_FIXTURE_URL"]!)!
    let config = URLSessionConfiguration.ephemeral
    let policy = try AttachmentPreviewPolicy(baseURL:base)
    func file(_ path: String) throws -> UploadedAttachment {
        let obj:[String:Any] = ["filename":"a.png", "path":path, "mime":"image/png", "size":3, "is_image":true]
        return try UploadedAttachment(data:JSONSerialization.data(withJSONObject:obj))
    }
    let loader = AttachmentPreviewLoader(policy:policy, configuration:config)
    let data = try await loader.imageData(sessionID:"s", attachment:file("/ok"))
    check(data == Data([1, 2, 3]), "preview transport returns bounded raster data")
    for path in ["/html", "/big", "/stream-big", "/unauth", "/redirect"] {
        do { _ = try await loader.imageData(sessionID:"s", attachment:file(path)); fatalError("FAIL unsafe response accepted") }
        catch { check(true, "preview rejects \(path) response") }
    }
    let task = Task<Data, Error> { try await loader.imageData(sessionID:"s", attachment:file("/ok")) }
    task.cancel()
    do { _ = try await task.value; fatalError("FAIL cancelled preview succeeded") }
    catch { check(true, "cancelled preview does not deliver image") }
    // A failed user-owned image must reveal the failure category, never a
    // URL, token, opaque filesystem path, or raw server response body.
    check(AttachmentImageFailurePresentation.reason(for: AttachmentError.http(401)).contains("无权"),
          "401 preview reports an authentication problem")
    check(AttachmentImageFailurePresentation.reason(for: AttachmentError.http(404)).contains("找不到"),
          "404 preview distinguishes a missing remote file")
    check(AttachmentImageFailurePresentation.reason(for: AttachmentError.unsupportedPreview).contains("图片格式"),
          "invalid MIME reports a preview-format failure")
    check(AttachmentImageFailurePresentation.reason(for: URLError(.timedOut)).contains("超时"),
          "preview timeout is distinguishable from HTTP and decode errors")
    let testMessage = AttachmentImageFailurePresentation.reason(for: AttachmentError.http(502))
    check(testMessage.contains("502") && !testMessage.contains("https://"),
          "HTTP failures include only the safe status code")
    let guardDelegate = AttachmentRedirectGuard()
    let session = URLSession(configuration:.ephemeral)
    defer { session.invalidateAndCancel() }
    let request = URLRequest(url:base)
    let redirect = HTTPURLResponse(url:base, statusCode:302, httpVersion:nil, headerFields:nil)!
    // Immutable Sendable witness confirms redirect is rejected, including same-origin redirects.
    let witness = RedirectWitness()
    guardDelegate.urlSession(session, task:session.dataTask(with:request), willPerformHTTPRedirection:redirect, newRequest:request) { witness.record($0 == nil) }
    check(witness.rejected, "all preview redirects are denied before credentials can escape")
}
@MainActor func runCoordinatorTests() async throws {
    let harness = UploadHarness()
    let coordinator = AttachmentUploadCoordinator(sessionID:"s1") { sessionID, draft, _ in
        try await harness.upload(sessionID:sessionID, draft:draft)
    }
    let id = try coordinator.add(name:"a.png", mime:"image/png", data:Data([1]))
    await Task.yield()
    check(harness.sessions == ["s1"], "coordinator uploads only selected file into captured session")
    check(!coordinator.batch.canSend, "coordinator blocks while upload pending")
    coordinator.reset(sessionID:"s2")
    harness.finishNext()
    await Task.yield()
    check(coordinator.batch.sessionID == "s2" && coordinator.batch.items.isEmpty, "coordinator ignores late response after session switch")
    coordinator.remove(id)
}
@MainActor private final class UploadHarness {
    var sessions:[String] = []
    private var pending:[CheckedContinuation<UploadedAttachment, Error>] = []
    func upload(sessionID:String, draft:AttachmentDraft) async throws -> UploadedAttachment {
        sessions.append(sessionID)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finishNext() {
        let fixture = Data(#"{"filename":"a.png","path":"/a.png","size":1,"mime":"image/png","is_image":true}"#.utf8)
        pending.removeFirst().resume(returning:try! UploadedAttachment(data:fixture))
    }
}
private final class RedirectWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record(_ value:Bool) { lock.withLock { self.value = value } }
    var rejected:Bool { lock.withLock { value } }
}
