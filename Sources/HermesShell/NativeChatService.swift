import Foundation

enum ActiveRunProbe: Equatable, Sendable {
    case alive
    case terminal(RunTerminalStatus)
    case unresolved
    case unknown
}

/// A read-only preflight bound to one canonical lost execution epoch.
/// It cannot be synthesized from a 404 or inferred from transcript content.
struct UnknownRunResolutionOffer: Equatable, Sendable {
    let sessionID: String
    let runID: String
    let admissionID: String
    let executionGeneration: Int
}

/// A stable, random, non-secret identity for one admitted submission. Never
/// derive it from the message or reuse it for a different user action.
enum RunSubmissionIdentity {
    static func make() -> String { "hermes-ios-" + UUID().uuidString.lowercased() }
    static func valid(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 255 && key.utf8.allSatisfy { (33...126).contains($0) }
    }
}

/// What the current deployment actually advertises, not an inference from
/// its version or backend kind. No capability grants permission to replay.
struct RunRecoveryCapabilities: Equatable, Sendable {
    let idempotencySupported: Bool
    let durableStatusRetentionSeconds: Int?
    let unknownResolutionSupported: Bool
}

@MainActor
protocol NativeChatService:AnyObject {
    func requiresAuthentication(after error: Error) -> Bool
    /// The latest run-recovery write failed, so this process can still avoid a
    /// duplicate POST but a relaunch may not know which run is active.
    var runRecoveryUnavailable: Bool { get }
    /// Only an explicit Gateway implementation may opt into /v1/runs options.
    var supportsReasoningEffort: Bool { get }
    /// Client transport can carry a per-submission key, even on old Gateways.
    /// This is not a claim about the remote deployment's durability.
    var carriesRunSubmissionIdentity: Bool { get }
    func runRecoveryCapabilities() async throws -> RunRecoveryCapabilities?
    func history(sessionID:String,before:Int?) async throws -> ChatSnapshot
    /// Bounded recovery-only status probe. A missing active_stream_id cannot
    /// prove completion; this method lets a durable receipt verify its exact
    /// run without replaying the original POST.
    func probeActiveRun(sessionID:String,runID:String) async throws -> ActiveRunProbe
    /// The final reply text the Run reported with its terminal status, if any.
    /// Content evidence that does not depend on history having caught up.
    func runTerminalOutput(sessionID: String, runID: String) -> String?
    /// The Run this session already settled against a validated terminal status.
    func settledTerminalRunID(sessionID: String) -> String?
    func restoreVerifiedRunTerminal(sessionID: String, runID: String, outcome: RunTerminalStatus)
    func restoreAcceptedRunIdentity(sessionID: String, runID: String)
    /// Explicit external user confirmation of a missing execution record.
    /// No remote mutation, no synthetic terminal result, no original POST.
    func releaseMissingRunAfterUserConfirmation(sessionID: String, runID: String) async throws -> Bool
    func unknownRunResolutionOffer(sessionID: String, runID: String) async throws -> UnknownRunResolutionOffer?
    /// User-confirmed mutation only. Never automatically repeat it.
    func resolveUnknownRun(_ offer: UnknownRunResolutionOffer) async throws -> ActiveRunProbe
    func startNativeTurn(sessionID:String,text:String) async throws -> String
    /// 带附件发送。必须在协议 requirement 里声明：否则调用按静态类型派发，
    /// 只会命中 extension 的默认实现（旧实现会忽略附件），HermesAPI 的真实实现
    /// 永远不会被调到（protocol extension 静态派发的经典陷阱）。
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload]) async throws -> String
    /// New requirement is dynamically dispatched. Non-Gateway implementations
    /// refuse non-default effort, rather than silently dropping the option.
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload],
                         reasoningEffort:String?) async throws -> String
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload],
                         reasoningEffort:String?, submissionKey:String?) async throws -> String
    func stopNativeTurn(streamID:String) async throws
    /// 运行中追加引导。nil 表示已受理；非 nil 是服务端的降级原因。
    /// 必须在协议里声明：否则调用按静态类型派发，只会命中 extension 的默认实现。
    func steerNativeTurn(sessionID:String,text:String) async throws -> String?
    func streamNativeTurn(streamID:String,lastEventID:String?,onFrame:(SSEFrame) async throws -> Bool) async throws
    /// 回答服务端的审批请求。nil 表示已受理；非 nil 是降级原因（例如该后端没有
    /// 审批通道）。`choice` 用网关的取值：once / session / always / deny。
    /// 同样必须在协议里声明——否则调用只会命中 extension 的默认实现。
    func approveNativeTurn(runID:String,choice:String,requestID:String,
                           executionGeneration:Int) async throws -> String?
    /// 回答服务端的补充信息请求。nil 表示已受理；非 nil 是降级原因。
    /// 与审批分开：服务端字段是 `answer`，且必须带 `execution_generation`。
    func clarifyNativeTurn(runID:String,answer:String,requestID:String,
                           executionGeneration:Int) async throws -> String?
}

