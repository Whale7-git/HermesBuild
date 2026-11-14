import Foundation

private var checks = 0
private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard value() else { fatalError("FAIL: \(message)") }
}

let order = (0..<1_000).map { "row-\($0)" }
var queue = ChatPreparationQueue(pendingLimit: 6)
for id in order { queue.enqueue(id) }
let bottom = ChatPreparationQueue.priority(order: order, candidates: Set(order), pivot: nil)
expect(Array(bottom.prefix(3)) == ["row-999", "row-998", "row-997"], "cold preparation starts at the actual latest rows")
for _ in 0..<3 { expect(queue.take(prioritized: bottom, limit: 2).count == 2, "one turn admits at most two hosts") }
expect(queue.active.count == 6 && queue.queued.count == 994, "a thousand rows cannot create more than six pending hosts")
expect(queue.take(prioritized: bottom, limit: 2).isEmpty, "waiting beyond a former warmup deadline cannot exceed pending admission")
queue.enqueue("row-999")
expect(queue.take(prioritized: bottom, limit: 2) == ["row-999"] && queue.active.count == 6,
       "a newer snapshot restarts an admitted row without using another pending slot")
queue.suspend("row-999")
let visible = ["row-500"] + bottom
expect(queue.take(prioritized: visible, limit: 2) == ["row-500"], "a fling can suspend an old pending row and admit a visible row")
queue.finish("row-500")
expect(queue.take(prioritized: bottom, limit: 2) == ["row-999"], "suspended work remains restartable after the viewport returns")
queue.retain(["row-999", "row-10"])
expect(queue.active == ["row-999"] && queue.queued == ["row-10"], "deleted rows cannot remain in a preparation cycle")
let near = ChatPreparationQueue.priority(order: order, candidates: ["row-1", "row-499", "row-501", "row-900"], pivot: "row-500")
expect(near == ["row-501", "row-499", "row-900", "row-1"], "reading anchors prioritize nearby historical rows over the distant bottom")

let timeline = ["old-1", "old-2", "old-3", "visible", "new-1", "new-2"]
let measured: Set<String> = ["old-1", "old-3", "visible", "new-2"]
let admitted = ChatPreparationQueue.admitted(order: timeline, measured: measured, committed: ["visible"])
expect(admitted == ["old-3", "visible"], "only a contiguous real-height history prefix enters, and unmeasured append holes remain absent")
expect(ChatPreparationQueue.admitted(order: timeline, measured: measured.subtracting(["new-2"]), committed: []).isEmpty,
       "cold geometry never assigns guessed heights to fill a missing final row")
let coldMeasured: Set<String> = ["new-1", "new-2", "old-1"]
expect(ChatPreparationQueue.admitted(order: timeline, measured: coldMeasured, committed: []) == ["new-1", "new-2"],
       "cold initial geometry is a measured chronological suffix")
let nextMeasured = measured.union(["old-2", "new-1"])
let all = ChatPreparationQueue.admitted(order: timeline, measured: nextMeasured, committed: Set(admitted))
expect(all == timeline, "a completed page enters in its real chronological order")

let oldFrames = ChatViewportLayout.frames(for: [.init(id: "visible", height: 400), .init(id: "tail", height: 500)])
let anchors = ChatViewportLayout.anchors(in: oldFrames, offset: 100, viewport: 300)
let expanded = ChatViewportLayout.frames(for: [
    .init(id: "old-2", height: 233), .init(id: "old-3", height: 377),
    .init(id: "visible", height: 400), .init(id: "tail", height: 500)])
let offset = ChatViewportLayout.offset(after: expanded, anchors: anchors, previous: 100, viewport: 300, following: false)
expect(offset == 710 && expanded[2].top - offset == oldFrames[0].top - 100,
       "committing a measured history batch preserves the same reading point")
var widthQueue = ChatPreparationQueue(pendingLimit: 6)
for id in timeline { widthQueue.enqueue(id) }
expect(ChatPreparationQueue.admitted(order: timeline, measured: nextMeasured, committed: Set(timeline)) == timeline,
       "width invalidation keeps previous actual geometry while replacement measurements queue")
