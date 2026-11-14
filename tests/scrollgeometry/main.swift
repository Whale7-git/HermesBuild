import Foundation

// 滚动几何的离线回归。
//
// 这一组补的是本项目最大的一块测试空白：`StableChatScrollView` + Coordinator +
// Geometry 共约 1400 行，历史上零覆盖，而「跳一下」「卡住」「回不到最新」这些
// 用户可见的 bug 全部出自这里。判定逻辑现在抽成了 `ChatGeometryPlan`（纯函数），
// 加上已有的 `ChatViewportLayout`，两条腿都能在容器里跑。

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

typealias Layout = ChatViewportLayout
typealias Plan = ChatGeometryPlan

// MARK: - 决策：结构变化优先于一切

// 结构变了（行序/测量集合变了）就必须整表重算，就地平移的前提是行集合不变。
expect(Plan.plan(structureChanged: true, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["a": 100], committedHeights: ["a": 90],
                 contentBottom: 5000, maxIncrementalRows: 8) == .rebuild,
       "a structural change forces a full rebuild even with a small delta")

// Only real row-structure changes demand a full rebuild; keyboard height alone does not.
expect(Plan.plan(structureChanged: true, viewport: 400, bottomPadding: 0,
                 pendingDeltas: [:], committedHeights: [:],
                 contentBottom: 5000, maxIncrementalRows: 8) == .rebuild,
       "true row structure changes still require a rebuild")
expect(Plan.plan(structureChanged: false, viewport: 400, bottomPadding: 0,
                 pendingDeltas: [:], committedHeights: ["row": 100],
                 contentBottom: 100, maxIncrementalRows: 8) == .unchanged,
       "keyboard-only viewport resize is not a row-geometry change")

// MARK: - 决策：底部留白非零时不可增量

// 内容不足一屏时所有 top 都随留白平移，增量路径会算错位置。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 120,
                 pendingDeltas: ["a": 100], committedHeights: ["a": 90],
                 contentBottom: 680, maxIncrementalRows: 8) == .rebuild,
       "non-zero bottom padding forces a rebuild: every top shifts with the padding")

// MARK: - 决策：无增量时不做事

// 最常见的空转路径：流式没产生新高度，不该白跑一遍几何计算。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: [:], committedHeights: ["a": 90],
                 contentBottom: 5000, maxIncrementalRows: 8) == .unchanged,
       "no pending deltas means nothing to do")

// MARK: - 决策：单行增量走快路径

// 这是流式回答的主路径：只有最后一行在变高，改一个元素、平移零长度。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["last": 240], committedHeights: ["last": 200],
                 contentBottom: 5000, maxIncrementalRows: 8) == .applyDeltas,
       "a single growing row takes the incremental path")

// 正好等于阈值仍然走增量。
var atLimit: [String: Double] = [:]
var atLimitCommitted: [String: Double] = [:]
for i in 0..<8 {
    atLimit["row-\(i)"] = 120
    atLimitCommitted["row-\(i)"] = 100
}
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: atLimit, committedHeights: atLimitCommitted,
                 contentBottom: 5000, maxIncrementalRows: 8) == .applyDeltas,
       "exactly maxIncrementalRows still fits the incremental path")

// 超过阈值：逐行平移会退化成 O(n²)，整表重建只有一次线性扫描。
var overLimit = atLimit
overLimit["row-8"] = 120
var overLimitCommitted = atLimitCommitted
overLimitCommitted["row-8"] = 100
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: overLimit, committedHeights: overLimitCommitted,
                 contentBottom: 5000, maxIncrementalRows: 8) == .rebuild,
       "more than maxIncrementalRows collapses to a rebuild instead of O(n squared) shifts")

// MARK: - 决策：未提交的行必须走重建

// 历史中间的空洞：增量路径只能改已存在的行，硬走会丢掉这次高度。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["ghost": 300], committedHeights: ["a": 90],
                 contentBottom: 5000, maxIncrementalRows: 8) == .rebuild,
       "a delta for an uncommitted row falls back to a rebuild")

// MARK: - build152：短会话缩小后不再整表重建

// build151 已移除全局底部补白；高度越过视口边界并不会移动其他行。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["big": 10], committedHeights: ["big": 900],
                 contentBottom: 810, maxIncrementalRows: 8) == .applyDeltas,
       "top-aligned short chat updates must preserve row identities/anchors")
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["short": 120], committedHeights: ["short": 80],
                 contentBottom: 80, maxIncrementalRows: 8) == .applyDeltas,
       "a short streamed reply can grow incrementally below viewport height")

// 收缩后仍然撑满一屏，则可以增量。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["big": 700], committedHeights: ["big": 900],
                 contentBottom: 2000, maxIncrementalRows: 8) == .applyDeltas,
       "shrinking while still taller than the viewport keeps the incremental path")

