import Foundation

// 能力表是纯数据，不需要 UIKit/SwiftUI。这里只编译它自己 + BackendKind 的定义，
// 因此不需要拉整个 HermesShell 模块（那会牵进 UIKit 依赖，在 Linux 上编不过）。

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
        exit(1)
    }
}

// MARK: - 两个后端的能力表都要完整

let web = BackendCapabilities.webUI
let gw = BackendCapabilities.gateway

// WebUI 是本地 Hermes 的完整能力。
expect(web.canArchive, "WebUI can archive: it owns the archive list")
expect(web.canForkAtMessage, "WebUI can fork at an arbitrary message")
expect(web.canForkWholeSession, "WebUI can fork the whole session")
expect(web.searchesFullBody, "WebUI search covers message bodies")
expect(web.canPasswordLogin, "WebUI authenticates with a password")
expect(web.authProbeMode == .dedicatedEndpoint,
       "WebUI refreshes through its dedicated authentication endpoint")

// 网关是只读转发层。
expect(!gw.canArchive, "gateway cannot archive: no archive list exists, so it would be unrecoverable")
expect(!gw.canForkAtMessage, "gateway cannot fork at a message: it only copies whole sessions")
expect(gw.canForkWholeSession, "gateway can still copy a whole session")
expect(!gw.searchesFullBody, "gateway search only matches title and preview")
expect(!gw.canPasswordLogin, "gateway authenticates with an API key, not a password")
expect(gw.authProbeMode == .sessionListStatus,
       "gateway derives auth state from the list request instead of duplicating it")

// MARK: - 两条能力的独立性

// 这一条是能力表存在的核心原因：把「能不能分支」错当成「能不能复制整会话」，
// 会让网关用户以为会话复制也不可用。两者必须分开表达。
expect(gw.canForkWholeSession && !gw.canForkAtMessage,
       "whole-session copy and fork-at-message are independent capabilities")

// MARK: - 不可用提示：可用时留白，不可用时必须给理由

expect(web.unavailableHint(for: .archive) == nil,
       "an available capability must not produce a hint")
expect(web.unavailableHint(for: .forkAtMessage) == nil,
       "an available fork capability must not produce a hint")
expect(web.unavailableHint(for: .searchFullBody) == nil,
       "an available search capability must not produce a hint")
expect(web.unavailableHint(for: .passwordLogin) == nil,
       "an available password login must not produce a hint")
expect(web.unavailableHint(for: .forkWholeSession) == nil,
       "an available whole-session copy must not produce a hint")

let missingKeys: [BackendCapabilities.Key] = [.archive, .forkAtMessage, .searchFullBody, .passwordLogin]
for (index, key) in missingKeys.enumerated() {
    let hint = gw.unavailableHint(for: key)
    expect(hint != nil, "gateway must explain why capability #\(index) is unavailable")
    expect((hint ?? "").isEmpty == false, "the explanation for capability #\(index) must not be empty")
}
expect(gw.unavailableHint(for: .forkWholeSession) == nil,
       "gateway supports whole-session copy, so it must not be explained away")

// 提示要讲清「不支持」而不是「坏了」：静默消失会让用户以为是故障。
expect(gw.unavailableHint(for: .forkAtMessage)?.contains("不能从指定消息处分支") == true,
       "the fork hint must name the actual limitation")

// MARK: - 每个能力键都被覆盖（防止新增能力时漏写提示）

let allKeys: [BackendCapabilities.Key] = [.archive, .forkAtMessage, .forkWholeSession,
                                         .searchFullBody, .passwordLogin]
// 网关缺 4 项能力，WebUI 缺 0 项：总提示数必须正好是 4。
// 若新增能力而忘了补 hint，这个计数会变。
let missingOnGateway = allKeys.filter { gw.unavailableHint(for: $0) != nil }
expect(missingOnGateway.count == 4,
       "gateway is missing exactly 4 of the 5 capabilities, got \(missingOnGateway.count)")
let missingOnWeb = allKeys.filter { web.unavailableHint(for: $0) != nil }
expect(missingOnWeb.isEmpty, "WebUI must not be missing any capability")

// MARK: - 等价性（Equatable 用于快照比较）

expect(BackendCapabilities.webUI == BackendCapabilities.webUI, "webUI capabilities are stable")
expect(BackendCapabilities.gateway == BackendCapabilities.gateway, "gateway capabilities are stable")
expect(BackendCapabilities.webUI != BackendCapabilities.gateway,
       "the two backends must not compare equal, or the snapshot diff would skip updates")

print("BACKEND_CAPABILITIES_PASS \(checks) assertions")
