import Foundation
import Combine

@MainActor
private var checks = 0
@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}
@MainActor
private func eventually(_ message: String, timeout: Double = 5, _ predicate: () -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    expect(predicate(), message)
}
@MainActor
private func text(_ document: ChatMarkdownDocument) -> String { String(document.content.characters) }

@main
struct RenderPipelineTests {
    @MainActor
    static func main() async throws {
        let probe = RenderProbe.shared
        let scheduler = ChatRenderScheduler.shared
        let visible = ChatRowRenderState()
        visible.update(.init())
        let doc = ChatMarkdownDocument(source: "a", finished: false)
        doc.appear(rendering: visible)
        doc.update(source: "a", finished: false)
        await eventually("first content publishes") { text(doc) == "parsed:a" }
        for source in ["ab", "abc", "abcd"] { doc.update(source: source, finished: false) }
        await eventually("append bursts coalesce to the latest source") { text(doc) == "parsed:abcd" }
        expect(!probe.requests.contains { $0.source == "ab" || $0.source == "abc" }, "superseded prefixes are not parsed")

        // Every update arrives sooner than the pacing interval. This must still
        // publish intermediate output while the producer is running.
        let before = probe.requests.count
        for count in 1...40 {
            doc.update(source: "abcd" + String(repeating: "x", count: count), finished: false)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expect(probe.requests.count >= before + 2, "continuous generation does not debounce-starve publication")
        doc.update(source: "abcd" + String(repeating: "x", count: 40), finished: true)
        await eventually("final output restores highlighting") { doc.highlightAfter == nil && text(doc).hasSuffix(String(repeating: "x", count: 40)) }
        doc.disappear()
        let completedCount = probe.requests.count
        doc.appear(rendering: visible)
        doc.update(source: "abcd" + String(repeating: "x", count: 40), finished: true)
        for _ in 0..<10 { await Task.yield() }
        expect(probe.requests.count == completedCount, "remounting a completed unchanged document does not parse again")
        doc.disappear()

        let first = UUID(), second = UUID()
        try await scheduler.acquire(first, priority: .visible)
        try await scheduler.acquire(second, priority: .visible)
        let queued = ChatMarkdownDocument(source: "queued-old", finished: false)
        queued.appear(rendering: visible)
        queued.update(source: "queued-old", finished: false)
        await eventually("document queues behind active workers") { scheduler.snapshot.waiting == 1 }
        expect(!visible.isReadyForMeasurement, "queued text cannot overwrite an exact height with empty content")
        queued.update(source: "queued-new", finished: false)
        queued.update(source: "queued-final", finished: true)
        scheduler.release(first)
        await eventually("queued work consumes newest source and final flag") { text(queued) == "parsed:queued-final" && queued.highlightAfter == nil }
        expect(visible.isReadyForMeasurement, "published final document unlocks calibration")
        expect(!probe.requests.contains { $0.source == "queued-old" || $0.source == "queued-new" }, "queueing never replays obsolete text")
        scheduler.release(second)
        queued.disappear()

        let motion = ChatRowRenderState()
        motion.update(.init(isScrolling: true))
        let paced = ChatMarkdownDocument(source: "paced", finished: false)
        paced.appear(rendering: motion)
        paced.update(source: "paced", finished: false)
        await eventually("pacing fixture starts") { text(paced) == "parsed:paced" }
        paced.update(source: "paced-live", finished: false)
        for _ in 0..<10 { await Task.yield() }
        paced.update(source: "paced-final", finished: true)
        await eventually("finalization wakes a long pacing wait", timeout: 0.15) { text(paced) == "parsed:paced-final" }
        paced.disappear()

        let hold1 = UUID(), hold2 = UUID()
        try await scheduler.acquire(hold1, priority: .visible)
        try await scheduler.acquire(hold2, priority: .visible)
        let row = ChatRowRenderState()
        let offscreen = ChatMarkdownDocument(source: "offscreen", finished: true)
        offscreen.appear(rendering: row)
        offscreen.update(source: "offscreen", finished: true)
        await eventually("speculative document queues") { scheduler.snapshot.waiting == 1 }
        row.update(.init(priority: .background, isActive: false))
        await eventually("UIKit detach cancels waiting work without onDisappear") { scheduler.snapshot.waiting == 0 }
        expect(!probe.requests.contains { $0.source == "offscreen" }, "hidden queued work never enters the parser")
        scheduler.release(hold1); scheduler.release(hold2)
        row.update(.init())
        await eventually("reattaching restarts the latest pending request") { text(offscreen) == "parsed:offscreen" }
        offscreen.disappear()

        probe.held.insert("stale")
        let stale = ChatMarkdownDocument(source: "stale", finished: false)
        var publications: [String] = []
        let subscription = stale.$content.sink { publications.append(String($0.characters)) }
        stale.appear(rendering: visible)
        stale.update(source: "stale", finished: false)
        await eventually("old parse is held") { probe.requests.contains { $0.source == "stale" } }
        stale.update(source: "replacement-final", finished: true)
        probe.release("stale")
        await eventually("replacement rejects the stale result") { text(stale) == "parsed:replacement-final" }
        expect(!publications.contains("parsed:stale"), "replaced content is never published even briefly")
        subscription.cancel(); stale.disappear()

        probe.held.insert("cache-race")
        let cached = ChatMarkdownDocument(source: "cache-race", finished: false)
        cached.appear(rendering: visible)
        cached.update(source: "cache-race", finished: false)
        await eventually("cache race parse starts") { probe.requests.contains { $0.source == "cache-race" } }
        ChatMarkdownParser.cache["cache-final"] = AttributedString("cached:cache-final")
        cached.update(source: "cache-final", finished: true)
        expect(text(cached) == "cached:cache-final", "cached final bypasses active work")
        expect(scheduler.snapshot.running >= 1, "cancelled parser retains its slot until actual exit")
        probe.release("cache-race")
        await eventually("cancelled parser eventually exits") { scheduler.snapshot.running == 0 }
        expect(text(cached) == "cached:cache-final", "late active result cannot overwrite cached final")
        cached.disappear()

        probe.held.insert("generation")
        let generation = ChatMarkdownDocument(source: "generation", finished: true)
        generation.appear(rendering: visible)
        generation.update(source: "generation", finished: true)
        await eventually("old-generation parse starts") { probe.requests.contains { $0.source == "generation" } }
        ChatMarkdownParser.clearCache()
        probe.release("generation")
        await eventually("current view can finish after clearing cache") { text(generation) == "parsed:generation" }
        expect(ChatMarkdownParser.cache["generation"] == nil, "late work cannot repopulate a cleared cache")
        generation.disappear()
        let fail1 = UUID(), fail2 = UUID()
        try await scheduler.acquire(fail1, priority: .visible)
        try await scheduler.acquire(fail2, priority: .visible)
        let failed = ChatMarkdownDocument(source: "failure-old", finished: false)
        failed.appear(rendering: visible)
        failed.update(source: "failure-old", finished: false)
        await eventually("failure fixture queues") { scheduler.snapshot.waiting == 1 }
        probe.failing.insert("failure-latest")
        failed.update(source: "failure-latest", finished: true)
        scheduler.release(fail1)
        await eventually("parser failure falls back to newest actual source") { text(failed) == "failure-latest" }
        expect(visible.isReadyForMeasurement, "readable fallback also unlocks measurement")
        scheduler.release(fail2); failed.disappear()

        let inactiveRow = ChatRowRenderState()
        var readinessEvents = 0
        inactiveRow.onReadinessChange = { readinessEvents += 1 }
        inactiveRow.update(.init(priority: .background, isActive: false))
        inactiveRow.beginMount(41)
        let reactivated = ChatMarkdownDocument(source: "reactivate-cached-host", finished: true)
        reactivated.appear(rendering: inactiveRow)
        reactivated.update(source: "reactivate-cached-host", finished: true)
        inactiveRow.didMount(41)
        for _ in 0..<10 { await Task.yield() }
        expect(!probe.requests.contains { $0.source == "reactivate-cached-host" }, "inactive cached host does not start parsing")
        let block1 = UUID(), block2 = UUID()
        try await scheduler.acquire(block1, priority: .visible)
        try await scheduler.acquire(block2, priority: .visible)
        inactiveRow.update(.init(priority: .visible, isActive: true))
        await eventually("preparation explicitly activates a previously detached host") { scheduler.snapshot.waiting == 1 }
        expect(!inactiveRow.isReadyForMeasurement, "a queued document cannot be fitted as an empty message")
        inactiveRow.update(.init(priority: .background, isActive: false))
        await eventually("detaching a queued host cancels its old admission") { scheduler.snapshot.waiting == 0 }
        reactivated.disappear()
        expect(inactiveRow.isReadyForMeasurement, "a disappeared document explicitly retires its pending readiness")
        inactiveRow.beginMount(42)
        inactiveRow.update(.init(priority: .visible, isActive: true))
        reactivated.appear(rendering: inactiveRow)
        reactivated.update(source: "reactivate-cached-host", finished: true)
        await eventually("reattach requeues the latest pending document") { scheduler.snapshot.waiting == 1 }
        scheduler.release(block1); scheduler.release(block2)
        await eventually("reattached host receives content without a warmup timeout poll") { text(reactivated) == "parsed:reactivate-cached-host" }
        expect(!inactiveRow.isReadyForMeasurement, "ready text still waits for the current root mount barrier")
        inactiveRow.didMount(41)
        expect(!inactiveRow.isReadyForMeasurement, "a stale root mount event cannot unlock a replacement root")
        inactiveRow.didMount(42)
        expect(inactiveRow.isReadyForMeasurement && readinessEvents > 4, "explicit readiness completion wakes the fitting owner")
        reactivated.disappear()

        let liveRow = ChatRowRenderState()
        let live = ChatMarkdownDocument(source: "prefix", finished: false)
        live.appear(rendering: liveRow)
        live.update(source: "prefix", finished: false)
        await eventually("stream prefix is initially visible") { text(live) == "parsed:prefix" }
        let delay1 = UUID(), delay2 = UUID()
        try await scheduler.acquire(delay1, priority: .visible)
        try await scheduler.acquire(delay2, priority: .visible)
        live.update(source: "prefix-append", finished: false)
        expect(liveRow.isReadyForMeasurement, "a valid displayed prefix remains measurable during a newer queued append")
        live.update(source: "different replacement", finished: false)
        expect(!liveRow.isReadyForMeasurement, "replacing text invalidates stale displayed content for fitting")
        await eventually("replacement queues") { scheduler.snapshot.waiting == 1 }
        scheduler.release(delay1); scheduler.release(delay2)
        await eventually("replacement becomes measurable only after publication") { text(live) == "parsed:different replacement" && liveRow.isReadyForMeasurement }
        live.disappear()

        let readiness = ChatRowRenderState()
        var shortLived: ChatRenderReadiness? = ChatRenderReadiness()
        readiness.track(shortLived!)
        expect(!readiness.isReadyForMeasurement, "pending document blocks calibration")
        shortLived = nil
        expect(readiness.isReadyForMeasurement, "deallocated document cannot leave a pending flag")
        await eventually("all document jobs return their slots") { scheduler.snapshot.running == 0 && scheduler.snapshot.waiting == 0 }
        expect(scheduler.snapshot.peakRunning <= 2, "document integration respects the global parse ceiling")
        print("RENDER_PIPELINE_PASS \(checks) assertions (real document/scheduler; headless publishers and controlled parser, no UIKit or Markdown semantics)")
    }
}