// 刚好等于视口高度：`>=` 允许增量（不需要留白）。
expect(Plan.plan(structureChanged: false, viewport: 800, bottomPadding: 0,
                 pendingDeltas: ["big": 800], committedHeights: ["big": 900],
                 contentBottom: 900, maxIncrementalRows: 8) == .applyDeltas,
       "content exactly one viewport tall needs no padding")

// MARK: - 锚点保持：行高变化后可见首行的 offsetInRow 不变

let base = Layout.frames(for: [
    .init(id: "a", height: 200), .init(id: "b", height: 1000), .init(id: "c", height: 300),
])
let reading = Layout.anchors(in: base, offset: 650, viewport: 700)
expect(reading.first?.id == "b", "the reading anchor is the row under the viewport top")
expect(reading.first?.offsetInRow == 450, "the anchor keeps the pixel offset inside the row")

// 同一行变高：锚点仍然指向同一行、同一像素偏移。
let grown = Layout.frames(for: [
    .init(id: "a", height: 200), .init(id: "b", height: 1400), .init(id: "c", height: 300),
])
let afterGrowth = Layout.offset(after: grown, anchors: reading, previous: 650,
                                viewport: 700, following: false)
expect(afterGrowth == 650, "a row growing below the anchor never moves it")
expect(Layout.anchors(in: grown, offset: afterGrowth, viewport: 700).first?.offsetInRow == 450,
       "the pixel offset inside the row survives a height change")

// MARK: - prepend 保位：前插 N 行后原首行仍在同一视口位置

for pages in 1...5 {
    var rows: [Layout.Row] = []
    for page in 0..<pages {
        rows.append(.init(id: "page-\(page)-0", height: 400))
        rows.append(.init(id: "page-\(page)-1", height: 250))
    }
    rows.append(.init(id: "a", height: 200))
    rows.append(.init(id: "b", height: 1000))
    rows.append(.init(id: "c", height: 300))
    let prepended = Layout.frames(for: rows)
    let moved = Layout.offset(after: prepended, anchors: reading, previous: 650,
                              viewport: 700, following: false)
    let added = Double(pages) * 650
    expect(moved == 650 + added, "prepending \(pages) page(s) shifts by exactly their height")
    // 原首行在屏幕上的相对位置不变。
    let frame = prepended.first { $0.id == "b" }!
    expect(frame.top - moved == base.first { $0.id == "b" }!.top - 650,
           "the anchored row keeps its screen position after \(pages) prepend(s)")
}

// MARK: - 边界：空帧

expect(Layout.frames(for: []).isEmpty, "empty rows produce no frames")
expect(Layout.anchors(in: [], offset: 0, viewport: 800).isEmpty, "empty history has no anchors")
expect(Layout.offset(after: [], anchors: reading, previous: 500, viewport: 800,
                     following: false) == 0,
       "an empty transcript clamps to the top instead of keeping a stale offset")
expect(Layout.offset(after: [], anchors: reading, previous: 500, viewport: 800,
                     following: true) == 0,
       "following an empty transcript lands at zero")
expect(Layout.intersecting(in: [], lower: 0, upper: 800).isEmpty,
       "an empty history has an empty visible window")

// MARK: - 边界：单行

let single = Layout.frames(for: [.init(id: "only", height: 400)])
expect(single.count == 1 && single[0].top == 0 && single[0].bottom == 400,
       "a single row starts at zero")
expect(Layout.intersecting(in: single, lower: 0, upper: 800) == 0..<1,
       "a short single row is visible")
expect(Layout.offset(after: single, anchors: [], previous: 0, viewport: 800,
                     following: true) == 0,
       "a single short row has no scroll range")
let singleAnchor = Layout.anchors(in: single, offset: 100, viewport: 200)
expect(singleAnchor.first?.offsetInRow == 100, "a single row preserves the in-row offset")
expect(Layout.offset(after: single, anchors: singleAnchor, previous: 100, viewport: 200,
                     following: false) == 100,
       "a single row resolves to its own offset")

// MARK: - 边界：超高单行（> 视口 3 倍）

let tall = Layout.frames(for: [.init(id: "tall", height: 2400)])
// 最大滚动量 = 内容高 - 视口高 = 2400 - 700 = 1700。探针必须落在这个范围内，
// 越界的探针会被正确夹取（下面单独断言）。
for probe in [0.0, 400.0, 1200.0, 1700.0] {
    let anchor = Layout.anchors(in: tall, offset: probe, viewport: 700)
    expect(anchor.first?.id == "tall", "a row taller than 3 viewports still yields an anchor")
    expect(anchor.first?.offsetInRow == probe,
           "the in-row offset inside a very tall row is exact at \(probe)")
    expect(Layout.offset(after: tall, anchors: anchor, previous: probe, viewport: 700,
                         following: false) == probe,
           "a very tall row resolves back to the same offset at \(probe)")
}
// 底部夹取：最大滚动量 = 内容高 - 视口高。
expect(Layout.offset(after: tall, anchors: [], previous: 99999, viewport: 700,
                     following: false) == 1700,
       "overscrolling a very tall row clamps to the exact maximum")
