import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var password = ""
    @State private var busy = false
    @State private var loginTask: Task<Void, Never>?
    @State private var loginAttempt = UUID()
    /// 已播报过的错误文案，避免同一错误在重复渲染时反复打断 VoiceOver。
    @State private var lastAnnouncedError: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        HermesLogo(size: 56)
                            .padding(.bottom, 12)
                        Text(isGateway ? "验证网关连接。" : "欢迎回来。")
                            .font(.system(.largeTitle, design: .default, weight: .semibold))
                            .tracking(-1)
                        Text(isGateway ? "更新此实例的 API 密钥，继续连接。" : "登录 Hermes，接着上次的想法。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        instanceSelector
                        if let baseURL = activeInstance?.baseURL {
                            Text(baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecureField(isGateway ? "网关 API 密钥" : "WebUI 密码", text: $password)
                            .font(.body)
                            .textContentType(isGateway ? nil : .password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($passwordFocused)
                            .submitLabel(.go)
                            .onSubmit { submit() }
                            .padding(16)
                            .background(AppTheme.softFill,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        if let error = errorDisplay {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(error.message, systemImage: error.systemImage)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = error.detail {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button(action: submit) {
                            HStack(spacing: 10) {
                                if busy { ProgressView().tint(AppTheme.onAction) }
                                Text(busy ? (isGateway ? "正在验证…" : "正在登录…")
                                          : (isGateway ? "保存并连接" : "登录"))
                                if !busy { Image(systemName: "arrow.right") }
                            }
                        }
                        .buttonStyle(HermesPrimaryButtonStyle())
                        .disabled(password.isEmpty || busy)
                    }
                    Text(isGateway ? "网关密钥保存在本机系统钥匙串，不会显示现有密钥。附件 WebUI 的登录在设置中单独管理。"
                                   : "使用此实例的 WebUI 密码。密码不会保存在本地。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.canvas)
            .navigationTitle(isGateway ? "网关凭证" : "登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 明确的退出路径：与下滑关闭（sheet 默认）并存，避免登录页无法离开。
                ToolbarItem(placement: .topBarLeading) {
                    Button("稍后登录") { app.needsLogin = false }
                        .accessibilityLabel("稍后登录，关闭登录页")
                }
            }
            .onChange(of: app.errorText) { _, _ in
                announceErrorIfNeeded()
            }
            .onChange(of: app.active.id) { _, _ in
                cancelLogin()
                password = ""
                lastAnnouncedError = nil
            }
            .onDisappear { cancelLogin() }
        }
    }

    // MARK: - 实例

    private var activeInstance: HermesInstance? {
        app.instances.indices.contains(app.activeIndex) ? app.instances[app.activeIndex] : nil
    }
    /// 登录形态：网关用 API 密钥，WebUI 用密码。读能力表而不是比字面量——
    /// 新增第三个后端时这里不必再改。
    private var isGateway: Bool { !(app.api.capabilities.canPasswordLogin) }

    /// 实例切换入口：登录页也要能换实例，否则实例填错就彻底出不去。
    @ViewBuilder
    private var instanceSelector: some View {
        if app.instances.isEmpty {
            Label("未配置实例", systemImage: "server.rack")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(Array(app.instances.enumerated()), id: \.offset) { index, instance in
                    Button {
                        switchInstance(to: index)
                    } label: {
                        Label("\(instance.name) · \(instance.baseURL)",
                              systemImage: index == app.activeIndex ? "checkmark" : "server.rack")
                    }
                    .accessibilityLabel("\(instance.name)，\(instance.baseURL)")
                    .accessibilityAddTraits(index == app.activeIndex ? .isSelected : [])
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").foregroundStyle(AppTheme.accent)
                    Text(activeInstance?.name ?? "选择实例").fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("切换实例")
            .accessibilityValue("当前 \(activeInstance?.name ?? "未配置实例")")
            .accessibilityHint("展开实例列表，选择要登录的实例")
        }
    }

    private func switchInstance(to index: Int) {
        guard app.instances.indices.contains(index), index != app.activeIndex else { return }
        app.switchTo(index)
        password = ""
        // switchTo 内部会置 needsLogin = false，sheet 因此收起。
        // 用户是在登录页里主动换实例，说明仍想登录，立即恢复意图，避免被当成取消登录。
        if !app.needsLogin { app.needsLogin = true }
    }

    // MARK: - 错误

    private struct LoginErrorDisplay {
        let message: String
        let detail: String?
        let systemImage: String
    }

    private static let networkHints = [
        "网络", "超时", "连接", "断开", "互联网",
        "network", "timeout", "timed out", "connection", "offline", "internet", "socket", "ssl", "tls"
    ]

    /// 只做视图层分流：网络类失败别让用户以为自己密码输错。
    /// `needsLogin == false`（例如非 401 的刷新失败）也按网络/服务异常处理。
    private var errorDisplay: LoginErrorDisplay? {
        guard let raw = app.errorText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let looksNetwork = !app.needsLogin
            || Self.networkHints.contains { raw.range(of: $0, options: .caseInsensitive) != nil }
        if looksNetwork {
            return LoginErrorDisplay(message: "网络异常，可稍后重试", detail: raw, systemImage: "wifi.exclamationmark")
        }
        return LoginErrorDisplay(message: raw, detail: nil, systemImage: "exclamationmark.circle")
    }

    private func announceErrorIfNeeded(force: Bool = false) {
        guard UIAccessibility.isVoiceOverRunning, let message = errorDisplay?.message else { return }
        if !force, message == lastAnnouncedError { return }
        lastAnnouncedError = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        let submittedPassword = password
        let instance = app.active.id
        let gateway = isGateway
        let attempt = UUID()
        loginAttempt = attempt
        passwordFocused = false
        busy = true
        loginTask = Task {
            guard !Task.isCancelled, loginAttempt == attempt,
                  app.active.id == instance else { return }
            if gateway { await app.updateGatewayAPIKey(submittedPassword) }
            else { await app.signIn(password: submittedPassword) }
            guard !Task.isCancelled, loginAttempt == attempt,
                  app.active.id == instance else { return }
            loginTask = nil
            busy = false
            if !app.needsLogin {
                password = ""
            } else {
                // 同一错误重复提交时 errorText 不变、onChange 不会再触发，这里补播一次。
                announceErrorIfNeeded(force: true)
            }
        }
    }

    private func cancelLogin() {
        loginAttempt = UUID()
        loginTask?.cancel(); loginTask = nil
        busy = false
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var historyBytes: Int64 = 0
    @State private var historyEntries = 0
    @State private var localDataFiles = 0
    @State private var localDataBytes: Int64 = 0
    @State private var localDataCorruptFiles = 0
    @AppStorage("chatReturnSends") private var returnSends = true
    @State private var exportedLogText = ""
    /// 分享与日志预览合并成同一个 sheet：同一视图上挂两个 `.sheet` 时，
    /// 后挂的那个会被先挂的吞掉，表现为「点查看所选日志没有任何反应」。
    @State private var activeSheet: SettingsSheet?
    /// 日志分区的实际内容为空时的原因，用于区分「没有分区」和「分区在但没内容」。
    @State private var logEmptyReason: String?
    /// 诊断页可选的日志分区（应用级 + 最近会话），导出时不再依赖「当前活动作用域」。
    @State private var logScopes: [RuntimeLogRecorder.ScopeSummary] = []
    @State private var selectedLogScope: String?
    /// 附件上传失败等场景留下的本地留底文件。
    @State private var localLogFiles: [URL] = []
    /// 待确认移除的实例 id；nil 表示当前没有确认弹窗。
    @State private var pendingRemoval: UUID?
    @State private var showClearHistoryConfirm = false

    @AppStorage("hermesAppearance") private var appearance = "system"
    @AppStorage(NotificationPreference.approvalKey) private var notifyApproval = true
    @AppStorage(NotificationPreference.finishedKey) private var notifyFinished = true
    @AppStorage(NotificationPreference.recoveryKey) private var notifyRecovery = true
    @AppStorage(NotificationPreference.soundKey) private var notifySound = false
    /// 通知权限是否被拒。只在被拒时提示，未决定不打扰。
    @State private var notificationAuthDenied = false
    @State private var notificationAuthStatus: TaskNotificationAuthorization = .notDetermined

    private var connectionSettings: some View {
                Section {
                    ForEach(Array(app.instances.enumerated()), id: \.offset) { index, instance in
                        HStack(spacing: 4) {
                            Button { app.switchTo(index) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .font(.body)
                                        .foregroundStyle(index == app.activeIndex ? AppTheme.accent : Color.secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(instance.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                        Text(instance.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    if index == app.activeIndex {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent)
                                    }
                                }
                                .padding(.vertical, 4)
                                .frame(minHeight: 52)
                            }
                            .accessibilityAddTraits(index == app.activeIndex ? .isSelected : [])

                            Menu {
                                Button {
                                    activeSheet = .editInstance(instance.id)
                                } label: { Label("编辑实例", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    pendingRemoval = instance.id
                                } label: { Label("移除实例", systemImage: "trash") }
                                    .disabled(!app.canDeleteInstance)
                                if !app.canDeleteInstance {
                                    Text("至少保留一个实例")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("「\(instance.name)」的更多操作")
                            .accessibilityHint(app.canDeleteInstance ? "可编辑或移除该实例" : "可编辑该实例；至少保留一个实例")
                            .confirmationDialog("移除「\(instance.name)」？",
                                                isPresented: removalBinding(for: instance),
                                                titleVisibility: .visible) {
                                Button("移除实例", role: .destructive) {
                                    removeInstance(id: instance.id)
                                }
                                Button("取消", role: .cancel) { pendingRemoval = nil }
                            } message: {
                                Text("会同时删除该实例的本地历史缓存、草稿与消息队列。此操作无法撤销，只有服务端会话不受影响。")
                            }
                        }
                    }
                    Button {
                        activeSheet = .addInstance
                    } label: { Label("添加实例", systemImage: "plus.circle") }
                        .frame(minHeight: 44)
                } header: { Text("连接的实例") }
                  footer: { Text("点选切换实例；右侧菜单可编辑名称、地址及网关密钥，或移除实例。至少保留一个。") }
    }

    private var inputSettings: some View {
                Section {
                    Toggle("回车键发送消息", isOn: $returnSends)
                } header: { Text("输入") }
                  footer: { Text("关闭后回车键换行，仍可点输入栏箭头发送。") }
    }

    private var historySettings: some View {
                Section {
                    LabeledContent("本地历史", value: "\(historyEntries) 个会话")
                    LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: historyBytes, countStyle: .file))
                } header: { Text("历史缓存") }
                  footer: { Text("再次打开会话时先显示已保存的历史，再联网同步。清除入口在页面底部的「危险操作」。") }
    }

    private var localSettings: some View {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: localDataCorruptFiles == 0
                              ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(localDataCorruptFiles == 0
                                             ? AppTheme.success : AppTheme.warning)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(localDataCorruptFiles == 0 ? "草稿与队列已保护" : "本地数据需要检查")
                                .font(.subheadline.weight(.medium))
                            Text(localDataCorruptFiles == 0
                                 ? "当前账号 \(localDataFiles) 个文件；写入后会回读验证。"
                                 : "发现 \(localDataCorruptFiles) 个无法验证的文件。进入会话的恢复中心查看。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 3)
                    LabeledContent("本地草稿与队列",
                                   value: ByteCountFormatter.string(fromByteCount: localDataBytes,
                                                                   countStyle: .file))
                } header: { Text("本地数据") }
                  footer: { Text("草稿和消息队列保存在受保护的应用数据目录，排除系统备份；正文不会写入诊断日志。") }
    }

    private var accountSettings: some View {
                Section("账号") {
                    LabeledContent(app.active.backend == .gateway ? "网关认证" : "登录状态") {
                        Text(app.active.backend == .gateway
                            ? (app.needsLogin ? "需要更新密钥" : "使用 API 密钥")
                            : (app.needsLogin ? "未登录" : "已登录"))
                            .foregroundStyle(app.needsLogin ? Color.secondary : AppTheme.success)
                    }
                    Button { app.needsLogin = true } label: {
                        Label(app.active.backend == .gateway ? "更新网关密钥" : "重新登录", systemImage: "key")
                    }
                    if app.active.backend == .webui, let url = attachmentWebUIURL {
                        Button { activeSheet = .attachmentWebUILogin(url) } label: {
                            Label("登录附件 WebUI", systemImage: "paperclip")
                        }
                    }
                    Button { Task { await app.refresh() } } label: { Label("刷新会话", systemImage: "arrow.clockwise") }
                    Button { app.clearAllCompletions() } label: {
                        Label("清除会话完成标记", systemImage: "checkmark.circle")
                    }
                    .disabled(app.completedSessionIDs.isEmpty)
                    if let warning = app.credentialWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
    }

    private var diagnosticSettings: some View {
                Section {
                    NavigationLink("体验诊断") { ChatPerformanceView() }
                    // The two stress fixtures remain internal: the experience
                    // recorder is opt-in and off by default, while these pages
                    // generate synthetic workloads and should not be exposed in
                    // the production package.
                    #if DEBUG
                    NavigationLink("键盘测试") { ChatKeyboardTestView() }
                    NavigationLink("渲染检查") { MarkdownRenderCheckView() }
                    #endif
                    if logScopes.isEmpty {
                        Text("暂无日志。发一条消息或上传附件后回来查看。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("日志分区", selection: Binding(
                            get: { selectedLogScope ?? logScopes[0].key },
                            set: { selectedLogScope = $0 }
                        )) {
                            ForEach(logScopes) { scope in
                                Text("\(scope.label)（\(scope.entryCount)）").tag(scope.key)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Button {
                        showSelectedLog()
                    } label: { Label("查看所选日志", systemImage: "doc.text.magnifyingglass") }
                    .disabled(logScopes.isEmpty)
                    Button { exportLogFile() } label: {
                        Label("导出日志文件…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(logScopes.isEmpty)
                    if !localLogFiles.isEmpty {
                        Button { shareLocalSnapshot(localLogFiles[0]) } label: {
                            Label("分享失败留底（最近 \(localLogFiles.count) 份）", systemImage: "tray.and.arrow.up")
                        }
                    }
                } header: { Text("诊断") }
                  footer: { Text("体验诊断默认关闭，只记录有上限的性能数字，不记录正文、会话标识、地址或凭据；报告不会自动上传。日志只保存在本机，导出后由你决定是否分享。开启后会周期采样帧耗时，采样本身会略微影响流畅度。") }
    }

    private var cleanupSettings: some View {
                Section {
                    if app.clearingHistory {
                        HStack {
                            ProgressView()
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("正在清除本地历史缓存")
                    } else {
                        Button(role: .destructive) {
                            showClearHistoryConfirm = true
                        } label: {
                            Text("清除本地历史缓存").foregroundStyle(AppTheme.danger)
                        }
                        .frame(minHeight: 44)
                    }
                } header: { Text("危险操作") }
                  footer: { Text("移除实例会同时删除该实例的本地历史缓存、草稿与消息队列。这些都无法撤销，只有服务端会话不受影响。") }
    }

    private var appearanceSettings: some View {
        Section("显示") {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
        }
    }

    /// 通知开关。三类都是「需要你知道」的事实，默认开；声音默认关。
    private var notificationSettings: some View {
        Section {
            if notificationAuthStatus == .denied {
                Label("iOS 系统通知已关闭；下面的偏好仍会保存，但暂时无法发出提醒。",
                      systemImage: "bell.slash.fill")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
            Toggle("等待你确认", isOn: $notifyApproval)
            Toggle("后台处理完成", isOn: $notifyFinished)
            Toggle("后台恢复需处理", isOn: $notifyRecovery)
            Toggle("声音", isOn: $notifySound)
        } header: {
            Text("通知")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("只在本机观察到事实时提醒。App 被系统结束后不会再收到——那需要服务端推送。")
                Text("系统授权：" + notificationAuthorizationLabel)
                if notificationAuthStatus == .notDetermined {
                    Button("启用系统通知权限") {
                        Task { await requestNotificationAuthorizationIfNeeded() }
                    }
                    .font(.footnote.weight(.semibold))
                }
                if notificationAuthDenied {
                    Button("通知权限未开启，前往系统设置") { openNotificationSystemSettings() }
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .task { await refreshNotificationAuthorization() }
        // P1：用户主动打开任一通知开关时才申请系统权限。
        //
        // 不在启动时申请：那会在用户还没表达意愿时弹框，拒绝一次之后就再也
        // 申请不到了（iOS 只允许弹一次）。放在这里，用户点开关的瞬间申请，
        // 意图明确；被拒则把「前往系统设置」的提示显示出来。
        .onChange(of: notifyApproval) { _, on in
            guard on else { return }
            Task { await requestNotificationAuthorizationIfNeeded() }
        }
        .onChange(of: notifyFinished) { _, on in
            guard on else { return }
            Task { await requestNotificationAuthorizationIfNeeded() }
        }
        .onChange(of: notifyRecovery) { _, on in
            guard on else { return }
            Task { await requestNotificationAuthorizationIfNeeded() }
        }
    }

    /// 只在 `.notDetermined` 时申请；已授权/已拒绝都不再弹框。
    private var notificationAuthorizationLabel: String {
        switch notificationAuthStatus {
        case .notDetermined: return "尚未申请"
        case .denied: return "未授权"
        case .authorized: return "已授权"
        case .provisional: return "临时授权"
        }
    }

    private func requestNotificationAuthorizationIfNeeded() async {
        let status = await SystemNotificationDeliverer.shared.authorizationStatus()
        guard status == .notDetermined else {
            notificationAuthStatus = status
            notificationAuthDenied = (status == .denied)
            return
        }
        let result = await SystemNotificationDeliverer.shared.requestAuthorization()
        notificationAuthStatus = result
        notificationAuthDenied = (result == .denied)
    }

    /// 读取当前授权状态，只用于「被拒」提示。
    private func refreshNotificationAuthorization() async {
        let status = await SystemNotificationDeliverer.shared.authorizationStatus()
        notificationAuthStatus = status
        notificationAuthDenied = (status == .denied)
    }

    private func openNotificationSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    private func settingsPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .scrollContentBackground(.hidden).background(AppTheme.canvas)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        HermesLogo(size: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Hermes").font(.title3.weight(.semibold))
                            Text("版本 \(AppTheme.version) · \(AppTheme.build)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } header: { Text("关于") }
                  footer: {
                      VStack(alignment: .leading, spacing: 4) {
                          Text("更新时直接覆盖安装，保留本地登录状态。")
                          Text("清晰、可靠、顺手。")
                      }
                  }
                Section {
                    NavigationLink { settingsPage("连接与账号") { connectionSettings; accountSettings } }
                        label: { Label("连接与账号", systemImage: "server.rack") }
                    NavigationLink { settingsPage("外观与输入") { appearanceSettings; inputSettings } }
                        label: { Label("外观与输入", systemImage: "paintpalette") }
                    NavigationLink { settingsPage("通知") { notificationSettings } }
                        label: { Label("通知", systemImage: "bell") }
                    NavigationLink { settingsPage("本地数据") { historySettings; localSettings; cleanupSettings } }
                        label: { Label("本地数据", systemImage: "externaldrive") }
                    NavigationLink { settingsPage("诊断与日志") { diagnosticSettings } }
                        label: { Label("诊断与日志", systemImage: "stethoscope") }
                }
            }
            .scrollContentBackground(.hidden)
            .onAppear { reloadLogScopes() }
            .onChange(of: app.activeChangeToken) { _, _ in
                // Settings remains open while selecting another instance.
                // Discard cached previews and file URLs from the old account.
                activeSheet = nil
                exportedLogText = ""
                logEmptyReason = nil
                selectedLogScope = nil
                pendingRemoval = nil
                showClearHistoryConfirm = false
                reloadLogScopes()
            }
            .background(AppTheme.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task { await updateHistoryStatistics() }
            // Returning from iOS Settings does not recreate this navigation view.
            // Re-read authorization so the status and recovery link are accurate.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshNotificationAuthorization() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.medium)
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .logPreview:
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if let logEmptyReason {
                                    Text(logEmptyReason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !exportedLogText.isEmpty {
                                    Text(exportedLogText)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .navigationTitle("所选日志")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { activeSheet = nil }
                            }
                        }
                    }
                case .addInstance:
                    AddInstanceView(app: app) { activeSheet = nil }
                case .editInstance(let id):
                    if let item = app.instances.first(where: { $0.id == id }) {
                        AddInstanceView(app: app, editing: item) { activeSheet = nil }
                            .id(id)
                    } else {
                        Text("该实例已被移除").padding()
                    }
                case .attachmentWebUILogin(let url):
                    AttachmentWebUILoginView(baseURL: url).environmentObject(app)
                case .share(let url):
                    ShareSheet(items: [url]) {
                        // 只删本次导出的临时文件；失败留底是持久副本，保留供重复取证。
                        if url.deletingLastPathComponent().standardizedFileURL
                            == FileManager.default.temporaryDirectory.standardizedFileURL {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
            .confirmationDialog("清除本地历史缓存？",
                                isPresented: $showClearHistoryConfirm,
                                titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    Task {
                        await app.clearCachedHistory()
                        await updateHistoryStatistics()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除 \(historyEntries) 个会话的本地缓存（\(ByteCountFormatter.string(fromByteCount: historyBytes, countStyle: .file))）。服务端会话不受影响，此操作无法撤销。")
            }
        }
    }

    private var attachmentWebUIURL: URL? {
        guard app.active.backend == .gateway, !app.active.webuiBaseURL.isEmpty else { return nil }
        return URL(string: app.active.webuiBaseURL)
    }

    /// 只让「这条实例」的弹窗响应共享的待确认状态，避免多行各自绑定同一个 Bool。
    private func removalBinding(for instance: HermesInstance) -> Binding<Bool> {
        Binding(get: { pendingRemoval == instance.id },
                set: { if !$0 { pendingRemoval = nil } })
    }

    /// 按 id 定位再删：确认弹窗期间列表变化也不会误删别的实例。
    private func removeInstance(id: UUID) {
        pendingRemoval = nil
        guard let index = app.instances.firstIndex(where: { $0.id == id }) else { return }
        app.deleteInstance(at: IndexSet(integer: index))
    }

    /// Writes the sanitized in-memory scope to a temporary .txt and hands it to
    /// the system share sheet; the file is removed when sharing ends.
    /// 分区列表随页面出现刷新：用户在会话里复现完问题、退出来打开设置，
    /// 此时 activeToken 已为空，只能靠这份历史分区列表找回日志。
    private func reloadLogScopes() {
        logScopes = RuntimeLogRecorder.shared.recentScopes()
        if let selected = selectedLogScope, !logScopes.contains(where: { $0.key == selected }) {
            selectedLogScope = nil
        }
        if selectedLogScope == nil { selectedLogScope = logScopes.first?.key }
        localLogFiles = RuntimeLogRecorder.shared.localSnapshots()
    }

    private func shareLocalSnapshot(_ url: URL) {
        guard RuntimeLogRecorder.shared.localSnapshots().contains(url) else {
            reloadLogScopes()
            exportedLogText = ""
            logEmptyReason = "这份留底已不属于当前账号或已被清理，请重新选择。"
            activeSheet = .logPreview
            return
        }
        // 留底文件是只读副本，分享后不删除，方便重复取证。
        activeSheet = .share(url)
    }

    /// 打开所选分区的日志预览。选中分区可能已失效（会话被清、分区被 LRU 淘汰），
    /// 此时回退到首个可用分区，而不是静默显示空白页。
    private func showSelectedLog() {
        reloadLogScopes()
        let resolved = selectedLogScope.flatMap { key in
            logScopes.first(where: { $0.key == key })
        } ?? logScopes.first
        guard let resolved else {
            exportedLogText = ""
            logEmptyReason = "没有可用的日志分区。先在会话里发一条消息，再回到这里查看。"
            activeSheet = .logPreview
            return
        }
        selectedLogScope = resolved.key
        exportedLogText = RuntimeLogRecorder.shared.snapshot(scopeKey: resolved.key)
        if exportedLogText.isEmpty {
            logEmptyReason = "「\(resolved.label)」分区存在但没有记录。日志只保留本次启动后的内容，重启 App 会清空。"
        } else {
            logEmptyReason = nil
        }
        activeSheet = .logPreview
    }

    private func exportLogFile() {
        reloadLogScopes()
        guard let key = selectedLogScope ?? logScopes.first?.key,
              let exported = RuntimeLogRecorder.shared.export(scopeKey: key) else {
            exportedLogText = ""
            logEmptyReason = "该分区没有可导出的日志内容。"
            activeSheet = .logPreview
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(exported.filename)
        do {
            try Data(exported.text.utf8).write(to: url, options: .atomic)
            activeSheet = .share(url)
        } catch {
            exportedLogText = String(decoding: Data(exported.text.utf8), as: UTF8.self)
            logEmptyReason = "写入临时文件失败，以下为内存中的日志内容。"
            activeSheet = .logPreview
        }
    }

    private func updateHistoryStatistics() async {
        let value = await ChatHistoryStore.statistics()
        historyBytes = value.bytes
        historyEntries = value.entries
        let local = LocalDataFileStore.statistics(
            instanceID: app.historyInstanceID, accountScope: app.historyAccountScope,
            rootDirectory: LocalDataFileStore.defaultRoot)
        localDataFiles = local.files
        localDataBytes = local.payloadBytes
        localDataCorruptFiles = local.corruptFiles
    }
}

/// 设置页需要弹出的 sheet。合并成一个枚举，避免同视图多个 `.sheet` 互相覆盖。
private enum SettingsSheet: Identifiable {
    case logPreview
    case share(URL)
    case addInstance
    case editInstance(UUID)
    case attachmentWebUILogin(URL)

    var id: String {
        switch self {
        case .logPreview: return "logPreview"
        case .share(let url): return "share-" + url.absoluteString
        case .addInstance: return "addInstance"
        case .editInstance(let id): return "editInstance-" + id.uuidString
        case .attachmentWebUILogin(let url): return "attachmentWebUILogin-" + url.absoluteString
        }
    }
}

/// Gateway authentication and its attachment WebUI cookie are separate. This
/// sheet authenticates only the configured WebUI and then rotates local caches
/// through AppState; it never replaces the gateway's API key.
private struct AttachmentWebUILoginView: View {
    let baseURL: URL
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var attempt = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(baseURL.absoluteString).font(.caption).textSelection(.enabled)
                    SecureField("WebUI 密码", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                    Button(action: submit) {
                        HStack {
                            Text(busy ? "正在登录…" : "登录附件 WebUI")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(password.isEmpty || busy)
                } footer: {
                    Text("用于此网关的附件上传与预览。密码不会保存在本地，网关 API 密钥不受影响。")
                }
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(AppTheme.danger) }
                }
            }
            .navigationTitle("登录附件 WebUI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onDisappear {
                attempt = UUID()
                task?.cancel(); task = nil
                password = ""
            }
        }
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        let instance = app.active.id
        let scope = app.activeChangeToken
        let ticket = UUID()
        let submittedPassword = password
        attempt = ticket
        busy = true
        errorText = nil
        task = Task {
            guard !Task.isCancelled, attempt == ticket,
                  app.active.id == instance, app.activeChangeToken == scope else { return }
            do {
                try await HermesAPI(baseURL: baseURL.absoluteString).login(password: submittedPassword)
                guard !Task.isCancelled, attempt == ticket,
                      app.active.id == instance, app.activeChangeToken == scope else { return }
                password = ""
                await app.didAuthenticateAttachmentWebUI()
                // The scope transition dismisses this sheet in Settings. Do
                // not write into a successor account after that transition.
            } catch {
                guard !Task.isCancelled, attempt == ticket,
                      app.active.id == instance, app.activeChangeToken == scope else { return }
                errorText = error.localizedDescription
                busy = false
                task = nil
            }
        }
    }
}
