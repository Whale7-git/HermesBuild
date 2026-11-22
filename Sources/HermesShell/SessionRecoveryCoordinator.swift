import Foundation

/// App-foreground, bounded, GET-only recovery for sessions whose chat view is
/// not mounted. Never submits, stops, approves, or dispatches queued turns.
@MainActor
final class SessionRecoveryCoordinator {
    private var worker: Task<Void, Never>?
    private var ticket = UUID()
    private var attempted: [String: Date] = [:]

    func cancel() {
        ticket = UUID()
        worker?.cancel()
        worker = nil
        attempted.removeAll()
    }

    /// An unknown run status is not authoritative evidence of no active Run.
    static func canRetireAcceptedReceipt(from snapshot: ChatSnapshot, sessionID: String) -> Bool {
        snapshot.sessionID == sessionID && !snapshot.readOnly &&
            snapshot.activeRunEvidence == .absent
    }

    func schedule(api: HermesBackend,
                  instanceID: String, accountScope: String,
                  observations: [String: SessionTaskObservation],
                  visibleSessionID: String?,
                  onVerified: @escaping @MainActor (String, Double) -> Void) {
        guard worker == nil else { return }
        let now = Date()
        let candidates = observations.filter { sessionID, observation in
            guard sessionID != visibleSessionID,
                  observation.signals.contains(.needsVerification) else { return false }
            let key = instanceID + "|" + accountScope + "|" + sessionID
            return attempted[key].map { now.timeIntervalSince($0) >= 30 } ?? true
        }.sorted { $0.value.observedAt < $1.value.observedAt }.prefix(5)
        guard !candidates.isEmpty else { return }
        let owner = UUID()
        let deadline = Date().addingTimeInterval(30)
        ticket = owner
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ticket == owner { self.worker = nil }
            }
            // Serial work prevents burst polling on foreground transitions.
            for (sessionID, observation) in candidates {
                guard !Task.isCancelled, self.ticket == owner,
                      Date() < deadline else { return }
                let key = instanceID + "|" + accountScope + "|" + sessionID
                self.attempted[key] = Date()
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
                    guard !Task.isCancelled, self.ticket == owner else { return }
                    guard case .terminal(.completed) = run else { continue }
                    let latest = try await api.history(sessionID: sessionID, before: nil)
                    guard !Task.isCancelled, self.ticket == owner,
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
                          Self.canRetireAcceptedReceipt(from: head, sessionID: sessionID),
                          head.rawMessageEndIndex == latest.rawMessageEndIndex,
                          head.messages.last?.id == latest.messages.last?.id else { continue }
                    // Write durable receipt retirement before notifying AppState.
                    guard store.saveActiveRun(nil).succeeded else { continue }
                    onVerified(sessionID, observation.version(for: .needsVerification))
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
