import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct ImageGalleryEntry: Identifiable {
    let id: String
    let title: String
}

/// One pager and navigation treatment for sent images and composer previews.
/// Only its selected page is allowed to fetch/decode image content.
struct ImageGallery<Content: View>: View {
    private let entries: [ImageGalleryEntry]
    private let content: (ImageGalleryEntry, Bool) -> Content
    @State private var selection: ImageGallerySelection

    init(entries: [ImageGalleryEntry], selectedID: String,
         @ViewBuilder content: @escaping (ImageGalleryEntry, Bool) -> Content) {
        let initial = ImageGallerySelection(ids: entries.map(\.id), selected: selectedID)
        self.entries = initial.ids.compactMap { id in entries.first(where: { $0.id == id }) }
        self.content = content
        _selection = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: Binding(get: { selection.selected }, set: { selection.select($0) })) {
            ForEach(entries) { entry in content(entry, selection.selected == entry.id).tag(entry.id) }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle(entries.first(where: { $0.id == selection.selected })?.title ?? "图片")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.ids.count > 1 {
                HStack {
                    Button { selection.step(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .disabled(selection.index == 0).accessibilityLabel("上一张图片")
                    Spacer()
                    Text("\(selection.index + 1) / \(selection.ids.count)")
                        .font(.footnote.monospacedDigit())
                        .accessibilityLabel("第 \(selection.index + 1) 张，共 \(selection.ids.count) 张图片")
                    Spacer()
                    Button { selection.step(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }
                    .disabled(selection.index + 1 == selection.ids.count).accessibilityLabel("下一张图片")
                }
                .buttonStyle(.plain).padding(.horizontal, 12)
                .background(.ultraThinMaterial)
            }
        }
    }
}

/// The actual system share controller retains the lease independently of its
/// source row. File cleanup happens only after the final owner goes away.
struct SharedTemporaryFile: Identifiable {
    let id = UUID()
    let url: URL
    let lifetime: AttachmentPresentationLifetime
    init(url: URL) {
        self.url = url
        lifetime = AttachmentPresentationLifetime {
            AttachmentDownloadFiles.remove(url)
            // Reply sharing creates a unique containing directory. Remove the
            // empty parent after the file lease ends; downloaded attachment
            // directories are shared and remain untouched.
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent.hasPrefix("HermesReply-") {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }
}

struct ImagePreviewActions: View {
    let saved: Bool
    let saving: Bool
    let sharing: Bool
    let save: () -> Void
    let share: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: share) {
                actionIcon("square.and.arrow.up", busy: sharing)
            }
            .disabled(sharing || saving)
            .accessibilityLabel(sharing ? "正在准备原图分享" : "分享原图")
            Button(action: save) {
                actionIcon(saved ? "checkmark" : "square.and.arrow.down", busy: saving)
            }
            .disabled(saved || saving || sharing)
            .accessibilityLabel(saving ? "正在保存图片" : saved ? "已保存到相册" : "保存原图")
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    private func actionIcon(_ symbol: String, busy: Bool) -> some View {
        Group {
            if busy { ProgressView() }
            else { Image(systemName: symbol).font(.body.weight(.semibold)) }
        }
        .frame(width: 44, height: 44)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
    }
}

@MainActor final class ImageOriginalShare: ObservableObject {
    @Published var file: SharedTemporaryFile?
    @Published private(set) var preparing = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    deinit { task?.cancel() }

    /// 闭包必须弱捕获 self：`task` 是实例属性，强捕获会形成
    /// `self -> task -> self` 的环，对象永不释放、`deinit` 永不执行，
    /// 取消也就不会发生。
    func prepare(name: String, load: @escaping @MainActor () async throws -> Data) {
        guard !preparing, file == nil else { return }
        generation &+= 1
        let token = generation
        preparing = true
        error = nil
        task = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                let writer = Task.detached(priority: .utility) { try Self.stage(data, name: name) }
                let url = try await withTaskCancellationHandler(operation: { try await writer.value },
                                                                onCancel: { writer.cancel() })
                guard let self, !Task.isCancelled, token == self.generation else {
                    AttachmentDownloadFiles.remove(url); return
                }
                self.file = SharedTemporaryFile(url: url)
            } catch is CancellationError {
            } catch {
                if let self, token == self.generation, !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
            if let self, token == self.generation {
                self.preparing = false
                self.task = nil
            }
        }
    }

    func cancelPreparation() {
        generation &+= 1
        task?.cancel(); task = nil
        preparing = false
        // Do not remove a file still presented by a share extension.
    }

    nonisolated private static func stage(_ data: Data, name: String) throws -> URL {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else {
            throw AttachmentError.unsupportedPreview
        }
        let raw = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        let stem = String(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0)
        }.map(String.init).joined().prefix(60))
        let leaf = (stem.isEmpty ? "图片" : stem) + "." + ext
        let url = try AttachmentDownloadFiles.createDestination(leaf: leaf)
        do {
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return url
        } catch { AttachmentDownloadFiles.remove(url); throw error }
    }
}
