import SwiftUI
import UIKit

/// 可复用的大图页：UIScrollView + UIImageView，系统惯性、边界回弹与捏合都比
/// 纯 SwiftUI 手势稳。双击在 1× 与 2.5× 之间切换（以点击点为中心），捏合范围
/// 1×–4×，松手低于 1× 自动回弹；图片小于视口时按 1:1 居中，不放大。
/// overlay 由调用方提供（关闭/保存按钮）。这里刻意不做下滑关闭，会与图片 pan 冲突。
struct ZoomableImagePage<Overlay: View>: View {
    private let image: UIImage
    private let accessibilityLabel: String
    private let overlay: Overlay

    init(image: UIImage, accessibilityLabel: String,
         @ViewBuilder overlay: () -> Overlay) {
        self.image = image
        self.accessibilityLabel = accessibilityLabel
        self.overlay = overlay()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZoomingImageScrollView(image: image, accessibilityLabel: accessibilityLabel,
                                   reduceMotion: reduceMotion)
            overlay
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

private struct ZoomingImageScrollView: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    /// A-04：双击缩放的动画必须响应「减弱动态效果」。
    var reduceMotion: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = FittingScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = accessibilityLabel
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let coordinator = context.coordinator
        coordinator.scrollView = scrollView
        coordinator.imageView = imageView
        coordinator.reduceMotion = reduceMotion
        scrollView.onBoundsChange = { [weak coordinator] size in coordinator?.layout(in: size) }
        coordinator.adopt(image: image, label: accessibilityLabel)
        coordinator.layout(in: scrollView.bounds.size)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // 只在内容/文案真正变化时替换；既有缩放不会被 body 刷新重置。
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.adopt(image: image, label: accessibilityLabel)
        context.coordinator.layout(in: scrollView.bounds.size)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        /// A-04：为 true 时所有缩放跳转都不带动画。
        var reduceMotion = false
        private var lastBoundsSize = CGSize.zero
        private var lastImage: UIImage?

        func adopt(image: UIImage, label: String) {
            guard let imageView else { return }
            if imageView.accessibilityLabel != label { imageView.accessibilityLabel = label }
            guard lastImage !== image else { return }
            lastImage = image
            imageView.image = image
            scrollView?.setZoomScale(1, animated: false)
            lastBoundsSize = .zero
        }

        /// 仅视口尺寸真正变化（首次布局、旋转）时重排；
        /// 尺寸没变就完全不动缩放，否则每次 body 刷新都会把用户缩放弹回。
        func layout(in size: CGSize) {
            guard size.width > 1, size.height > 1, size != lastBoundsSize,
                  let scrollView, let imageView, let image = imageView.image else { return }
            lastBoundsSize = size
            scrollView.setZoomScale(1, animated: false)
            let natural = image.size
            guard natural.width > 0, natural.height > 0 else { return }
            // 小图不放大：最多 1:1 点尺寸；大图按视口等比缩小。
            let fit = min(1, min(size.width / natural.width, size.height / natural.height))
            let fitted = CGSize(width: max(1, floor(natural.width * fit)),
                                height: max(1, floor(natural.height * fit)))
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            center(in: scrollView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(in: scrollView) }

        /// 内容小于视口时用对称 contentInset 居中；缩回 1× 后同样回到中央。
        private func center(in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let horizontal = max(0, (bounds.width - content.width) / 2)
            let vertical = max(0, (bounds.height - content.height) / 2)
            let inset = UIEdgeInsets(top: vertical, left: horizontal,
                                     bottom: vertical, right: horizontal)
            if scrollView.contentInset != inset { scrollView.contentInset = inset }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            // A-04：减弱动态效果时不播缩放动画，直接跳到目标倍率。
            let animated = !reduceMotion
            let target = min(2.5, scrollView.maximumZoomScale)
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
                return
            }
            let tap = gesture.location(in: imageView)
            let imageBounds = imageView.bounds
            // 目标视口按 2.5× 计算，再夹进图片边界；图片小于目标视口时退化为整图缩放。
            let width = min(imageBounds.width, scrollView.bounds.width / target)
            let height = min(imageBounds.height, scrollView.bounds.height / target)
            let x = min(max(0, tap.x - width / 2), max(0, imageBounds.width - width))
            let y = min(max(0, tap.y - height / 2), max(0, imageBounds.height - height))
            scrollView.zoom(to: CGRect(x: x, y: y, width: width, height: height), animated: animated)
        }
    }
}

/// 旋转/分屏时 SwiftUI 不保证回调 updateUIView，改用 bounds 变化驱动重排。
private final class FittingScrollView: UIScrollView {
    var onBoundsChange: ((CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onBoundsChange?(bounds.size)
    }
}
