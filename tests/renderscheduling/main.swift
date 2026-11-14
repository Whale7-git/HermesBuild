import Foundation

@MainActor
private var checks = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}

@MainActor
private func eventually(_ message: String, _ predicate: () -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    expect(predicate(), message)
}

@main
struct RenderSchedulingTests {
    @MainActor
    static func main() async throws {
        let scheduler = ChatRenderScheduler()
        let first = UUID(), second = UUID(), visible = UUID()
        try await scheduler.acquire(first, priority: .prefetch)
        let background = Task { try await scheduler.acquire(second, priority: .prefetch) }
        await eventually("only one speculative parse can start") { scheduler.snapshot.waiting == 1 }
        expect(scheduler.snapshot.running == 1, "spare capacity is reserved for visible content")
        try await scheduler.acquire(visible, priority: .visible)
        expect(scheduler.snapshot.running == 2, "visible content can use the reserved slot")
        scheduler.release(first)
        try await background.value
        expect(scheduler.snapshot.running == 2, "a completed slot admits pending work")
        scheduler.release(second); scheduler.release(visible)

        // Reprioritization must change queued order without creating another
        // request, dropping a waiter or changing an in-flight view's identity.
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        try await scheduler.acquire(a, priority: .visible)
        try await scheduler.acquire(b, priority: .visible)
        var admitted: [UUID] = []
        let pendingC = Task { try await scheduler.acquire(c, priority: .background); admitted.append(c) }
        await eventually("C queues") { scheduler.snapshot.waiting == 1 }
        let pendingD = Task { try await scheduler.acquire(d, priority: .prefetch); admitted.append(d) }
        await eventually("D queues") { scheduler.snapshot.waiting == 2 }
        let pendingE = Task { try await scheduler.acquire(e, priority: .visible); admitted.append(e) }
        await eventually("E queues") { scheduler.snapshot.waiting == 3 }
        scheduler.setPriority(.interactive, for: c)
        scheduler.setPriority(.background, for: e)
        scheduler.release(a)
        try await pendingC.value
        expect(admitted == [c], "an upgraded visible/selection request overtakes prefetch")
        scheduler.release(b)
        try await pendingD.value
        expect(admitted == [c, d], "demoted offscreen work loses priority")
        scheduler.release(d)
        try await pendingE.value
        scheduler.release(c); scheduler.release(e)

        let fifo = ChatRenderScheduler(concurrencyLimit: 1)
        let blocker = UUID()
        try await fifo.acquire(blocker, priority: .visible)
        var order: [Int] = []
        var tasks: [(UUID, Task<Void, Error>)] = []
        for index in 0..<12 {
            let id = UUID()
            let task = Task { try await fifo.acquire(id, priority: .visible); order.append(index) }
            tasks.append((id, task))
            await eventually("FIFO waiter registers") { fifo.snapshot.waiting == index + 1 }
        }
        fifo.release(blocker)
        for (id, task) in tasks { try await task.value; fifo.release(id) }
        expect(order == Array(0..<12), "equal-priority work retains arrival order")

        let active = UUID(), cancelled = UUID()
        try await fifo.acquire(active, priority: .visible)
        let waiting = Task { try await fifo.acquire(cancelled, priority: .visible) }
        await eventually("cancellable waiter registers") { fifo.snapshot.waiting == 1 }
        waiting.cancel()
        do { try await waiting.value; fatalError("cancelled waiter admitted") }
        catch is CancellationError { checks += 1 }
        expect(fifo.snapshot.waiting == 0 && fifo.snapshot.running == 1, "queued cancellation does not release somebody else's slot")
        do { try await fifo.acquire(active, priority: .visible); fatalError("duplicate accepted") }
        catch ChatRenderScheduler.AdmissionError.duplicateTicket { checks += 1 }
        fifo.release(active)

        // Cancellation and a grant may race. Every successful grant is either
        // returned by acquire itself or released by the admitted operation.
        for _ in 0..<150 {
            let holder = UUID(), next = UUID()
            try await fifo.acquire(holder, priority: .visible)
            let task = Task {
                do { try await fifo.acquire(next, priority: .visible); fifo.release(next) }
                catch is CancellationError {} catch { fatalError("unexpected \(error)") }
            }
            task.cancel()
            fifo.release(holder)
            await task.value
            expect(fifo.snapshot.running == 0 && fifo.snapshot.waiting == 0, "cancel/grant race cannot leak capacity")
        }

        // A parser that has started may ignore cancellation until Foundation
        // returns. Cancellation must not falsely make room for a third parse.
        var finish: CheckedContinuation<Void, Never>?
        let runningID = UUID()
        let inFlight = Task {
            try await scheduler.acquire(runningID, priority: .visible)
            await withCheckedContinuation { finish = $0 }
            scheduler.release(runningID)
        }
        await eventually("in-flight parse entered") { finish != nil }
        inFlight.cancel()
        expect(scheduler.snapshot.running == 1, "cancelling actual work keeps its permit until exit")
        finish?.resume()
        try await inFlight.value
        expect(scheduler.snapshot.running == 0, "actual exit returns the permit")

        let stress = ChatRenderScheduler()
        let burst = (0..<250).map { index in
            Task {
                let id = UUID()
                do {
                    try await stress.acquire(id, priority: index % 3 == 0 ? .prefetch : .visible)
                    await Task.yield()
                    stress.release(id)
                } catch is CancellationError {} catch { fatalError("unexpected \(error)") }
            }
        }
        for (index, task) in burst.enumerated() where index % 4 == 0 { task.cancel() }
        for task in burst { await task.value }
        expect(stress.snapshot.peakRunning <= 2 && stress.snapshot.peakRunning > 0, "burst has a hard concurrency ceiling")
        expect(stress.snapshot.running == 0 && stress.snapshot.waiting == 0, "burst drains after cancellation and priority mixing")

        for bytes in [0, 8_191, 8_192, 32_767, 32_768, 10_000_000] {
            for duration in [-1.0, 0, 0.01, 0.08, 10, .infinity, .nan] {
                var pacing = ChatStreamPacing()
                pacing.published(at: 10, activeBytes: bytes, parseSeconds: duration)
                let idle = pacing.interval(context: .init())
                let scrolling = pacing.interval(context: .init(isScrolling: true))
                expect(idle.isFinite && idle >= 0.04 && idle <= 0.20, "pacing has a finite, bounded deadline")
                expect(scrolling >= idle && scrolling >= 0.24 && scrolling <= 0.32,
                       "scrolling coalesces more without starvation")
                expect(pacing.delay(now: 11, finished: false, context: .init()) == 0, "arrivals cannot postpone an expired deadline")
                expect(pacing.delay(now: 10, finished: true, context: .init(isScrolling: true)) == 0, "finalization bypasses pacing")
            }
        }
        expect(ChatStreamPacing().interval(context: .init()) == 0.04,
               "short visible output uses a faster cadence")
        print("RENDER_SCHEDULING_PASS \(checks) assertions (admission/cancellation/priority/pacing; no UIKit)")
    }
}
