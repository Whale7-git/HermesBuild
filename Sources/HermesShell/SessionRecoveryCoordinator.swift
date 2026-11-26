import Foundation

/// Discovers durable offscreen work and hands it to the application runtime registry.
@MainActor
final class SessionRecoveryCoordinator {
    struct Key: Hashable {
        let instanceID: String
        let accountScope: String
        let sessionID: String
    }
    struct Candidate {
        let key: Key
        let observation: SessionTaskObservation
        let api: HermesBackend
    }
    private var attempted: [Key: TimeInterval] = [:]

    static func recoverySignal(for observation: SessionTaskObservation) -> SessionTaskSignal? {
        if observation.signals.contains(.needsVerification) { return .needsVerification }
        if observation.signals.contains(.recoveryTracked) { return .recoveryTracked }
        if observation.signals.contains(.running) { return .running }
        return nil
    }

    static func eligibleKeys(_ keys: [Key], attempted: [Key: TimeInterval],
                             now: TimeInterval, cooldown: TimeInterval = 30,
                             limit: Int = 5) -> [Key] {
        keys.filter { key in
            attempted[key].map { now - $0 >= cooldown } ?? true
        }.sorted { lhs, rhs in
            let l = attempted[lhs] ?? -Double.infinity
            let r = attempted[rhs] ?? -Double.infinity
            if l != r { return l < r }
            if lhs.instanceID != rhs.instanceID { return lhs.instanceID < rhs.instanceID }
            if lhs.accountScope != rhs.accountScope { return lhs.accountScope < rhs.accountScope }
            return lhs.sessionID < rhs.sessionID
        }.prefix(max(0, limit)).map { $0 }
    }

    /// An unknown run status is not authoritative evidence of no active Run.
    static func canRetireAcceptedReceipt(from snapshot: ChatSnapshot, sessionID: String) -> Bool {
        snapshot.sessionID == sessionID && !snapshot.readOnly &&
            snapshot.activeRunEvidence == .absent
    }

    /// A foreground GET may finish after a new send/Run receipt is saved. Only
    /// retire the exact original receipt while no new pending POST exists.
    static func mayRetireStoredReceipt(expected: Data, current: Data?,
                                       pendingIsEmpty: Bool) -> Bool {
        pendingIsEmpty && current == expected
    }

    /// Expired foreground probes must not mutate receipts or task-center state.
    /// A slow but successful GET is still stale after the bounded window.
    static func withinVerificationWindow(now: Date, deadline: Date) -> Bool {
        now < deadline
    }

    /// Fair discovery only. Each eligible durable session is transferred to
    /// the same registry-owned Runtime used by a visible conversation.
    /// No history, status or receipt retirement occurs in this discovery layer.
    func schedule(candidates: [Candidate],
                  isEligible: (Key, SessionTaskSignal, Double) -> Bool,
                  onRestore: (Candidate) -> Bool) {
        let indexed = Dictionary(candidates.map { ($0.key, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let now = ProcessInfo.processInfo.systemUptime
        attempted = attempted.filter { now - $0.value < 3600 }
        // Eligibility failures must not consume a batch slot. A rejected
        // admission must not start a cooldown for a runtime that never existed.
        let eligible = indexed.keys.filter { key in
            guard let candidate = indexed[key],
                  let signal = Self.recoverySignal(for: candidate.observation) else { return false }
            return isEligible(key, signal, candidate.observation.version(for: signal))
        }
        for key in Self.eligibleKeys(Array(eligible), attempted: attempted, now: now) {
            guard let candidate = indexed[key] else { continue }
            if onRestore(candidate) { attempted[key] = now }
        }
    }
}
