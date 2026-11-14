import SwiftUI

/// 统一空态：图标 + 标题 + 说明 + 至多两个动作。
/// 会话列表、搜索结果、归档、模型目录与性能采样共用同一套间距与按钮层级，
/// 避免每个页面各写一版、字号与留白互相不一致。
struct HermesEmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let primaryTitle: String?
    private let primaryAction: (() -> Void)?
    private let secondaryTitle: String?
    private let secondaryAction: (() -> Void)?

    init(symbol: String, title: String, message: String? = nil,
         primaryTitle: String? = nil, primaryAction: (() -> Void)? = nil,
         secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hasActions {
                VStack(spacing: 10) {
                    if let primaryTitle, let primaryAction {
                        Button { primaryAction() } label: { Text(primaryTitle) }
                            .buttonStyle(HermesPrimaryButtonStyle())
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button { secondaryAction() } label: { Text(secondaryTitle) }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var hasActions: Bool {
        (primaryTitle != nil && primaryAction != nil) || (secondaryTitle != nil && secondaryAction != nil)
    }
}
