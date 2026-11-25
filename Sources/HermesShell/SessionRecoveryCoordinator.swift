import Foundation

/// App-foreground, bounded, GET-only recovery for sessions whose chat view is
/// not mounted. Never submits, stops, approves, or dispatches queued turns.
@MainActor
final class SessionRecoveryCoordinator {
    private var worker: Task<Void, Never>?
    private var ticket = UUID()
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

    func cancel() {
        ticket = UUID()
        worker?.cancel()
        worker = nil
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

    func schedule(candidates: [Candidate],
                  isEligible: @escaping @MainActor (Key, SessionTaskSignal, Double) -> Bool,
                  onPending: @escaping @MainActor (Candidate) -> Void = { _ in },
                  onVerified: @escaping @MainActor (Key, SessionTaskSignal, Double) -> Void) {
        guard worker == nil else { return }
        let indexed = Dictionary(candidates.map { ($0.key, $0) },
                                 uniquingKeysWith: { first, _ in first })
        attempted = attempted.filter { indexed[$0.key] != nil }
        let selected = Self.eligibleKeys(Array(indexed.keys), attempted: attempted,
            now: ProcessInfo.processInfo.systemUptime).compactMap { indexed[$0] }
        guard !selected.isEmpty else { return }
        let owner = UUID()
        let deadline = Date().addingTimeInterval(30)
        ticket = owner
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ticket == owner { self.worker = nil }
            }
            // Serial work prevents burst polling on foreground transitions.
            for candidate in selected {
                guard !Task.isCancelled, self.ticket == owner,
                      Self.withinVerificationWindow(now: Date(), deadline: deadline) else { return }
                let key = candidate.key
                guard let signal = Self.recoverySignal(for: candidate.observation) else { continue }
                let version = candidate.observation.version(for: signal)
                guard isEligible(key, signal, version) else { continue }
                let instanceID = key.instanceID
                let accountScope = key.accountScope
                let sessionID = key.sessionID
                let api = candidate.api
                self.attempted[key] = ProcessInfo.processInfo.systemUptime
                let store = ChatDraftStore(instanceID: instanceID, accountScope: accountScope,
                    sessionID: sessionID,
                    fileStore: LocalDataFileStore(instanceID: instanceID,
                        accountScope: accountScope, sessionID: sessionID))
                let pending = store.loadPending()
                let accepted = store.loadActiveRun()
                // A pending POST is independent of an accepted Run. Absence of
                // either local record never proves successful delivery.
                guard pending.result.succeeded, accepted.result.succeeded else { continue }
                if pending.value != nil {
                    // Reuse the canonical pending-delivery and queue
                    // reconciliation in the app-owned runtime, not a second
                    // implementation that could lose attachments or replay POST.
                    guard isEligible(key, signal, version) else { continue }
                    onPending(candidate)
                    continue
                }
                guard var data = accepted.value,
                      var receipt = try? JSONDecoder().decode(ActiveTurnRecovery.self, from: data)
                else { continue }
                do {
                    let run: ActiveRunProbe
                    if let terminal = receipt.terminalStatus { run = .terminal(terminal) }
                    else { run = try await api.probeActiveRun(sessionID: sessionID,
                                                             runID: receipt.runID) }
                    guard !Task.isCancelled, self.ticket == owner,
                          Self.withinVerificationWindow(now: Date(), deadline: deadline) else { return }
                    guard case .terminal(let outcome) = run,
                          isEligible(key, signal, version) else { continue }
                    // Persist exact terminal evidence even if the final history
                    // is temporarily unavailable. Never retire a newer receipt.
                    if receipt.terminalStatus == nil {
                        let current = store.loadActiveRun()
                        let pendingNow = store.loadPending()
                        guard current.result.succeeded, pendingNow.result.succeeded,
                              Self.mayRetireStoredReceipt(expected: data, current: current.value,
                                  pendingIsEmpty: pendingNow.value == nil) else { continue }
                        receipt.terminalStatus = outcome
                        guard let updated = try? JSONEncoder().encode(receipt),
                              store.saveActiveRun(updated).succeeded else { continue }
                        data = updated
                    }
                    // Non-success outcomes remain durable for the visible
                    // runtime to present; do not label them completed.
                    guard outcome == .completed else { continue }
                    let latest = try await api.history(sessionID: sessionID, before: nil)
                    guard !Task.isCancelled, self.ticket == owner,
                          Self.withinVerificationWindow(now: Date(), deadline: deadline),
                          Self.canRetireAcceptedReceipt(from: latest, sessionID: sessionID),
                          let boundary = receipt.historyEnd else { continue }
                    var pages = [latest]
                    var valid = true
                    for _ in 0..<63 where (pages.last?.olderOffset ?? 0) > boundary {
                        guard !Task.isCancelled, self.ticket == owner,
                              Date() < deadline else { return }
                        guard isEligible(key, signal, version) else { valid = false; break }
                        let cursor = pages[pages.count - 1].olderOffset
                        let older = try await api.history(sessionID: sessionID, before: cursor)
                        guard Self.canRetireAcceptedReceipt(from: older, sessionID: sessionID),
                              older.rawMessageEndIndex == cursor,
                              older.olderOffset < cursor else {
                            valid = false
                            break
                        }
                        pages.append(older)
                    }
                    guard valid, (pages.last?.olderOffset ?? Int.max) <= boundary,
                          receipt.confirmsCompletion(in: pages) else { continue }
                    // Recheck the head: a concurrently appended turn must not
                    // be confused with the accepted turn being verified.
                    let head = try await api.history(sessionID: sessionID, before: nil)
                    guard !Task.isCancelled, self.ticket == owner,
                          Self.withinVerificationWindow(now: Date(), deadline: deadline),
                          Self.canRetireAcceptedReceipt(from: head, sessionID: sessionID),
                          head.rawMessageEndIndex == latest.rawMessageEndIndex,
                          head.messages.last?.id == latest.messages.last?.id else { continue }
                    // The GETs above may have awaited while another task
                    // accepted a newer Run or persisted a pending original POST.
                    // No await may occur between this recheck and the retirement
                    // write: MainActor serialization prevents a lost update.
                    let latestPending = store.loadPending()
                    let latestReceipt = store.loadActiveRun()
                    guard Self.withinVerificationWindow(now: Date(), deadline: deadline),
                          isEligible(key, signal, version),
                          latestPending.result.succeeded, latestReceipt.result.succeeded,
                          Self.mayRetireStoredReceipt(
                              expected: data, current: latestReceipt.value,
                              pendingIsEmpty: latestPending.value == nil) else { continue }
                    guard store.saveActiveRun(nil).succeeded else { continue }
                    onVerified(key, signal, version)
                } catch is CancellationError {
                    return
                } catch {
                    // An inaccessible backend is not evidence of completion.
                    continue
                }
            }
        }
    }
}
