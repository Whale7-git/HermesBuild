import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor func runReliabilityProbe(_ probe: String) async throws {
    let base = URL(string: ProcessInfo.processInfo.environment["ATTACHMENT_FIXTURE_URL"]!)!
    let policy = try AttachmentPreviewPolicy(baseURL: base)
    let loader = AttachmentFileDownloader(policy: policy)
    switch probe {
    case "ownership":
        async let first = loader.download(sessionID: "s", path: "/same-a", name: "same.pdf")
        async let second = loader.download(sessionID: "other", path: "/same-b", name: "same.pdf")
        let (a, b) = try await (first, second)
        defer { AttachmentDownloadFiles.remove(a); AttachmentDownloadFiles.remove(b) }
        check(a != b && a.deletingLastPathComponent() != b.deletingLastPathComponent(), "same-name downloads own independent directories")
        check((try? Data(contentsOf: a)) == Data(repeating: 65, count: 8192), "first same-name file keeps exact bytes")
        check((try? Data(contentsOf: b)) == Data(repeating: 66, count: 4096), "second same-name file keeps exact bytes")
    case "unknown":
        let url = try await loader.download(sessionID: "s", path: "/chunked-small", name: "unknown.bin")
        defer { AttachmentDownloadFiles.remove(url) }
        check((try? Data(contentsOf: url)) == Data([1, 2, 3]), "unknown-length small download succeeds")
    case "fallback":
        do {
            _ = try await loader.download(sessionID: "s", path: "/media-denied", name: "denied.bin")
            check(false, "media 403 never falls back to raw")
        } catch AttachmentError.http(403) { check(true, "media 403 preserves permission error") }
    case "mediaimage":
        let file = UploadedAttachment(name: "image.png", path: "/media-only-image", size: 3, mime: "image/png", isImage: true)
        let data = try await AttachmentPreviewLoader(policy: policy).imageData(sessionID: "s", attachment: file)
        check(data == Data([1, 2, 3]), "image preview uses media route for agent output")
    default: fatalError("unknown fixture probe")
    }
}

