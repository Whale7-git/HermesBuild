import SwiftUI
import UIKit
import ImageIO

struct AttachmentEditSelection: Identifiable {
    let id: UUID
    let sessionID: String
    let generation: UUID
    let name: String
    let data: Data
}

enum AttachmentImageRenderer {
    /// 编辑链只处理 scale == 1 的位图。
    ///
    /// 裁剪用 `cgImage` 的**像素**坐标，画布用 `image.size` 的**点**坐标；
    /// 两者只有在 scale == 1 时才等价。任何引入 scale ≠ 1 的源图（例如
    /// `UIImage(named:)` 或改过 `UIGraphicsImageRendererFormat.scale`）都会让
    /// 裁剪框与手指位置错位一倍，所以这里显式归一化，不依赖调用方自觉。
    static func normalized(_ image: UIImage) -> UIImage {
        guard image.scale != 1 else { return image }
        let pixels = CGSize(width: image.size.width * image.scale,
                            height: image.size.height * image.scale)
        return draw(size: pixels) { _ in
            image.draw(in: CGRect(origin: .zero, size: pixels))
        }
    }

    static func render(data: Data, steps: [ImageEditStep], maxEdge: Int) throws -> UIImage {
        try Task.checkCancellation()
        guard steps.count <= ImageEditHistory.limit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AttachmentError.unsupportedPreview }
        // 统一成 scale == 1，锁住「点 == 像素」这条不变量。
        var image = normalized(UIImage(cgImage: cg))
        for step in steps {
            try Task.checkCancellation()
            image = try autoreleasepool {
                switch step {
                case .rotateClockwise:
                    let old = image
                    return draw(size: CGSize(width: old.size.height, height: old.size.width)) { context in
                        context.translateBy(x: old.size.height / 2, y: old.size.width / 2)
                        context.rotate(by: .pi / 2)
                        old.draw(in: CGRect(x: -old.size.width / 2, y: -old.size.height / 2,
                            width: old.size.width, height: old.size.height))
                    }
                case .crop(let crop):
                    guard crop.valid, let pixels = image.cgImage else { throw AttachmentError.invalidMetadata }
                    let rect = CGRect(x: crop.x * Double(pixels.width), y: crop.y * Double(pixels.height),
                        width: crop.width * Double(pixels.width), height: crop.height * Double(pixels.height))
                        .integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
                    guard let cropped = pixels.cropping(to: rect) else { throw AttachmentError.invalidMetadata }
                    return UIImage(cgImage: cropped)   // scale == 1
                case .mark(let mark):
                    let old = image
                    return draw(size: old.size) { context in
                        old.draw(at: .zero)
                        draw(mark, size: old.size, in: context)
                    }
                }
            }
        }
        return image
    }

    static func export(data: Data, steps: [ImageEditStep]) throws -> Data {
        let image = try render(data: data, steps: steps, maxEdge: 4096)
        // Flatten transparency onto white and normalize orientation/metadata.
        let flattened = draw(size: image.size) { _ in image.draw(at: .zero) }
        for quality in [0.90, 0.75, 0.60] {
            try Task.checkCancellation()
            if let encoded = flattened.jpegData(compressionQuality: quality),
               encoded.count < AttachmentMultipart.defaultMaxBytes - 8192 { return encoded }
        }
        throw AttachmentError.tooLarge
    }

    private static func draw(size: CGSize, actions: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { output in
            UIColor.white.setFill()
            output.fill(CGRect(origin: .zero, size: size))
            actions(output.cgContext)
        }
    }

    private static func color(_ value: ImageEditColor) -> UIColor {
        switch value {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .black: return .black
        }
    }

    private static func draw(_ mark: ImageEditMark, size: CGSize, in context: CGContext) {
        let points = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = points.first, let last = points.last else { return }
        let width = max(2, min(size.width, size.height) * 0.008)
        context.setStrokeColor(color(mark.color).cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if mark.kind == .rectangle {
            context.stroke(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                width: max(1, abs(last.x - first.x)), height: max(1, abs(last.y - first.y))))
            return
        }
        context.move(to: first)
        if mark.kind == .pen {
            for point in points.dropFirst() { context.addLine(to: point) }
            if points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
        } else {
            context.addLine(to: last)
        }
        context.strokePath()
        if mark.kind == .arrow {
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = width * 4
            for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + delta), y: last.y - length * sin(angle + delta)))
            }
            context.strokePath()
        }
    }
}

