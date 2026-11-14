import Foundation

/// Pure display policy. Calendar-day arithmetic also works across DST changes.
enum SessionRecencyBucket: Int, CaseIterable, Identifiable {
    case today, yesterday, week, earlier, unknown
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "最近 7 天"
        case .earlier: return "更早"
        case .unknown: return "其他会话"
        }
    }
    static func bucket(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Self {
        guard let date, date.timeIntervalSince1970.isFinite else { return .unknown }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let start = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: start),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -6, to: start), date >= week, date < start {
            return .week
        }
        return .earlier
    }
}

/// One ordinary status surface, without pretending a disconnected run stopped.
struct ChatTaskSummary: Equatable {
    enum Kind { case idle, progress, queued, attention }
    let kind: Kind
    let title: String
    let detail: String?
    var visible: Bool { kind != .idle }
    /// Ordinary progress belongs in the navigation subtitle. A second progress
    /// bar directly above the composer competes with the answer and repeats the
    /// same state. Queue, errors, verification and local-storage issues remain
    /// actionable and therefore keep their own entry.
    var needsActionBar: Bool { kind == .queued || kind == .attention }
    init(activity: String, progressing: Bool, queued: Int, submitting: Int,
         uncertain: Int, needsVerification: Bool, hasError: Bool, storageIssue: Bool) {
        let waiting = max(0, queued)
        if storageIssue {
            kind = .attention; title = "本地数据需要检查"; detail = "查看恢复与保存状态"
        } else if needsVerification || uncertain > 0 {
            kind = .attention; title = "发送结果待核对"
            detail = uncertain > 0 ? "\(uncertain) 条待核对 · 不会自动重发" : "查看恢复操作"
        } else if hasError {
            kind = .attention; title = "操作未完成"; detail = "查看详情与恢复操作"
        } else if waiting > 0 {
            // A queued message is user-owned work that can still be inspected
            // or edited. Do not hide that action merely because another request
            // is currently streaming.
            kind = .queued
            title = "待发送 \(waiting) 条"
            detail = progressing ? "\(activity) · 查看消息队列" : "查看消息队列"
        } else if progressing || submitting > 0 {
            kind = .progress; title = activity
            detail = nil
        } else {
            kind = .idle; title = "就绪"; detail = nil
        }
    }
}
