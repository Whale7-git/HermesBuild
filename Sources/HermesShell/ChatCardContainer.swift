import SwiftUI

/// One full-bleed, safe-area-aware card for BOTH drawer reveal and pushed-page
/// back navigation. Route ownership and drag recognition stay with RootView.
///
/// The status-bar background, scrollable transcript, composer, home-indicator
/// background and optional dismiss scrim are clipped by the SAME shape.
/// Changing only a local overlay/cornerRadius can no longer introduce square
/// corners outside the moving page.
struct ChatCardContainer<Content: View>: View {
    let size: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat
    let progress: CGFloat
    let translation: CGFloat
    let reduceMotion: Bool
    let showsDismissSurface: Bool
    let onDismiss: () -> Void
    let content: Content

    init(size: CGSize, topInset: CGFloat, bottomInset: CGFloat,
         progress: CGFloat, translation: CGFloat, reduceMotion: Bool,
         showsDismissSurface: Bool, onDismiss: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.size = size
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.progress = progress
        self.translation = translation
        self.reduceMotion = reduceMotion
        self.showsDismissSurface = showsDismissSurface
        self.onDismiss = onDismiss
        self.content = content()
    }

    private var style: ChatCardPresentation.Style {
        ChatCardPresentation.style(progress: Double(progress),
                                   reduceMotion: reduceMotion)
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .frame(width: size.width, height: size.height + topInset + bottomInset)
            .background(AppTheme.canvas)
            .overlay {
                if showsDismissSurface {
                    Color.black.opacity(style.cardDim)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onDismiss)
                        .accessibilityLabel("关闭会话侧栏")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: CGFloat(style.cornerRadius), style: .continuous))
            .shadow(color: .black.opacity(style.shadowOpacity),
                    radius: style.shadowRadius, x: -3, y: 0)
            .offset(x: translation)
    }
}
