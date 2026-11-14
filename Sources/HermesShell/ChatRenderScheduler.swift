import Foundation

enum ChatRenderPriority: Int, Comparable, Sendable {
    case background, prefetch, visible, interactive
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ChatRenderContext: Equatable, Sendable {
    var priority: ChatRenderPriority = .visible
    var isScrolling = false
    var isActive = true
}

/// Only admission/bookkeeping runs on MainActor. The operation must hand work
/// to a worker actor. A synchronous Foundation parse cannot be preempted: its
/// slot stays occupied until it really returns, even after cancellation.
@MainActor
final class ChatRenderScheduler {
    static let shared = ChatRenderScheduler()
    enum AdmissionError: Error { case duplicateTicket }

    struct Snapshot: Equatable {
        let running: Int
        let waiting: Int
        let peakRunning: Int
    }
    private struct Waiter {
        var priority: ChatRenderPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private let limit: Int
    private let backgroundLimit: Int
    private var waiting: [UUID: Waiter] = [:]
    private var running: [UUID: ChatRenderPriority] = [:]
    private var sequence: UInt64 = 0
    private var peakRunning = 0

    init(concurrencyLimit: Int = 2, backgroundLimit: Int = 1) {
        self.limit = max(1, concurrencyLimit)
        self.backgroundLimit = max(1, min(backgroundLimit, max(1, concurrencyLimit)))
    }

    var snapshot: Snapshot {
        .init(running: running.count, waiting: waiting.count, peakRunning: peakRunning)
    }

    func run<Value: Sendable>(id: UUID, priority: ChatRenderPriority,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        try await acquire(id, priority: priority)
        defer { release(id) }
        try Task.checkCancellation()
        let value = try await operation()
        try Task.checkCancellation()
        return value
    }

    func setPriority(_ priority: ChatRenderPriority, for id: UUID) {
        if var item = waiting[id] {
            item.priority = priority
            waiting[id] = item
            drain()
        }
        // Running work is not preemptible. Keep its original admission class
        // until it exits so demotion cannot create a phantom available slot.
    }

    func acquire(_ id: UUID, priority: ChatRenderPriority) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                guard waiting[id] == nil && running[id] == nil else {
                    continuation.resume(throwing: AdmissionError.duplicateTicket); return
                }
                sequence &+= 1
                waiting[id] = Waiter(priority: priority, sequence: sequence, continuation: continuation)
                drain()
            }
        }, onCancel: {
            Task { @MainActor in self.cancelWaiting(id) }
        })
        // Cancellation may race with a grant; release the real slot exactly
        // once here if the caller will never enter its operation.
        if Task.isCancelled { release(id); throw CancellationError() }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let item = waiting.removeValue(forKey: id) else { return }
        item.continuation.resume(throwing: CancellationError())
        drain()
    }

    func release(_ id: UUID) {
        guard running.removeValue(forKey: id) != nil else { return }
        drain()
    }

    private func drain() {
        while running.count < limit {
            let backgroundCount = running.values.filter { $0 < .visible }.count
            let next = waiting.filter { $0.value.priority >= .visible || backgroundCount < backgroundLimit }
                .min {
                    $0.value.priority == $1.value.priority
                        ? $0.value.sequence < $1.value.sequence : $0.value.priority > $1.value.priority
                }
            guard let (id, item) = next else { return }
            waiting.removeValue(forKey: id)
            running[id] = item.priority
            peakRunning = max(peakRunning, running.count)
            item.continuation.resume()
        }
    }
}
