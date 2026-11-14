import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}
typealias Layout = ChatViewportLayout
let original = Layout.frames(for: [
    .init(id: "a", height: 200), .init(id: "b", height: 1000),
    .init(id: "c", height: 300), .init(id: "d", height: 500)
])
let reading = Layout.anchors(in: original, offset: 650, viewport: 700)
expect(reading.first?.id == "b", "reading point is INSIDE a long message")
expect(reading.first?.offsetInRow == 450, "preserves pixel offset, not just row identity")

let prepended = Layout.frames(for: [
    .init(id: "older", height: 730), .init(id: "a", height: 200),
    .init(id: "b", height: 1000), .init(id: "c", height: 300), .init(id: "d", height: 500)
])
let paged = Layout.offset(after: prepended, anchors: reading, previous: 650, viewport: 700, following: false)
expect(paged == 1380, "pagination preserves the same line of the same message")
expect(prepended[2].top - paged == original[1].top - 650, "screen edge unchanged after prepend")

let streamed = Layout.frames(for: [
    .init(id: "a", height: 200), .init(id: "b", height: 1000),
    .init(id: "c", height: 300), .init(id: "d", height: 900)
])
expect(Layout.offset(after: streamed, anchors: reading, previous: 650, viewport: 700, following: false) == 650,
       "streaming BELOW the reading point never shifts it")
expect(Layout.offset(after: streamed, anchors: reading, previous: 650, viewport: 700, following: true) == 1700,
       "following lands on the new exact bottom")

let expandedAbove = Layout.frames(for: [
    .init(id: "a", height: 700), .init(id: "b", height: 1000),
    .init(id: "c", height: 300), .init(id: "d", height: 500)
])
expect(Layout.offset(after: expandedAbove, anchors: reading, previous: 650, viewport: 700, following: false) == 1150,
       "late rich-text layout ABOVE viewport preserves visible content")

let folded = Layout.frames(for: [
    .init(id: "a", height: 200), .init(id: "b", height: 120),
    .init(id: "c", height: 300), .init(id: "d", height: 1500)
])
expect(Layout.offset(after: folded, anchors: reading, previous: 650, viewport: 700, following: false) == 319,
       "collapse inside a long message keeps its remaining tail visible")

let deleted = Layout.frames(for: [
    .init(id: "a", height: 200), .init(id: "c", height: 300), .init(id: "d", height: 1500)
])
expect(Layout.offset(after: deleted, anchors: reading, previous: 650, viewport: 700, following: false) == 0,
       "deleted primary anchor uses a visible neighbour and clamps at top")
let boundary = Layout.anchors(in: original, offset: 200, viewport: 700)
expect(boundary.first?.id == "b", "zero visible pixels do not count as a visible row")
expect(Layout.offset(after: [], anchors: reading, previous: 600, viewport: 700, following: false) == 0,
       "empty transcript is bounded")
expect(Layout.offset(after: original, anchors: [], previous: -50, viewport: 700, following: false) == 0,
       "top rubber band is clamped only when committing new content")
expect(Layout.offset(after: original, anchors: [], previous: 9000, viewport: 700, following: false) == 1300,
       "bottom rubber band is bounded")
expect(Layout.offset(after: original, anchors: reading, previous: 650, viewport: 400, following: true) == 1600,
       "keyboard opening keeps the newest edge visible while following")
expect(Layout.offset(after: original, anchors: reading, previous: 650, viewport: 400, following: false) == 650,
       "keyboard opening preserves the reading anchor while detached")
let invalid = Layout.frames(for: [.init(id: "a", height: .nan), .init(id: "b", height: -20)])
expect(invalid.last?.bottom == 2, "transient invalid measurements cannot poison content coordinates")
expect(Layout.offset(after: original, anchors: reading, previous: 650, viewport: 5000, following: true) == 0,
       "short content has a zero scroll range")

// Property checks: an arbitrary prepend and an arbitrary growth below a long
// visible row preserve its exact screen position for every reading point.
for step in 0..<200 {
    let before = Double(step * 13 + 17)
    let inside = Double(step * 3 + 5)
    let old = Layout.frames(for: [.init(id: "head", height: before), .init(id: "read", height: 2000),
                                  .init(id: "tail", height: 3000)])
    let offset = before + inside
    let anchor = Layout.anchors(in: old, offset: offset, viewport: 600)
    let extra = Double(step * 7 + 1)
    let after = Layout.frames(for: [.init(id: "page", height: extra), .init(id: "head", height: before),
                                    .init(id: "read", height: 2000), .init(id: "tail", height: 4000)])
    let result = Layout.offset(after: after, anchors: anchor, previous: offset, viewport: 600, following: false)
    expect(result == offset + extra, "exact reading position survives mutation \(step)")
}
// Real measured heights stay unchanged as the attached window moves. Searching
// 10,000 rows must match an exhaustive overlap check at boundaries and overscroll.
let longHistory = Layout.frames(for: (0..<10_000).map {
    Layout.Row(id: "row-\($0)", height: $0 % 11 == 0 ? 1800 : Double(30 + $0 % 160))
})
for step in -2..<202 {
    let lower = Double(step) * (longHistory.last!.bottom / 200)
    let upper = lower + 2400
    let window = Layout.intersecting(in: longHistory, lower: lower, upper: upper)
    let expected = longHistory.filter { $0.bottom > lower && $0.top < upper }
    expect(Array(longHistory[window]) == expected, "binary window matches overlap scan \(step)")
    expect(Layout.anchors(in: longHistory, offset: lower, viewport: 2400).map(\.id) == expected.map(\.id),
           "long-history anchor order stays stable \(step)")
}
expect(Layout.intersecting(in: original, lower: 200, upper: 1200) == 1..<2,
       "rows with zero pixels at either edge stay outside the window")
expect(Layout.intersecting(in: original, lower: 0, upper: 0).isEmpty, "zero viewport has no rows")
expect(Layout.intersecting(in: [], lower: 0, upper: 100).isEmpty, "empty history has no window")
expect(Layout.intersecting(in: original, lower: .nan, upper: 100).isEmpty, "invalid viewport is bounded")
print("VIEWPORT_GEOMETRY_PASS \(checks) assertions (pure geometry; device UX untested)")
