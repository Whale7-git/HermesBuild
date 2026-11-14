import SwiftUI
import UIKit

/// Shared semantic colours. Light and dark appearances use the same hierarchy.
enum AppTheme {
    static let accent = adaptive(0x1767CE, 0x85B8FF)
    static let canvas = adaptive(0xFFFFFF, 0x151618)
    static let surface = adaptive(0xFFFFFF, 0x202226)
    static let softFill = adaptive(0xF0F1F2, 0x292C31)
    static let codeFill = adaptive(0xE6EBF1, 0x181E26)
    static let hairline = adaptive(0xE3E5E8, 0x36393F, highContrast: .separator)
    static let action = adaptive(0x202B39, 0xE8EEF6)
    static let onAction = adaptive(0xFFFFFF, 0x18212D)
    // Neutral conversation bubble, leaving blue for links/actions rather than
    // saturating every user message. Keep the high-contrast system override.
    static let userFill = adaptive(0xF2F2F2, 0x303134, highContrast: .secondarySystemFill)
    static let success = adaptive(0x26745A, 0x78CAA7)
    static let warning = adaptive(0xB26A00, 0xF0B45A)
    static let danger = adaptive(0xC0392B, 0xFF6B5E)
    /// `accent.opacity(0.10)` 的实色等价物（按 canvas 复合），避免依赖叠加顺序。
    static let selectionFill = adaptive(0xDBE5F2, 0x1D242F)

    // 间距
    static let pagePadding: CGFloat = 20
    static let pageInset: CGFloat = 20
    static let rowGap: CGFloat = 16
    static let groupGap: CGFloat = 8
    static let cardInset: CGFloat = 12

    // 圆角
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 16
    static let radiusXL: CGFloat = 24
    static let radiusSheet: CGFloat = 28

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    /// 高对比度不再靠颜色字面量识别；动态颜色本身已按 traits 解析，
    /// 这里供需要在视图层分支的调用方读取当前环境。
    static var isHighContrast: Bool {
        UITraitCollection.current.accessibilityContrast == .high
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            solid(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// 用于高对比度需换成系统语义色的 token（`hairline`、`userFill`）。
    private static func adaptive(_ light: UInt32, _ dark: UInt32, highContrast: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high { return highContrast }
            return solid(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func solid(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
