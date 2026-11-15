import AVFoundation
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import UIKit
import Photos
import PhotosUI
// PhotosUI's SwiftUI overlay is a cross-import module. The Linux xtool
// typecheck driver does not discover it from `import PhotosUI` alone.
import _PhotosUI_SwiftUI

/// PhotosUI can export an asset as a temporary file. Copy it into our own
/// temporary directory before the provider's security scope ends, then inspect
/// only the image header and stream the bytes into the attachment batch.
private struct AttachmentPickerFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let source = received.file
            let suffix = source.pathExtension.isEmpty ? "img" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("HermesPicker-\(UUID().uuidString)")
                .appendingPathExtension(suffix)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return Self(url: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Adapter only: core chat/service files are deliberately not changed by this feature.
@MainActor final class AttachmentComposerModel: ObservableObject {
    @Published private(set) var batch: AttachmentBatch
    @Published private(set) var isImporting = false
    @Published private(set) var editingID: UUID?
    @Published var errorMessage: String?
    /// nil 表示 `attachmentBaseURL` 没通过 `AttachmentPreviewPolicy` 的校验
    /// （非 http(s)、带 userinfo/query、含 `..` 段）。此时禁用图片预览，
    /// 而不是用 `try!` 崩掉整个输入框（F-37）。
    let previewLoader: AttachmentPreviewLoader?
    private let coordinator: AttachmentUploadCoordinator
    private let draftStore: ChatDraftStore
    private let onPersistenceResult: (LocalStoreWriteResult) -> Void
    private var importTask: Task<Void, Never>?
    private var importGeneration = UUID()

    deinit { importTask?.cancel() }

    init(api: HermesBackend, sessionID: String, draftStore: ChatDraftStore,
         onPersistenceResult: @escaping (LocalStoreWriteResult) -> Void = { _ in }) {
        // 上传走 `api.attachmentBaseURL`，路由与认证都由后端声明：
        // WebUI 是 `api/upload` + cookie，网关是 `v1/files` + Bearer。
        // （此前这里写着「网关没有 multipart 端点」，是错的——网关的
        //  `v1/files` 由 attachments 插件提供，实测 POST 返回 201。）
        let baseURL = api.attachmentBaseURL
        // AppState 已校验过 API URL；这里仍按可恢复失败处理，不假设上游一定合法。
        // P1：预览必须带**预览通道**的认证，不是上传通道的。
        //
        // 原调用只传 `baseURL`，于是网关实例的预览请求永远不带 Bearer——
        // 网关的 `_check_auth` 只认 `Authorization: Bearer`，图片预览全部 401。
        // 其他预览点（`NativeChatView+MessageList` / `Panels`）都正确使用
        // `attachmentPreviewAuthorization`：WebUI 走 cookie，网关才带 Bearer。
        // 只有这一处漏了，补上同一个属性。
        self.previewLoader = (try? AttachmentPreviewPolicy(baseURL:baseURL,
                                                           authorization:api.attachmentPreviewAuthorization))
            .map { AttachmentPreviewLoader(policy: $0) }
        self.batch = AttachmentBatch(sessionID:sessionID)
        self.draftStore = draftStore
        self.onPersistenceResult = onPersistenceResult
        // 诊断日志：不再自动上报整段日志；上传失败只做本地留底。
        self.coordinator = AttachmentUploadCoordinator(sessionID:sessionID) { sessionID, draft, reportProgress in
            // Bind the scope now: the upload may finish after the user switched
            // sessions, and its outcome must not land in the newer scope.
            let logToken = RuntimeLogRecorder.shared.currentToken()
            let multipart = try await Task.detached(priority:.userInitiated) {
                try AttachmentMultipart(sessionID:sessionID, filename:draft.name, mime:draft.mime, data:draft.data)
            }.value
            try Task.checkCancellation()
            let request = try multipart.request(baseURL:baseURL, route:api.attachmentUploadRoute,
                                                authorization: api.attachmentAuthorization)
            let cookieCount = HTTPCookieStorage.shared.cookies(for: baseURL)?.count ?? 0
            RuntimeLogRecorder.shared.record(.info, "upload",
                "start name=\(draft.name) size=\(draft.data.count) mime=\(draft.mime) cookie=\(cookieCount)",
                token: logToken)
            do {
                // Same authenticated URLSession and cookie store as every other native API call.
                // 进度按整数百分比节流：传输回调可能每几 KB 来一次，
                // 每次都写 @Published 会让整条 chip 反复重建。
                let gate = ProgressGate()
                let attachment = try UploadedAttachment(data: await api.uploadAttachment(request) { progress in
                    let fraction = progress.fraction ?? 0
                    guard gate.shouldReport(fraction) else { return }
                    Task { @MainActor in reportProgress(fraction) }
                })
                RuntimeLogRecorder.shared.record(.info, "upload",
                    "ok name=\(draft.name) path=\(attachment.path) size=\(attachment.size)",
                    token: logToken)
                return attachment
            } catch {
                RuntimeLogRecorder.shared.record(.error, "upload",
                    "fail name=\(draft.name) err=\(error.localizedDescription)",
                    token: logToken)
                RuntimeLogRecorder.shared.flush(sessionID: sessionID, baseURL: baseURL, token: logToken)
                throw error
            }
        }
        coordinator.onChange = { [weak self] batch in
            guard let self else { return }
            self.batch = batch
            self.persist(batch)
        }
        restorePersistedDraft()
    }

    var isEditing: Bool { editingID != nil }
    var canSend: Bool { !isImporting && !isEditing && batch.canSend }
    func payload(for sessionID: String) throws -> [UploadedAttachment] {
        guard !isImporting, !isEditing else { throw AttachmentError.invalidMetadata }
        return try batch.payload(for:sessionID)
    }

    private func persist(_ batch: AttachmentBatch) {
        let value = batch.persistedValue
        guard !value.items.isEmpty else {
            onPersistenceResult(draftStore.saveAttachmentDraft(nil))
            return
        }
        guard let data = try? JSONEncoder().encode(value) else {
            onPersistenceResult(.failed(.encoding))
            return
        }
        guard draftStore.attachmentDraftFits(data) else {
            errorMessage = "附件总大小已接近上限，无法保存草稿；发送成功前请勿关闭此页面。"
            onPersistenceResult(.failed(.payloadTooLarge))
            return
        }
        onPersistenceResult(draftStore.saveAttachmentDraft(data))
    }

    private func restorePersistedDraft() {
        let loaded = draftStore.loadAttachmentDraft()
        if let failure = loaded.result.failure {
            errorMessage = "草稿附件无法恢复，请重新添加。"
            onPersistenceResult(loaded.result)
            return
        }
        guard let data = loaded.value else { return }
        guard let value = try? JSONDecoder().decode(PersistedAttachmentBatch.self, from: data) else {
            errorMessage = "草稿附件数据已损坏，请重新添加。"
            onPersistenceResult(.failed(.corruptFile))
            return
        }
        do {
            try coordinator.restorePersisted(value)
            batch = coordinator.batch
            persist(batch)
            for item in batch.items where item.canResumeUpload {
                retry(item.id)
            }
        } catch {
            errorMessage = "草稿附件无法恢复：\(error.localizedDescription)"
            onPersistenceResult(.failed(.corruptFile))
        }
    }
    func importFiles(_ result: Result<[URL], Error>) {
        guard !isImporting else { return }
        let urls: [URL]
        do { urls = try result.get() }
        catch {
            // Cancelling the system picker is not a failed upload.
            if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
            return
        }
        guard !urls.isEmpty else { return }
        guard urls.count + batch.items.count <= batch.maxCount else {
            errorMessage = "最多添加 \(batch.maxCount) 个附件"; return
        }
        let generation = importGeneration
        let sessionID = batch.sessionID
        isImporting = true
        importTask = Task { [weak self] in
            for url in urls {
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try AttachmentFileImport.read(url) }.value
                    try Task.checkCancellation()
                    guard let self, self.importGeneration == generation, self.batch.sessionID == sessionID else { return }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    try self.coordinator.add(name: url.lastPathComponent, mime: mime, data: data)
                } catch is CancellationError { break }
                catch {
                    guard let self, self.importGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
            guard let self, self.importGeneration == generation else { return }
            self.isImporting = false
            self.importTask = nil
        }
    }

    /// Photos picker returns data blobs, not file URLs. Infer a stable name and
    /// MIME from the item's preferred type; never fabricate an upload progress.
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !isImporting else { return }
        guard !items.isEmpty else { return }
        guard items.count + batch.items.count <= batch.maxCount else {
            errorMessage = "最多添加 \(batch.maxCount) 个附件"; return
        }
        let generation = importGeneration
        let sessionID = batch.sessionID
        isImporting = true
        importTask = Task { [weak self] in
            for item in items {
                do {
                    // 只接受相册里声明为图片的项：先看类型，再取字节，避免为无关内容读数据。
                    guard item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) else {
                        throw AttachmentPhotoImportError.notImage
                    }
                    // PhotosUI can hand us a temporary file. Inspect that file's
                    // image header before reading its full bytes into memory.
                    // The Data fallback remains for providers that do not export
                    // a file representation.
                    let picked = try? await item.loadTransferable(type: AttachmentPickerFile.self)
                    let data: Data
                    if let picked {
                        defer { picked.remove() }
                        let oversized = await Task.detached(priority: .userInitiated) {
                            AttachmentComposerModel.exceedsPixelLimit(at: picked.url)
                        }.value
                        guard !oversized else { throw AttachmentPhotoImportError.dimensionsTooLarge }
                        data = try await Task.detached(priority: .userInitiated) {
                            try AttachmentFileImport.read(picked.url)
                        }.value
                    } else {
                        guard let loaded = try await item.loadTransferable(type: Data.self),
                              !loaded.isEmpty else { continue }
                        let oversized = await Task.detached(priority: .userInitiated) {
                            AttachmentComposerModel.exceedsPixelLimit(loaded)
                        }.value
                        guard !oversized else { throw AttachmentPhotoImportError.dimensionsTooLarge }
                        data = loaded
                    }
                    guard !data.isEmpty else { continue }
                    try Task.checkCancellation()
                    guard let self, self.importGeneration == generation, self.batch.sessionID == sessionID else { return }
                    let type = item.supportedContentTypes.first
                    // 与 importFiles 一致：推断不出就回退 octet-stream，不硬编码 image/jpeg。
                    // 否则类型未知的相册项会被误标成 JPEG，服务端按扩展名判 MIME 时也不匹配。
                    let mime = type?.preferredMIMEType ?? "application/octet-stream"
                    let ext = type?.preferredFilenameExtension ?? "bin"
                    let name = "photo-\(UUID().uuidString.prefix(8)).\(ext)"
                    try self.coordinator.add(name: name, mime: mime, data: data)
                } catch is CancellationError { break }
                catch {
                    guard let self, self.importGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
            guard let self, self.importGeneration == generation else { return }
            self.isImporting = false
            self.importTask = nil
        }
    }

    /// 相机拍摄结果复用相册导入的校验与上传通路：同样走 coordinator.add，
    /// 不新增上传路径。nil 表示取消拍摄，直接丢弃。
    func importCameraImage(_ data: Data?) {
        guard !isImporting, let data, !data.isEmpty else { return }
        guard batch.items.count + 1 <= batch.maxCount else {
            errorMessage = "最多添加 \(batch.maxCount) 个附件"; return
        }
        // 与 importPhotos 同一 100MP 图头阈值与文案，不复制魔法数。
        guard !Self.exceedsPixelLimit(data) else {
            errorMessage = AttachmentPhotoImportError.dimensionsTooLarge.localizedDescription
            return
        }
        let name = "photo-\(UUID().uuidString.prefix(8)).jpg"
        do { try coordinator.add(name: name, mime: "image/jpeg", data: data) }
        // 超过 20MB 由上传统一的 AttachmentMultipart 上限拦下，文案与相册导入一致。
        catch { errorMessage = error.localizedDescription }
    }

    /// 只读图头像素尺寸；超过 100MP（与预览降采样的保护阈值一致）直接拒绝。
    /// 读不出尺寸时返回 false：保持原有导入行为，不额外拦下可上传的文件。
    nonisolated static func exceedsPixelLimit(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return false }
        return width.doubleValue * height.doubleValue > 100_000_000
    }

    /// Inspect a picker's temporary file without materializing its full Data.
    nonisolated static func exceedsPixelLimit(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
              [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return false }
        return width.doubleValue * height.doubleValue > 100_000_000
    }

    func retry(_ id: UUID) {
        do { try coordinator.retry(id) } catch { errorMessage = error.localizedDescription }
    }
    func remove(_ id: UUID) { coordinator.remove(id) }

    func beginEditing(_ id: UUID) async -> AttachmentEditSelection? {
        guard !isEditing, !isImporting,
              let draft = batch.items.first(where: { $0.id == id }),
              AttachmentPreviewPolicy.rasterMIMEs.contains(draft.mime.lowercased()) else { return nil }
        editingID = id
        defer { editingID = nil }

        var data = draft.data
        if data.isEmpty {
            guard let previewLoader,
                  case .ready(let uploaded) = draft.state else {
                errorMessage = "原图暂时不可用，无法继续编辑。"
                return nil
            }
            do {
                data = try await previewLoader.imageData(sessionID: batch.sessionID,
                                                         attachment: uploaded)
            } catch {
                errorMessage = "读取原图失败：\(error.localizedDescription)"
                return nil
            }
        }
        guard !data.isEmpty else {
            errorMessage = "原图暂时不可用，无法继续编辑。"
            return nil
        }
        guard !Self.exceedsPixelLimit(data) else {
            errorMessage = AttachmentPhotoImportError.dimensionsTooLarge.localizedDescription
            return nil
        }
        return AttachmentEditSelection(id: id, sessionID: batch.sessionID,
            generation: importGeneration, name: draft.name, data: data)
    }

    func saveEdit(_ selection: AttachmentEditSelection, data: Data) throws {
        guard editingID == selection.id, importGeneration == selection.generation,
              batch.sessionID == selection.sessionID else { throw AttachmentError.invalidMetadata }
        let stem = String((selection.name as NSString).deletingPathExtension.prefix(80))
        let name = (stem.isEmpty ? "image" : stem) + "-edited-" + UUID().uuidString.prefix(8) + ".jpg"
        try coordinator.replace(selection.id, name: name, mime: "image/jpeg", data: data)
    }

    func cancelEditing() { editingID = nil }
    /// Also call on instance change (recreate this model for a NEW API/base URL).
    /// Do NOT clear until chat/start acceptance is confirmed; ambiguous sends retain attachments.
    func reset(sessionID: String) {
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        isImporting = false
        editingID = nil
        errorMessage = nil
        onPersistenceResult(draftStore.saveAttachmentDraft(nil))
        coordinator.reset(sessionID:sessionID)
    }

    /// P1：编辑队列项时，把已上传的附件引用恢复回输入区。
    ///
    /// 队列项里存的是服务端引用（`path`），不需要重新上传；只把这些引用
    /// 恢复成 `.ready` 状态的草稿，让再次发送时附件不丢。
    func restoreReady(_ payloads: [ChatAttachmentPayload]) {
        coordinator.restoreReady(payloads)
    }
}