expect(widthQueue.active.isEmpty, "invalidating a whole history does not itself allocate any pending hosts")
// build31: duplicate identifiers and the cached preparation order index.
let duplicated = ["row-1", "row-2", "row-1", "row-3"]
let dupIndices = ChatPreparationQueue.indices(for: duplicated)
expect(dupIndices["row-1"] == 0 && dupIndices["row-3"] == 3,
       "duplicate identifiers keep the first position instead of trapping")
expect(ChatPreparationQueue.priority(order: duplicated, candidates: ["row-1", "row-3"], pivot: "row-3") == ["row-3", "row-1"],
       "priority stays deterministic when a row identifier repeats")
var cachedIndex = ChatPreparationIndex()
cachedIndex.update(order: order)
let cachedCandidates: Set<String> = ["row-1", "row-499", "row-501", "row-900"]
expect(cachedIndex.priority(candidates: cachedCandidates, pivot: "row-500") == near,
       "cached order index reproduces the uncached anchor priority")
expect(cachedIndex.priority(candidates: Set(order), pivot: nil) == bottom,
       "cached order index reproduces the cold bottom-up priority")
cachedIndex.update(order: order)
expect(cachedIndex.order == order, "an unchanged order does not rebuild the index")
cachedIndex.update(order: Array(order.reversed()))
expect(cachedIndex.priority(candidates: ["row-0", "row-999"], pivot: nil) == ["row-0", "row-999"],
       "a changed order rebuilds the index before prioritizing")

// A changed span is not a set of deletions: a surviving selected/measured row
// inside it must keep its host, height and committed admission.
let unchanged = ChatRowOrderChange(previous: ["a", "b"], next: ["a", "b"])
expect(!unchanged.structureChanged && unchanged.removed.isEmpty,
       "a content-only update preserves order and all measured hosts")
let beforeMutation = ["a", "read", "obsolete", "tail", "end"]
let afterMutation = ["a", "new", "read", "tail", "end"]
let mutation = ChatRowOrderChange(previous: beforeMutation, next: afterMutation)
expect(mutation.firstChangedIndex == 1 && mutation.removed == ["obsolete"],
       "a replacement around a surviving reading row retires only the truly absent identity")
var cachedHeights = ["a": 100.0, "read": 900.0, "obsolete": 40.0, "tail": 500.0, "end": 100.0]
for id in mutation.removed { cachedHeights.removeValue(forKey: id) }
expect(cachedHeights["read"] == 900 && cachedHeights["tail"] == 500,
       "interior survivors keep their exact real heights for anchored layout")
cachedHeights["new"] = 30
let priorLayout = ChatViewportLayout.frames(for: beforeMutation.map {
    .init(id: $0, height: $0 == "obsolete" ? 40 : cachedHeights[$0]!)
})
let updatedLayout = ChatViewportLayout.frames(for: afterMutation.map {
    .init(id: $0, height: cachedHeights[$0]!)
})
let retainedAnchor = ChatViewportLayout.anchors(in: priorLayout, offset: 200, viewport: 300)
expect(ChatViewportLayout.offset(after: updatedLayout, anchors: retainedAnchor, previous: 200,
                                viewport: 300, following: false) == 230,
       "a surviving reading row remains on its same line after an interior replacement")
let reordered = ["a", "tail", "read", "end"]
let reorder = ChatRowOrderChange(previous: ["a", "read", "tail", "end"], next: reordered)
expect(reorder.structureChanged && reorder.removed.isEmpty && reorder.firstChangedIndex == 1,
       "reordering with unchanged endpoints/count invalidates indices without evicting any host")
cachedIndex.update(order: reordered)
expect(cachedIndex.priority(candidates: ["read", "tail"], pivot: "a") == ["tail", "read"],
       "surviving interior rows use their new preparation priority")
expect(ChatRowOrderChange(previous: ["a"], next: ["old", "a", "new"]).removed.isEmpty,
       "simultaneous history prepend and reply append never evict the existing host")
expect(ChatRowOrderChange(previous: ["a", "b"], next: []).removed == ["a", "b"],
       "an empty replacement retires every old host")
let wrapperOnly = ChatRowOrderChange(previous: ["a"], next: ["a"], wrappersChanged: true)
expect(wrapperOnly.structureChanged && wrapperOnly.removed.isEmpty,
       "history/footer wrapper changes update indices while retaining message geometry")
print("CHAT_PREPARATION_PASS \(checks) assertions (production admission and real-height geometry, no UIKit timing claims)")
