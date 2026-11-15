import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AppState / NativeChatModel 共同面对的聚合后端。
///
/// 这样拆的理由：`NativeChatService` 只描述「一轮对话」，而会话生命周期
/// （列表/fork/改名/归档…）是另一组关注点。WebUI 把两者混在一个类里，
/// 直连网关后它们来自不同端点，必须分开才能各自演进。
///
/// Gateway 文件操作通过原生 Files API；Bearer 不能转发到回退域名。
@MainActor
protocol HermesBackend: NativeChatService, SessionService {
    /// 这个后端能做到什么。**唯一来源**：UI 与方法层都读它，
    /// 不再各自比较 `BackendKind` 字面量。
    var capabilities: BackendCapabilities { get }

    /// 附件上传的基地址。WebUI 实例就是自己的地址；网关实例也是自己的地址
    /// （网关自带 Files API，不再依赖配套 WebUI）。
    var attachmentBaseURL: URL { get }

    /// 上传路由。WebUI 是 `api/upload`；网关是 `v1/files`（attachments 插件）。
    /// 两条路径不同，必须由后端声明，不能由共用代码写死。
    var attachmentUploadRoute: String { get }

    /// 附件的认证方式。WebUI 靠登录 cookie（返回 `.cookieOnly`），
    /// 网关只认 `Authorization: Bearer`，不返回它会 401。
    var attachmentAuthorization: AttachmentAuthorization { get }

    /// 「浏览器打开这个会话」的基地址。WebUI 实例指向自己；
    /// 网关实例优先用配套 WebUI（会话页只有那边有），没有再退回网关地址。
    var webConsoleBaseURL: URL { get }
    /// A real browser session page exists only on WebUI or when a gateway has
    /// an explicitly configured companion WebUI.
    var browserSessionURL: URL? { get }

    func authStatus() async throws -> AuthStatus
    func login(password: String) async throws
    func availableModels() async throws -> ModelCatalog
    func performNative(_ request: URLRequest) async throws -> Data
    /// Gateway 上传必须绑定本实例地址并注入 Bearer，404 不能回退 WebUI。
    ///
    /// `onProgress` 报的是**请求体已发送字节**，不是响应下载进度。
    /// 默认 `nil` 时实现可以走不带 delegate 的快路径。
    func uploadAttachment(_ request: URLRequest,
                          onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> Data
    func syncCookiesToWebKit() async
    func syncCookiesFromWebKit() async
}

extension HermesBackend {
    /// 默认就是 WebUI 的形态：上传走 `api/upload`、认证靠 cookie。
    /// 网关覆盖这两个，其他 conformer（含测试替身）不必跟着改。
    var attachmentUploadRoute: String { "api/upload" }
    var attachmentAuthorization: AttachmentAuthorization { .cookieOnly }
    var browserSessionURL: URL? { webConsoleBaseURL }

    /// 预览/下载用的认证方式。
    ///
    /// 关键：预览走的是 `webConsoleBaseURL`（网关实例优先用配套 WebUI）。
    /// 如果指向的是 WebUI，认证就该是 cookie；只有真正落到网关地址时才用 Bearer。
    /// 两者混用会让「配了 WebUI 的网关实例」把 Bearer 发给 WebUI、或不带认证直连网关。
    var attachmentPreviewAuthorization: AttachmentAuthorization { .cookieOnly }
}

/// 会话生命周期与列表元数据。
@MainActor
protocol SessionService: AnyObject {
    func sessions() async throws -> [SessionSummary]
    func createSession(title: String?, model: String?) async throws -> String
    func renameSession(sessionID: String, title: String) async throws
    func setSessionPinned(sessionID: String, pinned: Bool) async throws
    func setSessionArchived(sessionID: String, archived: Bool) async throws
    func deleteSession(sessionID: String) async throws
    /// `keepCount` 为 nil 表示保留全部历史。
    func forkSession(sessionID: String, keepCount: Int?) async throws -> String
    func setSessionModel(sessionID: String, model: String, provider: String?) async throws
}
