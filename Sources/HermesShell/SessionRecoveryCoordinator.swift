import Foundation

enum SessionRecoveryProof {
    case acceptedRun(ActiveTurnRecovery)
    case deliveredPending(Data)
}

private struct SessionPendingEvidence: Decodable {
    let id: String
    let text: String
    let attachments: [ChatAttachmentPayload]
    let historyEnd: Int?
    let knownIDs: Set<String>
}

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

    /// Reconciliation is read-only until AppState has revalidated the owner.
    private func deliveredPending(_ bytes: Data, api: HermesBackend,
                                  sessionID: String, owner: UUID, deadline: Date) async -> Bool {
        guard let pending = try? JSONDecoder().decode(SessionPendingEvidence.self, from: bytes),
              let boundary = pending.historyEnd, boundary >= 0 else { return false }
        do {
            let latest = try await api.history(sessionID: sessionID, before: nil)
            guard !Task.isCancelled, ticket == owner, Date() < deadline,
                  latest.sessionID == sessionID, !latest.readOnly,
                  latest.activeRunEvidence == .absent else { return false }
            var pages = [latest]
            for _ in 0..<63 where (pages.last?.olderOffset ?? 0) > boundary {
                guard !Task.isCancelled, ticket == owner, Date() < deadline else { return false }
                let cursor = pages[pages.count - 1].olderOffset
                let older = try await api.history(sessionID: sessionID, before: cursor)
                guard older.sessionID == sessionID, !older.readOnly,
                      older.activeRunEvidence == .absent,
                      older.rawMessageEndIndex == cursor,
                      older.olderOffset < cursor else { return false }
                pages.append(older)
            }
            guard (pages.last?.olderOffset ?? Int.max) <= boundary,
                  DeliveryReconciliationPolicy.resolve(
                      text: pending.text, attachments: pending.attachments,
                      historyEnd: boundary, knownIDs: pending.knownIDs,
                      pages: pages) == .delivered else { return false }
            let head = try await api.history(sessionID: sessionID, before: nil)
            return !Task.isCancelled && ticket == owner && Date() < deadline
                && head.sessionID == sessionID && !head.readOnly
                && head.activeRunEvidence == .absent
                && head.rawMessageEndIndex == latest.rawMessageEndIndex
                && head.messages.last?.id == latest.messages.last?.id
        } catch { return false }
    }

    func schedule(api: HermesBackend,
                  instanceID: String, accountScope: String,
                  observations: [String: SessionTaskObservation],
                  visibleSessionID: String?,
                  onVerified: @escaping @MainActor (String, Double, SessionRecoveryProof) -> Void) {
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
                guard pending.result.succeeded, accepted.result.succeeded else { continue }
                if let bytes = pending.value {
                    guard accepted.value == nil else { continue }
                    if await self.deliveredPending(bytes, api: api, sessionID: sessionID,
                                                   owner: owner, deadline: deadline) {
                        onVerified(sessionID, observation.version(for: .needsVerification),
                                   .deliveredPending(bytes))
                    }
                    continue
                }
                guard let data = accepted.value,
                      let receipt = try? JSONDecoder().decode(ActiveTurnRecovery.self, from: data)
                else { continue }
                do {
                    let run = try await api.probeActiveRun(sessionID: sessionID,
                                                            runID: receipt.runID)
                    guard !Task.isCancelled, self.ticket == owner else { return }
                    guard case .terminal(.completed) = run else { continue }
                    let latest = try await api.history(sessionID: sessionID, before: nil)
                    guard !Task.isCancelled, self.ticket == owner,
                          latest.sessionID == sessionID, !latest.readOnly,
                          latest.activeRunEvidence == .absent,
                          let boundary = receipt.historyEnd else { continue }
                    var pages = [latest]
                    var valid = true
                    for _ in 0..<63 where (pages.last?.olderOffset ?? 0) > boundary {
                        guard !Task.isCancelled, self.ticket == owner,
                              Date() < deadline else { return }
                        let cursor = pages[pages.count - 1].olderOffset
                        let older = try await api.history(sessionID: sessionID, before: cursor)
                        guard older.sessionID == sessionID, !older.readOnly,
                              older.activeRunEvidence == .absent,
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
                          head.sessionID == sessionID, !head.readOnly,
                          head.activeRunEvidence == .absent,
                          head.rawMessageEndIndex == latest.rawMessageEndIndex,
                          head.messages.last?.id == latest.messages.last?.id else { continue }
                    // AppState owns the final scoped compare-and-clear; user
                    // navigation may have changed while the GET was in flight.
                    onVerified(sessionID, observation.version(for: .needsVerification), .acceptedRun(receipt))
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
