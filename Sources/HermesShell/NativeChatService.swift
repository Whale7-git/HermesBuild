import Foundation

enum ActiveRunProbe: Equatable, Sendable {
    case alive
    case terminal
    case unknown
}

@MainActor
protocol NativeChatService:AnyObject {
    func requiresAuthentication(after error: Error) -> Bool
    /// The latest run-recovery write failed, so this process can still avoid a
    /// duplicate POST but a relaunch may not know which run is active.
    var runRecoveryUnavailable: Bool { get }
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot
    /// Bounded recovery-only status probe. A missing active_stream_id cannot
    /// prove completion; this method lets a durable receipt verify its exact
    /// run without replaying the original POST.
    func probeActiveRun(sessionID:String,runID:String) async throws -> ActiveRunProbe
    func startNativeTurn(sessionID:String,text:String) async throws -> String
    /// 带附件发送。必须在协议 requirement 里声明：否则调用按静态类型派发，
    /// 只会命中 extension 的默认实现（旧实现会忽略附件），HermesAPI 的真实实现
    /// 永远不会被调到（protocol extension 静态派发的经典陷阱）。
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload]) async throws -> String
    func stopNativeTurn(streamID:String) async throws
    /// 运行中追加引导。nil 表示已受理；非 nil 是服务端的降级原因。
    /// 必须在协议里声明：否则调用按静态类型派发，只会命中 extension 的默认实现。
    func steerNativeTurn(sessionID:String,text:String) async throws -> String?
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws
    /// 回答服务端的审批请求。nil 表示已受理；非 nil 是降级原因（例如该后端没有
    /// 审批通道）。`choice` 用网关的取值：once / session / always / deny。
    /// 同样必须在协议里声明——否则调用只会命中 extension 的默认实现。
    func approveNativeTurn(runID:String,choice:String,requestID:String?) async throws -> String?
    /// 回答服务端的补充信息请求。nil 表示已受理；非 nil 是降级原因。
    /// 与审批分开：服务端字段是 `answer`，且必须带 `execution_generation`。
    func clarifyNativeTurn(runID:String,answer:String,requestID:String,
                           executionGeneration:Int) async throws -> String?
}

extension NativeChatService {
    func requiresAuthentication(after error: Error) -> Bool { false }
    var runRecoveryUnavailable: Bool { false }
    /// Unknown is fail-closed. A backend that cannot prove the exact run is
    /// alive must never turn the receipt into permission to send again.
    func probeActiveRun(sessionID:String,runID:String) async throws -> ActiveRunProbe { .unknown }
    /// 未实现 steer 的服务按「不支持」处理，调用方会退回排队语义，不会静默丢弃。
    func steerNativeTurn(sessionID:String,text:String) async throws -> String? { "unsupported" }
    /// 没有审批通道的服务：明确回报「不支持」，让界面提示去对应终端处理，
    /// 而不是把一个永远不会被受理的确认按钮留在屏幕上。
    func approveNativeTurn(runID:String,choice:String,requestID:String?) async throws -> String? { "unsupported" }
    /// 没有 clarify 通道的服务：明确回报「不支持」，让界面提示去对应终端处理。
    func clarifyNativeTurn(runID:String,answer:String,requestID:String,
                           executionGeneration:Int) async throws -> String? { "unsupported" }
    /// Text-only services may use this fallback only for an empty attachment
    /// list. Silently accepting a file here would lose it after a valid upload.
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload]) async throws -> String {
        guard attachments.isEmpty else { throw NativeChatServiceError.attachmentsUnsupported }
        return try await startNativeTurn(sessionID:sessionID,text:text)
    }
}

enum NativeChatServiceError: LocalizedError {
    case attachmentsUnsupported
    var errorDescription: String? { "当前聊天服务未实现附件发送，附件未提交。" }
}

/// 历史附件是服务端已上传的引用（只有 path 字符串，没有本地 Data），
/// 编辑/重生成分支重发时只把它包装成载荷引用，**不会重新上传**文件。
/// size 记为 0、path 原样回填；仅依赖 Foundation，不引用本地上传模型类型。
extension ChatAttachmentPayload {
    init(historyPath: String) {
        let name = (historyPath as NSString).lastPathComponent
        let ext = (historyPath as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
        let isImage = imageExtensions.contains(ext)
        let mime: String
        if isImage {
            mime = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
        } else {
            mime = "application/octet-stream"
        }
        self.init(name: name, path: historyPath, mime: mime, size: 0, isImage: isImage)
    }
}