extension NativeChatService {
    func requiresAuthentication(after error: Error) -> Bool { false }
    var runRecoveryUnavailable: Bool { false }
    var supportsReasoningEffort: Bool { false }
    var carriesRunSubmissionIdentity: Bool { false }
    func runRecoveryCapabilities() async throws -> RunRecoveryCapabilities? { nil }
    /// Unknown is fail-closed. A backend that cannot prove the exact run is
    /// alive must never turn the receipt into permission to send again.
    func probeActiveRun(sessionID:String,runID:String) async throws -> ActiveRunProbe { .unknown }
    func runTerminalOutput(sessionID: String, runID: String) -> String? { nil }
    func settledTerminalRunID(sessionID: String) -> String? { nil }
    func restoreVerifiedRunTerminal(sessionID: String, runID: String, outcome: RunTerminalStatus) {}
    func restoreAcceptedRunIdentity(sessionID: String, runID: String) {}
    func releaseMissingRunAfterUserConfirmation(sessionID: String, runID: String) async throws -> Bool { false }
    func unknownRunResolutionOffer(sessionID: String, runID: String) async throws -> UnknownRunResolutionOffer? { nil }
    func resolveUnknownRun(_ offer: UnknownRunResolutionOffer) async throws -> ActiveRunProbe { .unknown }
    /// 未实现 steer 的服务按「不支持」处理，调用方会退回排队语义，不会静默丢弃。
    func steerNativeTurn(sessionID:String,text:String) async throws -> String? { "unsupported" }
    /// 没有审批通道的服务：明确回报「不支持」，让界面提示去对应终端处理，
    /// 而不是把一个永远不会被受理的确认按钮留在屏幕上。
    func approveNativeTurn(runID:String,choice:String,requestID:String,
                           executionGeneration:Int) async throws -> String? { "unsupported" }
    /// 没有 clarify 通道的服务：明确回报「不支持」，让界面提示去对应终端处理。
    func clarifyNativeTurn(runID:String,answer:String,requestID:String,
                           executionGeneration:Int) async throws -> String? { "unsupported" }
    /// Text-only services may use this fallback only for an empty attachment
    /// list. Silently accepting a file here would lose it after a valid upload.
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload]) async throws -> String {
        guard attachments.isEmpty else { throw NativeChatServiceError.attachmentsUnsupported }
        return try await startNativeTurn(sessionID:sessionID,text:text)
    }
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload],
                         reasoningEffort:String?) async throws -> String {
        guard reasoningEffort == nil else { throw NativeChatServiceError.reasoningUnsupported }
        return try await startNativeTurn(sessionID:sessionID,text:text,attachments:attachments)
    }
    func startNativeTurn(sessionID:String,text:String,attachments:[ChatAttachmentPayload],
                         reasoningEffort:String?, submissionKey:String?) async throws -> String {
        // Existing non-Gateway implementations retain their original witness.
        // Do not silently drop a key from a backend that promised to carry it.
        guard submissionKey == nil else { throw NativeChatServiceError.submissionIdentityUnsupported }
        return try await startNativeTurn(sessionID:sessionID,text:text,attachments:attachments,
                                         reasoningEffort:reasoningEffort)
    }
}

enum NativeChatServiceError: LocalizedError {
    case attachmentsUnsupported, reasoningUnsupported, submissionIdentityUnsupported
    var errorDescription: String? {
        switch self {
        case .attachmentsUnsupported: return "当前聊天服务未实现附件发送，附件未提交。"
        case .reasoningUnsupported: return "当前聊天后端不支持推理强度覆盖，消息未发送；请改用服务端默认。"
        case .submissionIdentityUnsupported: return "当前服务无法携带发送标识，本次未发送。"
        }
    }
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


/// Application-wide admission for read-only recovery requests. FIFO among
/// eligible scopes; a saturated instance cannot block another instance.
/// The permit is released only when the actual operation returns, even if
/// its caller was cancelled. SSE and mutating requests never use these slots.
@MainActor
final class RecoveryScheduler {
    static let shared = RecoveryScheduler()
    struct OwnerKey: Hashable {
        let scope: String
        let session: String
    }
    private var owners: [OwnerKey: (ticket: UUID, task: Task<Void, Never>)] = [:]

    /// Ordinary recovery and STOP use one owner per exact session. Replacing
    /// a timer cancels the old owner; GET admission retains in-flight permits
    /// until the underlying operation actually returns.
    func startOwner(key: OwnerKey, ticket: UUID,
                    onFinish: @escaping @MainActor () -> Void = {},
                    operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        owners[key]?.task.cancel()
        let task = Task { [weak self] in
            defer {
                if self?.owners[key]?.ticket == ticket { self?.owners.removeValue(forKey: key) }
                // Cleanup must run even if a replacement cancelled this
                // owner before its operation ever started.
                onFinish()
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        owners[key] = (ticket, task)
        return task
    }
    private struct Waiter {
        let id: UUID
        let instance: String
        let session: String
        let continuation: CheckedContinuation<Void, Error>
    }
    private let globalLimit: Int
    private let instanceLimit: Int
    private var waiting: [Waiter] = []
    private var running: [UUID: (instance: String, session: String)] = [:]

    init(globalLimit: Int = 4, instanceLimit: Int = 2) {
        self.globalLimit = max(1, globalLimit)
        self.instanceLimit = max(1, instanceLimit)
    }

    static func mayAdmit(instance: String, session: String,
                         active: [(instance: String, session: String)],
                         globalLimit: Int, instanceLimit: Int) -> Bool {
        active.count < globalLimit &&
            active.filter { $0.instance == instance }.count < instanceLimit &&
            !active.contains { $0.instance == instance && $0.session == session }
    }

    private func drain() {
        while let index = waiting.firstIndex(where: { waiter in
            Self.mayAdmit(instance: waiter.instance, session: waiter.session,
                active: Array(running.values), globalLimit: globalLimit, instanceLimit: instanceLimit)
        }) {
            let waiter = waiting.remove(at: index)
            running[waiter.id] = (waiter.instance, waiter.session)
            waiter.continuation.resume()
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }

    func perform<T>(instance: String, session: String,
                    operation: () async throws -> T) async throws -> T {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiting.append(Waiter(id: id, instance: instance, session: session, continuation: continuation))
                drain()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(id) }
        })
        defer { running.removeValue(forKey: id); drain() }
        try Task.checkCancellation()
        return try await operation()
    }
}
