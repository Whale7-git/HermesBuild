import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Attachment classification is pure: driven by MIME first, then extension,
/// then the server's own is_image flag. No UIKit here so it is testable on Linux.
@MainActor func runKindTests() {
    check(AttachmentKind.classify(name: "a.png", mime: "image/png") == .image, "classify raster image by MIME")
    check(AttachmentKind.classify(name: "照片.HEIC", mime: "image/heic") == .image, "classify HEIC by MIME")
    check(AttachmentKind.classify(name: "clip.mp4", mime: "video/mp4") == .video, "classify video by MIME")
    check(AttachmentKind.classify(name: "note.m4a", mime: "audio/mp4") == .audio, "classify audio by MIME")
    check(AttachmentKind.classify(name: "报告.pdf", mime: "application/pdf") == .pdf, "classify PDF by MIME")
    check(AttachmentKind.classify(name: "sheet.xlsx", mime: "application/octet-stream") == .spreadsheet, "classify spreadsheet by extension fallback")
    check(AttachmentKind.classify(name: "bundle.zip", mime: "application/octet-stream") == .archive, "classify archive by extension fallback")
    check(AttachmentKind.classify(name: "readme.md", mime: "application/octet-stream") == .document, "classify document by extension fallback")
    check(AttachmentKind.classify(name: "blob.bin", mime: "application/octet-stream") == .other, "unknown extension is other")
    check(AttachmentKind.classify(name: "noext", mime: "image/svg+xml") == .other, "SVG is not a native image category")
    check(AttachmentKind.classify(name: "x.tar.gz", mime: "application/octet-stream") == .archive, "compound archive extension")
    check(!AttachmentKind.classify(name: "a.png", mime: "image/png").symbol.isEmpty, "every category has a non-empty symbol")
    check(AttachmentKind.mime(forPathExtension: "png") == "image/png", "infer PNG mime")
    check(AttachmentKind.mime(forPathExtension: "JPG") == "image/jpeg", "infer JPEG mime case-insensitively")
    check(AttachmentKind.mime(forPathExtension: "heic") == "image/heic", "infer HEIC mime")
    check(AttachmentKind.mime(forPathExtension: "pdf") == "", "non-raster extension has no raster mime")
    check(AttachmentKind.rasterImage(name: "x.webp") == true, "webp is raster")
    check(AttachmentKind.rasterImage(name: "x.svg") == false, "svg is not raster")
    check(AttachmentKind.rasterImage(name: "noext") == false, "no extension is not raster")
}

