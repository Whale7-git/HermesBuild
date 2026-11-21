import SwiftUI

@main
public struct HermesShellApp: App {
    @StateObject private var app = AppState()

    public init() {
        // 注册通知 delegate。前台策略由 SystemNotificationDeliverer 决定
        // （一律不弹：用户已在 App 内，切任务中心即可看到）。
        SystemNotificationDeliverer.shared.install()
    }

    public var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-hermes-font-probe") {
                HermesNativeFontProbeView()
            } else {
                RootView()
                    .environmentObject(app)
                    .tint(AppTheme.accent)
            }
            #else
            RootView()
                .environmentObject(app)
                .tint(AppTheme.accent)
            #endif
        }
    }
}
