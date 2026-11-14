import SwiftUI

/// 会话导出的完整子状态机。
///
/// 从 `NativeChatView` 里搬出来，**逻辑一字未改**——只是把原先散在视图里的
/// 5 个 `@State`（`exportFile` / `readyExport` / `exportProgress` /
/// `exportTask` / `exportTicket`）连同它们的生命周期收进一个对象。
///
/// 搬的理由：这 5 个变量构成一个封闭的状态机（空闲 → 准备中 → 就绪），
/// 与查找、阅读位置恢复、附件等其他子状态机互不交互，却共享同一个视图身份。
/// 视图每重建一次，它们的存续都要靠 SwiftUI 的 `@State` 语义兜着；独立成
/// `ObservableObject` 后，生命周期与视图更新解耦，也让 `NativeChatView` 的
/// `@State` 从 43 个降到 38 个。
@MainActor
final class ChatExportController: ObservableObject {
    /// 交给系统分享面板的文件。置位后由视图弹 `ShareLink`/sheet。
    @Published var sharingFile: SharedTemporaryFile?
    /// 已生成好、等待用户分享的导出文件。
    @Published var readyFile: SharedTemporaryFile?
    /// 正在抓取历史时的进度；非 nil 即「导出进行中」。
    @Published var progress: TranscriptPager.Progress?
    /// 当前导出任务。
    var task: Task<Void, Never>?
    /// The last user-initiated export that failed. The UI keeps the recovery
    /// action visible until the user retries, dismisses it, or starts a new one.
    @Published var failure: String?
    @Published var failedFullHistory = false
    /// 每次导出/取消都换一个，用于丢弃过期任务的回写。
    var ticket = UUID()

    var isBusy: Bool { progress != nil }
    var hasReadyFile: Bool { readyFile != nil }

    /// 取消导出并清理中间状态。递增 ticket 让在途任务的结果被丢弃。
    func cancel() {
        ticket = UUID()
        task?.cancel()
        task = nil
        progress = nil
        readyFile = nil
        failure = nil
    }

    /// 分享就绪的文件。分享后清掉「就绪」标记，避免重复分享同一份。
    func shareReadyFile() {
        sharingFile = readyFile
        readyFile = nil
    }

    func dismissReadyFile() {
        readyFile = nil
    }

    func markFailure(_ message: String, fullHistory: Bool) {
        failure = message
        failedFullHistory = fullHistory
    }

    func dismissFailure() {
        failure = nil
    }
}