/// Native Files picker supports files AND images. No full-page WebUI / WebView.
/// Pass isLocked=true for the entire captured-submission/acceptance window.
struct AttachmentComposerBar: View {
    @ObservedObject var model: AttachmentComposerModel
    var isLocked = false
    var showsPicker = true
    var showsItems = true
    var launchPicker = 0
    @State private var askAttachmentSource = false
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var choosingCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var preview: PreviewSelection?
    @State private var editing: AttachmentEditSelection?
    private struct PreviewSelection: Identifiable {
        let id = UUID()
        let attachment: UploadedAttachment
        let sessionID: String
        let images: [UploadedAttachment]
    }
    var body: some View {
        VStack(alignment:.leading, spacing:8) {
            if showsPicker {
                HStack {
                    Menu {
                        Button { choosingPhotos = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                        if CameraPicker.isAvailable {
                            // 已被拒绝时只给一行提示，不再触发系统弹窗；模拟器/无相机设备自动隐藏。
                            Button { openCamera() } label: { Label("拍照", systemImage: "camera") }
                        }
                        Button { choosingFiles = true } label: { Label("选择文件", systemImage: "folder") }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.body.weight(.medium))
                            .foregroundStyle(model.batch.items.isEmpty ? Color.secondary : AppTheme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("添加附件")
                    .accessibilityHint("选择照片、拍照或文件")
                    .disabled(isLocked || model.isImporting || model.batch.items.count >= model.batch.maxCount)
                }
            }
            if showsItems, model.isImporting { ProgressView("正在读取附件…").font(.caption) }
            if showsItems, !model.batch.items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment:.top, spacing:8) {
                        ForEach(model.batch.items) { draft in
                            AttachmentChip(draft:draft, isLocked:isLocked,
                                remove:{ model.remove(draft.id) }, retry:{ model.retry(draft.id) },
                                edit: {
                                    Task {
                                        editing = await model.beginEditing(draft.id)
                                    }
                                },
                                preview:{ attachment in
                                    // 预览地址校验失败（previewLoader 为 nil）时不给入口，
                                    // 否则会打开一个永远读不到图的页面。
                                    guard model.previewLoader != nil else { return }
                                    var images = model.batch.items.compactMap { draft -> UploadedAttachment? in
                                        if case .ready(let value) = draft.state, value.isImage { return value }
                                        return nil
                                    }
                                    if !images.contains(where: { $0.path == attachment.path }) { images.append(attachment) }
                                    preview = PreviewSelection(attachment:attachment, sessionID:model.batch.sessionID, images:images)
                                })
                        }
                    }
                }
            }
            if showsItems, let error = model.errorMessage {
                HStack(alignment:.top) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength:4)
                    Button("关闭", systemImage:"xmark") { model.errorMessage = nil }.labelStyle(.iconOnly).frame(minWidth:44, minHeight:44)
                }
            }
        }
        .onChange(of: launchPicker) { _, trigger in
            if trigger > 0 && !isLocked { askAttachmentSource = true }
        }
        .confirmationDialog("添加附件", isPresented: $askAttachmentSource,
                            titleVisibility: .visible) {
            Button("从相册选择", systemImage: "photo.on.rectangle") {
                choosingPhotos = true
            }
            if CameraPicker.isAvailable {
                Button("拍照", systemImage: "camera") { openCamera() }
            }
            Button("选择文件", systemImage: "folder") { choosingFiles = true }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented:$choosingFiles, allowedContentTypes:[.item], allowsMultipleSelection:true) { result in
            // A picker opened before the send lock must not mutate a submitted draft.
            if !isLocked { model.importFiles(result) }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems,
                     maxSelectionCount: max(1, model.batch.maxCount - model.batch.items.count),
                     matching: .images)
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            if !isLocked { model.importPhotos(newItems) }
            photoItems = []
        }
        .fullScreenCover(isPresented:$choosingCamera) {
            CameraPicker { data in
                choosingCamera = false
                // 拍摄期间进入提交锁时丢弃，不把照片插进已提交的批次。
                if !isLocked { model.importCameraImage(data) }
            }
        }
        .sheet(item:$preview) { item in
            NavigationStack {
                Group {
                    if let loader = model.previewLoader {
                        ImageGallery(entries: item.images.map { .init(id: $0.path, title: $0.name) },
                                     selectedID: item.attachment.path) { entry, active in
                            if let attachment = item.images.first(where: { $0.path == entry.id }) {
                                SecureAttachmentPreview(attachment:attachment, sessionID:item.sessionID,
                                                        loader:loader, isActive:active)
                            }
                        }
                    } else {
                        // 与上方预览失败态同一套组件，文案说明「为什么没有预览入口」。
                        ContentUnavailableView {
                            Label("无法预览", systemImage: "photo.badge.exclamationmark")
                        } description: {
                            Text("当前实例的附件地址不合法，已禁用图片预览。")
                        }
                    }
                }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { preview = nil } } }
            }
        }
        .fullScreenCover(item: $editing, onDismiss: { model.cancelEditing() }) { item in
            AttachmentImageEditor(selection: item,
                onCancel: { editing = nil },
                onSave: { data in
                    guard !isLocked else { throw AttachmentError.invalidMetadata }
                    try model.saveEdit(item, data: data)
                    editing = nil
                })
        }
        .onChange(of: model.isEditing) { _, active in if !active { editing = nil } }
        .onChange(of: isLocked) { _, locked in
            if locked, editing != nil { model.cancelEditing(); editing = nil }
        }
    }

    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            // 系统已在设置里关闭：只走现有 errorMessage 文案，不反复弹窗。
            model.errorMessage = "无法使用相机，请在系统设置中允许 Hermes 访问相机"
        default:
            // .notDetermined 交给 UIImagePickerController 自己弹系统授权提示。
            choosingCamera = true
        }
    }
}