/// A file download request must stay on this instance's raw route and never
/// require the file to be a raster image (unlike the inline-image preview path).
@MainActor func runDownloadContractTests() throws {
    let baseURL = URL(string: "https://host.example/p/default/")!
    let policy = try AttachmentPreviewPolicy(baseURL: baseURL)
    let request = try policy.downloadRequest(sessionID: "s+1", path: "/state/attachments/s1/文档.pdf", name: "文档.pdf")
    check(request.url?.path == "/p/default/api/file/raw", "download uses authenticated raw route under prefix")
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    check(query.first(where: { $0.name == "path" })?.value == "/state/attachments/s1/文档.pdf", "download passes opaque server path as query")
    check(query.first(where: { $0.name == "session_id" })?.value == "s+1", "download carries session id")
    check(request.value(forHTTPHeaderField: "Accept")?.contains("application/octet-stream") == true, "download accepts arbitrary bytes")
    check(policy.allows(request.url!), "policy accepts generated download URL")
    // Download path must not care whether the file is an image.
    try policy.validateDownloadResponse(size: 0)
    try policy.validateDownloadResponse(size: 100)
    rejects("download response size still capped") { try policy.validateDownloadResponse(size: AttachmentMultipart.defaultMaxBytes + 1) }
    try policy.validateDownloadResponse(size: -1)
    check(true, "unknown Content-Length is allowed until bounded chunks arrive")
    rejects("invalid negative response size rejected") { try policy.validateDownloadResponse(size: -2) }
    rejects("download still rejects empty session") { _ = try policy.downloadRequest(sessionID: "", path: "/a", name: "a") }
    rejects("download still rejects empty path") { _ = try policy.downloadRequest(sessionID: "s", path: "", name: "a") }

    // /api/media：取 agent 产物（/opt/data/...）用。与 file/raw 一样只允许本实例。
    let mediaRequest = try policy.mediaRequest(sessionID: "s+1", path: "/opt/data/attachments/a.zip")
    check(mediaRequest.url?.path == "/p/default/api/media", "media request uses /api/media under prefix")
    let mediaQuery = URLComponents(url: mediaRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
    check(mediaQuery.first(where: { $0.name == "path" })?.value == "/opt/data/attachments/a.zip",
          "media request passes absolute agent path as query")
    check(mediaQuery.first(where: { $0.name == "session_id" })?.value == "s+1",
          "media request carries escaped session id")
    check(policy.allows(mediaRequest.url!), "policy accepts /api/media route")
    rejects("media request rejects empty path") { _ = try policy.mediaRequest(sessionID: "s", path: "") }
    rejects("media request rejects control chars in path") {
        _ = try policy.mediaRequest(sessionID: "s", path: "/opt/data/a\u{0000}b")
    }
    // 仍然只允许本实例的两条路由，其它路径一律拒绝。
    check(!policy.allows(URL(string: "https://host.example/p/default/api/upload")!), "policy rejects upload route")
    check(!policy.allows(URL(string: "https://host.example.evil/p/default/api/media")!), "media route stays same-origin")

    let internalURL = "https://host.example:443/p/default/api/media?path=%2Fopt%2Fdata%2Fa%2Bb.png&session_id=old-session"
    check(policy.internalFilePath(from: internalURL) == "/opt/data/a+b.png", "approved absolute media URL becomes an opaque file reference")
    let normalized = try policy.downloadRequest(sessionID: "current-session", path: internalURL, name: "a.png")
    let normalizedQuery = URLComponents(url: normalized.url!, resolvingAgainstBaseURL: false)!.queryItems!
    check(normalizedQuery.first(where: { $0.name == "path" })?.value == "/opt/data/a+b.png", "absolute internal file URL is not wrapped as a literal server path")
    check(normalizedQuery.first(where: { $0.name == "session_id" })?.value == "current-session", "normalized download always binds current captured session")
    let image = UploadedAttachment(name: "a.png", path: internalURL, size: 0, mime: "image/png", isImage: true)
    let normalizedImage = try policy.request(sessionID: "image-current", attachment: image)
    let imageQuery = URLComponents(url: normalizedImage.url!, resolvingAgainstBaseURL: false)!.queryItems!
    check(imageQuery.first(where: { $0.name == "session_id" })?.value == "image-current", "normalized image discards stale URL session id")
    check(policy.internalFilePath(from: "https://host.example/p/default/api/file/raw?path=relative%2Ffile.png") == "relative/file.png", "approved absolute raw URL supports a relative opaque path")
    for rejected in [
        "https://host.example.evil/p/default/api/media?path=/a.png",
        "https://host.example:444/p/default/api/media?path=/a.png",
        "http://host.example/p/default/api/media?path=/a.png",
        "https://user:password@host.example/p/default/api/media?path=/a.png",
        "https://host.example/p/default/api/upload?path=/a.png",
        "https://host.example/api/media?path=/a.png",
        "https://host.example/p/default/api/media?path=/a.png#fragment",
        "https://host.example/p/default/api/media?path=/a.png&path=/b.png",
        "https://host.example/p/default/api/media?path=/a.png&%70ath=/b.png",
        "https://host.example/p/default/api/media?session_id=old",
        "https://host.example/p/default/api/media?path=",
        "https://host.example/p/default/api/media?path=%00a.png",
        "https://host.example/p/default/api/media?path=%0Aa.png",
        "https://host.example/p/default/api/media?path=https%3A%2F%2Fevil.example%2Fa.png",
        "https://host.example/p/default/api/media?path=%2F%2Fevil.example%2Fa.png",
        "https://host.example/p/default/api/media?path=/a.png\n"
    ] {
        check(policy.internalFilePath(from: rejected) == nil, "unsafe/ambiguous absolute URL is never an internal reference")
        rejects("unsafe absolute URL cannot be rewritten as authenticated file path") {
            _ = try policy.downloadRequest(sessionID: "current", path: rejected, name: "a.png")
        }
    }
}

/// The generic file downloader writes any bounded byte stream to a temp file,
/// independent of raster MIME, and reuses the same-origin raw route.
@MainActor func runFileDownloaderTests() async throws {
    let base = URL(string: ProcessInfo.processInfo.environment["ATTACHMENT_FIXTURE_URL"]!)!
    let policy = try AttachmentPreviewPolicy(baseURL: base)
    let loader = AttachmentFileDownloader(policy: policy, configuration: .ephemeral)
    let url = try await loader.download(sessionID: "s", path: "/ok", name: "文档.pdf")
    check(url.lastPathComponent == "文档.pdf", "downloaded file keeps the sanitized leaf name")
    check((try? Data(contentsOf: url)) == Data([1, 2, 3]), "downloaded file holds exact bytes")
    check(FileManager.default.fileExists(atPath: url.path), "downloaded file exists at the returned path")
    AttachmentDownloadFiles.remove(url)
    do { _ = try await loader.download(sessionID: "s", path: "/big", name: "big.bin"); fatalError("FAIL oversized download accepted") }
    catch { check(true, "downloader rejects oversized response") }
    do { _ = try await loader.download(sessionID: "s", path: "/redirect", name: "r.bin"); fatalError("FAIL redirect download accepted") }
    catch { check(true, "downloader rejects redirects before credentials escape") }
    do { _ = try await loader.download(sessionID: "s", path: "/stream-big", name: "s.bin"); fatalError("FAIL streaming oversized download accepted") }
    catch { check(true, "downloader rejects streaming oversized response") }
    let task = Task<URL, Error> { try await loader.download(sessionID: "s", path: "/ok", name: "cancel.bin") }
    task.cancel()
    do { _ = try await task.value; fatalError("FAIL cancelled download succeeded") }
    catch { check(true, "cancelled download does not deliver a file") }
    // A path like "../../evil" must never escape the temp directory.
    do {
        _ = try await loader.download(sessionID: "s", path: "/ok", name: "../evil.bin")
        fatalError("FAIL traversal name accepted")
    } catch {
        check(true, "downloader rejects path-traversal file name")
    }
}
