import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The same backend coordinator runs against a scripted transport in offline tests.
@MainActor
protocol GatewayTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func events(for request: URLRequest, onFrame: (SSEFrame) async throws -> Bool) async throws
    /// 上传走专用 session，resource 上限 120s。实现方可用同一 session 兜底。
    func uploadData(for request: URLRequest,
                    onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> (Data, HTTPURLResponse)
}

/// Never forward a configured Bearer credential through an HTTP redirect.
private final class GatewayRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class GatewayURLTransport: GatewayTransport {
    private let session: URLSession
    /// 上传专用 session：multipart 传输常超过 45s 的资源上限。
    /// 两级超时对齐 120s，与 `AttachmentMultipart` 的请求级一致。
    private let uploadSession: URLSession
    /// 流式专用 session：SSE 是长期连接，不能被 45s 资源总时限掐断。
    private let streamSession: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        #if !canImport(FoundationNetworking)
        cfg.waitsForConnectivity = true
        #endif
        cfg.timeoutIntervalForRequest = 30
        // waitsForConnectivity 下必须有资源级超时，否则离线时请求永不失败、
        // 界面无限转圈且输入栏锁死。
        cfg.timeoutIntervalForResource = 45
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        session = URLSession(configuration: cfg, delegate: GatewayRedirectPolicy(), delegateQueue: nil)

        let uploadCfg = URLSessionConfiguration.default
        #if !canImport(FoundationNetworking)
        uploadCfg.waitsForConnectivity = true
        #endif
        uploadCfg.timeoutIntervalForRequest = 120
        uploadCfg.timeoutIntervalForResource = 120
        uploadCfg.httpShouldSetCookies = false
        uploadCfg.httpCookieStorage = nil
        uploadCfg.urlCredentialStorage = nil
        uploadCfg.urlCache = nil
        uploadSession = URLSession(configuration: uploadCfg, delegate: GatewayRedirectPolicy(), delegateQueue: nil)

        // 流式专用 session。
        //
        // 共享 session 的 `timeoutIntervalForResource` 是 45s，而它是「整次传输
        // 总时限、永不重置」——SSE 是一条长期连接，长回复几分钟后就被系统掐断，
        // 客户端进入「连接中断，正在恢复」的循环。`timeoutIntervalForRequest`
        // 管「多久没收到字节」，对流式才是正确的语义。
        let streamCfg = URLSessionConfiguration.default
        #if !canImport(FoundationNetworking)
        streamCfg.waitsForConnectivity = true
        #endif
        streamCfg.timeoutIntervalForRequest = 60
        streamCfg.timeoutIntervalForResource = 3600
        streamCfg.httpShouldSetCookies = false
        streamCfg.httpCookieStorage = nil
        streamCfg.urlCredentialStorage = nil
        streamCfg.urlCache = nil
        streamSession = URLSession(configuration: streamCfg, delegate: GatewayRedirectPolicy(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        uploadSession.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        return (data, http)
    }

    /// 上传走专用 session，resource 上限 120s。
    func uploadData(for request: URLRequest,
                    onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        // 有进度回调时才建带 delegate 的 session；没有就走原来的快路径，
        // 避免每次上传都为没人看的进度付一次 delegate 开销。
        guard let onProgress else {
            let (data, response) = try await uploadSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
            return (data, http)
        }
        let relay = AttachmentUploadProgressRelay()
        let session = URLSession(configuration: uploadSession.configuration,
                                 delegate: relay, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await AttachmentUploadTransport.send(request, session: session,
                                                        relay: relay, onProgress: onProgress)
    }

    func events(for request: URLRequest, onFrame: (SSEFrame) async throws -> Bool) async throws {
        #if canImport(FoundationNetworking)
        throw APIError.http(501, "当前运行环境不支持流式传输")
        #else
        let (bytes, response) = try await streamSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, "无法连接回复流") }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            .contains("text/event-stream") == true else { throw APIError.badResponse }
        try await Self.parseStream(bytes, onFrame: onFrame)
        #endif
    }

    #if !canImport(FoundationNetworking)
    nonisolated private static func parseStream(_ bytes: URLSession.AsyncBytes,
        onFrame: (SSEFrame) async throws -> Bool) async throws {
        var line = Data()
        var parser = SSEParser()
        var budget = SSEFrameBudget()
        for try await byte in bytes {
            try Task.checkCancellation()
            try budget.consume(byte)
            if byte == 10 {
                let raw = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let frame = parser.feed(line: raw), try await onFrame(frame) { return }
            } else {
                guard line.count < 8_388_608 else { throw APIError.http(413, "回复帧过大") }
                line.append(byte)
            }
        }
        if !line.isEmpty, let frame = parser.feed(line: String(decoding: line, as: UTF8.self)),
           try await onFrame(frame) { return }
        if let frame = parser.feed(line: "") { _ = try await onFrame(frame) }
    }
    #endif
}
