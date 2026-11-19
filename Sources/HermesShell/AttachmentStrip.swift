import SwiftUI
import UIKit
import Photos
import QuickLook
import ImageIO

/// Same-origin paths use the authenticated bounded downloader. External files
/// remain explicit links; external raster images use the credential-free loader.
struct HistoryAttachment: Identifiable, Equatable {
    let id: String
    let path: String
    let label: String
    let isRemote: Bool
    let kind: AttachmentKind

    static func parse(_ paths: [String], baseURL: URL?) -> [HistoryAttachment] {
        var seen = Set<String>()
        return paths.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            if let baseURL, let policy = try? AttachmentPreviewPolicy(baseURL: baseURL),
               let path = policy.internalFilePath(from: value) {
                let label = (path as NSString).lastPathComponent
                let kind = InlineImageKind.isRaster(path)
                    ? AttachmentKind.image : AttachmentKind.classify(name: label, mime: "application/octet-stream")
                return HistoryAttachment(id: value, path: path, label: label, isRemote: false, kind: kind)
            }
            let label = (value as NSString).lastPathComponent.isEmpty ? value : (value as NSString).lastPathComponent
            if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
                guard scheme == "http" || scheme == "https", url.user == nil, url.password == nil else { return nil }
                let kind: AttachmentKind = InlineImageKind.isRaster(value)
                    ? .image : AttachmentKind.classify(name: label, mime: "application/octet-stream")
                return HistoryAttachment(id: value, path: value, label: label,
                    isRemote: !sameOrigin(url, baseURL), kind: kind)
            }
            let kind = AttachmentKind.rasterImage(name: label)
                ? AttachmentKind.image : AttachmentKind.classify(name: label, mime: "application/octet-stream")
            return HistoryAttachment(id: value, path: value, label: label, isRemote: false, kind: kind)
        }
    }

    private static func sameOrigin(_ url: URL, _ baseURL: URL?) -> Bool {
        guard let base = baseURL, url.scheme?.lowercased() == base.scheme?.lowercased(),
              url.host?.lowercased() == base.host?.lowercased(),
              url.user == nil, url.password == nil, base.user == nil, base.password == nil else { return false }
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return port(url) == port(base)
    }
}

private struct AttachmentPresentation: Identifiable {
    let id: UUID
    let item: HistoryAttachment
    let intent: AttachmentInteractionState.Intent
    let localURL: URL?
    let baseURL: URL
    let sessionID: String
    let lifetime: AttachmentPresentationLifetime
    var images: [HistoryAttachment] = []
    /// 预览/下载该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var authorization: AttachmentAuthorization = .cookieOnly
}

/// The model, route and actual system controller independently retain the file
/// lifetime. Retiring a never-presented route cannot leak the cross-row gate;
/// retiring an existing route cannot delete a file still held by its controller.
@MainActor
private final class AttachmentInteractionController: ObservableObject {
    @Published private(set) var state = AttachmentInteractionState()
    @Published var presentation: AttachmentPresentation? {
        didSet {
            if presentation == nil, let previous = oldValue { endLocalPresentation(previous.id) }
        }
    }
    private var task: Task<Void, Never>?
    private var lease: AttachmentPresentationLifetime?
    private var heldTicket: UUID?
    private static var scheduledCleanup = false

    deinit {
        task?.cancel()
        if let heldTicket {
            Task { @MainActor in AttachmentPresentationGate.shared.release(heldTicket) }
        }
        // The system controller keeps its independent lifetime reference if it
        // outlives this source row or SwiftUI omits a dismissal callback.
    }

    func activate(scope: String) {
        if !Self.scheduledCleanup {
            Self.scheduledCleanup = true
            Task.detached(priority: .utility) { AttachmentDownloadFiles.cleanupExpired() }
        }
        if state.scope != scope { retire() }
        state.activate(scope: scope)
    }

    func retire() {
        state.deactivate()
        task?.cancel()
        task = nil
        if lease == nil { releaseGate() }
        presentation = nil
        lease = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        state.cancel()
        if lease == nil { releaseGate() }
    }

