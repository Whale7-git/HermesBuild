import Foundation

/// A task fact that belongs to one session. The server list can prove that a
/// run is active; approval, stopping, verification and recovery facts are only
/// added after this device has observed them inside that session.
enum SessionTaskSignal: String, Codable, CaseIterable, Sendable {
    case running
    case waitingForApproval
    case waitingForClarify
    case stopping
    case needsVerification
    case recoveryIssue
}

/// Persisted per-session facts. A timestamp is kept only to make updates
/// deterministic; the UI never claims that elapsed time proves a run ended.
struct SessionTaskObservation: Codable, Equatable, Sendable {
    var signals: Set<SessionTaskSignal>
    var observedAt: Double

    init(signals: Set<SessionTaskSignal>, observedAt: Date = Date()) {
        self.signals = signals
        self.observedAt = observedAt.timeIntervalSince1970
    }
}

/// The merged view of server truth and local observations for one session.
struct SessionTaskSummary: Identifiable, Equatable, Sendable {
    let sessionID: String
    let signals: Set<SessionTaskSignal>

    var id: String { sessionID }
    var needsAttention: Bool {
        signals.contains(.waitingForApproval) || signals.contains(.waitingForClarify)
            || signals.contains(.needsVerification)
            || signals.contains(.recoveryIssue)
    }
    var isRunning: Bool {
        signals.contains(.running) || signals.contains(.stopping)
    }

    var title: String {
        if signals.contains(.waitingForApproval) { return "等待你确认" }
        if signals.contains(.waitingForClarify) { return "等待你补充信息" }
        if signals.contains(.recoveryIssue) { return "后台恢复需处理" }
        if signals.contains(.needsVerification) { return "发送结果待核对" }
        if signals.contains(.stopping) { return "正在停止" }
        return "正在处理"
    }

    var detail: String {
        if signals.contains(.waitingForApproval) { return "回复停在审批步骤" }
        if signals.contains(.waitingForClarify) { return "Hermes 正在等待你的回答" }
        if signals.contains(.recoveryIssue) { return "检查恢复记录后继续" }
        if signals.contains(.needsVerification) { return "确认前不会自动重发" }
        if signals.contains(.stopping) { return "等待服务端确认" }
        return "后台仍在运行"
    }

    var icon: String {
        if signals.contains(.waitingForApproval) { return "hand.raised.fill" }
        if signals.contains(.waitingForClarify) { return "text.bubble.fill" }
        if signals.contains(.recoveryIssue) { return "exclamationmark.triangle.fill" }
        if signals.contains(.needsVerification) { return "paperplane.badge.clock" }
        if signals.contains(.stopping) { return "stop.circle.fill" }
        return "waveform"
    }
}

/// A pure merge policy. Local observations can add facts that the list cannot
/// expose, while server `is_streaming` can remove a stale local `running` fact.
enum SessionTaskCenter {
    static func summary(
        sessionID: String,
        serverStreaming: Bool?,
        observation: SessionTaskObservation?
    ) -> SessionTaskSummary? {
        var signals = observation?.signals ?? []
        if serverStreaming == true {
            signals.insert(.running)
        } else if serverStreaming == false {
            signals.remove(.running)
        }
        return signals.isEmpty ? nil : SessionTaskSummary(sessionID: sessionID, signals: signals)
    }

    static func summaries(
        sessions: [SessionSummary],
        observations: [String: SessionTaskObservation]
    ) -> [SessionTaskSummary] {
        // Session listing may contain duplicate IDs before deduplication.
        // Do not use Dictionary(uniqueKeysWithValues:) here: it traps at runtime.
        var updatedAt: [String: Double] = [:]
        for session in sessions {
            updatedAt[session.sessionId] = max(updatedAt[session.sessionId] ?? 0,
                                               session.updatedDate?.timeIntervalSince1970 ?? 0)
        }
        return sessions.compactMap { session in
            summary(sessionID: session.sessionId, serverStreaming: session.isStreaming,
                    observation: observations[session.sessionId])
        }
        .sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            // Recent task activity before stable session-ID tie breaking.
            let left = max(observations[lhs.sessionID]?.observedAt ?? 0,
                           updatedAt[lhs.sessionID] ?? 0)
            let right = max(observations[rhs.sessionID]?.observedAt ?? 0,
                            updatedAt[rhs.sessionID] ?? 0)
            if left != right { return left > right }
            return lhs.sessionID < rhs.sessionID
        }
    }

    /// Sanitize a record after a list refresh. Only sessions that still exist
    /// in the current list may retain local facts.
    static func prune(
        observations: [String: SessionTaskObservation],
        liveSessionIDs: Set<String>
    ) -> [String: SessionTaskObservation] {
        observations.filter { liveSessionIDs.contains($0.key) && !$0.value.signals.isEmpty }
    }

    /// Signals are all local observations; `running` is intentionally not
    /// persisted because it is server truth from `/api/sessions`.
    static func persistable(_ signals: Set<SessionTaskSignal>) -> Set<SessionTaskSignal> {
        signals.subtracting([.running])
    }

    /// 按确认记录过滤展示用的摘要。
    ///
    /// P1：粒度是**信号**，不是整个会话。原实现在 `AppState` 里把命中的
    /// `sessionID` 收集成集合再整条过滤，于是同一会话里「已确认的恢复问题」
    /// 和「仍需你确认的审批」一起消失——用户确认了一个问题，另一个真问题
    /// 也跟着不见了。
    ///
    /// 规则：从信号集合里剔除已确认的那一个，其余照常展示；
    /// 只有当一个会话的信号**全部**被确认时才整条隐藏。
    ///
    /// 抽成纯函数是为了能在离线套件里断言：`AppState` 的这条路径挂着大量
    /// 私有状态，直接构造代价过高。
    static func filteringAcknowledged(
        _ summaries: [SessionTaskSummary],
        observations: [String: SessionTaskObservation],
        acknowledgements: [TaskAcknowledgement]
    ) -> [SessionTaskSummary] {
        guard !acknowledgements.isEmpty else { return summaries }
        return summaries.compactMap { summary -> SessionTaskSummary? in
            guard let observation = observations[summary.sessionID] else { return summary }
            let acknowledged = summary.signals.filter { signal in
                acknowledgements.contains {
                    $0.covers(sessionID: summary.sessionID, observation: observation)
                        && $0.signal == signal
                }
            }
            guard !acknowledged.isEmpty else { return summary }
            let remaining = summary.signals.subtracting(acknowledged)
            guard !remaining.isEmpty else { return nil }
            return SessionTaskSummary(sessionID: summary.sessionID, signals: remaining)
        }
    }
}
