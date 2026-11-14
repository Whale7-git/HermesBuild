import Foundation

private enum ProbeError: Error { case failed }

private final class ReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0
    func released() { lock.withLock { releases += 1 } }
    var count: Int { lock.withLock { releases } }
}

private actor Probe {
    private var continuations: [UUID: CheckedContinuation<Int, Error>] = [:]
    private(set) var starts = 0
    private(set) var cancellations = 0
    let finishesOnCancel: Bool
    init(finishesOnCancel: Bool = true) { self.finishesOnCancel = finishesOnCancel }
    func fetch() async throws -> Int {
        let id = UUID()
        starts += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in continuations[id] = continuation }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        cancellations += 1
        if finishesOnCancel { continuations.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }
    func finish(_ result: Result<Int, Error>) {
        let waiting = continuations.values
        continuations.removeAll()
        for item in waiting { item.resume(with: result) }
    }
}

@main
private struct AttachmentInteractionTests {
    @MainActor private static var checks = 0
    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { print("FAIL: \(name)"); exit(1) }
    }
    @MainActor private static func checkAsync(_ condition: @autoclosure () async -> Bool, _ name: String) async {
        let value = await condition()
        check(value, name)
    }
    @MainActor private static func eventually(_ name: String, _ condition: () async -> Bool) async {
        for _ in 0..<5000 {
            if await condition() { checks += 1; return }
            try? await Task.sleep(nanoseconds: 100_000)
        }
        print("FAIL (timeout): \(name)"); exit(1)
    }
    @MainActor static func main() async {
        var state = AttachmentInteractionState()
        check(state.begin(itemID: "a", intent: .preview) == nil, "inactive cannot begin")
        state.activate(scope: "instance/session/row")
        let first = state.begin(itemID: "a", intent: .preview)!
        check(state.isBusy, "download reserves state")
        check(state.begin(itemID: "a", intent: .preview) == nil, "duplicate preview rejected")
        check(state.begin(itemID: "b", intent: .share) == nil, "cross-file parallel presentation rejected")
        check(state.progress(first, received: 10, expected: 100), "current progress accepted")
        check(state.receivedBytes == 10 && state.expectedBytes == 100, "progress stored")
        state.progress(first, received: 5, expected: -1)
        check(state.receivedBytes == 10 && state.expectedBytes == nil, "bytes never go backwards and invalid expected omitted")
        state.cancel()
        check(!state.isBusy, "cancel permits retry")
        check(!state.progress(first, received: 99, expected: 100), "late cancelled progress rejected")
        check(!state.present(first), "late cancelled success cannot present")
        check(!state.fail(first, message: "old error"), "late cancelled error ignored")
        let retry = state.begin(itemID: "a", intent: .share)!
        check(retry.id != first.id, "retry receives fresh ticket")
        check(state.fail(retry, message: "network failed"), "failure retained")
        check(state.failure?.message == "network failed", "user can read concrete error")
        check(!state.isBusy, "failure permits retry")
        let third = state.begin(itemID: "a", intent: .share)!
        check(state.failure == nil, "retry clears old error")
        check(!state.present(retry), "old failed success cannot steal new ticket")
        check(state.present(third), "current success starts presentation")
        check(state.pending == nil && state.isBusy, "presentation remains reserved after transfer")
        state.deactivate()
        check(state.presentationID == nil, "leaving view retires local presentation even before a surface was created")
        check(!state.dismissed(first.id), "stale dismissal cannot release another file")
        check(!state.dismissed(third.id), "late dismissal after retirement does not touch local state")
        check(!state.isBusy && !state.isActive, "retired view remains inactive")
        state.activate(scope: "old")
        let scoped = state.begin(itemID: "a", intent: .preview)!
        state.activate(scope: "new")
        check(!state.present(scoped), "session/instance scope change rejects old completion")
        let current = state.begin(itemID: "b", intent: .image)!
        check(state.present(current), "image preview uses same presentation gate")
        check(state.begin(itemID: "b", intent: .share) == nil, "image and file panels cannot overlap")
        check(state.dismissed(current.id), "image dismissal releases gate")
        let staged = state.begin(itemID: "staged", intent: .preview)!
        check(state.present(staged), "route staged before UIKit surface construction")
        state.deactivate()
        state.activate(scope: "new")
        let afterRetirement = state.begin(itemID: "fresh", intent: .share)!
        check(state.present(afterRetirement), "retired staged route does not leave local busy flag")
        check(!state.dismissed(staged.id), "old route dismissal cannot end new presentation")
        check(state.presentationID == afterRetirement.id, "new presentation survives stale callback")
        check(state.dismissed(afterRetirement.id), "matching new dismissal succeeds")
        let gate = AttachmentPresentationGate()
        let a = UUID(), b = UUID()
        check(gate.reserve(a), "first row reserves global gate")
        check(!gate.reserve(b), "another row cannot reserve gate")
        gate.release(b)
        check(gate.owner == a, "late other-row release cannot clear gate")
        gate.release(a)
        check(gate.reserve(b), "real owner release permits another row")

        let release = ReleaseProbe()
        var modelOwner: AttachmentPresentationLifetime? = AttachmentPresentationLifetime { release.released() }
        var systemSurfaceOwner = modelOwner
        modelOwner = nil
        withExtendedLifetime(systemSurfaceOwner) {
            check(release.count == 0, "destroying source row cannot reclaim a file still held by system preview")
        }
        systemSurfaceOwner = nil
        check(release.count == 1, "last surface destruction reclaims lease even without onDismiss")
        let releaseOtherOrder = ReleaseProbe()
        var presentingModel: AttachmentPresentationLifetime? = AttachmentPresentationLifetime { releaseOtherOrder.released() }
        var presentedSurface = presentingModel
        presentedSurface = nil
        withExtendedLifetime(presentingModel) {
            check(releaseOtherOrder.count == 0, "surface loss alone cannot reclaim file while model still presents")
        }
        presentingModel = nil
        check(presentedSurface == nil && releaseOtherOrder.count == 1, "cleanup runs exactly once in opposite release order")

        let pool = SharedAsyncResourcePool<String, Int>()
        let shared = Probe()
        let consumerA = Task { try await pool.value(for: "same") { try await shared.fetch() } }
        let consumerB = Task { try await pool.value(for: "same") { try await shared.fetch() } }
        await eventually("two consumers coalesced") { await pool.consumerCount(for: "same") == 2 }
        await eventually("one transfer starts") { await shared.starts == 1 }
        consumerA.cancel()
        do { _ = try await consumerA.value; check(false, "cancelled consumer must throw") }
        catch is CancellationError { check(true, "cancelled consumer returns immediately") }
        catch { check(false, "unexpected cancellation error") }
        await checkAsync(await shared.cancellations == 0, "one consumer cancellation does not cancel shared work")
        await checkAsync(await pool.consumerCount(for: "same") == 1, "remaining consumer retained")
        await shared.finish(.success(42))
        await checkAsync((try? await consumerB.value) == 42, "remaining consumer receives shared result")
        await checkAsync(await pool.activeCount == 0, "completed entry removed")

        let last = Probe()
        let lastConsumer = Task { try await pool.value(for: "last") { try await last.fetch() } }
        await eventually("last transfer starts") { await last.starts == 1 }
        lastConsumer.cancel()
        _ = try? await lastConsumer.value
        await eventually("last consumer cancels underlying transfer") { await last.cancellations == 1 }
        await eventually("cancelled underlying transfer exits") { await pool.runningCount == 0 }

        // An uncooperative/cpu decode keeps its slot until completion, even after
        // cancellation. A retry of the same URL has a different operation ID.
        let limited = SharedAsyncResourcePool<String, Int>(maxConcurrent: 1)
        let slow = Probe(finishesOnCancel: false), newer = Probe(), queued = Probe()
        let old = Task { try await limited.value(for: "url") { try await slow.fetch() } }
        await eventually("old operation running") { await slow.starts == 1 }
        old.cancel()
        _ = try? await old.value
        let replacement = Task { try await limited.value(for: "url") { try await newer.fetch() } }
        let queuedTask = Task { try await limited.value(for: "queued") { try await queued.fetch() } }
        await eventually("replacement and queued consumer registered") { await limited.activeCount == 2 }
        await checkAsync(await limited.runningCount == 1, "cancelled operation still owns slot")
        let newerStarts = await newer.starts, queuedStarts = await queued.starts
        check(newerStarts == 0 && queuedStarts == 0, "no replacement work before real old exit")
        queuedTask.cancel()
        _ = try? await queuedTask.value
        await slow.finish(.success(13))
        await eventually("replacement starts after real old exit") { await newer.starts == 1 }
        await checkAsync(await queued.starts == 0, "cancelled queued operation never starts")
        await checkAsync(await limited.consumerCount(for: "url") == 1, "old completion cannot remove replacement")
        await newer.finish(.success(99))
        await checkAsync((try? await replacement.value) == 99, "same URL retry receives fresh result")
        await checkAsync(await limited.runningCount == 0, "limited pool drains")

        let imageBudget = SharedAsyncResourcePool<String, Int>(maxConcurrent: 3)
        let images = (0..<4).map { _ in Probe() }
        let imageConsumers = (0..<4).map { index in
            Task { try await imageBudget.value(for: "unique-\(index)") { try await images[index].fetch() } }
        }
        await eventually("all image consumers queued") { await imageBudget.activeCount == 4 }
        await eventually("three image operations run") {
            var starts = 0
            for image in images { starts += await image.starts }
            return starts == 3
        }
        await checkAsync(await imageBudget.runningCount == 3, "internal unique keys and remote keys share three slots")
        for consumer in imageConsumers { consumer.cancel() }
        for consumer in imageConsumers { _ = try? await consumer.value }
        await eventually("image budget drained after all consumers depart") { await imageBudget.runningCount == 0 }
        await checkAsync(await imageBudget.activeCount == 0, "cancelled queued images retain no entry")

        let failure = Probe()
        let failedA = Task { try await pool.value(for: "failed") { try await failure.fetch() } }
        let failedB = Task { try await pool.value(for: "failed") { try await failure.fetch() } }
        await eventually("failure coalesced") { await pool.consumerCount(for: "failed") == 2 }
        await eventually("failing transfer starts") { await failure.starts == 1 }
        await failure.finish(.failure(ProbeError.failed))
        do { _ = try await failedA.value; check(false, "failure A must throw") }
        catch ProbeError.failed { check(true, "failure A propagated") }
        catch { check(false, "unexpected failure A") }
        do { _ = try await failedB.value; check(false, "failure B must throw") }
        catch ProbeError.failed { check(true, "failure B propagated") }
        catch { check(false, "unexpected failure B") }
        await checkAsync(await pool.activeCount == 0, "failure does not poison next attempt")
        let stalled = SharedAsyncResourcePool<String, Int>(maxConcurrent: 1)
        let stallProbe = Probe(finishesOnCancel: false)
        let stallOwner = Task { try await stalled.value(for: "busy") { try await stallProbe.fetch() } }
        await eventually("queue stress owns its running slot") { await stallProbe.starts == 1 }
        for index in 0..<256 {
            let id = "cancelled-\(index)"
            let waiter = Task { try await stalled.value(for: id) { -1 } }
            await eventually("queued stress consumer admitted") { await stalled.consumerCount(for: id) == 1 }
            waiter.cancel()
            _ = try? await waiter.value
        }
        await checkAsync(await stalled.queuedCount == 0, "cancelled queue retains no tombstones during blocked decode")
        await checkAsync(await stalled.runningCount == 1, "queue cleanup cannot release actual running slot")
        await stallProbe.finish(.success(8))
        await checkAsync((try? await stallOwner.value) == 8, "running decode still delivers after queue stress")
        print("ATTACHMENT_INTERACTION_PASS \(checks) assertions")
    }
}
