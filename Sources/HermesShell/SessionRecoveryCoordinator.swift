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
                  isEligible: @escaping @MainActor (Key, Double) -> Bool,
                  onVerified: @escaping @MainActor (Key, Double) -> Void) {
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
                let version = candidate.observation.version(for: .needsVerification)
                guard isEligible(key, version) else { continue }
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
                guard pending.result.succeeded, pending.value == nil,
                      accepted.result.succeeded, let data = accepted.value,
                      let receipt = try? JSONDecoder().decode(ActiveTurnRecovery.self, from: data)
                else { continue }
                do {
                    let run = try await api.probeActiveRun(sessionID: sessionID,
                                                            runID: receipt.runID)
                    guard !Task.isCancelled, self.ticket == owner,
                          Self.withinVerificationWindow(now: Date(), deadline: deadline) else { return }
                    guard case .terminal(.completed) = run else { continue }
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
                          isEligible(key, version),
                          latestPending.result.succeeded, latestReceipt.result.succeeded,
                          Self.mayRetireStoredReceipt(
                              expected: data, current: latestReceipt.value,
                              pendingIsEmpty: latestPending.value == nil) else { continue }
                    guard store.saveActiveRun(nil).succeeded else { continue }
                    onVerified(key, version)
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
