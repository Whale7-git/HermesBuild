import Foundation

/// 后端能力表：把「这个后端能做到什么」从散落的条件判断收成一份显式声明。
///
/// 改造前全仓有 22 处直接比较 `BackendKind` 字面量（`backend == .webui` × 6、
/// `backend == .gateway` × 16），同一个问题（「这个后端做不到」）有两套答案：
/// 归档是「方法层 guard + 可操作文案 + UI 隐藏入口」，分支/重生成却是「长按菜单项
/// 直接不存在，无任何说明」。更糟的是 `supportsArchive` 定义了两份
/// （`AppState` 与 `SessionDrawer`），而前者注释写着「与 SessionDrawer 同一判据，
/// 避免 UI 与方法层漂移」——用两份字面量来避免漂移，注释与实现自相矛盾。
///
/// 现在能力只有一处定义，UI 与方法层读同一份；新增第三个后端时不必再全仓搜字面量。
struct BackendCapabilities: Equatable {
    /// 刷会话列表前如何确认认证状态。
    ///
    /// WebUI 有独立的 `/api/auth/status`，但网关的 `authStatus()` 本身就是
    /// 请求一页会话列表再丢掉结果。若调用方仍先探测、再正式分页，网关每次刷新
    /// 都会多发一轮请求。把策略放进能力表后，刷新只在真正需要时探测。
    enum AuthProbeMode: Equatable {
        case dedicatedEndpoint
        case sessionListStatus
    }

    /// 能否把会话移入归档。网关没有归档列表接口，归档即不可找回。
    var canArchive: Bool
    /// 能否从指定消息处分支。网关只支持整会话复制。
    var canForkAtMessage: Bool
    /// 能否复制完整会话。与上一条**独立**：网关
    /// `canForkWholeSession == true` 但 `canForkAtMessage == false`。
    var canForkWholeSession: Bool
    /// 搜索是否覆盖正文，还是只匹配标题与预览。
    var searchesFullBody: Bool
    /// 是否支持密码登录（网关用 API key）。
    var canPasswordLogin: Bool
    /// 会话列表刷新前如何确认登录态。
    var authProbeMode: AuthProbeMode

    /// WebUI：本地 Hermes 的完整能力。
    static let webUI = BackendCapabilities(
        canArchive: true,
        canForkAtMessage: true,
        canForkWholeSession: true,
        searchesFullBody: true,
        canPasswordLogin: true,
        authProbeMode: .dedicatedEndpoint)

    /// 网关：只读转发层，归档/定点分支/全文搜索/密码登录都没有。
    static let gateway = BackendCapabilities(
        canArchive: false,
        canForkAtMessage: false,
        canForkWholeSession: true,
        searchesFullBody: false,
        canPasswordLogin: false,
        authProbeMode: .sessionListStatus)

    /// 某能力不可用时的说明。返回 nil 表示该能力可用，界面不需要解释。
    ///
    /// 这些句子存在的理由是「静默消失让用户无法区分『不支持』与『坏了』」：
    /// 能力缺失时菜单项仍然显示但禁用，并把原因挂在无障碍提示上。
    /// 文案与 `GatewayBackend` 里那几句 501 提示保持一致口径，但**不共用**——
    /// 那些是请求失败后的解释，这些是操作前的预告，出现时机不同。
    func unavailableHint(for key: Key) -> String? {
        switch key {
        case .archive:
            return canArchive ? nil
                : "当前实例不支持归档：网关后端没有归档列表，归档后无法在 App 内查看或恢复。"
        case .forkAtMessage:
            return canForkAtMessage ? nil
                : "当前实例只支持复制完整会话，不能从指定消息处分支。"
        case .forkWholeSession:
            return canForkWholeSession ? nil : "当前实例不支持复制会话。"
        case .searchFullBody:
            return searchesFullBody ? nil : "当前实例只搜索标题与预览，不搜索正文。"
        case .passwordLogin:
            return canPasswordLogin ? nil : "当前实例使用 API 密钥登录，不支持密码登录。"
        }
    }

    /// 能力名。用枚举而不是字符串，避免调用点各写一份拼写。
    enum Key {
        case archive, forkAtMessage, forkWholeSession, searchFullBody, passwordLogin
    }
}