    func start(_ item: HistoryAttachment, intent: AttachmentInteractionState.Intent,
               baseURL: URL, sessionID: String, images: [HistoryAttachment] = [],
               authorization: AttachmentAuthorization = .cookieOnly) {
        guard let ticket = state.begin(itemID: item.id, intent: intent) else { return }
        guard AttachmentPresentationGate.shared.reserve(ticket.id) else {
            state.fail(ticket, message: "请先完成当前附件操作，再打开其他附件。")
            return
        }
        heldTicket = ticket.id
        if intent == .image {
            guard state.present(ticket) else { releaseGate(); return }
            stage(ticket, item: item, url: nil, baseURL: baseURL, sessionID: sessionID,
                  images: images, authorization: authorization)
            return
        }
        task = Task { [weak self] in
            do {
                let policy = try AttachmentPreviewPolicy(baseURL: baseURL, authorization: authorization)
                let url = try await AttachmentFileDownloader(policy: policy).download(
                    sessionID: sessionID, path: item.path, name: item.label,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.record(ticket, received: progress.receivedBytes, expected: progress.expectedBytes)
                        }
                    })
                guard let self, !Task.isCancelled, self.state.present(ticket) else {
                    AttachmentDownloadFiles.remove(url)
                    return
                }
                self.task = nil
                self.stage(ticket, item: item, url: url, baseURL: baseURL, sessionID: sessionID)
            } catch {
                guard let self, self.state.pending == ticket else { return }
                self.task = nil
                if Task.isCancelled || error is CancellationError { self.state.cancel() }
                else { self.state.fail(ticket, message: error.localizedDescription) }
                self.releaseGate()
            }
        }
    }

    private func record(_ ticket: AttachmentInteractionState.Ticket, received: Int, expected: Int?) {
        state.progress(ticket, received: received, expected: expected)
    }

    func requestDismissal(id: UUID) {
        guard presentation?.id == id else { return }
        presentation = nil
    }

    private func endLocalPresentation(_ id: UUID) {
        guard state.dismissed(id) else { return }
        lease = nil
        // A controller that is still displayed retains its own reference. There
        // is deliberately no unscoped onDismiss callback touching a newer route.
    }

    private func stage(_ ticket: AttachmentInteractionState.Ticket, item: HistoryAttachment,
                       url: URL?, baseURL: URL, sessionID: String, images: [HistoryAttachment] = [],
                       authorization: AttachmentAuthorization = .cookieOnly) {
        let id = ticket.id
        let lifetime = AttachmentPresentationLifetime {
            if let url { AttachmentDownloadFiles.remove(url) }
            Task { @MainActor in AttachmentPresentationGate.shared.release(id) }
        }
        heldTicket = nil // ownership transfers to the independent lifetime
        lease = lifetime
        presentation = AttachmentPresentation(id: id, item: item, intent: ticket.intent,
            localURL: url, baseURL: baseURL, sessionID: sessionID, lifetime: lifetime,
            images: images, authorization: authorization)
    }

    private func releaseGate() {
        if let heldTicket { AttachmentPresentationGate.shared.release(heldTicket) }
        heldTicket = nil
    }
}

