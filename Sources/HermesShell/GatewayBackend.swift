import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 直连 Hermes 网关的后端。
///
/// 分工：
/// - 会话生命周期（列表 / fork / 改名 / 置顶 / 归档 / 删除 / 换模型）→ 网关。
///   网关自己的 `/fork` 会把消息真正复制进 `state.db`，所以分支会话有完整历史；
///   WebUI 的 `/api/session/branch` 只复制进它自己的 sidecar，网关侧是空会话。
/// - 聊天轮次 → 网关 `/v1/runs` + `/v1/runs/{id}/events`（两段式，与
///   `NativeChatService` 的「先拿 id 再订阅」天然对齐，且支持 `Last-Event-ID` 续传）。
/// - 附件上传 / 模型目录 → 转发到配套 WebUI。网关没有 multipart 上传端点，
///   `/v1/models` 也只返回一个占位条目，这两项只能回落。
@MainActor
final class GatewayBackend: ObservableObject, HermesBackend, DiscoveryProviding,
                            SessionDiscoveryService {
    let gatewayBaseURL: URL
    let webuiBaseURL: URL?
    private let apiKey: String
    private let transport: GatewayTransport
    private let runStore: GatewayRunStore
    private let historyReader = GatewayHistoryReader()
    private let requests: GatewayRequests
    /// 附件上传 / 模型目录的回落通道。配置了 webuiBaseURL 才有。
    private let fallback: HermesAPI?

    /// 网关容器里对应 WebUI `~/.hermes` 的路径，用于把上传返回的绝对路径
    /// 换成 agent 容器里真实存在的位置。空串表示不做映射。
    private let gatewayDataPath: String

    /// Unverifiable run statuses never mean "finished". A bounded budget
    /// converts repeated 404/unknown/5xx/malformed/network failures to a
    /// user-visible verification error while retaining the durable run ID.
    private var failedRunProbes: [String: Int] = [:]
    private var nextRunProbeAt: [String: TimeInterval] = [:]
    private static let maxFailedRunProbes = 5

    init(gatewayBaseURL: URL, apiKey: String, webuiBaseURL: URL?, gatewayDataPath: String = "",
         recoveryScope: String? = nil, transport: GatewayTransport? = nil,
         runStore: GatewayRunStore? = nil) {
        self.gatewayBaseURL = gatewayBaseURL
        self.apiKey = apiKey
        self.webuiBaseURL = webuiBaseURL
        self.requests = GatewayRequests(baseURL: gatewayBaseURL, apiKey: apiKey)
        self.transport = transport ?? GatewayURLTransport()
        self.runStore = runStore ?? GatewayRunStore(scope: recoveryScope)
        self.fallback = webuiBaseURL.map { HermesAPI(baseURL: $0.absoluteString) }
        self.gatewayDataPath = gatewayDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 传输

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            // 网关错误是 OpenAI 风格：{"error":{"message","type","code"}}
            let message = Self.errorMessage(from: data)
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, message)
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = root["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String)
        }
        return root["error"] as? String
    }

    func performNative(_ request: URLRequest) async throws -> Data {
        try await perform(request)
    }

    // MARK: - 认证

    /// 网关只用 API key，没有登录态概念。这里做一次轻量连通性检查：
    /// 401/403 视为「密钥不可用」，其余错误（网络不通等）照常抛出。
    func authStatus() async throws -> AuthStatus {
        var request = try requests.sessions(limit: 1)
        request.timeoutInterval = 15
        do {
            let (_, http) = try await transport.data(for: request)
            switch http.statusCode {
            case 200...299: return AuthStatus(authEnabled: true, loggedIn: true, passwordAuthEnabled: false)
            case 401, 403: return AuthStatus(authEnabled: true, loggedIn: false, passwordAuthEnabled: false)
            default: throw APIError.http(http.statusCode, "网关连通性检查失败")
            }
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            return AuthStatus(authEnabled: true, loggedIn: false, passwordAuthEnabled: false)
        }
    }

    /// 网关模式没有网页登录流程：身份就是实例配置里的 API 密钥。
    ///
    /// A-17：原来这里是空实现（`{}`），静默成功。空实现的问题不是「少做了一件事」，
    /// 而是**骗了调用方**：`AppState.signIn` 拿到成功返回后会走 `retireHistoryAccount()`
    /// + `needsLogin = false`，等于宣布「登录态已建立」并轮换账号域，而实际上一条
    /// 认证都没发生。现在明确抛 501，调用方会把它当成错误展示，不会误判成功。
    /// 改密钥请走 `updateGatewayAPIKey`（先用新密钥做只读探测再保存）。
    func login(password: String) async throws {
        throw APIError.http(501, "网关模式使用 API 密钥认证，不支持密码登录")
    }

    func requiresAuthentication(after error: Error) -> Bool {
        if case APIError.http(let code, _) = error { return code == 401 || code == 403 }
        return false
    }

    /// 协议要求（`HermesBackend`），实现即「什么都不做」。
    ///
    /// 网关请求带的是 `Authorization: Bearer`，全程不碰 WebKit 的 cookie 罐；
    /// 但 `HermesBackend` 是网关与 WebUI 共用的聚合协议，AppState 在切换实例后
    /// 会无条件调用这两个方法，所以必须保留。空实现是正确语义，不是漏写。
    func syncCookiesToWebKit() async {}
    func syncCookiesFromWebKit() async {}

    var attachmentBaseURL: URL { gatewayBaseURL }
    /// 网关自己提供 OpenAI Files API（`/v1/files`，由 attachments 插件注册）。
    var attachmentUploadRoute: String { "v1/files" }
    /// 网关只认 `Authorization: Bearer`（`api_server._check_auth` 完全不看 cookie）。
    var attachmentAuthorization: AttachmentAuthorization { .bearer(apiKey) }
    /// 预览落在哪一边，认证就跟哪一边：指向配套 WebUI 时用 cookie，
    /// 落到网关地址时用 Bearer。
    var attachmentPreviewAuthorization: AttachmentAuthorization {
        // The preview base URL is always Gateway; its authentication must match.
        .bearer(apiKey)
    }

    /// 附件上传走网关自带的 `/v1/files`。
    ///
    /// 以前这里要求配一个 WebUI 地址去借它的 `/api/upload`，于是纯网关实例根本传不了附件。
    /// Gateway Files API 不存在时明确报错，不向 WebUI 重发带密钥的请求。
    func uploadAttachment(_ request: URLRequest,
                          onProgress: (@Sendable (AttachmentTransferProgress) -> Void)? = nil) async throws -> Data {
        // The multipart builder may already include Bearer; validate again before transport.
        // Bind upload authentication and endpoint to this exact Gateway origin.
        guard let endpoint = request.url,
              let scheme = gatewayBaseURL.scheme?.lowercased(),
              endpoint.scheme?.lowercased() == scheme,
              endpoint.host?.lowercased() == gatewayBaseURL.host?.lowercased(),
              (endpoint.port ?? (scheme == "https" ? 443 : 80))
                  == (gatewayBaseURL.port ?? (scheme == "https" ? 443 : 80)),
              endpoint.path == gatewayBaseURL.appendingPathComponent("v1/files").path,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              request.httpMethod?.uppercased() == "POST",
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.http(400, "附件上传地址不属于当前 Gateway，已拒绝发送密钥")
        }
        var authorized = request
        authorized.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await transport.uploadData(for: authorized, onProgress: onProgress)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw APIError.http(501, "Gateway 没有 /v1/files；请在服务端启用 Files API 插件，不会回退到 WebUI")
            }
            throw APIError.http(http.statusCode, Self.errorMessage(from: data) ?? "附件上传失败")
        }
        return data
    }

    /// 会话页只有 WebUI 有；配了配套 WebUI 就指向它，否则退回网关地址。
    var webConsoleBaseURL: URL { webuiBaseURL ?? gatewayBaseURL }
    var browserSessionURL: URL? { webuiBaseURL }

    /// 网关是只读转发层：没有归档列表、不能从指定消息处分支、不搜索正文、
    /// 用 API 密钥而不是密码。整会话复制仍然支持。
    var capabilities: BackendCapabilities { .gateway }

    /// Search scans gateway title/preview pages. Archive is explicitly unavailable
    /// until the gateway offers a way to list archived rows.
    var discovery: SessionDiscoveryService? { self }

    /// 本轮 run 恢复记录写盘失败（F-55d）。
    ///
    /// `runStore` 是 `private`，UI 层看不到它内部的 `persistenceFailed`，这个标记
    /// 就会变成「只写不读」的死状态。这里做一次只读转发：写失败意味着「不自动重发」
    /// 的保证不再可靠，UI 需要据此提示「本轮恢复能力不可用」。
    ///
    /// 内存里的 run 记录仍然是对的（`GatewayRunStore.current()` 在写失败期间切到内存
    /// 真源，`runID(for:)` 照常返回正确值），所以这只影响「重启后能不能恢复」这一件事，
    /// 不应该阻断当前轮的发送或历史读取。
    ///
    /// **这是会翻转的瞬时值，不是粘滞标记**：每次写入都按本次 `persist` 结果重置，
    /// 失败后下一次成功写入会把它变回 false。所以 UI 若想「出现过就常驻提示」，
    /// 必须自己做 sticky（例如 `if backend.runRecoveryUnavailable { shown = true }`），
    /// 不能把这个属性直接绑到常驻横幅上——否则横幅会闪一下就消失。
    ///
    /// 两个类型都是 `@MainActor`，同 actor 内直接读，不需要额外隔离。
    var runRecoveryUnavailable: Bool { runStore.persistenceFailed }

    // MARK: - 会话

    func sessions() async throws -> [SessionSummary] {
        let decoded = try await GatewaySessionReader.all(requests: requests, load: perform)
        // P1：网关的列表接口不返回流式标记（`GatewayDecode` 里 `isStreaming: nil`），
        // 于是 `AppState.markCompletions` 依赖的「上一轮 true → 这一轮非 true」
        // 判定永远不成立，后台完成圆点与通知在纯网关模式下从不触发。
        //
        // 本地 `GatewayRunStore` 正好记着「哪个会话有未结束的 run」，而它只在
        // run 收到终态（completed/failed/cancelled/interrupted）或 404/unknown
        // 收敛时才 `finish`。用它补齐这个字段，不必新增网络往返。
        // Refresh known runs when returning to the list as well as inside a chat.
        // Unknown/network failure keeps the durable record; it is not completion.
        scheduleRunProbes(sessionIDs: decoded.map(\.sessionId))
        return decoded.map { row in
            var copy = row
            copy.isStreaming = runStore.runID(for: row.sessionId) != nil
            return copy
        }
    }

    static let runsChanged = Notification.Name("Hermes.gatewayRunsChanged")
    private var runProbeTask: Task<Void, Never>?

    /// List availability never waits for status endpoints.
    private func scheduleRunProbes(sessionIDs: [String]) {
        guard runProbeTask == nil else { return }
        let known = sessionIDs.filter { runStore.runID(for: $0) != nil }
        guard !known.isEmpty else { return }
        runProbeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.runProbeTask = nil }
            let before = known.map { self.runStore.runID(for: $0) }
            await withTaskGroup(of: Void.self) { group in
                var iterator = known.makeIterator()
                for _ in 0..<4 {
                    if let id = iterator.next() {
                        group.addTask { _ = try? await self.activeRun(sessionID: id) }
                    }
                }
                while await group.next() != nil {
                    if !Task.isCancelled, let id = iterator.next() {
                        group.addTask { _ = try? await self.activeRun(sessionID: id) }
                    }
                }
            }
            if before != known.map({ self.runStore.runID(for: $0) }) {
                NotificationCenter.default.post(name: Self.runsChanged, object: self)
            }
        }
    }
    func createSession(title: String?, model: String?) async throws -> String {
        let data = try await perform(try requests.createSession(title: title, model: model))
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = root["session"] as? [String: Any],
              let id = session["id"] as? String, !id.isEmpty else {
            throw APIError.badResponse
        }
        return id
    }

    func renameSession(sessionID: String, title: String) async throws {
        _ = try await perform(try requests.patchSession(sessionID: sessionID, title: title,
                                                       pinned: nil, archived: nil))
    }

    func setSessionPinned(sessionID: String, pinned: Bool) async throws {
        _ = try await perform(try requests.patchSession(sessionID: sessionID, title: nil,
                                                       pinned: pinned, archived: nil))
    }

    func setSessionArchived(sessionID: String, archived: Bool) async throws {
        // The deployed list route excludes archived rows and ignores include_archived.
        // Refuse hiding a session that this API cannot subsequently list/restore.
        if archived { throw APIError.http(501, "当前网关不提供归档列表，暂不能在 App 内归档；请在支持归档管理的终端操作。") }
        _ = try await perform(try requests.patchSession(sessionID: sessionID, title: nil,
                                                       pinned: nil, archived: archived))
    }

    func deleteSession(sessionID: String) async throws {
        _ = try await perform(try requests.deleteSession(sessionID: sessionID))
        if let runID = runStore.runID(for: sessionID) {
            runStore.finish(runID: runID)
            clearFailedRunProbes(runID: runID)
        }
    }

    /// 网关 fork：`create_session` + `get_messages(source)` + `replace_messages(fork, …)`，
    /// 消息真的复制进 state.db，所以新会话 `history` 不为 0。
    /// The deployed fork is a full copy; reject cutoff requests before any mutation.
    func forkSession(sessionID: String, keepCount: Int?) async throws -> String {
        guard keepCount == nil else {
            throw APIError.http(501, "当前网关只支持复制完整会话，不能从指定消息处分支。未创建分支，也未发送消息。")
        }
        let data = try await perform(try requests.fork(sessionID: sessionID, keepCount: nil))
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = root["session"] as? [String: Any],
              let id = session["id"] as? String, !id.isEmpty else {
            throw APIError.badResponse
        }
        return id
    }

    func setSessionModel(sessionID: String, model: String, provider: String?) async throws {
        _ = try await perform(try requests.setModel(sessionID: sessionID, model: model, provider: provider))
    }

    // MARK: - 聊天轮次

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        // Run-status lookup is a recovery hint, not a prerequisite for reading
        // history. A transient /v1/runs failure must not prevent the user from
        // loading the canonical transcript that can prove completion.
        let active = try await activeRunForHistory(sessionID: sessionID)
        let window = try await historyReader.read(sessionID: sessionID, before: before,
                                                   requests: requests, load: perform)
        return try GatewayDecode.snapshot(window.data, offset: window.offset,
                                          activeRunID: active, requestedSessionID: sessionID)
    }

    func probeActiveRun(sessionID: String, runID: String) async throws -> ActiveRunProbe {
        let now = Date().timeIntervalSince1970
        if let retryAt = nextRunProbeAt[runID], now < retryAt {
            return .unknown
        }
        let data: Data
        do {
            data = try await perform(requests.runStatus(runID: runID))
        } catch let error as APIError {
            if case .http(let code, _) = error, code == 401 || code == 403 {
                throw error
            }
            return recordProbeFailure(runID: runID)
        } catch {
            if error is CancellationError { throw error }
            return recordProbeFailure(runID: runID)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["run_id"] as? String == runID,
              let status = root["status"] as? String,
              let returnedSessionID = root["session_id"] as? String,
              returnedSessionID == sessionID else {
            return recordProbeFailure(runID: runID)
        }
        switch status {
        case "queued", "running", "waiting_for_approval", "stopping":
            clearFailedRunProbes(runID: runID)
            // The receipt can outlive a local run-store cleanup after a crash or
            // account-scope repair. A status response that proves both the
            // exact run ID and session ownership is sufficient to re-arm it.
            if runStore.runID(for: sessionID) == nil {
                runStore.remember(runID: runID, sessionID: sessionID)
            } else if runStore.runID(for: sessionID) != runID {
                return .unknown
            }
            return .alive
        case "completed", "failed", "cancelled", "interrupted":
            clearFailedRunProbes(runID: runID)
            return .terminal
        default:
            return recordProbeFailure(runID: runID)
        }
    }

    private func activeRun(sessionID: String, allowBackoff: Bool = true) async throws -> String? {
        guard let runID = runStore.runID(for: sessionID) else { return nil }
        let now = Date().timeIntervalSince1970
        if allowBackoff, let retryAt = nextRunProbeAt[runID], now < retryAt {
            throw GatewayDecodeError.malformed(
                "后台任务状态仍待核对；已暂停频繁重试，不会清除运行记录或自动重发。")
        }
        let data: Data
        do {
            data = try await perform(requests.runStatus(runID: runID))
        } catch let error as APIError {
            if case .http(let code, _) = error, code == 401 || code == 403 {
                throw error // Credential errors must not be hidden as "running".
            }
            return try unresolvedRun(runID: runID)
        } catch {
            if error is CancellationError { throw error }
            return try unresolvedRun(runID: runID)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["run_id"] as? String == runID,
              let status = root["status"] as? String else {
            return try unresolvedRun(runID: runID)
        }
        guard runStore.runID(for: sessionID) == runID else {
            throw GatewayDecodeError.malformed("任务状态已变化，请刷新核对")
        }
        switch status {
        case "queued", "running", "waiting_for_approval", "stopping":
            clearFailedRunProbes(runID: runID)
            return runID
        case "completed", "failed", "cancelled", "interrupted":
            // Only an explicit terminal status can retire the recovery record.
            clearFailedRunProbes(runID: runID)
            runStore.finish(runID: runID)
            return nil
        default:
            return try unresolvedRun(runID: runID)
        }
    }

    /// History is the completion authority; run status is only a recovery hint.
    /// An unavailable status is unknown, not proof that execution is still live.
    /// Return no active ID so completed history can reconcile, while the durable
    /// run-store entry remains available for a later bounded probe. Authentication
    /// and cancellation still abort.
    private func activeRunForHistory(sessionID: String) async throws -> String? {
        guard runStore.runID(for: sessionID) != nil else { return nil }
        do {
            return try await activeRun(sessionID: sessionID)
        } catch let error as APIError {
            if case .http(let code, _) = error, code == 401 || code == 403 {
                throw error
            }
            return nil
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    private func clearFailedRunProbes(runID: String) {
        failedRunProbes.removeValue(forKey: runID)
        nextRunProbeAt.removeValue(forKey: runID)
    }

    private func recordProbeFailure(runID: String) -> ActiveRunProbe {
        let failures = min(32, (failedRunProbes[runID] ?? 0) + 1)
        failedRunProbes[runID] = failures
        if failures >= Self.maxFailedRunProbes {
            let exponent = min(5, failures - Self.maxFailedRunProbes)
            nextRunProbeAt[runID] = Date().timeIntervalSince1970
                + Double(min(60, 2 << exponent))
        }
        return .unknown
    }

    /// Never erase runStore for a guessed terminal state. Bounded exponential
    /// backoff stops a dead gateway from polling forever at full frequency.
    private func unresolvedRun(runID: String) throws -> String {
        let failures = min(32, (failedRunProbes[runID] ?? 0) + 1)
        failedRunProbes[runID] = failures
        guard failures >= Self.maxFailedRunProbes else { return runID }
        let exponent = min(5, failures - Self.maxFailedRunProbes)
        nextRunProbeAt[runID] = Date().timeIntervalSince1970
            + Double(min(60, 2 << exponent))
        throw GatewayDecodeError.malformed(
            "后台任务连续无法确认状态；运行记录已保留，请稍后核对，不会自动重发。")
    }

    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        try await startNativeTurn(sessionID: sessionID, text: text, attachments: [])
    }

    /// 附件：网关没有上传端点，附件必须在 WebUI 侧先换成服务端引用（path）。
    /// 这里只负责把它们拼进文本——网关的 `input` 是纯文本字段。
    func startNativeTurn(sessionID: String, text: String,
                         attachments: [ChatAttachmentPayload]) async throws -> String {
        let body = inputText(text: text, attachments: attachments)
        let data = try await perform(try requests.startRun(sessionID: sessionID, text: body))
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runID = root["run_id"] as? String, !runID.isEmpty else {
            throw APIError.badResponse
        }
        runStore.remember(runID: runID, sessionID: sessionID)
        clearFailedRunProbes(runID: runID)
        return runID
    }

    /// 新会话可能的附件形态：已上传的引用以绝对路径追加，让 agent 用 read_file 取。
    /// 网关的 `input` 只接受文本，所以这是唯一无损的方式。
    ///
    /// 格式与 QQ 适配器一致（`[file: 名字 (路径)]`）：那是 agent 已经认识、
    /// 且各平台入站消息里出现过同一种写法的形态，模型不需要额外解释就知道去读路径。
    private func inputText(text: String, attachments: [ChatAttachmentPayload]) -> String {
        guard !attachments.isEmpty else { return text }
        let lines = attachments.map { attachment -> String in
            let path = GatewayAttachmentPaths.rewrite(attachment.path, gatewayDataPath: gatewayDataPath)
            return "[file: \(attachment.name) (\(path))]"
        }
            .joined(separator: "\n")
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? lines : "\(head)\n\n\(lines)"
    }

    func stopNativeTurn(streamID: String) async throws {
        do {
            _ = try await perform(try requests.stopRun(runID: streamID))
        } catch let error as APIError {
            // 404/409 = 这轮已经结束或没有可停的 run。用户点「停止」时
            // 界面上仍显示在跑，这种竞态不该弹成错误。
            if case .http(let code, _) = error, code == 404 || code == 409 {
                runStore.finish(runID: streamID)
                clearFailedRunProbes(runID: streamID)
                return
            }
            throw error
        }
        // A successful stop is an acknowledgement, not a terminal state.
        // Keep the record until GET status confirms the task actually stopped.
    }

    /// 引导：网关原生 `/v1/runs/{id}/steer`，不需要 WebUI 转发。
    /// 返回 nil 表示已受理；非 nil 是给调用方的降级原因。
    func steerNativeTurn(sessionID: String, text: String) async throws -> String? {
        guard let runID = runStore.runID(for: sessionID), !runID.isEmpty else {
            return "not_running"
        }
        do {
            _ = try await perform(try requests.steerRun(runID: runID, text: text))
            return nil
        } catch let error as APIError {
            if case .http(409, _) = error { return "not_running" }
            throw error
        }
    }

    /// 网关原生审批回传。`choice` 走服务端白名单（once/session/always/deny）。
    func approveNativeTurn(runID: String, choice: String, requestID: String?) async throws -> String? {
        do {
            _ = try await perform(try requests.approveRun(runID: runID, choice: choice,
                                                          requestID: requestID))
            return nil
        } catch let error as APIError {
            // 409 = 这个审批已经不在等待了（超时、被别处处理、或 run 已结束）。
            // 告诉调用方原因，让它把卡片收掉并提示刷新，而不是反复重试。
            if case .http(let code, _) = error {
                if code == 409 { return "not_pending" }
                if code == 400 { return "rejected" }
            }
            throw error
        }
    }

    /// 网关原生补充信息回传。`answer` 是原始文本或所选选项文字，服务端负责解析
    /// （认编号、认标签、认多选），客户端不做映射。
    func clarifyNativeTurn(runID: String, answer: String, requestID: String,
                           executionGeneration: Int) async throws -> String? {
        do {
            _ = try await perform(try requests.clarifyRun(
                runID: runID, answer: answer, requestID: requestID,
                executionGeneration: executionGeneration))
            return nil
        } catch let error as APIError {
            // 409 not_pending：这条 clarify 已超时或被别处处理。
            // 400：字段合同不匹配（generation 过期、answer 缺失），
            // 与审批不同——clarify 的 400 多半是 generation 变了，重试也没用。
            if case .http(let code, _) = error {
                if code == 409 { return "not_pending" }
                if code == 400 { return "rejected" }
            }
            throw error
        }
    }

    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        let request = try requests.runEvents(runID: streamID, lastEventID: lastEventID)
        // 终态判定必须在 map 循环**之外**独立执行：map 对无法解析的帧返回空数组，
        // 若把 finish 嵌在循环里，坏帧会让 run 永远悬挂（下次启动锁发送）。
        let terminalRawNames: Set<String> = [
            "run.completed", "run.cancelled", "run.interrupted", "run.failed",
            "replay.truncated", "error"
        ]
        try await transport.events(for: request) { frame in
            let rawName = GatewayEventMap.rawEventName(of: frame)
            let mapped = GatewayEventMap.map(frame)
            // 收尾只看原始事件名：即使这一帧 map 失败（空数组），也要清 run。
            if terminalRawNames.contains(rawName) {
                self.runStore.finish(runID: streamID)
                self.clearFailedRunProbes(runID: streamID)
            }
            for item in mapped {
                if try await onFrame(item) { return true }
            }
            // map 空但原帧是终态时，仍然要把「结束」信号交给上层，否则流不会收尾。
            if mapped.isEmpty, terminalRawNames.contains(rawName) {
                let synthetic = SSEFrame(
                    event: rawName == "replay.truncated" || rawName == "error" ? "apperror" : "stream_end",
                    data: "{\"status\":\"\(rawName == "run.completed" ? "completed" : rawName)\"}",
                    id: frame.id)
                if try await onFrame(synthetic) { return true }
            }
            return false
        }
    }

    // MARK: - 回落到 WebUI 的两项

    /// 模型目录：网关 `/v1/models` 只有 `hermes-agent` 占位，必须读 WebUI 的真实目录。
    /// 模型目录优先走网关自己的 `/api/model/options`（实测 52 个 provider、
    /// 当前 provider 的模型全量返回）。只有它不可用时才回落 WebUI——
    /// 这样不配回落地址的网关实例也能切模型。
    func availableModels() async throws -> ModelCatalog {
        // 回落原因（F-48 要求「记一条诊断」）。本文件会被离线测试组单独编译，
        // 那些测试没有链接运行时日志模块（日志单例在那个编译单元里根本不存在），
        // 所以这里只用局部字符串拼进错误消息，绝不引用任何日志单例符号。
        // 想加日志请加在调用方（AppState 一侧），不要加回这个文件。
        var fallbackReason: String?
        do {
            let data = try await perform(requests.modelOptions())
            if GatewayModelCatalog.hasUsableModels(data) { return try GatewayModelCatalog.options(data) }
            // 200 但没有任何「带模型的 provider」：可能是 providers 缺失、全部为空，
            // 或模型列表还没拉取。交给下面的回落路径，并记下原因。
            fallbackReason = "网关返回的模型目录里没有任何可用模型"
        } catch {
            if error is CancellationError || requiresAuthentication(after: error) { throw error }
            if let error = error as? URLError, error.code == .cancelled { throw error }
            // F-48：回落条件不能只看 404/501。200 但结构异常（providers 缺失、
            // 全部 provider 的 models 为空、顶层带 error 字段等）同样意味着
            // 「这个网关版本给不出可用目录」，原来会直接抛错，模型选择器彻底不可用。
            // 现在把解析失败也纳入回落，并留下一条可读诊断。
            if case APIError.http(let code, _) = error, code == 404 || code == 501 {
                fallbackReason = "网关没有 /api/model/options（HTTP \(code)）"
            } else if error is GatewayDecodeError {
                fallbackReason = "网关模型目录结构无法解析：\(error.localizedDescription)"
            } else {
                throw error
            }
        }
        guard let fallback else {
            throw APIError.http(
                501,
                "网关没有返回可用的模型目录（\(fallbackReason ?? "原因未知")），"
                    + "且实例未配置 WebUI 地址；请在实例设置里补充。")
        }
        return try await fallback.availableModels()
    }

    // MARK: - 搜索与归档（本地实现）

    // A-17：原来这里有一个 `sessionsForFiltering()` 只是 `try await sessions()` 的
    // 纯转发，唯一的调用点就是下面的 `searchSessions`。它不是协议要求
    // （`SessionDiscoveryService` 只声明 `searchSessions` / `archivedSessions`），
    // 已删除，调用点直接走 `sessions()`。

    func searchSessions(query: String) async throws -> SessionSearchResponse {
        let all = try await sessions()
        let rows = GatewaySessionFilter.search(all, query: query)
        let hits = rows.map {
            SessionSearchHit(session: $0, matchType: "local",
                             preview: GatewaySessionFilter.snippet(for: $0, query: query))
        }
        return SessionSearchResponse(hits: hits)
    }

    func archivedSessions(offset: Int, limit: Int) async throws -> ArchivedSessionPage {
        throw APIError.http(501, "当前网关没有归档列表接口，不能将空结果当作没有归档；请在支持归档管理的终端查看。")
    }
}

/// `HermesAPI`（WebUI）补齐到聚合协议。它本来就有这些方法，这里只是显式声明归属。
extension HermesAPI: HermesBackend {
    /// WebUI 是本地 Hermes 的完整能力：归档、定点分支、全文搜索、密码登录都有。
    var capabilities: BackendCapabilities { .webUI }
    var attachmentBaseURL: URL { chatRequests.baseURL }
    /// WebUI 的上传端点一直是 `api/upload`。
    var attachmentUploadRoute: String { "api/upload" }
    /// WebUI 用登录 cookie，不额外加认证头。
    var attachmentAuthorization: AttachmentAuthorization { .cookieOnly }
    var webConsoleBaseURL: URL { chatRequests.baseURL }

    func createSession(title: String?, model: String?) async throws -> String {
        try await createNativeSession()
    }

    func forkSession(sessionID: String, keepCount: Int?) async throws -> String {
        try await branchSession(sessionID: sessionID, keepCount: keepCount, title: nil)
    }
}
