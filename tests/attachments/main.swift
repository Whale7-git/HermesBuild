import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var checks = 0
@MainActor func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard value() else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
@MainActor func rejects(_ name: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); fatalError("FAIL: \(name) did not reject") }
    catch { print("PASS: \(name)") }
}
if let probe = ProcessInfo.processInfo.environment["ATTACHMENT_PROBE"] {
    try await runReliabilityProbe(probe)
    exit(0)
}
// Source-derived fixture: exact deployed handle_upload keys, not a live upload.
let fixture = Data(#"{"filename":"图片-1.png","path":"/state/attachments/s1/图片-1.png","size":3,"mime":"image/png","is_image":true}"#.utf8)
let attachment = try UploadedAttachment(data: fixture)
check(attachment.name == "图片-1.png", "parse deployed flat upload filename")
check(attachment.path == "/state/attachments/s1/图片-1.png", "retain opaque server path")
check(attachment.size == 3 && attachment.isImage, "parse size and is_image")
let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as! [String:Any]
check(payload["name"] as? String == "图片-1.png" && payload["filename"] == nil, "chat payload uses name, not upload filename")
check(payload["is_image"] as? Bool == true && payload["mime"] as? String == "image/png", "chat payload retains image metadata")
let baseURL = URL(string: "https://host.example/p/default/")!
let bytes = Data([0, 10, 13, 255])
let multipart = try AttachmentMultipart(sessionID: "s+1", filename: "../dir/a\"\r\nX-Evil: yes.png", mime: "image/png", data: bytes, boundary: "test-boundary")
let request = try multipart.request(baseURL: baseURL)
let wire = String(decoding: multipart.body, as: UTF8.self)
check(request.url?.absoluteString == "https://host.example/p/default/api/upload", "upload preserves base prefix")
check(request.httpMethod == "POST" && request.httpBody == multipart.body, "multipart POST has exact body")
check(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary", "boundary header matches")
check(request.value(forHTTPHeaderField: "Content-Length") == String(multipart.body.count), "length includes overhead")
check(wire.contains("name=\"session_id\"\r\n\r\ns+1\r\n"), "session_id form field is unmodified")
// 网关的 `/v1/files` 只认 Bearer，WebUI 的 `api/upload` 靠 cookie。
// 上传请求此前不带任何认证头，纯网关实例必然 401——预览路径早就分好了，
// 只有上传这一跳漏了，所以这里按两种后端各钉一条。
let cookieRequest = try multipart.request(baseURL: baseURL, route: "api/upload", authorization: .cookieOnly)
check(cookieRequest.value(forHTTPHeaderField: "Authorization") == nil,
      "webui upload must not send an Authorization header")
let bearerRequest = try multipart.request(baseURL: baseURL, route: "v1/files",
                                          authorization: .bearer("gw-secret"))
check(bearerRequest.value(forHTTPHeaderField: "Authorization") == "Bearer gw-secret",
      "gateway upload must send the bearer credential")
check(bearerRequest.url?.absoluteString == "https://host.example/p/default/v1/files",
      "gateway upload route is v1/files")

let simulatedWebUICookie = HTTPCookie(properties: [
    .name: "session", .value: "webui-login", .domain: "host.example", .path: "/"
])!
var gatewayDownloadRequest = URLRequest(url: baseURL.appendingPathComponent("v1/files/by-path"))
gatewayDownloadRequest.setValue("session=old", forHTTPHeaderField: "Cookie")
AttachmentRequestAuthentication.apply(to: &gatewayDownloadRequest,
                                      authorization: .bearer("gateway-key"),
                                      cookies: [simulatedWebUICookie])
check(gatewayDownloadRequest.value(forHTTPHeaderField: "Authorization") == "Bearer gateway-key"
      && gatewayDownloadRequest.value(forHTTPHeaderField: "Cookie") == nil,
      "Gateway image/download uses Bearer without forwarding same-host WebUI cookies")
var webUIDownloadRequest = URLRequest(url: baseURL.appendingPathComponent("api/file/raw"))
webUIDownloadRequest.setValue("Bearer stale", forHTTPHeaderField: "Authorization")
AttachmentRequestAuthentication.apply(to: &webUIDownloadRequest,
                                      authorization: .cookieOnly,
                                      cookies: [simulatedWebUICookie])
check(webUIDownloadRequest.value(forHTTPHeaderField: "Authorization") == nil
      && webUIDownloadRequest.value(forHTTPHeaderField: "Cookie")?.contains("session=webui-login") == true,
      "WebUI image/download uses cookie without forwarding Gateway Bearer")
// One consistent authorization policy must serve inline thumbnails,
 // fullscreen previews and original-byte operations for this Gateway session.
let gatewayPreviewPolicy = try AttachmentPreviewPolicy(
    baseURL: baseURL, authorization: .bearer("gateway-key"))
let galleryAttachment = UploadedAttachment(
    name: "image.png", path: "/state/attachments/s1/image.png",
    size: 5, mime: "image/png", isImage: true)
// AttachmentPreviewPolicy builds an uncredentialed URLRequest; the download
// transport applies authorization immediately before sending it. Test both
// stages, rather than incorrectly requiring auth on a raw policy request.
_ = try gatewayPreviewPolicy.request(sessionID: "s1", attachment: galleryAttachment)
var galleryRequest = try gatewayPreviewPolicy.gatewayFileRequest(path: galleryAttachment.path)
AttachmentRequestAuthentication.apply(
    to: &galleryRequest, authorization: gatewayPreviewPolicy.authorization,
    cookies: [simulatedWebUICookie])
check(galleryRequest.url?.path == "/p/default/v1/files/by-path",
      "Gateway fullscreen image uses its authenticated Files API route")
check(galleryRequest.value(forHTTPHeaderField: "Authorization") == "Bearer gateway-key",
      "Gateway fullscreen preview sends current scoped Bearer credential")
check(galleryRequest.value(forHTTPHeaderField: "Cookie") == nil,
      "Gateway image preview never silently inherits WebUI cookies")
let missingGatewayKey = AttachmentAuthorization.bearer("")
check(missingGatewayKey.requiresBearer && missingGatewayKey.header == nil
      && missingGatewayKey != .cookieOnly,
      "empty Gateway key does not silently switch authentication to cookie mode")
var missingKeyRequest = URLRequest(url: baseURL.appendingPathComponent("v1/files/by-path"))
missingKeyRequest.setValue("session=old", forHTTPHeaderField: "Cookie")
AttachmentRequestAuthentication.apply(to: &missingKeyRequest, authorization: missingGatewayKey,
                                      cookies: [simulatedWebUICookie])
check(missingKeyRequest.value(forHTTPHeaderField: "Cookie") == nil
      && missingKeyRequest.value(forHTTPHeaderField: "Authorization") == nil,
      "Gateway with no key refuses inherited WebUI cookie instead of leaking it")

check(wire.contains("name=\"file\"; filename=\"a___X-Evil: yes.png\"\r\n"), "filename cannot inject headers or retain paths")
check(multipart.body.range(of: bytes) != nil && wire.hasSuffix("\r\n--test-boundary--\r\n"), "binary payload survives framing")
rejects("reject MIME header injection") { _ = try AttachmentMultipart(sessionID:"s", filename:"a", mime:"text/plain\r\nInjected: yes", data:bytes) }
rejects("reject invalid boundary") { _ = try AttachmentMultipart(sessionID:"s", filename:"a", mime:"text/plain", data:bytes, boundary:"bad\r\n") }
rejects("reject boundary collision in binary data") { _ = try AttachmentMultipart(sessionID:"s", filename:"a", mime:"text/plain", data:Data("--test-boundary".utf8), boundary:"test-boundary") }
rejects("reject boundary collision in session field") { _ = try AttachmentMultipart(sessionID:"--test-boundary", filename:"a", mime:"text/plain", data:bytes, boundary:"test-boundary") }
rejects("reject empty session") { _ = try AttachmentMultipart(sessionID:"", filename:"a", mime:"text/plain", data:bytes) }
rejects("reject dot-only filename") { _ = try AttachmentMultipart(sessionID:"s", filename:"..", mime:"text/plain", data:bytes) }
let exact = try AttachmentMultipart(sessionID:"s", filename:"a", mime:"text/plain", data:bytes, boundary:"test-boundary")
_ = try AttachmentMultipart(sessionID:"s", filename:"a", mime:"text/plain", data:bytes, boundary:"test-boundary", maxBytes:exact.body.count)
rejects("cap covers multipart overhead") { _ = try AttachmentMultipart(sessionID:"s", filename:"a", mime:"text/plain", data:bytes, boundary:"test-boundary", maxBytes:exact.body.count - 1) }
rejects("malformed upload missing required keys") { _ = try UploadedAttachment(data: Data(#"{"filename":"a"}"#.utf8)) }
rejects("negative upload size") { _ = try UploadedAttachment(data: Data(#"{"filename":"a","path":"/a","size":-1,"mime":"image/png","is_image":true}"#.utf8)) }
rejects("empty upload server path") { _ = try UploadedAttachment(data: Data(#"{"filename":"a","path":"","size":0,"mime":"text/plain","is_image":false}"#.utf8)) }
// P2b：服务端 filename/mime 含控制字符必须被清洗，超长必须截断。
let dirtyAttachment = try UploadedAttachment(data: Data(#"{"filename":"a\r\nb.png","path":"/a","size":0,"mime":"image/png","is_image":true}"#.utf8))
check(!dirtyAttachment.name.contains("\r") && !dirtyAttachment.name.contains("\n"), "server filename control chars sanitized")
let longName = try UploadedAttachment(data: Data("{\"filename\":\"\(String(repeating:"x",count:500)).png\",\"path\":\"/a\",\"size\":0,\"mime\":\"image/png\",\"is_image\":true}".utf8))
check(longName.name.count <= 200, "server filename truncated to 200 chars")
let dirtyMime = try UploadedAttachment(data: Data(#"{"filename":"a.png","path":"/a","size":0,"mime":"image/png\r\nInjected: yes","is_image":true}"#.utf8))
check(!dirtyMime.mime.contains("\r") && !dirtyMime.mime.contains("\n"), "server mime control chars sanitized")
let policy = try AttachmentPreviewPolicy(baseURL: baseURL)
let raw = try policy.request(sessionID:"s+1&二", attachment:attachment)
let query = URLComponents(url:raw.url!, resolvingAgainstBaseURL:false)!.queryItems!
check(raw.url?.path == "/p/default/api/file/raw", "preview uses authenticated raw route under prefix")
check(query.first(where:{$0.name == "path"})?.value == attachment.path, "preview keeps absolute server path in query, not URL host")
check(query.first(where:{$0.name == "session_id"})?.value == "s+1&二" && raw.url!.absoluteString.contains("%2B"), "raw query escapes literal plus for parse_qs")
check(policy.allows(raw.url!), "policy accepts generated raw URL")
for unsafe in ["https://host.example.evil/api/file/raw", "http://host.example/p/default/api/file/raw", "https://host.example:444/p/default/api/file/raw", "https://user@host.example/p/default/api/file/raw", "https://host.example/api/file/raw", "https://host.example/p/default/api/auth/status", "file:///etc/passwd", "https://tracker.invalid/pixel.png"] {
    check(!policy.allows(URL(string:unsafe)!), "reject untrusted preview URL: \(unsafe)")
}
rejects("SVG not an inline native preview") { _ = try policy.request(sessionID:"s", attachment:UploadedAttachment(data:Data(#"{"filename":"a.svg","path":"/a.svg","size":1,"mime":"image/svg+xml","is_image":true}"#.utf8))) }
rejects("file cannot masquerade as image") { _ = try policy.request(sessionID:"s", attachment:UploadedAttachment(data:Data(#"{"filename":"a.png","path":"/a.png","size":1,"mime":"image/png","is_image":false}"#.utf8))) }
rejects("invalid base URL credentials") { _ = try AttachmentPreviewPolicy(baseURL:URL(string:"https://user:pass@host.example")!) }
rejects("preview response MIME must be raster") { try policy.validateResponse(mime:"text/html", size:3) }
rejects("preview response size limited") { try policy.validateResponse(mime:"image/png", size:AttachmentMultipart.defaultMaxBytes + 1) }
try policy.validateResponse(mime:"image/png; charset=binary", size:3)
var restored = AttachmentBatch(sessionID:"s1")
restored.restoreReady([ChatAttachmentPayload(name: "restored.pdf", path: "/srv/restored.pdf",
                                               mime: "application/pdf", size: 4096, isImage: false)])
check(restored.items.first?.byteCount == 4096, "restored attachment displays declared server size")
let countBeforeInvalid = restored.items.count
restored.restoreReady([ChatAttachmentPayload(name: "bad", path: "/bad", mime: "text/plain", size: -1, isImage: false)])
check(restored.items.count == countBeforeInvalid, "invalid negative remote attachment size rejected")
restored.restoreReady([ChatAttachmentPayload(name: "oversized", path: "/big", mime: "text/plain",
                                          size: AttachmentMultipart.defaultMaxBytes + 1, isImage: false)])
check(restored.items.count == countBeforeInvalid, "oversized remote reference rejected before quota calculation")
var batch = AttachmentBatch(sessionID:"s1")
let fileID = try batch.append(name:"image.png", mime:"image/png", data:bytes)
check(batch.items.count == 1 && !batch.canSend, "imported file blocks send until uploaded")
let attempt = try batch.begin(fileID)
batch.progress(fileID, attempt:attempt, fraction:0.5)
check(batch.items[0].state == .uploading(0.5), "real byte progress exposed")
batch.complete(fileID, attempt:UUID(), attachment:attachment)
check(!batch.canSend, "stale attempt cannot complete upload")
batch.complete(fileID, attempt:attempt, attachment:attachment)
let readyPayload = try batch.payload(for:"s1")
check(batch.canSend && readyPayload == [attachment], "only ready attachment enters payload")
rejects("cannot send attachment into other session") { _ = try batch.payload(for:"other") }
batch.remove(fileID)
batch.complete(fileID, attempt:attempt, attachment:attachment)
check(batch.items.isEmpty, "removed chip cannot reappear after late upload")
let failedID = try batch.append(name:"a", mime:"text/plain", data:bytes)
let failedAttempt = try batch.begin(failedID)
batch.fail(failedID, attempt:failedAttempt, message:"offline")
check(!batch.canSend && batch.items[0].state == .failed("offline"), "failed upload remains visible and blocks send")
let retryAttempt = try batch.begin(failedID)
batch.fail(failedID, attempt:failedAttempt, message:"late error")
check(batch.items[0].state == .uploading(0), "late previous failure cannot clobber retry")
batch.reset(sessionID:"s2")
batch.complete(failedID, attempt:retryAttempt, attachment:attachment)
check(batch.items.isEmpty && batch.sessionID == "s2", "session reset invalidates old uploads")
var capped = AttachmentBatch(sessionID:"s", maxCount:1, maxTotalBytes:4)
_ = try capped.append(name:"a", mime:"text/plain", data:bytes)
rejects("import count cap") { _ = try capped.append(name:"b", mime:"text/plain", data:Data()) }
var small = AttachmentBatch(sessionID:"s", maxTotalBytes:3)
rejects("aggregate import memory cap") { _ = try small.append(name:"a", mime:"text/plain", data:bytes) }

// MARK: - 上传完成后释放原始字节（S1-2）
//
// 40MB 总量上限的字节此前会常驻到会话结束：服务端已有副本，本地不再需要。
// 图片也按需从服务端重新读取再编辑，避免整批原图常驻内存。

do {
    var b = AttachmentBatch(sessionID:"release")
    let docID = try b.append(name:"a.pdf", mime:"application/pdf", data:bytes)
    let docAttempt = try b.begin(docID)
    b.complete(docID, attempt:docAttempt, attachment:attachment)
    check(b.items[0].data.isEmpty, "a non-image drops its bytes once the server has them")
    check(b.items[0].byteCount == bytes.count, "the byte count survives so the chip still shows a size")
    check(b.canSend, "dropping bytes must not affect readiness")
}

do {
    var b = AttachmentBatch(sessionID:"image")
    let imgID = try b.append(name:"a.png", mime:"image/png", data:bytes)
    let imgAttempt = try b.begin(imgID)
    b.complete(imgID, attempt:imgAttempt, attachment:attachment)
    check(b.items[0].data.isEmpty, "an uploaded image drops its bytes and reloads them only when editing")
    check(b.items[0].byteCount == bytes.count && b.canSend,
          "an uploaded image keeps its displayed size and remains sendable after releasing bytes")
}

do {
    // 释放后容量核算必须用 byteCount，否则已上传的大文件会「凭空腾出」配额，
    // 用户可以无限追加直到内存爆掉。
    var b = AttachmentBatch(sessionID:"quota", maxTotalBytes:bytes.count * 2)
    let a = try b.append(name:"a.pdf", mime:"application/pdf", data:bytes)
    let at = try b.begin(a)
    b.complete(a, attempt:at, attachment:attachment)
    check(b.items[0].data.isEmpty, "fixture precondition: bytes were actually released")
    rejects("released bytes still count against the aggregate cap") {
        _ = try b.append(name:"b.pdf", mime:"application/pdf", data:bytes)
        _ = try b.append(name:"c.pdf", mime:"application/pdf", data:bytes)
    }
}
// Durable composer attachments: local bytes survive for pending uploads,
// completed references do not need bytes, and restore validates session,
// identity and quota before replacing the current batch.
do {
    var source = AttachmentBatch(sessionID: "persisted")
    let pendingID = try source.append(
        name: "notes.txt", mime: "text/plain", data: bytes)
    let pendingAttempt = try source.begin(pendingID)
    source.progress(pendingID, attempt: pendingAttempt, fraction: 0.5)
    var restoredPending = AttachmentBatch(sessionID: "persisted")
    try restoredPending.restorePersisted(source.persistedValue)
    check(restoredPending.items.count == 1
          && restoredPending.items[0].state == .queued
          && restoredPending.items[0].data == bytes
          && restoredPending.items[0].canResumeUpload,
          "interrupted local upload restores as resumable queued bytes")

    var readySource = AttachmentBatch(sessionID: "persisted")
    let readyID = try readySource.append(
        name: "report.pdf", mime: "application/pdf", data: bytes)
    let readyAttempt = try readySource.begin(readyID)
    let readyAttachment = UploadedAttachment(
        name: "report.pdf", path: "/state/attachments/persisted/report.pdf",
        size: bytes.count, mime: "application/pdf", isImage: false)
    readySource.complete(readyID, attempt: readyAttempt, attachment: readyAttachment)
    var restoredReady = AttachmentBatch(sessionID: "persisted")
    try restoredReady.restorePersisted(readySource.persistedValue)
    check(restoredReady.canSend && restoredReady.items[0].data.isEmpty
          && (try? restoredReady.payload(for: "persisted")) == [readyAttachment],
          "completed server reference restores without local bytes")

    let wrongScope = PersistedAttachmentBatch(
        version: readySource.persistedValue.version, sessionID: "other",
        items: readySource.persistedValue.items)
    rejects("persisted attachment batch is session scoped") {
        try restoredReady.restorePersisted(wrongScope)
    }
    let duplicate = PersistedAttachmentBatch(
        version: readySource.persistedValue.version,
        sessionID: readySource.persistedValue.sessionID,
        items: [readySource.persistedValue.items[0], readySource.persistedValue.items[0]])
    rejects("persisted attachment IDs are unique") {
        try restoredReady.restorePersisted(duplicate)
    }
    let original = readySource.persistedValue.items[0]
    let invalidItem = PersistedAttachmentDraft(
        id: original.id, name: original.name, mime: original.mime,
        byteCount: original.byteCount, data: Data(), state: .pending,
        reuploading: false)
    rejects("pending attachment requires local bytes") {
        try restoredReady.restorePersisted(PersistedAttachmentBatch(
            version: readySource.persistedValue.version,
            sessionID: readySource.persistedValue.sessionID,
            items: [invalidItem]))
    }
    var quotaBatch = AttachmentBatch(sessionID: "quota-persist", maxTotalBytes: 3)
    rejects("persisted attachment quota is rechecked") {
        try quotaBatch.restorePersisted(PersistedAttachmentBatch(
            version: PersistedAttachmentBatch.currentVersion,
            sessionID: "quota-persist",
            items: [PersistedAttachmentDraft(
                id: UUID(), name: "a", mime: "text/plain", byteCount: 4,
                data: bytes, state: .pending, reuploading: false)]))
    }
}

let historyParts: [[String:Any]] = [
    ["type":"text", "text":"look MEDIA:/media/out.png and ![outside](https://tracker.invalid/pixel.png)"],
    ["type":"image_url", "image_url":["url":"/state/picture.png"]],
    ["type":"image_url", "image_url":["url":"data:image/png;base64,AAAA"]],
    ["type":"input_image", "image_url":"https://images.invalid/photo.png"]
]
let history = AttachmentHistory.paths(content:historyParts, attachments:["/state/picture.png", ["name":"文档.pdf", "path":"/state/文档.pdf"], ["name":"old.txt"]])
check(history == ["/state/picture.png", "/state/文档.pdf", "old.txt", "/media/out.png", "https://tracker.invalid/pixel.png", "https://images.invalid/photo.png"], "history extracts structured files, media and images with stable deduplication")
check(AttachmentHistory.paths(content:"ordinary text", attachments:nil).isEmpty, "normal history text is not an attachment")
// A literal API-server documentation example is not a real file. Only genuine
// MEDIA references in visible prose or structured attachment metadata may load.
let documentationExample = """
> Hermes says images are referenced as MEDIA:/absolute/path tags.
> ![sample](https://example.invalid/quoted.png)

```markdown
MEDIA:/tmp/code.png
![sample](https://example.invalid/code.png)
```
Inline `MEDIA:/tmp/inline.png` and `![sample](/tmp/inline.png)` are samples.
    MEDIA:/tmp/indented.png
"""
check(AttachmentHistory.paths(content: documentationExample, attachments: nil).isEmpty,
      "quoted, fenced, indented and inline examples cannot become attachment requests")
let realMedia = "Here is MEDIA:/state/real.png and ![preview](/state/preview.png)"
check(AttachmentHistory.paths(content: realMedia, attachments: nil) ==
      ["/state/real.png", "/state/preview.png"],
      "real inline MEDIA and Markdown image references still work")
check(AttachmentHistory.paths(content: documentationExample,
      attachments: [["path": "/state/from-metadata.pdf"]]) == ["/state/from-metadata.pdf"],
      "structured attachment metadata survives Markdown example filtering")
check(AttachmentHistory.paths(content:"![x](javascript:alert)", attachments:["data:text/plain,secret", "file:///etc/passwd"]).isEmpty, "reject dangerous schemes in history")
let importURL = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("import-test-\(UUID().uuidString)")
try bytes.write(to:importURL)
defer { try? FileManager.default.removeItem(at:importURL) }
let importedData = try AttachmentFileImport.read(importURL)
check(importedData == bytes, "bounded file importer preserves selected bytes")
rejects("file importer rejects size above cap") { _ = try AttachmentFileImport.read(importURL, maxBytes:3) }
rejects("file importer rejects directories") { _ = try AttachmentFileImport.read(importURL.deletingLastPathComponent()) }
let symlinkURL = importURL.appendingPathExtension("link")
try FileManager.default.createSymbolicLink(at:symlinkURL, withDestinationURL:importURL)
defer { try? FileManager.default.removeItem(at:symlinkURL) }
rejects("file importer rejects symlinks") { _ = try AttachmentFileImport.read(symlinkURL) }
try await runCoordinatorTests()
// A temporary destination must be a leaf even if a future caller forgets its
// own filename sanitization. Reject before creating or leasing any directory.
for leaf in ["", ".", "..", "../outside.txt", "dir/file.txt", "dir\\file.txt", "bad\nname.txt"] {
    rejects("temporary destination rejects non-leaf filename") {
        _ = try AttachmentDownloadFiles.createDestination(leaf: leaf)
    }
}
// F-75：`opaqueFilePath` 的 `..` 防护。原文与百分号解码后的值都要查，`\` 统一成 `/`
// 再按段比对——少查一层就等于「编码一次就能绕过」。服务端把 path 直接拼进文件系统路径，
// 这里漏一条就是任意文件读取。
for traversal in ["../etc/passwd", "..%2f..%2fetc", "%2e%2e%2f%2e%2e%2f", "..%5c..%5cwindows", "//host/share", "a/../../b"] {
    do {
        _ = try policy.mediaRequest(sessionID: "s", path: traversal)
        fatalError("FAIL: opaque file path accepted traversal: \(traversal)")
    } catch {
        // 必须报 unsafeURL，而不是被别的原因（空路径、控制符）顺带拦下。
        check((error as? AttachmentError) == AttachmentError.unsafeURL,
              "opaque file path rejects traversal: \(traversal)")
    }
}
// 过度拦截同样有害：普通文件名里可以有两个点，目录名也可以以两点开头，它们都不是 `..` 段。
for benign in ["dir/file.txt", "a..b.txt", "..hidden/file"] {
    check((try? policy.mediaRequest(sessionID: "s", path: benign)) != nil,
          "opaque file path keeps benign relative path: \(benign)")
}
// 另一条分支：已批准的绝对 media/raw 链接会先被拆出 query 里的 path 再检查，
// 编码过的 `..` 在这里同样必须拦住，否则「包成合法链接」就成了绕过手段。
do {
    _ = try policy.mediaRequest(sessionID: "s",
                                path: "https://host.example/p/default/api/media?path=%2Fopt%2F..%2F..%2Fetc%2Fpasswd")
    fatalError("FAIL: approved internal URL with encoded traversal was accepted")
} catch {
    check((error as? AttachmentError) == AttachmentError.unsafeURL,
          "opaque file path rejects traversal inside an approved internal URL")
}
// F-75/F-76：落盘叶子名。`\` 必须先归一成 `/`，否则 createDestination 直接拒收，
// Windows 风格回传名的文件就永远下载不下来（F-54）。
check(AttachmentFileDownloader.safeLeaf("dir\\file.txt") == "file.txt",
      "safe leaf normalizes backslash to the last component")
// 含 `..` 段一律拒绝，而不是「取末段了事」：静默把 `..\..\evil.txt` 改成 `evil.txt`
// 会让一次越权尝试看起来像成功，和 downloader 对 `../evil.bin` 的拒绝也不一致。
check(AttachmentFileDownloader.safeLeaf("..\\..\\evil.txt") == nil,
      "safe leaf rejects parent traversal instead of stripping it")
// U+202E（RLO）能把 `exe.txt` 显示成 `txt.exe`：落盘名里绝不能留这个控制符。
let rloLeaf = AttachmentFileDownloader.safeLeaf("invoice\u{202E}fdp.exe") ?? ""
check(!rloLeaf.isEmpty && !rloLeaf.contains("\u{202E}"),
      "safe leaf drops bidi override U+202E")
let longLeaf = AttachmentFileDownloader.safeLeaf(String(repeating: "a", count: 400) + ".txt") ?? ""
check(!longLeaf.isEmpty && longLeaf.utf8.count <= 255 && longLeaf.hasSuffix(".txt"),
      "safe leaf stays within 255 UTF-8 bytes and keeps extension")
// 空名字与纯分隔符没有可用叶子：返回 nil 让调用方报 invalidMetadata，不能崩。
check(AttachmentFileDownloader.safeLeaf("") == nil, "safe leaf rejects empty name without crashing")
check(AttachmentFileDownloader.safeLeaf("/") == nil, "safe leaf rejects separator-only name without crashing")
// F-76：清洗器的三件事——NFC 归一化、Cc/Cf 剔除、按 UTF-8 字节截断。
// 断言用 scalar 数而不是 `==`：Swift 的字符串相等本来就按规范等价比较，
// 用 `==` 即使没归一化也会通过，测不出东西。
let decomposed = AttachmentFilenameSanitizer.sanitize("e\u{0301}.png", maxBytes: 200)
check(decomposed.unicodeScalars.count == 5 && decomposed.utf8.count == 6,
      "sanitizer normalizes decomposed name to NFC")
check(AttachmentFilenameSanitizer.sanitize("a\u{00AD}b\u{2060}c\u{FEFF}d", maxBytes: 200) == "a_b_c_d",
      "sanitizer replaces soft hyphen, word joiner and BOM")
// ZWJ（U+200D）也是 Cf。这里刻意不留它：留着会让 createDestination 的平台相关
// 控制符守卫在 Apple 上拒收整个文件，代价比 emoji 名字被拆开更大。
let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.png"
check(AttachmentFilenameSanitizer.sanitize(family, maxBytes: 200)
        == "\u{1F468}_\u{1F469}_\u{1F467}.png",
      "sanitizer replaces ZWJ with underscore instead of keeping Cf")
let byteCapped = AttachmentFilenameSanitizer.sanitize(String(repeating: "中", count: 100) + ".txt", maxBytes: 255)
check(byteCapped.utf8.count <= 255 && byteCapped.hasSuffix(".txt"),
      "sanitizer truncates by UTF-8 bytes, not characters, and keeps extension")
// The uploader is owned by a composer page. Destroying that page cancels its
// pending work instead of silently keeping an upload alive in the background.
var ownerReply: CheckedContinuation<UploadedAttachment, Error>?
var ownerUploadCancelled = false
var ownedCoordinator: AttachmentUploadCoordinator? = AttachmentUploadCoordinator(sessionID: "owner") { _, _, _ in
    let result = try await withCheckedThrowingContinuation { ownerReply = $0 }
    ownerUploadCancelled = Task.isCancelled
    return result
}
weak var releasedCoordinator = ownedCoordinator
_ = try ownedCoordinator!.add(name: "owned.txt", mime: "text/plain", data: Data([1]))
for _ in 0..<200 where ownerReply == nil {
    try await Task.sleep(nanoseconds: 10_000_000)
}
check(ownerReply != nil, "owned upload started before owner release")
ownedCoordinator = nil
check(releasedCoordinator == nil, "upload task does not retain its composer coordinator")
ownerReply?.resume(returning: attachment)
for _ in 0..<200 where !ownerUploadCancelled {
    try await Task.sleep(nanoseconds: 10_000_000)
}
check(ownerUploadCancelled, "releasing the upload coordinator cancels its task")
try await runPreviewTests()
runKindTests()
try runDownloadContractTests()
try await runFileDownloaderTests()
try await runReliabilityTests()
print("\(checks) attachment checks passed")
