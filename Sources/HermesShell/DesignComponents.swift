import SwiftUI
import UIKit

/// 代码绘制的机器人头像。避免依赖 AppIcon 资源查找路径；
/// XcodeGen 项目将图标 PNG 作为 bundle 资源，而非统一 Asset Catalog。
struct HermesAvatar: View {
    var size: CGFloat = 20
    /// 深色底 + 浅色五官；小尺寸时保证对比度。
    var tint: Color = AppTheme.accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: max(0.6, size * 0.04))
            head
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 简笔机器人：一对方眼 + 嘴，尺寸够小也能辨认。
    private var head: some View {
        let eyeW = size * 0.14
        let eyeH = size * 0.18
        let gap = size * 0.12
        let mouthW = size * 0.30
        return VStack(spacing: size * 0.10) {
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: eyeW * 0.35)
                    .fill(tint).frame(width: eyeW, height: eyeH)
                RoundedRectangle(cornerRadius: eyeW * 0.35)
                    .fill(tint).frame(width: eyeW, height: eyeH)
            }
            RoundedRectangle(cornerRadius: mouthW * 0.5)
                .fill(tint.opacity(0.85))
                .frame(width: mouthW, height: max(0.8, size * 0.055))
        }
    }
}

struct HermesLogo: View {
    var size: CGFloat = 32
    var body: some View {
        // 优先用真实 App 图标；取不到就退回代码绘制的机器人头像，绝不渲染空白。
        if let image = Self.bundledIcon {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                .accessibilityHidden(true)
        } else {
            HermesAvatar(size: size)
        }
    }

    /// 从应用 bundle 的实际 PNG 资源读取；缺失时使用代码绘制的头像。
    private static let bundledIcon: UIImage? = {
        for name in ["AppIcon60x60@3x", "AppIcon60x60@2x", "AppIcon60x60"] {
            if let path = Bundle.main.path(forResource: name, ofType: "png"),
               let image = UIImage(contentsOfFile: path) { return image }
        }
        return nil
    }()
}

/// Minimal navigation chrome: retain a 44pt hit target without decorative
/// permanent bubbles around every toolbar action.
struct ChromeIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

struct HermesPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(enabled ? AppTheme.onAction : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(enabled ? AppTheme.action : AppTheme.softFill,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 列表行容器：0.5pt 发丝线只在这里画一次，行内容不再各自描边。
/// 线从左起 74（图标 12+36+12+12 的视觉对齐点）到右 12，与文字块对齐。
struct SessionRowContainer<Content: View>: View {
    private let showsSeparator: Bool
    private let content: Content

    init(showsSeparator: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsSeparator = showsSeparator
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if showsSeparator {
                Rectangle()
                    .fill(AppTheme.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 74)
                    .padding(.trailing, 12)
            }
        }
    }
}

/// Shared rows keep regular, searched and archived conversations consistent.
struct SessionRowContent: View {
    let title: String
    var preview: String? = nil
    var date: Date? = nil
    var pinned = false
    var running = false
    var task: SessionTaskSummary? = nil
    var selected = false
    /// 命中类型 / 归档标记，渲染成时间右侧的小胶囊；为空时不占位。
    var badge: String? = nil
    /// 搜索高亮词：只标摘要里的首个命中，大小写不敏感。
    var highlight: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pinned ? "pin.fill" : "bubble.left.and.bubble.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? AppTheme.accent : Color.secondary)
                .frame(width: 28, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                // 运行点与首行文字同轴（center）：放进基线会贴在字脚下像句号。
                HStack(alignment: .center, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if running || task != nil {
                        Circle()
                            .fill(task?.needsAttention == true ? AppTheme.warning : AppTheme.success)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(task?.title ?? "正在运行")
                    }
                    Spacer(minLength: 6)
                    if let date {
                        Text(ChatPresentation.shortAge(date))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(AppTheme.softFill, in: Capsule())
                            .fixedSize()
                    }
                }
                if let task {
                    Text(task.detail)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(task.needsAttention ? AppTheme.warning : Color.secondary)
                        .lineLimit(1)
                } else if let preview, !preview.isEmpty {
                    Text(previewText(preview))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 48, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(selected ? AppTheme.userFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppTheme.radiusL, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // 置顶原本只有图标，合并后也应作为值读出。
        .accessibilityValue([pinned ? "已置顶" : "", task?.title ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "，"))
    }

    private func previewText(_ raw: String) -> AttributedString {
        var text = AttributedString(raw)
        guard let needle = highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty,
              let range = text.range(of: needle, options: [.caseInsensitive]) else { return text }
        text[range].backgroundColor = AppTheme.accent.opacity(0.18)
        return text
    }
}