private struct AttachmentChip: View {
    let draft: AttachmentDraft
    let isLocked: Bool
    let remove: () -> Void
    let retry: () -> Void
    let edit: () -> Void
    let preview: (UploadedAttachment) -> Void

    /// 只有「已上传 + 图片 + 可安全解码的 raster 格式」才允许点开预览。
    /// 队列中、上传中、失败态一律没有预览入口。
    private var previewable: UploadedAttachment? {
        guard case .ready(let attachment) = draft.state,
              attachment.isImage,
              AttachmentPreviewPolicy.rasterMIMEs.contains(attachment.mime.lowercased()) else { return nil }
        return attachment
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // 预览主体用点击手势而不是 Button：删除/重试是它内部的独立 Button，
            // 再套一层 Button 会形成嵌套并吞掉子按钮的点击。
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: draft.mime.hasPrefix("image/") ? "photo" : "doc")
                    Text(draft.name).font(.callout).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(draft.byteCount), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                status
            }
            .frame(maxWidth: 200, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if let attachment = previewable { preview(attachment) } }
            .modifier(AttachmentPreviewAccessibility(name: draft.name, enabled: previewable != nil,
                activate: { if let attachment = previewable { preview(attachment) } }))

            if AttachmentPreviewPolicy.rasterMIMEs.contains(draft.mime.lowercased()) {
                Button(action: edit) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(isLocked)
                .accessibilityLabel("编辑图片 \(draft.name)")
            }

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .accessibilityLabel("移除附件 \(draft.name)")
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var status: some View {
        switch draft.state {
        case .queued:
            // 编辑保存后字节已替换、正在重新上传：与首次等待区分，避免看起来没生效。
            Text(draft.reuploading ? "正在重新上传编辑版…" : "等待上传").font(.caption)
        case .uploading(let fraction):
            // 有确定比例就画进度条 + 百分比；`fraction` 为 0 且还没收到首个
            // 回调时仍显示不确定态，避免「0%」看起来像卡住。
            VStack(alignment: .leading, spacing: 2) {
                if fraction > 0 {
                    ProgressView(value: fraction).frame(width: 140)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(AttachmentProgressPresentation.text(
                    for: AttachmentTransferProgress(receivedBytes: Int(fraction * 100),
                                                    expectedBytes: 100)) ?? "正在上传…")
                    .font(.caption)
            }
            .accessibilityLabel("正在上传 \(draft.name)，已完成 \(Int(fraction * 100))%")
        case .ready:
            Label("已上传", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            // 编辑版重新上传失败要和首次上传失败区分：否则用户不知道重试的是编辑版。
            Text(draft.reuploading ? "编辑版上传失败：\(message)" : message)
                .font(.caption).foregroundStyle(.red).lineLimit(3)
                .frame(maxWidth: 200, alignment: .leading)
            Button("重试", action: retry)
                .frame(minHeight: 44)
                .disabled(isLocked)
                .accessibilityLabel("重试上传 \(draft.name)")
        }
    }
}

/// 上传进度的节流闸：只在整数百分比变化时放行。
///
/// 传输回调可能每几 KB 就来一次（3MB 实测 46 次），每次都跳主线程写
/// `@Published` 会让整条 chip 反复重建。语义与
/// `AttachmentProgressPresentation.shouldUpdate` 一致，但这里只需要
/// 「上一次放行的百分比」一个整数。
private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func shouldReport(_ fraction: Double) -> Bool {
        let percent = Int((fraction * 100).rounded(.down))
        lock.lock(); defer { lock.unlock() }
        guard percent != last else { return false }
        last = percent
        return true
    }
}