@MainActor func runReliabilityTests() async throws {
    for probe in ["ownership", "unknown", "fallback", "mediaimage"] { try await runReliabilityProbe(probe) }
    let base = URL(string: ProcessInfo.processInfo.environment["ATTACHMENT_FIXTURE_URL"]!)!
    let policy = try AttachmentPreviewPolicy(baseURL: base)
    let loader = AttachmentFileDownloader(policy: policy)
    var internalURL = URLComponents(url: base.appendingPathComponent("api/media"), resolvingAgainstBaseURL: false)!
    internalURL.queryItems = [URLQueryItem(name: "path", value: "/normalized-scope"), URLQueryItem(name: "session_id", value: "stale-session")]
    let normalized = try await loader.download(sessionID: "scope-current", path: internalURL.url!.absoluteString, name: "scope.bin")
    check((try? Data(contentsOf: normalized)) == Data([1, 2, 3]), "absolute media file link downloads using the current session")
    AttachmentDownloadFiles.remove(normalized)
    let normalizedImage = UploadedAttachment(name: "a.png", path: internalURL.url!.absoluteString, size: 3, mime: "image/png", isImage: true)
    let normalizedImageData = try await AttachmentPreviewLoader(policy: policy).imageData(sessionID: "scope-current", attachment: normalizedImage)
    check(normalizedImageData == Data([1, 2, 3]), "absolute image link rebinds current session on real loopback request")
    for code in [404, 405, 501] {
        let url = try await loader.download(sessionID: "s", path: "/fallback-\(code)", name: "fallback.bin")
        check((try? Data(contentsOf: url)) == Data([1, 2, 3]), "file fallback accepts compatible media \(code)")
        try await Task.sleep(nanoseconds: 10_000_000)
        check(FileManager.default.fileExists(atPath: url.path), "late media completion cannot delete raw success \(code)")
        AttachmentDownloadFiles.remove(url)
        let image = UploadedAttachment(name: "a.png", path: "/fallback-\(code)", size: 3, mime: "image/png", isImage: true)
        let data = try await AttachmentPreviewLoader(policy: policy).imageData(sessionID: "s", attachment: image)
        check(data == Data([1, 2, 3]), "image fallback accepts compatible media \(code)")
    }
    let original = try await loader.download(sessionID: "s", path: "/same-a", name: "protected.pdf")
    for (path, expected) in [("/media-unauth", 401), ("/media-denied", 403), ("/media-error", 500)] {
        do {
            _ = try await loader.download(sessionID: "s", path: path, name: "protected.pdf")
            check(false, "HTTP \(expected) must not fall back")
        } catch AttachmentError.http(let code) { check(code == expected, "file preserves media HTTP \(expected)") }
        let image = UploadedAttachment(name: "a.png", path: path, size: 3, mime: "image/png", isImage: true)
        do { _ = try await AttachmentPreviewLoader(policy: policy).imageData(sessionID: "s", attachment: image); check(false, "image HTTP must not fall back") }
        catch AttachmentError.http(let code) { check(code == expected, "image preserves media HTTP \(expected)") }
        check((try? Data(contentsOf: original)) == Data(repeating: 65, count: 8192), "failed same-name transfer never removes existing owned file")
    }
    do { _ = try await loader.download(sessionID: "s", path: "/media-big", name: "big.bin"); check(false, "oversize must not fall back") }
    catch AttachmentError.tooLarge { check(true, "media oversize preserves size error") }
    do { _ = try await loader.download(sessionID: "s", path: "/media-network", name: "network.bin"); check(false, "network error must not fall back") }
    catch { check(!(error is AttachmentError), "media transport failure preserves its network error") }
    let root = original.deletingLastPathComponent().deletingLastPathComponent()
    let abandoned = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
    try Data([1]).write(to: abandoned.appendingPathComponent("abandoned.bin"))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: abandoned.path)
    let legacy = root.appendingPathComponent("legacy-build28.bin")
    try Data([2]).write(to: legacy)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: legacy.path)
    AttachmentDownloadFiles.cleanupExpired(maxAge: 86400, maxTotalBytes: .max)
    check(!FileManager.default.fileExists(atPath: abandoned.path) && !FileManager.default.fileExists(atPath: legacy.path), "janitor reclaims expired crash directories and legacy flat files")
    let overBudget = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: overBudget, withIntermediateDirectories: false)
    try Data([3]).write(to: overBudget.appendingPathComponent("budget.bin"))
    AttachmentDownloadFiles.cleanupExpired(maxAge: 0, maxTotalBytes: 0)
    check(!FileManager.default.fileExists(atPath: overBudget.path), "janitor applies total-byte limit to unleased directories")
    check(FileManager.default.fileExists(atPath: original.path), "janitor never evicts a leased preview URL")
    let ownedDirectory = original.deletingLastPathComponent()
    AttachmentDownloadFiles.remove(original)
    check(!FileManager.default.fileExists(atPath: ownedDirectory.path), "release removes the entire exclusive directory")
    // URL cleanup cannot be used against picker files or paths outside this module.
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("do-not-delete.bin")
    try Data([9]).write(to: outside)
    AttachmentDownloadFiles.remove(outside)
    check(FileManager.default.fileExists(atPath: outside.path), "release refuses unrelated file URLs")
    try FileManager.default.removeItem(at: outside)
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("outside-target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let targetFile = target.appendingPathComponent("keep.bin")
    try Data([8]).write(to: targetFile)
    let linked = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
    AttachmentDownloadFiles.remove(linked.appendingPathComponent("keep.bin"))
    AttachmentDownloadFiles.cleanupExpired(maxAge: 0, maxTotalBytes: 0)
    check(FileManager.default.fileExists(atPath: targetFile.path), "release and janitor never traverse a symlink directory")
    try FileManager.default.removeItem(at: linked)
    try FileManager.default.removeItem(at: target)
    let progress = ProgressWitness()
    let before = downloadDirectories()
    let cancel = Task { try await loader.download(sessionID: "s", path: "/slow", name: "cancel.bin", progress: { progress.record($0) }) }
    for _ in 0..<400 {
        if progress.maximumReceived > 0 { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    check(progress.maximumReceived > 0, "cancel probe receives actual network bytes first")
    cancel.cancel()
    do { _ = try await cancel.value; check(false, "in-flight cancellation must throw") }
    catch is CancellationError { check(true, "in-flight file cancellation preserves CancellationError") }
    check(downloadDirectories() == before, "cancelled transfer removes only its owned temporary directory")
    let knownProgress = ProgressWitness()
    let known = try await loader.download(sessionID: "s", path: "/ok", name: "progress.bin", progress: { knownProgress.record($0) })
    check(knownProgress.latest?.receivedBytes == 3 && knownProgress.latest?.fraction == 1, "known length progress ends at exact received byte count")
    AttachmentDownloadFiles.remove(known)
    let unknownProgress = ProgressWitness()
    let unknown = try await loader.download(sessionID: "s", path: "/chunked-small", name: "progress.bin", progress: { unknownProgress.record($0) })
    check(unknownProgress.latest?.receivedBytes == 3 && unknownProgress.latest?.fraction == nil, "unknown length exposes byte count without inventing a percentage")
    AttachmentDownloadFiles.remove(unknown)
    try await runRemoteTransferTests(base)
}

private func downloadDirectories() -> Set<String> {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HermesDownloads")
    return Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []))
}

