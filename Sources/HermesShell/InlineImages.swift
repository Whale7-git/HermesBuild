import SwiftUI
import UIKit
import ImageIO

/// Internal and external images share a three-operation transfer/decode budget.
/// Only credential-free external URLs share in-flight work and decoded cache.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    /// 认证图片（会话内附件）的解码缓存。
    /// 原先这类图片完全没有缓存，且池键用 `UUID()`，等于每次滚动到同一张图都要
    /// 重新请求 WebUI + 重新解码：长会话来回滚动会持续打满网络与 CPU。
    /// 现在键是「来源 + 会话 + 归一化路径」，同图复用；数量/体积都有上限。
    private let authenticatedCache = NSCache<NSString, UIImage>()
    private enum WorkKey: Hashable, Sendable {
        case remote(URL)
        /// 认证请求按稳定键合并在途工作，而不是每次一个全新 UUID。
        case authenticated(String)
    }
    private let work = SharedAsyncResourcePool<WorkKey, DecodedRemoteImage>(maxConcurrent: 3)
    private var memoryObserver: NSObjectProtocol?

    // UIImage is immutable here: it is decoded once off-main, then read by UI.
    private struct DecodedRemoteImage: @unchecked Sendable { let image: UIImage }

    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 32 * 1024 * 1024
        authenticatedCache.countLimit = 48
        authenticatedCache.totalCostLimit = 24 * 1024 * 1024
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cache.removeAllObjects()
                self?.authenticatedCache.removeAllObjects()
            }
        }
    }

    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url.absoluteString as NSString) }

    /// 账号/实例切换时调用：认证图片可能属于上一个账号，必须整片清掉，
    /// 不能靠「会话 ID 恰好不同」来碰运气。
    func purgeAuthenticated() { authenticatedCache.removeAllObjects() }

    func load(_ url: URL) async throws -> UIImage {
        try Task.checkCancellation()
        if let hit = cached(url) { return hit }
        guard ExternalInlineImageURLPolicy.mayRequest(url) else {
            throw AttachmentError.unsafeURL
        }
        let result = try await work.value(for: .remote(url)) {
            // The transport checks status, raster MIME and the byte limit while
            // receiving; no unbounded URLSession.data(for:) allocation occurs.
            let data = try await RemoteImageDataLoader().data(for: url)
            return try await Self.decode(data)
        }
        try Task.checkCancellation()
        let image = result.image
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
        return image
    }

    /// Recognized same-origin API URLs are normalized to their opaque file
    /// reference and rebound to the currently captured session. Other HTTP URLs
    /// remain credential-free.
    ///
    /// 认证结果现在会缓存：键 = 账号作用域 + baseURL + sessionID + 归一化路径。
    /// 四者共同决定「哪一份凭据能读到哪一张图」，因此跨账号/跨会话都不会串图。
    ///
    /// `accountScope` 为空表示调用方没有账号维度（例如单次打开的原图预览）：
    /// 这种情况**不缓存**，宁可多请求一次，也不冒跨账号复用图片的风险。
    func load(path raw: String, baseURL: URL, sessionID: String,
              accountScope: String = "",
              authorization: AttachmentAuthorization = .cookieOnly) async throws -> UIImage {
        try Task.checkCancellation()
        let policy = try AttachmentPreviewPolicy(baseURL: baseURL, authorization: authorization)
        let internalPath = policy.internalFilePath(from: raw)
        if internalPath == nil, InlineImageKind.isHTTP(raw), let url = URL(string: raw) {
            return try await load(url)
        }
        guard !InlineImageKind.hasUnsafeScheme(raw) else { throw AttachmentError.unsafeURL }
        let path = internalPath ?? raw
        let key = accountScope.isEmpty ? nil
            : Self.authenticatedKey(scope: accountScope, baseURL: baseURL, sessionID: sessionID, path: path)
        if let key, let hit = authenticatedCache.object(forKey: key as NSString) { return hit }
        let result = try await work.value(for: .authenticated(key ?? UUID().uuidString)) {
            let policy = try AttachmentPreviewPolicy(baseURL: baseURL, authorization: authorization)
            let mime = AttachmentKind.mime(forPathExtension: InlineImageKind.pathExtension(path))
            let attachment = UploadedAttachment(name: (path as NSString).lastPathComponent, path: path,
                size: 0, mime: mime.isEmpty ? "image/png" : mime, isImage: true)
            let data = try await AttachmentPreviewLoader(policy: policy)
                .imageData(sessionID: sessionID, attachment: attachment)
            return try await Self.decode(data)
        }
        try Task.checkCancellation()
        let image = result.image
        if let key {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            authenticatedCache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    /// 稳定的认证图片键。路径可能带 query/fragment 或不同前缀，这里只做
    /// 「同账号 + 同来源 + 同会话 + 同字符串路径」的精确复用，不猜测等价关系。
    private static func authenticatedKey(scope: String, baseURL: URL, sessionID: String,
                                         path: String) -> String {
        scope + "\u{1}" + baseURL.absoluteString + "\u{1}" + sessionID + "\u{1}" + path
    }

    nonisolated private static func decode(_ data: Data) async throws -> DecodedRemoteImage {
        try Task.checkCancellation()
        guard let image = await Task.detached(priority: .userInitiated, operation: {
            InlineImageDecoder.downsample(data, maxPixel: 1600)
        }).value else { throw AttachmentError.unsupportedPreview }
        try Task.checkCancellation()
        return DecodedRemoteImage(image: image)
    }
}

enum InlineImageDecoder {
    /// 降采样后再建 UIImage，绝不整幅解码不可信尺寸。
    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 100_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 按真实纵横比排版的图片。
///
/// 比例在创建时冻结：加载完成只把真实比例写进缓存，不改变这一行的行高；
/// 下次进入会话（新的快照）才会用上新的比例。未知比例用固定 4:3 占位。
struct InlineImageView: View {
    let raw: String
    let baseURL: URL
    let sessionID: String
    var onTap: ((UIImage) -> Void)?
    /// 真实比例（高/宽）回写；只影响下次进入会话的布局。
    var ratioScope: String
    var tile: Bool
    /// 预览该走哪种认证：网关实例没有 cookie，必须带 Bearer。
    var authorization: AttachmentAuthorization = .cookieOnly

    @State private var layoutRatio: CGFloat?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var failureReason: String?
    @State private var attempt = 0
    // Consent belongs to one exact source; a recycled SwiftUI row cannot carry
    // approval to a different URL or another account/session.
    @State private var approvedExternalSource: String?

    init(raw: String, baseURL: URL, sessionID: String, ratio: CGFloat? = nil,
         onTap: ((UIImage) -> Void)? = nil, ratioScope: String = "", tile: Bool = false,
         authorization: AttachmentAuthorization = .cookieOnly) {
        self.raw = raw
        self.baseURL = baseURL
        self.sessionID = sessionID
        self.onTap = onTap
        self.ratioScope = ratioScope
        self.tile = tile
        self.authorization = authorization
        _layoutRatio = State(initialValue: InlineImageLayout.normalized(ratio))
    }

    private var sourceIdentity: String {
        "\(baseURL.absoluteString)|\(sessionID)|\(ratioScope)|\(raw)"
    }
    private var identity: String { "\(sourceIdentity)|\(attempt)" }
    private var externalImage: Bool {
        guard InlineImageKind.isHTTP(raw) else { return false }
        guard let policy = try? AttachmentPreviewPolicy(
            baseURL: baseURL, authorization: authorization) else { return true }
        return policy.internalFilePath(from: raw) == nil
    }
    private var awaitingConsent: Bool {
        externalImage && approvedExternalSource != sourceIdentity
    }
    private var isLong: Bool { InlineImageLayout.isLong(ratio: layoutRatio) }

    var body: some View {
        box
            .background(AppTheme.softFill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.hairline))
            .contentShape(Rectangle())
            .onTapGesture {
                if awaitingConsent {
                    approvedExternalSource = sourceIdentity
                    attempt += 1
                } else if let image { onTap?(image) }
                else if failed { attempt += 1 }
            }
            .task(id: identity) {
                guard !awaitingConsent else { return }
                await load()
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("hermes-chat-image")
            .accessibilityValue(awaitingConsent ? "需要确认外部连接"
                : image != nil ? "已加载" : failed ? "加载失败" : "正在加载")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if awaitingConsent {
                    approvedExternalSource = sourceIdentity
                    attempt += 1
                } else if let image { onTap?(image) }
                else if failed { attempt += 1 }
            }
    }

    private var accessibilityText: String {
        if awaitingConsent { return "外部图片，轻点后才会连接第三方服务器" }
        if failed { return "图片加载失败：\(failureReason ?? "未知原因")，轻点重试" }
        return isLong ? "长图，轻点查看" : "图片"
    }

    @ViewBuilder
    private var box: some View {
        AttachmentImageFrame(ratio: layoutRatio, tile: tile) {
            if tile {
                GeometryReader { proxy in
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            .clipped()
                    } else { content.frame(width: proxy.size.width, height: proxy.size.height) }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if isLong {
                        Text("长图").font(.caption2).padding(6)
                            .background(.ultraThinMaterial, in: Capsule()).padding(6)
                    }
                }
            } else if isLong {
                longBox
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 长图固定高度并裁掉下半部分：只显示开头，比例仍然来自真实像素。
    private var longBox: some View {
        ZStack(alignment: .top) {
            if let image, let ratio = layoutRatio {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: proxy.size.width,
                               height: max(proxy.size.width * ratio, InlineImageLayout.longHeight))
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: InlineImageLayout.longHeight)
        .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Color.black.opacity(0.18)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 36)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("长图")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var content: some View {
        if awaitingConsent {
            VStack(spacing: 6) {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                Text("外部图片 · 点按加载").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else if failed {
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                Text("图片无法加载：\(failureReason ?? "未知原因")")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                Text("轻点重试").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func load() async {
        image = nil; failed = false; failureReason = nil
        let writeToken = ImageRatioStore.shared.token(scope: ratioScope)
        do {
            let loaded = try await RemoteImageLoader.shared.load(path: raw, baseURL: baseURL,
                sessionID: sessionID, accountScope: ratioScope, authorization: authorization)
            try Task.checkCancellation()
            image = loaded
            // 只写缓存，不动 layoutRatio：当前行高必须保持不变。
            if loaded.size.width > 0, loaded.size.height > 0 {
                ImageRatioStore.shared.remember(token: writeToken, sessionID: sessionID,
                    path: raw, ratio: loaded.size.height / loaded.size.width)
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                failureReason = AttachmentImageFailurePresentation.reason(for: error)
                failed = true
            }
        }
    }
}
