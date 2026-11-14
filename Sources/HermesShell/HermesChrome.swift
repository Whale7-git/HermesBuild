import SwiftUI

/// Glass belongs to navigation/actions. Transcripts remain opaque and legible.
private struct HermesSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(AppTheme.hairline, lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
extension View {
    func hermesSurface(cornerRadius: CGFloat = 24) -> some View {
        modifier(HermesSurface(radius: cornerRadius))
    }
}