expect(Layout.offset(after: tall, anchors: [], previous: 0, viewport: 700,
                     following: true) == 1700,
       "following a very tall row lands on its exact bottom")

// MARK: - intersecting 与 anchors 的一致性

// 两者必须描述同一个窗口，否则「当前可见行」与「锚点」会打架。
for step in 0..<60 {
    let lower = Double(step) * 37
    let upper = lower + 500
    let window = Layout.intersecting(in: tall, lower: lower, upper: upper)
    let anchorIDs = Layout.anchors(in: tall, offset: lower, viewport: 500).map(\.id)
    expect(Array(tall[window]).map(\.id) == anchorIDs,
           "the anchor list matches the intersecting window at step \(step)")
}


 // build157: the hot-path planner must consult only the existing frame index,
 // not allocate a dictionary containing every historical row.
 var lookups = 0
 let fast = Plan.plan(structureChanged: false, bottomPadding: 0,
                      pendingIDs: ["last"], maxIncrementalRows: 8,
                      isCommitted: { id in lookups += 1; return id == "last" })
 expect(fast == .applyDeltas && lookups == 1,
        "streaming one changed row does exactly one committed-frame lookup")
 lookups = 0
 expect(Plan.plan(structureChanged: false, bottomPadding: 0,
                  pendingIDs: [], maxIncrementalRows: 8,
                  isCommitted: { _ in lookups += 1; return true }) == .unchanged && lookups == 0,
        "keyboard-only geometry change must not traverse cached heights")
 expect(Plan.plan(structureChanged: false, bottomPadding: 0,
                  pendingIDs: ["missing"], maxIncrementalRows: 8,
                  isCommitted: { _ in false }) == .rebuild,
        "uncommitted row still forces geometry rebuild")

// build160: compare the one-pass height-delta implementation with the
// previous suffix-shifting algorithm. This tests layout correctness rather
// than assuming an O(n) rewrite is visually equivalent.
func legacyShift(_ frames: inout [Layout.Frame],
                 _ changes: [(index: Int, delta: Double)]) {
    for (index, delta) in changes {
        let own = frames[index]
        frames[index] = .init(id: own.id, top: own.top, height: own.height + delta)
        for next in (index + 1)..<frames.count {
            let old = frames[next]
            frames[next] = .init(id: old.id, top: old.top + delta, height: old.height)
        }
    }
}

for count in [1, 2, 10, 100, 500, 2_000] {
    let baseRows = (0..<count).map { Layout.Row(id: "r-\($0)", height: Double(80 + $0 % 11)) }
    let oldFrames = Layout.frames(for: baseRows)
    let sets: [[(index: Int, delta: Double)]] = [
        [(0, 35)],
        [(count - 1, 55)],
        Array(Set([0, count / 2, count - 1])).sorted().map {
            ($0, $0 % 2 == 0 ? -15.0 : 24.0)
        }
    ]
    for changes in sets {
        var linear = oldFrames, reference = oldFrames
        Layout.applyHeightDeltas(to: &linear, sortedChanges: changes)
        legacyShift(&reference, changes)
        expect(linear == reference, "one-pass geometry equals suffix shifting for \(count) rows, \(changes.count) edits")
        let anchor = Layout.anchors(in: oldFrames,
                                    offset: Double(min(300, oldFrames.count * 70)),
                                    viewport: 420)
        let oldOffset = Layout.offset(after: reference, anchors: anchor,
                                      previous: 300, viewport: 420, following: false)
        let newOffset = Layout.offset(after: linear, anchors: anchor,
                                      previous: 300, viewport: 420, following: false)
        expect(oldOffset == newOffset, "one-pass geometry preserves anchor at \(count) rows")
    }
}
// The hot path of streaming one final reply row must not move predecessors.
var finalOnly = Layout.frames(for: (0..<2_000).map { .init(id: "r\($0)", height: 80) })
let beforeFinal = finalOnly[1_998]
Layout.applyHeightDeltas(to: &finalOnly, sortedChanges: [(1_999, 43)])
expect(finalOnly[1_998] == beforeFinal && finalOnly.last?.height == 123,
       "last-row streaming growth leaves all earlier geometry unchanged")

print("SCROLL_GEOMETRY_PASS \(checks) assertions (pure geometry; device UX untested)")