/// Fixed-height images preserve chat geometry. File progress is local to the
/// file card, and preview/share buttons have separate 44pt hit targets.
struct AttachmentStrip: View {
    let paths: [String]
    let name: String
    let baseURL: URL
    let sessionID: String
    /// 预览/下载该走哪种认证。网关实例没有 cookie，必须带 Bearer。
    var authorization: AttachmentAuthorization = .cookieOnly
    /// 进入会话时冻结的比例快照；加载完成只写缓存，不改行高。
    var imageRatios: ImageRatioSnapshot = .empty
    /// 实例 + 账号作用域，比例缓存按它隔离。
    var imageRatioScope: String = ""
    @StateObject private var interaction = AttachmentInteractionController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 外部链接的打开入口；显式声明而不是依赖隐式查找。
    @Environment(\.openURL) private var openURL
    private var items: [HistoryAttachment] { HistoryAttachment.parse(paths, baseURL: baseURL) }
    private var images: [HistoryAttachment] { items.filter { $0.kind == .image } }
    private var scope: String { "\(baseURL.absoluteString)|\(sessionID)|\(name)|\(paths.joined(separator: "\u{1f}"))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if images.count == 1, let item = images.first {
                imageTile(item, tile: false)
            } else if images.count > 1 {
                AttachmentTileLayout(singleColumn: dynamicTypeSize.isAccessibilitySize) {
                    ForEach(Array(images.prefix(AttachmentGridPlan.visibleCount(images.count)).enumerated()), id: \.element.id) { index, item in
                        // 第 4 格的「+N」是独立按钮；格子本身也有 tap 手势，
                        // 两者叠在同一区域会互相竞争（点一次可能触发两次，表现为没反应）。
                        // 该格只让覆盖层接收点击。
                        let covered = index == 3 && AttachmentGridPlan.overflow(images.count) > 0
                        imageTile(item, tile: true)
                            .allowsHitTesting(!covered)
                            .overlay {
                                if covered {
                                    Button { start(item, .image) } label: {
                                        ZStack {
                                            Color.black.opacity(0.42)
                                            Text("+\(AttachmentGridPlan.overflow(images.count))")
                                                .font(.title.weight(.semibold)).foregroundStyle(.white)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("查看全部\(images.count)张图片，从第4张开始")
                                    .accessibilityHint("打开图集，还有\(images.count - 4)张图片")
                                }
                            }
                            .accessibilityHint(covered ? "" : "打开图集")
                    }
                }
            }
            ForEach(items.filter { $0.kind != .image }) { item in
                if item.isRemote {
                    remoteRow(item)
                } else {
                    fileCard(item)
                }
            }
        }
        .onAppear { interaction.activate(scope: scope) }
        .onChange(of: scope) { _, next in interaction.activate(scope: next) }
        .onChange(of: scenePhase) { _, phase in
            // Sharing extensions may briefly make the app inactive. A presented
            // lease remains valid through that transition; pending work is
            // retired when backgrounded so it cannot raise a late panel.
            if phase == .background, interaction.state.pending != nil { interaction.retire() }
            else if phase == .active { interaction.activate(scope: scope) }
        }
        .onDisappear { interaction.retire() }
        .sheet(item: $interaction.presentation) { route in
            switch route.intent {
            case .image:
                NavigationStack {
                    HistoryAttachmentGallery(items: route.images.isEmpty ? [route.item] : route.images,
                        selectedID: route.item.id, baseURL: route.baseURL, sessionID: route.sessionID,
                        authorization: route.authorization, accountScope: imageRatioScope)
                        .background(AttachmentLifetimeKeeper(lifetime: route.lifetime).frame(width: 0, height: 0))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { interaction.requestDismissal(id: route.id) }
                        } }
                }
            case .preview:
                if let url = route.localURL {
                    NavigationStack {
                        AttachmentQuickLook(url: url, lifetime: route.lifetime)
                            .navigationTitle(route.item.label)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { interaction.requestDismissal(id: route.id) }
                            } }
                    }
                }
            case .share:
                if let url = route.localURL {
                    ShareSheet(items: [url], lifetime: route.lifetime) { interaction.requestDismissal(id: route.id) }
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    private func imageTile(_ item: HistoryAttachment, tile: Bool) -> some View {
        InlineImageView(raw: item.path, baseURL: baseURL, sessionID: sessionID,
            ratio: imageRatios.ratio(for: item.path), onTap: { _ in start(item, .image) },
            ratioScope: imageRatioScope, tile: tile, authorization: authorization)
            .overlay(alignment: .topLeading) {
                if interaction.state.failure?.ticket.itemID == item.id {
                    Button("重试打开") { start(item, .image) }
                        .font(.caption).padding(8).frame(minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                }
            }
    }

    private func start(_ item: HistoryAttachment, _ intent: AttachmentInteractionState.Intent) {
        interaction.start(item, intent: intent, baseURL: baseURL, sessionID: sessionID,
                          images: items.filter { $0.kind == .image },
                          authorization: authorization)
    }

    /// 外部链接：不自动下载（避免任意 URL 的请求面），但给一个明确的打开入口。
    /// 之前这里只有一句「未自动加载」，用户看到说明却没有任何可做的动作。
    private func remoteRow(_ item: HistoryAttachment) -> some View {
        let openable = Self.webURL(item.path)
        return HStack(spacing: 6) {
            Image(systemName: "link").font(.caption)
            Text(item.label).font(.caption).lineLimit(1)
            Spacer(minLength: 6)
            if openable != nil {
                Button {
                    if let url = Self.webURL(item.path) { openURL(url) }
                } label: {
                    Label("打开", systemImage: "safari")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .accessibilityLabel("在浏览器打开 \(item.label)")
            } else {
                Text("外部链接，未自动加载").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
        .contextMenu {
            Button("复制路径", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.path }
            if openable != nil {
                Button("在浏览器打开", systemImage: "safari") {
                    if let url = Self.webURL(item.path) { openURL(url) }
                }
            }
        }
    }

    /// 规则本身在 `ExternalLinkPolicy`（不依赖 UIKit，可离线测）。
    static func webURL(_ raw: String) -> URL? { ExternalLinkPolicy.openableURL(raw) }

    private func fileCard(_ item: HistoryAttachment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { start(item, .preview) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.kind.symbol)
                            .font(.title3).foregroundStyle(AppTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.callout).lineLimit(1)
                            Text(kindLabel(item.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("预览 \(item.label)")
                .disabled(interaction.state.isBusy)
                Button { start(item, .share) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body).foregroundStyle(AppTheme.accent)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("分享 \(item.label)")
                .disabled(interaction.state.isBusy)
            }
            if interaction.state.pending?.itemID == item.id {
                HStack(spacing: 8) {
                    if let total = interaction.state.expectedBytes, total > 0 {
                        ProgressView(value: min(1, Double(interaction.state.receivedBytes) / Double(total)))
                            .frame(maxWidth: 80)
                    } else { ProgressView().controlSize(.small) }
                    Text("正在下载 · \(byteLabel(interaction.state.receivedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("取消") { interaction.cancel() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            failureView(item)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("下载并分享", systemImage: "square.and.arrow.up") { start(item, .share) }
                .disabled(interaction.state.isBusy)
            Button("复制路径", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.path }
        }
    }

    @ViewBuilder private func failureView(_ item: HistoryAttachment) -> some View {
        if let failure = interaction.state.failure, failure.ticket.itemID == item.id {
            VStack(alignment: .leading, spacing: 0) {
                Text(failure.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button("重试") { start(item, failure.ticket.intent) }.frame(minWidth: 44, minHeight: 44)
                    Button("关闭") { interaction.cancel() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func kindLabel(_ kind: AttachmentKind) -> String {
        switch kind {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .pdf: return "PDF"
        case .spreadsheet: return "表格"
        case .archive: return "压缩包"
        case .document: return "文档"
        case .other: return "文件"
        }
    }
}

private struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL
    let lifetime: AttachmentPresentationLifetime
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = LeasedQuickLookController()
        controller.lifetime = lifetime
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private final class LeasedQuickLookController: QLPreviewController {
    var lifetime: AttachmentPresentationLifetime?
}

/// An image sheet has no exported URL, but retains the cross-row reservation
/// independently of its presenting message for the lifetime of its UI surface.
private struct AttachmentLifetimeKeeper: UIViewRepresentable {
    let lifetime: AttachmentPresentationLifetime
    func makeUIView(context: Context) -> LifetimeView { LifetimeView(lifetime: lifetime) }
    func updateUIView(_ uiView: LifetimeView, context: Context) {}
    final class LifetimeView: UIView {
        let lifetime: AttachmentPresentationLifetime
        init(lifetime: AttachmentPresentationLifetime) { self.lifetime = lifetime; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

struct HistoryAttachmentGallery: View {
    let items: [HistoryAttachment]
    let selectedID: String
    let baseURL: URL
    let sessionID: String
    /// 预览/下载该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var authorization: AttachmentAuthorization = .cookieOnly
    var accountScope: String = ""

    var body: some View {
        ImageGallery(entries: items.map { .init(id: $0.id, title: $0.label) }, selectedID: selectedID) { entry, active in
            if let item = items.first(where: { $0.id == entry.id }) {
                HistoryAttachmentPreview(path: item.path, baseURL: baseURL, sessionID: sessionID,
                                authorization: authorization, accountScope: accountScope, isActive: active)
            }
        }
    }
}

private struct HistoryAttachmentPreview: View {
    let path: String
    let baseURL: URL
    let sessionID: String
    var authorization: AttachmentAuthorization = .cookieOnly
    var accountScope: String = ""
    var isActive = true
    @StateObject private var sharing = ImageOriginalShare()
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var saveError: String?
    @State private var saved = false
    @State private var saving = false
    @State private var attempt = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    /// Consent belongs to an exact source, account and session. Page swipes
    /// cannot silently grant third-party network access to another image.
    @State private var approvedExternalSource: String?
    @State private var saveNotice: String?

    private var sourceIdentity: String {
        "\(accountScope)|\(baseURL.absoluteString)|\(sessionID)|\(path)"
    }
    private var isExternalImage: Bool {
        guard InlineImageKind.isHTTP(path) else { return false }
        guard let policy = try? AttachmentPreviewPolicy(
            baseURL: baseURL, authorization: authorization) else { return true }
        return policy.internalFilePath(from: path) == nil
    }
    private var awaitingConsent: Bool {
        isExternalImage && approvedExternalSource != sourceIdentity
    }

    var body: some View {
        Group {
            if awaitingConsent {
                ContentUnavailableView {
                    Label("第三方图片", systemImage: "hand.tap")
                } description: {
                    Text("此图片位于其他网站。确认后仅加载当前图片，不向第三方发送实例密钥。")
                } actions: {
                    Button("加载此图片") { approvedExternalSource = sourceIdentity }
                        .frame(minHeight: 44)
                }
            } else if let image {
                ZoomableImagePage(image: image, accessibilityLabel: "附件图片") {
                    VStack(alignment: .trailing, spacing: 8) {
                        saveButton(image)
                        if let saveNotice {
                            Text(saveNotice)
                                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .accessibilityLabel(saveNotice)
                        }
                    }
                }
                // 保存不做成 toolbar 项：这个 sheet 的外层已经用 .confirmationAction
                // 放了「完成」，同一位置会把子视图的 .topBarTrailing 覆盖掉，真机上
                // 表现为右上角只剩一个「完成」。改成浮层后不依赖 toolbar 合并，
                // 也与输入框预览（SecureAttachmentPreview）的保存按钮一致。
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法预览", systemImage: "photo.badge.exclamationmark")
                } description: { Text(errorMessage) } actions: {
                    Button("重试") { attempt += 1 }.frame(minHeight: 44)
                }
            } else { ProgressView("正在读取…") }
        }
        .task(id: "\(sourceIdentity)|\(attempt)|\(isActive)|\(awaitingConsent)") {
            guard isActive, !awaitingConsent else { image = nil; return }
            await load()
        }
        .onChange(of: isActive) { _, active in if !active { retireWork() } }
        .onDisappear { retireWork(); image = nil }
        .sheet(item: $sharing.file) { file in
            ShareSheet(items: [file.url], lifetime: file.lifetime) { sharing.file = nil }
        }
        .alert(saveError != nil ? "未能保存图片" : "未能分享原图",
            isPresented: Binding(get: { saveError != nil || sharing.error != nil }, set: {
                if !$0 { saveError = nil; sharing.error = nil }
            })) {
            Button("知道了", role: .cancel) { saveError = nil; sharing.error = nil }
        } message: { Text(saveError ?? sharing.error ?? "") }
    }

    private func load() async {
        image = nil; errorMessage = nil
        do {
            let decoded = try await RemoteImageLoader.shared.load(
                path: path, baseURL: baseURL, sessionID: sessionID,
                accountScope: accountScope, authorization: authorization)
            try Task.checkCancellation()
            image = decoded
        } catch is CancellationError {
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    /// 44pt 圆形保存按钮，浮在图片右上角。触控目标与视觉尺寸分开：
    /// 视觉是 44pt 圆，点按区域由 padding 保证不贴边。
    private func saveButton(_ image: UIImage) -> some View {
        ImagePreviewActions(saved: saved, saving: saving, sharing: sharing.preparing,
            savedLabel: saveNotice ?? "已保存到相册",
            save: { save(image) },
            share: { sharing.prepare(name: (path as NSString).lastPathComponent) { try await originalBytes() } })
    }

    private func retireWork() {
        saveGeneration = UUID(); saveTask?.cancel(); saveTask = nil; saving = false
        sharing.cancelPreparation()
    }

    private func save(_ image: UIImage) {
        guard !saving, !saved else { return }
        saving = true; saveError = nil; saveNotice = nil
        let generation = saveGeneration
        saveTask = Task {
            do {
                var permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if permission == .notDetermined { permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
                try Task.checkCancellation()
                guard permission == .authorized || permission == .limited else {
                    throw NSError(domain: "HermesPhotoSave", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "没有添加到相册的权限，请在系统设置中允许 Hermes 添加照片后重试。"])
                }
                // 面板里显示的是 1600px 降采样；保存优先写回原始字节，取不到才回退预览图。
                let original = try? await originalBytes()
                try Task.checkCancellation()
                var savedOriginal = false
                if let original, !original.isEmpty {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.uniformTypeIdentifier = Self.uniformTypeIdentifier(for: original) ?? "public.image"
                        request.addResource(with: .photo, data: original, options: options)
                    }
                    savedOriginal = true
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }
                try Task.checkCancellation()
                guard generation == saveGeneration else { return }
                saved = true
                saveNotice = savedOriginal ? "原图已保存到相册" : "已保存预览图到相册"
                UIAccessibility.post(notification: .announcement, argument: saveNotice)
            } catch is CancellationError {
            } catch {
                if generation == saveGeneration, !Task.isCancelled { saveError = error.localizedDescription }
            }
            if generation == saveGeneration { saving = false; saveTask = nil }
        }
    }

    /// 预览只保留降采样，原图字节按与预览完全相同的路由重新取一次（不常驻内存）。
    private func originalBytes() async throws -> Data {
        let policy = try AttachmentPreviewPolicy(baseURL: baseURL, authorization: authorization)
        if let internalPath = policy.internalFilePath(from: path) {
            return try await AttachmentPreviewLoader(policy: policy)
                .imageData(sessionID: sessionID, attachment: Self.uploaded(path: internalPath))
        }
        guard !InlineImageKind.hasUnsafeScheme(path) else { throw AttachmentError.unsafeURL }
        if InlineImageKind.isHTTP(path), let url = URL(string: path) {
            // 外部图片与预览一致：无凭据、无 Cookie、按 MIME 与字节上限校验。
            return try await RemoteImageDataLoader().data(for: url)
        }
        return try await AttachmentPreviewLoader(policy: policy)
            .imageData(sessionID: sessionID, attachment: Self.uploaded(path: path))
    }

    private static func uploaded(path: String) -> UploadedAttachment {
        let mime = AttachmentKind.mime(forPathExtension: InlineImageKind.pathExtension(path))
        return UploadedAttachment(name: (path as NSString).lastPathComponent, path: path,
            size: 0, mime: mime.isEmpty ? "image/png" : mime, isImage: true)
    }

    /// UTI 从原始字节的图像类型取（HEIC 等不被误标成 JPEG），取不到才用 public.image。
    nonisolated private static func uniformTypeIdentifier(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var lifetime: AttachmentPresentationLifetime? = nil
    var onFinish: () -> Void = {}
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = LeasedActivityController(activityItems: items, applicationActivities: nil)
        controller.lifetime = lifetime
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { onFinish() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class LeasedActivityController: UIActivityViewController {
    var lifetime: AttachmentPresentationLifetime?
}
