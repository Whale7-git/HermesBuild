import Foundation

/// 决定「这条事实该不该变成一条通知」的纯策略。
///
/// 只有值进、值出，没有时钟、没有系统框架、没有全局状态，因此每条规则都能
/// 在离线套件里直接断言。真正的投递由 `SystemNotificationDeliverer` 负责。
enum TaskNotificationPlanner {

    /// 用户的通知偏好。默认全开、声音关：三类都是「需要你知道」的事实，
    /// 静音不会让它们变少，只会让人错过。
    struct Settings: Equatable, Sendable {
        var approvalEnabled: Bool
        var clarifyEnabled: Bool
        var finishedEnabled: Bool
        var recoveryEnabled: Bool

        init(approvalEnabled: Bool = true,
             clarifyEnabled: Bool? = nil,
             finishedEnabled: Bool = true,
             recoveryEnabled: Bool = true) {
            self.approvalEnabled = approvalEnabled
            self.clarifyEnabled = clarifyEnabled ?? approvalEnabled
            self.finishedEnabled = finishedEnabled
            self.recoveryEnabled = recoveryEnabled
        }
    }

    /// 空标题的降级文案。会话还没起名时列表里也是这么显示的。
    static let untitledSession = "未命名会话"

    /// 服务端挂起等审批。
    ///
    /// - Parameters:
    ///   - requestID: 服务端给的审批请求标识。缺失时退化为按会话去重。
    ///   - foregroundSessionID: 用户当前正看着的会话；相同则不打扰。
    static func approval(
        requestID: String?,
        sessionID: String,
        title: String,
        settings: Settings,
        foregroundSessionID: String?,
        appActive: Bool = true,
        instanceID: String = "",
        accountScope: String = ""
    ) -> TaskNotification? {
        guard settings.approvalEnabled else { return nil }
        guard !appActive || foregroundSessionID != sessionID else { return nil }
        let stableID = scopedIdentifier("approval", instanceID: instanceID,
                                        accountScope: accountScope, sessionID: sessionID, detail: requestID)
        return TaskNotification(kind: .approvalPending,
                                instanceID: instanceID,
                                accountScope: accountScope,
                                sessionID: sessionID,
                                sessionTitle: displayTitle(title),
                                stableID: stableID)
    }

    /// 服务端挂起等补充信息。与审批共用开关，但使用独立类型和标识，
    /// 这样两条通知不会互相替换，解决后也能分别撤回。
    static func clarify(
        requestID: String?,
        sessionID: String,
        title: String,
        settings: Settings,
        foregroundSessionID: String?,
        appActive: Bool = true,
        instanceID: String = "",
        accountScope: String = ""
    ) -> TaskNotification? {
        guard settings.clarifyEnabled else { return nil }
        guard !appActive || foregroundSessionID != sessionID else { return nil }
        return TaskNotification(
            kind: .clarifyPending,
            instanceID: instanceID,
            accountScope: accountScope,
            sessionID: sessionID,
            sessionTitle: displayTitle(title),
            stableID: scopedIdentifier("clarify", instanceID: instanceID,
                accountScope: accountScope, sessionID: sessionID, detail: requestID))
    }

    /// 后台那一轮结束了。
    ///
    /// - Parameters:
    ///   - runID: 这一轮的标识。调用方拿不到时传 nil，退化为按会话去重——
    ///     同一会话连续跑完会替换前一条，这是可接受的：结论都是「刚跑完」。
    static func finished(
        runID: String?,
        sessionID: String,
        title: String,
        settings: Settings,
        foregroundSessionID: String?,
        appActive: Bool = true,
        instanceID: String = "",
        accountScope: String = ""
    ) -> TaskNotification? {
        guard settings.finishedEnabled else { return nil }
        guard !appActive || foregroundSessionID != sessionID else { return nil }
        let stableID = scopedIdentifier("finished", instanceID: instanceID,
                                        accountScope: accountScope, sessionID: sessionID, detail: runID)
        return TaskNotification(kind: .runFinished,
                                instanceID: instanceID,
                                accountScope: accountScope,
                                sessionID: sessionID,
                                sessionTitle: displayTitle(title),
                                stableID: stableID)
    }

    /// 后台恢复出现需要人看的问题。
    ///
    /// 同一会话只保留一条：恢复提示重复堆叠只会掩盖真正的新问题。
    static func recovery(
        sessionID: String,
        title: String,
        settings: Settings,
        foregroundSessionID: String?,
        appActive: Bool = true,
        instanceID: String = "",
        accountScope: String = ""
    ) -> TaskNotification? {
        guard settings.recoveryEnabled else { return nil }
        guard !appActive || foregroundSessionID != sessionID else { return nil }
        return TaskNotification(kind: .recoveryIssue,
                                instanceID: instanceID,
                                accountScope: accountScope,
                                sessionID: sessionID,
                                sessionTitle: displayTitle(title),
                                stableID: scopedIdentifier("recovery", instanceID: instanceID,
                                    accountScope: accountScope, sessionID: sessionID, detail: nil))
    }

    /// 稳定标识：`<kind>.<sessionID>[.<detail>]`。
    ///
    /// 三个前缀互不相同，所以三类通知不会互相替换。
    private static func identifier(_ kind: String, sessionID: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return kind + "." + sessionID }
        return kind + "." + sessionID + "." + detail
    }

    /// Use unambiguous tuple encoding: neither session IDs nor server-derived
    /// request IDs are guaranteed not to contain delimiter characters.
    private static func scopedIdentifier(_ kind: String, instanceID: String,
                                         accountScope: String, sessionID: String,
                                         detail: String?) -> String {
        guard !instanceID.isEmpty, !accountScope.isEmpty else {
            return identifier(kind, sessionID: sessionID, detail: detail)
        }
        let values = [kind, instanceID, accountScope, sessionID, detail ?? ""]
        if let data = try? JSONEncoder().encode(values) {
            return "scoped." + data.base64EncodedString()
        }
        return "scoped-len." + values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Deterministic identity exposed for exact removal when a server request
    /// is resolved.
    static func requestIdentifier(kind: String, requestID: String?,
                                  sessionID: String, instanceID: String,
                                  accountScope: String) -> String {
        scopedIdentifier(kind, instanceID: instanceID, accountScope: accountScope,
                         sessionID: sessionID, detail: requestID)
    }

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledSession : trimmed
    }
}
