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
@MainActor private func waitFor(_ name: String, _ condition: () -> Bool) async {
    for _ in 0..<400 {
        if condition() { check(true, name); return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    check(false, name)
}

@MainActor func runCoordinatorTests() async throws {
    // T-09: adding, abandoning and switching an unsent draft must never
    // create a remote object. Upload only begins at an explicit send tap.
    let noSendHarness = UploadHarness()
    let noSend = AttachmentUploadCoordinator(sessionID: "draft") { sid, draft, _ in
        try await noSendHarness.upload(sessionID: sid, draft: draft)
    }
    let discarded = try noSend.add(name: "discarded.png", mime: "image/png", data: Data([1]))
    check(noSendHarness.sessions.isEmpty, "T-09 adding an unsent attachment performs zero gateway uploads")
    noSend.remove(discarded)
    noSend.reset(sessionID: "next")
    check(noSendHarness.sessions.isEmpty, "T-09 discard and session switch leave no uploaded draft object")

    // Legacy eager resume must not reappear after a process restart: retain
    // original bytes and ready references but do not issue network requests.
    let restoreHarness = UploadHarness()
    let restore = AttachmentUploadCoordinator(sessionID: "restored") { sid, draft, _ in
        try await restoreHarness.upload(sessionID: sid, draft: draft)
    }
    _ = try restore.add(name: "cold.png", mime: "image/png", data: Data([3]))
    let snapshot = restore.batch.persistedValue
    let reopened = AttachmentUploadCoordinator(sessionID: "restored") { sid, draft, _ in
        try await restoreHarness.upload(sessionID: sid, draft: draft)
    }
    try reopened.restorePersisted(snapshot)
    check(restoreHarness.sessions.isEmpty && reopened.batch.items.count == 1,
          "T-09 cold restore preserves bytes without eager upload")

    // One active upload invalidated by a conversation switch must never
    // complete into the other session; cancellation can be ignored by transport.
    let harness = UploadHarness()
    let coordinator = AttachmentUploadCoordinator(sessionID: "s1") { sid, draft, _ in
        try await harness.upload(sessionID: sid, draft: draft)
    }
    let id = try coordinator.add(name: "a.png", mime: "image/png", data: Data([1]))
    check(harness.sessions.isEmpty, "upload waits for explicit prepareForSend")
    let pending = Task { try await coordinator.prepareForSend(sessionID: "s1") }
    await waitFor("explicit send starts upload", { harness.sessions == ["s1"] })
    coordinator.reset(sessionID: "s2")
    pending.cancel()
    harness.finishNext()
    do { _ = try await pending.value; check(false, "switched session rejects old prepared send") }
    catch { check(true, "switched session never publishes old payload") }
    check(coordinator.batch.sessionID == "s2" && coordinator.batch.items.isEmpty,
          "late upload result cannot overwrite a new session")
    coordinator.remove(id)

    // T-10: a transport that ignores cancellation still owns its slot until
    // completion. A new session must not exceed the physical two-slot cap.
    let slow = UploadHarness()
    let bounded = AttachmentUploadCoordinator(sessionID: "old") { sid, draft, _ in
        try await slow.upload(sessionID: sid, draft: draft)
    }
    let first = try bounded.add(name: "one.png", mime: "image/png", data: Data([1]))
    let second = try bounded.add(name: "two.png", mime: "image/png", data: Data([2]))
    let oldSend = Task { try await bounded.prepareForSend(sessionID: "old") }
    await waitFor("two original preflight uploads occupy both slots", { slow.sessions.count == 2 })
    bounded.remove(first)
    bounded.remove(second)
    _ = try bounded.add(name: "three.png", mime: "image/png", data: Data([3]))
    check(slow.sessions.count == 2, "removed drafts do not create another upload")
    bounded.reset(sessionID: "new")
    _ = try bounded.add(name: "next.png", mime: "image/png", data: Data([4]))
    oldSend.cancel()
    let newSend = Task { try await bounded.prepareForSend(sessionID: "new") }
    try? await Task.sleep(nanoseconds: 30_000_000)
    check(slow.sessions.count == 2, "cancelled transport keeps its physical slot")
    slow.finishNext()
    await waitFor("new session starts after old transport finishes",
                  { slow.sessions == ["old", "old", "new"] })
    slow.finishNext()
    slow.finishNext()
    let newPayload = try await newSend.value
    check(newPayload.count == 1 && newPayload[0].name == "next.png",
          "only current session file reaches the prepared payload")
    _ = try? await oldSend.value
    check(slow.maximumActive <= 2, "session switch never exceeds two live uploads")

    // T-10: eight selected attachments must remain local until send; the
    // bounded queue drains without a third simultaneous multipart body.
    let eightHarness = UploadHarness()
    let eight = AttachmentUploadCoordinator(sessionID: "eight") { sid, draft, _ in
        try await eightHarness.upload(sessionID: sid, draft: draft)
    }
    for number in 0..<8 {
        _ = try eight.add(name: "asset-\(number).png", mime: "image/png", data: Data([UInt8(number)]))
    }
    check(eightHarness.sessions.isEmpty, "T-10 eight draft attachments have zero eager uploads")
    let eightSend = Task { try await eight.prepareForSend(sessionID: "eight") }
    await waitFor("T-10 first two uploads begin", { eightHarness.sessions.count == 2 })
    for completed in 0..<8 {
        eightHarness.finishNext()
        if completed < 6 {
            await waitFor("T-10 bounded queue advances \(completed + 1)",
                          { eightHarness.sessions.count == completed + 3 })
        }
    }
    let all = try await eightSend.value
    check(all.count == 8 && eight.batch.canSend, "T-10 all eight complete with correct file references")
    check(eightHarness.maximumActive <= 2, "T-10 no more than two physical uploads are active")

    // The 24-MiB raw in-flight budget is independent of the two-task limit.
    let byteHarness = UploadHarness()
    let bytes = AttachmentUploadCoordinator(sessionID: "large") { sid, draft, _ in
        try await byteHarness.upload(sessionID: sid, draft: draft)
    }
    _ = try bytes.add(name: "large-a.bin", mime: "application/octet-stream",
                      data: Data(repeating: 1, count: 13 * 1024 * 1024))
    _ = try bytes.add(name: "large-b.bin", mime: "application/octet-stream",
                      data: Data(repeating: 2, count: 13 * 1024 * 1024))
    let byteSend = Task { try await bytes.prepareForSend(sessionID: "large") }
    await waitFor("byte budget begins one 13-MiB upload", { byteHarness.sessions.count == 1 })
    check(byteHarness.sessions.count == 1, "24-MiB byte budget blocks second 13-MiB body")
    byteHarness.finishNext()
    await waitFor("byte budget frees after first upload", { byteHarness.sessions.count == 2 })
    byteHarness.finishNext()
    let largePayload = try await byteSend.value
    check(largePayload.count == 2, "both large uploads eventually complete")

    // A failure must stop further uploads, leave original bytes intact, and
    // keep already-ready references when the user explicitly retries.
    let interrupted = UploadHarness()
    let restart = AttachmentUploadCoordinator(sessionID: "retry") { sid, draft, _ in
        try await interrupted.upload(sessionID: sid, draft: draft)
    }
    for number in 0..<3 {
        _ = try restart.add(name: "f-\(number).png", mime: "image/png", data: Data([UInt8(number)]))
    }
    let firstAttempt = Task { try await restart.prepareForSend(sessionID: "retry") }
    await waitFor("two retry fixtures started", { interrupted.sessions.count == 2 })
    interrupted.finishNext()
    await waitFor("queue starts third fixture after first success", { interrupted.sessions.count == 3 })
    interrupted.failNext()
    do { _ = try await firstAttempt.value; check(false, "failed preflight cannot submit") }
    catch AttachmentError.uploadFailed { check(true, "failure blocks chat submission") }
    await waitFor("failed preflight leaves one ready attachment",
                  { restart.batch.items.filter { if case .ready = $0.state { return true }; return false }.count == 1 })
    // Retry while the cancelled third transport still owns its physical slot.
    // The scheduler must queue that draft and start it after the old transport
    // tears down, rather than silently dropping it from the retry batch.
    let secondAttempt = Task { try await restart.prepareForSend(sessionID: "retry") }
    await waitFor("retry starts first incomplete file while old slot is occupied",
                  { interrupted.sessions.count == 4 })
    check(interrupted.maximumActive <= 2,
          "retry never exceeds two physical uploads while an old cancellation drains")
    interrupted.finishNext() // Old cancelled transport ignores task cancellation.
    await waitFor("retry starts second incomplete file after old slot is released",
                  { interrupted.sessions.count == 5 })
    interrupted.finishNext()
    interrupted.finishNext()
    let retried = try await secondAttempt.value
    check(retried.count == 3 && interrupted.sessions.count == 5,
          "retry keeps completed server reference and uploads only two incomplete files")
}
@MainActor private final class UploadHarness {
    var sessions: [String] = []
    private var active = 0
    private(set) var maximumActive = 0
    private struct Pending {
        let continuation: CheckedContinuation<UploadedAttachment, Error>
        let name: String
        let mime: String
        let size: Int
    }
    private var pending: [Pending] = []
    func upload(sessionID: String, draft: AttachmentDraft) async throws -> UploadedAttachment {
        sessions.append(sessionID)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(continuation: continuation, name: draft.name,
                                   mime: draft.mime, size: draft.byteCount))
        }
    }
    func finishNext() {
        let next = pending.removeFirst()
        let object: [String: Any] = ["filename": next.name, "path": "/fixture/" + next.name,
                                     "size": next.size, "mime": next.mime,
                                     "is_image": next.mime.hasPrefix("image/")]
        let encoded = try! JSONSerialization.data(withJSONObject: object)
        next.continuation.resume(returning: try! UploadedAttachment(data: encoded))
    }
    func failNext() {
        pending.removeFirst().continuation.resume(throwing: URLError(.networkConnectionLost))
    }
}
private final class RedirectWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record(_ value:Bool) { lock.withLock { self.value = value } }
    var rejected:Bool { lock.withLock { value } }
}
