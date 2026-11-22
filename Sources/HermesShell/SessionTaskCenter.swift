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
    case sendNotFound
    case recoveryIssue
}

/// Persisted per-session facts. A timestamp is kept only to make updates
/// deterministic; the UI never claims that elapsed time proves a run ended.
struct SessionTaskObservation: Codable, Equatable, Sendable {
    var signals: Set<SessionTaskSignal>
    var observedAt: Double
    /// Added in build183; nil means a legacy build182 record, whose single
    /// observedAt timestamp is used for every signal until its next update.
    var signalVersions: [String: Double]? = nil

    init(signals: Set<SessionTaskSignal>, observedAt: Date = Date(),
         signalVersions: [String: Double]? = nil) {
        self.signals = signals
        self.observedAt = observedAt.timeIntervalSince1970
        self.signalVersions = signalVersions ?? Dictionary(
            uniqueKeysWithValues: signals.map { ($0.rawValue, observedAt.timeIntervalSince1970) })
    }

    func version(for signal: SessionTaskSignal) -> Double {
        signalVersions?[signal.rawValue] ?? observedAt
    }

    /// Unrelated signal changes MUST NOT invalidate a prior recovery
    /// acknowledgement. A removed/reintroduced signal receives a new version.
    static func updating(_ previous: SessionTaskObservation?,
                         signals: Set<SessionTaskSignal>,
                         at date: Date = Date()) -> SessionTaskObservation {
        var versions: [String: Double] = [:]
        for signal in signals {
            if let previous, previous.signals.contains(signal) {
                versions[signal.rawValue] = previous.version(for: signal)
            } else {
                versions[signal.rawValue] = date.timeIntervalSince1970
            }
        }
        return SessionTaskObservation(signals: signals, observedAt: date,
                                      signalVersions: versions)
    }
}

/// In-memory identities for individually observed approval/clarification
/// requests in the ACTIVE instance/account scope. A missing ID is a distinct
/// ambiguous observation, never a reason to replace the whole session set.
/// AppState resets this ledger when its account/instance scope changes.
enum SessionRequestSignalLedger {
    struct Key: Hashable {
        let signal: SessionTaskSignal
        let sessionID: String
        let requestID: String?
    }

    static func arrived(_ signal: SessionTaskSignal, sessionID: String,
                        requestID: String?, index: inout Set<Key>,
                        current: Set<SessionTaskSignal>) -> Set<SessionTaskSignal> {
        index.insert(Key(signal: signal, sessionID: sessionID,
                         requestID: normalized(requestID)))
        var updated = current
        updated.insert(signal)
        return updated
    }

    static func resolved(_ signal: SessionTaskSignal, sessionID: String,
                         requestID: String?, index: inout Set<Key>,
                         current: Set<SessionTaskSignal>) -> Set<SessionTaskSignal> {
        let id = normalized(requestID)
        let removed = index.remove(Key(signal: signal, sessionID: sessionID,
                                       requestID: id)) != nil
        var updated = current
        let stillObserved = index.contains {
            $0.sessionID == sessionID && $0.signal == signal
        }
        if id == nil {
            // A legacy resolution cannot prove that all indistinguishable
            // requests finished. Remove only the matching anonymous marker,
            // preserve named siblings, and retain a verification fact.
            if removed || updated.contains(signal) {
                updated.insert(.needsVerification)
            }
            if !stillObserved { updated.remove(signal) }
        } else if removed {
            // Only the exact request has been completed. Another ID or an
            // anonymous sibling must keep the blocking signal visible.
            if !stillObserved { updated.remove(signal) }
        } else if updated.contains(signal) {
            // A late resolution after process restart has no reliable local
            // request index. Never convert it into proof of all-complete.
            updated.insert(.needsVerification)
        }
        return updated
    }

    private static func normalized(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }
}

/// The merged view of server truth and local observations for one session.
struct SessionTaskSummary: Identifiable, Equatable, Sendable {
    let sessionID: String
    let signals: Set<SessionTaskSignal>

    var id: String { sessionID }
    var needsAttention: Bool {
        signals.contains(.waitingForApproval) || signals.contains(.waitingForClarify)
            || signals.contains(.needsVerification) || signals.contains(.sendNotFound)
            || signals.contains(.recoveryIssue)
    }
    var isRunning: Bool {
        signals.contains(.running) || signals.contains(.stopping)
    }

    var title: String {
        if signals.contains(.waitingForApproval) { return "等待你确认" }
        if signals.contains(.waitingForClarify) { return "等待你补充信息" }
        if signals.contains(.recoveryIssue) { return "后台恢复需处理" }
        if signals.contains(.sendNotFound) { return "消息未送达" }
        if signals.contains(.needsVerification) { return "后台状态核对中" }
        if signals.contains(.stopping) { return "正在停止" }
        return "正在处理"
    }

    var detail: String {
        if signals.contains(.waitingForApproval) { return "回复停在审批步骤" }
        if signals.contains(.waitingForClarify) { return "Hermes 正在等待你的回答" }
        if signals.contains(.recoveryIssue) { return "检查恢复记录后继续" }
        if signals.contains(.sendNotFound) { return "已核对服务端历史；可返回会话决定是否重试，不会自动重发" }
        if signals.contains(.needsVerification) { return "App 会在前台自动核对；状态不明时不会重复发送" }
        if signals.contains(.stopping) { return "等待服务端确认" }
        return "后台仍在运行"
    }

    var icon: String {
        if signals.contains(.waitingForApproval) { return "hand.raised.fill" }
        if signals.contains(.waitingForClarify) { return "text.bubble.fill" }
        if signals.contains(.recoveryIssue) { return "exclamationmark.triangle.fill" }
        if signals.contains(.sendNotFound) { return "paperplane.circle" }
        if signals.contains(.needsVerification) { return "arrow.triangle.2.circlepath.circle" }
        if signals.contains(.stopping) { return "stop.circle.fill" }
        return "waveform"
    }
}

enum SessionTaskBackgroundDecision: Equatable {
    case active
    case resolved
    case sendNotFound
    case needsVerification
    case recoveryIssue
}

/// Pure decision policy for the foreground reconciler. Unknown and unresolved
/// status can never clear a send/run receipt or manufacture a terminal result.
enum SessionTaskBackgroundPolicy {
    static func decide(runState: ActiveRunState,
                       storageReadable: Bool,
                       hasPendingSend: Bool,
                       pendingResult: PendingReconcileResult?,
                       hasAcceptedRun: Bool,
                       acceptedRunMatchesActive: Bool,
                       acceptedRunCompleted: Bool) -> SessionTaskBackgroundDecision {
        guard storageReadable else { return .recoveryIssue }
        switch runState {
        case .unknown, .unresolved:
            return .needsVerification
        case .active(_):
            if hasPendingSend && !acceptedRunMatchesActive { return .needsVerification }
            if hasAcceptedRun && !acceptedRunMatchesActive { return .needsVerification }
            return .active
        case .absent:
            if hasPendingSend {
                switch pendingResult {
                case .delivered: break
                case .absent:
                    return hasAcceptedRun && !acceptedRunCompleted
                        ? .needsVerification : .sendNotFound
                case .failed, .none: return .needsVerification
                }
            }
            if hasAcceptedRun && !acceptedRunCompleted { return .needsVerification }
            return .resolved
        }
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