@MainActor private func runRemoteTransferTests(_ base: URL) async throws {
    let cookie = HTTPCookie(properties: [.domain: base.host!, .path: "/", .name: "fixture-auth", .value: "must-not-leak"] )!
    HTTPCookieStorage.shared.setCookie(cookie)
    defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = ["Cookie": "bad-cookie", "Authorization": "Bearer must-not-leak"]
    let remote = RemoteImageDataLoader(configuration: config)
    let small = try await remote.data(for: base.appendingPathComponent("external-small"))
    check(small == Data([1, 2, 3]), "external image data succeeds without ambient credentials")
    let unknown = try await remote.data(for: base.appendingPathComponent("external-unknown"))
    check(unknown == Data([1, 2, 3]), "external unknown-length image is supported")
    for suffix in ["external-big", "external-stream-big"] {
        let witness = ProgressWitness()
        do { _ = try await remote.data(for: base.appendingPathComponent(suffix), progress: { witness.record($0) }); check(false, "external oversized image accepted") }
        catch AttachmentError.tooLarge { check(true, "external image rejects \(suffix) while receiving") }
        check(witness.maximumReceived <= AttachmentMultipart.defaultMaxBytes, "external retained body/progress never crosses byte budget")
    }
    for suffix in ["external-html", "external-redirect"] {
        do { _ = try await remote.data(for: base.appendingPathComponent(suffix)); check(false, "external unsafe response accepted") }
        catch { check(true, "external image rejects \(suffix)") }
    }
    for address in ["https://user:secret@example.invalid/x.png", "file:///a.png", "https://example.invalid:0/a.png", "https://example.invalid:65536/a.png"] {
        do { _ = try await remote.data(for: URL(string: address)!); check(false, "unsafe external URL accepted") }
        catch AttachmentError.unsafeURL { check(true, "external image rejects userinfo/scheme/invalid port before network") }
    }
    let witness = ProgressWitness()
    let cancelled = Task { try await remote.data(for: base.appendingPathComponent("external-slow"), progress: { witness.record($0) }) }
    for _ in 0..<400 {
        if witness.maximumReceived > 0 { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    check(witness.maximumReceived > 0, "external cancel probe starts a real response")
    cancelled.cancel()
    do { _ = try await cancelled.value; check(false, "external cancellation must throw") }
    catch is CancellationError { check(true, "external transfer propagates cancellation") }
}

private final class ProgressWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AttachmentTransferProgress] = []
    func record(_ value: AttachmentTransferProgress) { lock.withLock { values.append(value) } }
    var maximumReceived: Int { lock.withLock { values.map(\.receivedBytes).max() ?? 0 } }
    var latest: AttachmentTransferProgress? { lock.withLock { values.last } }
}