/// 主区域只在可预览时合并成一个按钮元素；否则保留名称、大小与状态三段朗读。
private struct AttachmentPreviewAccessibility: ViewModifier {
    let name: String
    let enabled: Bool
    let activate: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("附件 \(name)，已上传，轻点预览")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate() }
        } else {
            content
        }
    }
}

/// Created only after an explicit preview tap. External Markdown URLs are not accepted.
struct SecureAttachmentPreview: View {
    /// 预览始终用 1600px 降采样；原始字节只在当前页存活，超过该阈值就不保留。
    private static let maxRetainedOriginalBytes = 40 * 1024 * 1024

    let attachment: UploadedAttachment
    let sessionID: String
    let loader: AttachmentPreviewLoader
    var isActive = true
    @StateObject private var sharing = ImageOriginalShare()
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var originalData: Data?
    @State private var originalTooLarge = false
    @State private var saving = false
    @State private var saved = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    @State private var attempt = 0
    private var identity: String { "\(loader.policy.baseURL.absoluteString)|\(sessionID)|\(attachment.path)|\(attempt)|\(isActive)" }
    var body: some View {
        Group {
            if let image {
                ZoomableImagePage(image: image, accessibilityLabel: attachment.name) { saveOverlay }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法预览", systemImage: "photo.badge.exclamationmark")
                } description: { Text(errorMessage) } actions: {
                    Button("重试") { attempt += 1 }.frame(minHeight: 44)
                }
            } else { ProgressView("正在安全读取图片…") }
        }
        .task(id:identity) {
            image = nil; errorMessage = nil; originalData = nil; originalTooLarge = false
            guard isActive else { return }
            do {
                let data = try await loader.imageData(sessionID:sessionID, attachment:attachment)
                let decoded = await Task.detached(priority:.userInitiated) { Self.thumbnail(data) }.value
                try Task.checkCancellation()
                guard let decoded else { throw AttachmentError.unsupportedPreview }
                // 超大原图不留常驻副本，保存时再取一次；不要静默丢弃，给出可见状态。
                if data.count > Self.maxRetainedOriginalBytes { originalTooLarge = true } else { originalData = data }
                image = decoded
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .onChange(of: isActive) { _, active in if !active { retireWork() } }
        .onDisappear { retireWork() }
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

    private func retireWork() {
            image = nil
            originalData = nil
            originalTooLarge = false
            saveGeneration = UUID(); saveTask?.cancel(); saveTask = nil; saving = false
            sharing.cancelPreparation()
    }

    @ViewBuilder private var saveOverlay: some View {
        VStack(alignment:.trailing, spacing:8) {
            ImagePreviewActions(saved: saved, saving: saving, sharing: sharing.preparing,
                save: saveOriginal, share: {
                    let cached = originalData
                    sharing.prepare(name: attachment.name) {
                        if let cached { return cached }
                        return try await loader.imageData(sessionID:sessionID, attachment:attachment)
                    }
                })
            if originalTooLarge {
                Text("原图较大，保存时会重新下载")
                    .font(.caption2)
                    .padding(.horizontal,8).padding(.vertical,4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private func saveOriginal() {
        guard !saving, !saved, let displayed = image else { return }
        saving = true; saveError = nil
        let cached = originalData
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
                // 超过保留阈值（或首次读取已丢弃）时在这里重取一次；仍取不到就回退预览图。
                // 这里的失败**可忽略**：保存仍会成功，只是降级为预览图，
                // 且完成后的提示文案会明确写「已保存预览图」，用户能感知到差别。
                var original = cached
                if original == nil {
                    original = try? await loader.imageData(sessionID:sessionID, attachment:attachment)
                }
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
                        PHAssetChangeRequest.creationRequestForAsset(from: displayed)
                    }
                }
                try Task.checkCancellation()
                guard generation == saveGeneration else { return }
                saved = true
                UIAccessibility.post(notification: .announcement,
                                     argument: savedOriginal ? "原图已保存到相册" : "已保存预览图到相册")
            } catch is CancellationError {
            } catch {
                if generation == saveGeneration, !Task.isCancelled { saveError = error.localizedDescription }
            }
            if generation == saveGeneration { saving = false; saveTask = nil }
        }
    }

    /// 原图 UTI 取自字节流的图像类型（HEIC/GIF 也能取对），取不到才用 public.image。
    nonisolated private static func uniformTypeIdentifier(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }

    /// Downsample before UIImage creation; never allocate the full untrusted image dimensions.
    nonisolated private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 100_000_000 else { return nil }
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                                      kCGImageSourceCreateThumbnailWithTransform:true,
                                      kCGImageSourceThumbnailMaxPixelSize:1600,
                                      kCGImageSourceShouldCacheImmediately:true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return nil }
        return UIImage(cgImage:image)
    }
}

