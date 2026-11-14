import Foundation

/// Coalesces work while keeping each consumer's cancellation independent.
/// The last departing consumer cancels the transfer/decode task. Completed
/// entries are removed; a separate bounded image cache owns reusable results.
actor SharedAsyncResourcePool<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        var waiters: [UUID: CheckedContinuation<Value, Error>]
        let operation: @Sendable () async throws -> Value
        var task: Task<Void, Never>?
    }
    private var entries: [Key: Entry] = [:]
    private var queue: [(key: Key, id: UUID)] = []
    private var running = Set<UUID>()
    private let maxConcurrent: Int

    init(maxConcurrent: Int = 3) { self.maxConcurrent = max(1, maxConcurrent) }

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiter = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var entry = entries[key] {
                    entry.waiters[waiter] = continuation
                    entries[key] = entry
                    return
                }
                let identity = UUID()
                entries[key] = Entry(id: identity, waiters: [waiter: continuation], operation: operation, task: nil)
                queue.append((key, identity))
                startQueued()
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func complete(key: Key, identity: UUID, result: Result<Value, Error>) {
        guard running.remove(identity) != nil else { return }
        if let entry = entries[key], entry.id == identity {
            entries.removeValue(forKey: key)
            for continuation in entry.waiters.values { continuation.resume(with: result) }
        }
        // A cancelled transfer keeps its slot until its operation really exits.
        // In particular an in-flight decode must not be replaced without bound.
        startQueued()
    }

    private func cancel(key: Key, waiter: UUID) {
        guard var entry = entries[key], let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        if entry.waiters.isEmpty {
            entries.removeValue(forKey: key)
            // A blocked decode can own a slot for a while. Retire cancelled
            // queued work now instead of retaining tombstones until it exits.
            if entry.task == nil { queue.removeAll { $0.id == entry.id } }
            entry.task?.cancel()
        } else { entries[key] = entry }
        continuation.resume(throwing: CancellationError())
    }

    private func startQueued() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            guard var entry = entries[next.key], entry.id == next.id else { continue }
            running.insert(next.id)
            let operation = entry.operation
            entry.task = Task {
                let result: Result<Value, Error>
                do { result = .success(try await operation()) }
                catch { result = .failure(error) }
                self.complete(key: next.key, identity: next.id, result: result)
            }
            entries[next.key] = entry
        }
    }

    // Small read-only counters support deterministic offline cancellation tests.
    func consumerCount(for key: Key) -> Int { entries[key]?.waiters.count ?? 0 }
    var activeCount: Int { entries.count }
    var runningCount: Int { running.count }
    var queuedCount: Int { queue.count }
}