struct AttachmentImageEditor: View {
    let selection: AttachmentEditSelection
    let onCancel: () -> Void
    let onSave: (Data) throws -> Void
    private enum Tool: String, CaseIterable {
        case pen = "画笔", arrow = "箭头", rectangle = "方框", crop = "裁剪"
        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .crop: return "crop"
            }
        }
        var mark: ImageEditMarkKind {
            switch self { case .arrow: return .arrow; case .rectangle: return .rectangle; default: return .pen }
        }
    }
    @State private var history = ImageEditHistory()
    @State private var image: UIImage?
    @State private var tool = Tool.pen
    @State private var color = ImageEditColor.red
    @State private var points: [ImageEditPoint] = []
    @State private var crop = ImageEditCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var busy = false
    @State private var saving = false
    @State private var error: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var ticket = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("编辑结果保存为静态 JPEG，最长边不超过 4096 像素；不会修改相册原图。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
                ZStack {
                    Color.black.opacity(0.04)
                    if let image { canvas(image) }
                    if busy { ProgressView(saving ? "正在保存…" : "正在处理…").padding().background(.regularMaterial, in: Capsule()) }
                }
                if tool == .crop {
                    HStack {
                        Menu("范围") {
                            Button("全图") { crop = .full }
                            Button("上半部") { crop = .init(x: 0, y: 0, width: 1, height: 0.5) }
                            Button("下半部") { crop = .init(x: 0, y: 0.5, width: 1, height: 0.5) }
                        }.frame(minWidth: 44, minHeight: 44).disabled(busy)
                        Text("拖动两角调整").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("应用裁剪") { commit(.crop(crop)); tool = .pen }
                            .frame(minHeight: 44).disabled(busy)
                    }.padding(.horizontal)
                }
                controls
            }
            .navigationTitle("编辑图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { retire(); onCancel() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(busy || image == nil || !history.canUndo || tool == .crop)
                }
            }
            .task { preview() }
            .onDisappear { retire() }
            .interactiveDismissDisabled(busy)
            .alert("未能完成编辑", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Tool.allCases, id: \.self) { value in
                        Button { tool = value; points = [] } label: {
                            Label(value.rawValue, systemImage: value.symbol)
                                .padding(.horizontal, 10).frame(minHeight: 44)
                                .background(tool == value ? AppTheme.accent.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        }.accessibilityAddTraits(tool == value ? .isSelected : [])
                    }
                    Button { commit(.rotateClockwise) } label: {
                        Label("旋转", systemImage: "rotate.right").frame(minHeight: 44)
                    }
                }.padding(.horizontal, 12)
            }
            HStack {
                ForEach(ImageEditColor.allCases, id: \.self) { value in
                    Button { color = value } label: {
                        Circle().fill(swiftColor(value)).frame(width: 22, height: 22)
                            .padding(8).overlay(Circle().stroke(color == value ? Color.primary : Color.clear, lineWidth: 2).padding(4))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel(colorName(value))
                        .accessibilityAddTraits(color == value ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button("撤销", systemImage: "arrow.uturn.backward") { history.undo(); points = []; preview() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(!history.canUndo)
                Button("还原", systemImage: "arrow.counterclockwise") { history.reset(); points = []; preview() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(!history.canUndo)
            }.padding(.horizontal, 8)
        }
        .buttonStyle(.plain).disabled(busy)
        .padding(.vertical, 8).background(.bar)
    }

    private func canvas(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            let factor = min(proxy.size.width / max(1, image.size.width), proxy.size.height / max(1, image.size.height))
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            ZStack {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                Canvas { context, canvas in
                    guard let first = points.first, let last = points.last else { return }
                    func point(_ p: ImageEditPoint) -> CGPoint { CGPoint(x: p.x * canvas.width, y: p.y * canvas.height) }
                    let a = point(first), b = point(last)
                    let lineWidth = max(2, min(image.size.width, image.size.height) * 0.008) * factor
                    var path = Path()
                    if tool == .rectangle {
                        path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                    } else {
                        path.move(to: a)
                        if tool == .pen { for p in points.dropFirst() { path.addLine(to: point(p)) } }
                        else {
                            path.addLine(to: b)
                            let angle = atan2(b.y - a.y, b.x - a.x)
                            let length = lineWidth * 4
                            for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                                path.move(to: b)
                                path.addLine(to: CGPoint(x: b.x - length * cos(angle + delta), y: b.y - length * sin(angle + delta)))
                            }
                        }
                    }
                    context.stroke(path, with: .color(swiftColor(color)), style: StrokeStyle(
                        lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
                .allowsHitTesting(false)
                if tool == .crop { cropOverlay(size) }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "image-crop")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !busy, tool != .crop else { return }
                    let p = ImageEditPoint(x: value.location.x / max(1, size.width), y: value.location.y / max(1, size.height))
                    if tool == .pen {
                        if points.count < 2048 { points.append(p) }
                    } else {
                        let start = ImageEditPoint(x: value.startLocation.x / max(1, size.width), y: value.startLocation.y / max(1, size.height))
                        points = [start, p]
                    }
                }
                .onEnded { _ in
                    guard !busy, tool != .crop, !points.isEmpty else { return }
                    let mark = ImageEditMark(kind: tool.mark, color: color, points: points)
                    points = []
                    commit(.mark(mark))
                }, including: tool == .crop ? .subviews : .all)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func cropOverlay(_ size: CGSize) -> some View {
        let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height,
            width: crop.width * size.width, height: crop.height * size.height)
        return ZStack {
            Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect) }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().stroke(.white, lineWidth: 2).frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
            cropHandle(size, leading: true).position(x: rect.minX, y: rect.minY)
            cropHandle(size, leading: false).position(x: rect.maxX, y: rect.maxY)
        }
    }

    private func cropHandle(_ size: CGSize, leading: Bool) -> some View {
        Circle().fill(.white).frame(width: 18, height: 18).frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("image-crop"))
                .onChanged { value in
                    // The named space belongs to the full canvas, not the handle.
                    let x = min(1, max(0, value.location.x / max(1, size.width)))
                    let y = min(1, max(0, value.location.y / max(1, size.height)))
                    if leading {
                        let right = crop.x + crop.width, bottom = crop.y + crop.height
                        let left = min(x, right - 0.08), top = min(y, bottom - 0.08)
                        crop = .init(x: max(0, left), y: max(0, top), width: right - max(0, left), height: bottom - max(0, top))
                    } else {
                        crop = .init(x: crop.x, y: crop.y, width: max(0.08, x - crop.x), height: max(0.08, y - crop.y))
                    }
                })
            .accessibilityLabel(leading ? "裁剪左上角" : "裁剪右下角")
    }

    private func commit(_ step: ImageEditStep) {
        guard history.append(step) else { error = "最多保留40步编辑，请撤销部分操作后继续。"; return }
        crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        preview()
    }

    private func preview() {
        renderTask?.cancel()
        let next = UUID(); ticket = next; busy = true
        let data = selection.data, steps = history.steps
        renderTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                try AttachmentImageRenderer.render(data: data, steps: steps, maxEdge: 1600)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, ticket == next else { return }
                image = result
            } catch is CancellationError { }
            catch { if ticket == next { self.error = error.localizedDescription } }
            if ticket == next { busy = false; renderTask = nil }
        }
    }

    private func save() {
        guard !busy, history.canUndo else { return }
        let next = UUID(); ticket = next; busy = true; saving = true
        let data = selection.data, steps = history.steps
        renderTask = Task {
            let work = Task.detached(priority: .userInitiated) { try AttachmentImageRenderer.export(data: data, steps: steps) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, ticket == next else { return }
                try onSave(result)
            } catch is CancellationError { }
            catch { if ticket == next { self.error = error.localizedDescription } }
            if ticket == next { busy = false; saving = false; renderTask = nil }
        }
    }

    private func retire() { ticket = UUID(); renderTask?.cancel(); renderTask = nil }
    private func swiftColor(_ color: ImageEditColor) -> Color {
        switch color { case .red: return .red; case .yellow: return .yellow; case .blue: return .blue; case .black: return .black }
    }
    private func colorName(_ color: ImageEditColor) -> String {
        switch color { case .red: return "红色"; case .yellow: return "黄色"; case .blue: return "蓝色"; case .black: return "黑色" }
    }
}