/// 相机（UIImagePickerController）包装：只拍照，不编辑、不写相册。
/// 模拟器与无相机设备的 isAvailable 为 false，菜单项自动隐藏。
private struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    /// 成功时回传已降采样的 JPEG 字节；取消时回传 nil。
    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture:onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data?) -> Void
        /// 系统回调可能重复投递，保证只回传一次。
        private var finished = false
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !finished else { return }
            finished = true
            onCapture((info[.originalImage] as? UIImage).flatMap { cameraJPEGData(from: $0) })
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !finished else { return }
            finished = true
            onCapture(nil)
        }
    }
}

/// 先按长边 2048 渲染再编码 JPEG：12MP 原图不整幅进入编码/上传。
/// 结果只随本次拍摄存在，上传完成或移除后由附件批次释放。
private func cameraJPEGData(from image: UIImage, maxLongEdge: CGFloat = 2048, quality: CGFloat = 0.9) -> Data? {
    let longEdge = max(image.size.width, image.size.height)
    let target: UIImage
    if longEdge > maxLongEdge, longEdge > 0 {
        let scale = maxLongEdge / longEdge
        let size = CGSize(width:(image.size.width * scale).rounded(), height:(image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        target = UIGraphicsImageRenderer(size:size, format:format).image { _ in
            image.draw(in: CGRect(origin:.zero, size:size))
        }
    } else { target = image }
    return target.jpegData(compressionQuality: quality)
}

/// 相册导入的前置拒绝原因；沿用 errorMessage 的文案通路，不新增 UI。
private enum AttachmentPhotoImportError: LocalizedError {
    case notImage, dimensionsTooLarge
    var errorDescription: String? {
        switch self {
        case .notImage: return "只能从相册导入图片"
        case .dimensionsTooLarge: return "图片尺寸过大，无法导入"
        }
    }
}
