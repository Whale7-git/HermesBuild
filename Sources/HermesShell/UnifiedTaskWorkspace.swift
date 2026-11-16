import Foundation

/// One read-only task entry in the cross-instance browser. This is not a new
/// Run state machine: running is backed ONLY by a recently confirmed session
/// list flag; every other signal is explicitly a device observation.
struct UnifiedTaskEntry: Identifiable {
    enum Group: Int, CaseIterable {
        case attention
        case running
        case verification

        var title: String {
            switch self {
            case .attention: return "需要处理"
            case .running: return "最近确认运行"
            case .verification: return "待刷新与待核对"
            }
        }
    }

    let record: UnifiedSessionRecord
    let group: Group
    let status: String
    let evidence: String
    var id: String { record.id }
}

/// Built from the identity-scoped source snapshots, never from a bare
/// session ID. A failed or expired list cannot certify a currently running
/// task even when the old cached row had is_streaming = true.
struct UnifiedTaskSourceState {
    let observations: [String: SessionTaskObservation]
    let lastSuccessfulList: Date?
    let failed: Bool
}

enum UnifiedTaskWorkspace {
    static let freshnessWindow: TimeInterval = 120

    static func entries(records: [UnifiedSessionRecord],
                        states: [UnifiedSessionIdentity: UnifiedTaskSourceState],
                        now: Date = Date()) -> [UnifiedTaskEntry] {
        records.compactMap { record in
            guard let source = states[record.identity] else { return nil }
            let age = source.lastSuccessfulList.map { now.timeIntervalSince($0) }
            let recentlyConfirmed = !source.failed && age.map {
                $0 >= 0 && $0 <= freshnessWindow
            } == true
            let observation = source.observations[record.session.sessionId]
            let localSignals = observation?.signals ?? []
            let reportedRunning = record.session.isStreaming == true
            let verifiedRunning = recentlyConfirmed && reportedRunning
            let observed = SessionTaskCenter.summary(
                sessionID: record.session.sessionId,
                serverStreaming: recentlyConfirmed ? record.session.isStreaming : nil,
                observation: observation)
            // No visible task fact: never generate a task for a mere session
            // existence or for a Gateway's unknown is_streaming value.
            guard observed != nil || reportedRunning else { return nil }

            let evidence: String
            if source.failed { evidence = "实例刷新失败 · 历史记录，状态未确认" }
            else if !recentlyConfirmed { evidence = "列表未近期确认 · 历史记录" }
            else { evidence = "最近 2 分钟内确认过会话列表 · 非实时监测" }

            if let observed, observed.needsAttention {
                if recentlyConfirmed {
                    return UnifiedTaskEntry(
                        record: record, group: .attention,
                        status: "本机记录：\(observed.title)，进入会话核对",
                        evidence: evidence)
                }
                return UnifiedTaskEntry(
                    record: record, group: .verification,
                    status: "上次记录：\(observed.title)，需要重新核对",
                    evidence: evidence)
            }
            if localSignals.contains(.stopping) {
                return UnifiedTaskEntry(
                    record: record, group: .verification,
                    status: "停止状态待确认，请进入会话核对",
                    evidence: evidence)
            }
            if verifiedRunning {
                return UnifiedTaskEntry(
                    record: record, group: .running,
                    status: "服务端最近报告运行中",
                    evidence: evidence)
            }
            if reportedRunning {
                return UnifiedTaskEntry(
                    record: record, group: .verification,
                    status: "历史记录显示运行，当前状态待刷新",
                    evidence: evidence)
            }
            return nil
        }
        .sorted {
            if $0.group != $1.group { return $0.group.rawValue < $1.group.rawValue }
            let left = $0.record.session.updatedDate?.timeIntervalSince1970 ?? 0
            let right = $1.record.session.updatedDate?.timeIntervalSince1970 ?? 0
            return left != right ? left > right : $0.id < $1.id
        }
    }
}
