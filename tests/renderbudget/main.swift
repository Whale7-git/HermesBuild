import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

typealias Budget = ChatRenderBudget
func entry(_ id: String, _ cost: Int = 1, _ used: UInt64 = 0) -> Budget.Entry {
    .init(id: id, cost: cost, lastUse: used)
}

let limits = Budget.Limits(count: 4, cost: 10)
let selected = Budget.window(required: [entry("visible", 3)],
    candidates: [entry("near", 4), entry("huge", 20), entry("next", 3), entry("far", 1)], limits: limits)
expect(selected == ["visible", "near", "next"], "prefetch respects weighted cost and distance order")
expect(Budget.window(required: [entry("visible", 50)], candidates: [entry("near")], limits: limits) == ["visible"],
       "a single visible oversized row is retained without admitting extra hosts")
expect(Budget.window(required: [entry("selected", 50), entry("visible", 50)], candidates: [], limits: limits)
       == ["selected", "visible"], "selection and visible text survive an over-budget interaction")
expect(Budget.window(required: [entry("same", 1)], candidates: [entry("same", 1), entry("next", 1)],
                     limits: .init(count: 2, cost: 2)) == ["same", "next"],
       "required/candidate overlap never consumes a second host slot")

let hosts = [entry("old", 1, 1), entry("new", 1, 4), entry("read", 1, 0), entry("middle", 1, 3)]
expect(Budget.victims(in: hosts, keeping: ["read"], limits: .init(count: 2, cost: 99)) == ["old", "middle"],
       "eviction releases least recently visited hosts and pins the current reading point")
expect(Budget.victims(in: [entry("large", 20), entry("small", 1, 2)], keeping: [],
                      limits: .init(count: 10, cost: 2)) == ["large"],
       "cost pressure evicts before the host-count cap is reached")
expect(Budget.victims(in: hosts, keeping: Set(hosts.map(\.id)), limits: .init(count: 0, cost: 0)).isEmpty,
       "pressure never tears out protected text or a menu")
expect(Budget.victims(in: [], keeping: [], limits: .init(count: 0, cost: 0)).isEmpty,
       "empty cache is safe under memory pressure")

// Visit 10,000 row identities, reverse direction, and refresh recency. Revisit
// admission must prefer the local viewport and the working set stays bounded.
var cache: [String: Budget.Entry] = [:]
var clock: UInt64 = 0
let movements = Array(stride(from: 0, to: 10_000, by: 19))
    + Array(stride(from: 9999, through: 0, by: -23))
for centre in movements {
    let visibleIDs = (max(0, centre - 2)...min(9999, centre + 2)).map { "row-\($0)" }
    let neighbourIDs = (-20...20).map { centre + $0 }.filter { (0..<10_000).contains($0) }
        .sorted { abs($0 - centre) < abs($1 - centre) }.map { "row-\($0)" }
    let wanted = Budget.window(required: visibleIDs.map { entry($0, 3) },
        candidates: neighbourIDs.map { entry($0, 3) }, limits: .init(count: 16, cost: 48))
    for id in wanted {
        clock += 1
        cache[id] = entry(id, 3, clock)
    }
    let evicted = Budget.victims(in: Array(cache.values), keeping: wanted,
        limits: .init(count: 24, cost: 72))
    for id in evicted { cache.removeValue(forKey: id) }
    expect(cache.count <= 24, "host count bounded at reading position \(centre)")
    expect(cache.values.reduce(0) { $0 + $1.cost } <= 72, "layout cost bounded at \(centre)")
    expect(Set(visibleIDs).isSubset(of: cache.keys), "visible text retained at \(centre)")
}
print("RENDER_BUDGET_PASS \(checks) assertions (pure admission/LRU; device rendering untested)")
