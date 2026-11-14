import Foundation

/// The changed span may contain surviving rows (a reorder or two insertions
/// around an unchanged row). Those identities retain their measured geometry,
/// selection and host; only rows absent from the next order are retired.
struct ChatRowOrderChange {
    let firstChangedIndex: Int
    let structureChanged: Bool
    let removed: [String]

    init(previous: [String], next: [String], wrappersChanged: Bool = false) {
        var start = 0
        let shared = min(previous.count, next.count)
        while start < shared, previous[start] == next[start] { start += 1 }
        firstChangedIndex = start
        var oldEnd = previous.count
        var newEnd = next.count
        while oldEnd > start, newEnd > start, previous[oldEnd - 1] == next[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        structureChanged = wrappersChanged || start < oldEnd || start < newEnd
        guard start < oldEnd else { removed = []; return }
        let retained = Set(next)
        removed = previous[start..<oldEnd].filter { !retained.contains($0) }
    }
}

/// Admission for expensive hosts, separate from committed message geometry.
/// A queued row without a real height is absent from the viewport, not assigned
/// a placeholder height. Active work survives until ready or explicit suspend.
struct ChatPreparationQueue {
    private(set) var queued = Set<String>()
    private(set) var active = Set<String>()
    let pendingLimit: Int

    init(pendingLimit: Int = 6) { self.pendingLimit = max(1, pendingLimit) }

    mutating func enqueue(_ id: String) { queued.insert(id) }
    mutating func retain(_ ids: Set<String>) {
        queued.formIntersection(ids)
        active.formIntersection(ids)
    }
    mutating func remove(_ id: String) { queued.remove(id); active.remove(id) }
    mutating func finish(_ id: String) { active.remove(id) }
    mutating func suspend(_ id: String) { active.remove(id); queued.insert(id) }

    /// Order is supplied by current visibility, then distance from the reading
    /// anchor. Restarting an already admitted row does not use another slot.
    mutating func take(prioritized ids: [String], limit: Int) -> [String] {
        var result: [String] = []
        for id in ids where queued.contains(id) {
            guard result.count < max(0, limit) else { break }
            guard active.contains(id) || active.count < pendingLimit else { continue }
            queued.remove(id)
            active.insert(id)
            result.append(id)
        }
        return result
    }

    func canTake(from ids: [String]) -> Bool {
        ids.contains { queued.contains($0) && (active.contains($0) || active.count < pendingLimit) }
    }

    /// A duplicated identifier must not trap the UI; the first occurrence wins.
    static func indices(for order: [String]) -> [String: Int] {
        Dictionary(order.enumerated().map { ($0.element, $0.offset) },
                   uniquingKeysWith: { first, _ in first })
    }

    static func priority(order: [String], candidates: Set<String>, pivot: String?) -> [String] {
        priority(indices: indices(for: order), orderCount: order.count, candidates: candidates, pivot: pivot)
    }

    static func priority(indices: [String: Int], orderCount: Int,
                         candidates: Set<String>, pivot: String?) -> [String] {
        let centre = pivot.flatMap { indices[$0] } ?? max(0, orderCount - 1)
        return candidates.filter { indices[$0] != nil }.sorted {
            let a = indices[$0]!, b = indices[$1]!
            let left = abs(a - centre), right = abs(b - centre)
            return left == right ? a > b : left < right
        }
    }

    /// New history grows backwards from the existing first row; new replies
    /// grow forwards from the existing last row. Do not expose holes just
    /// because a small tool/footer finished before an adjacent long message.
    static func admitted(order: [String], measured: Set<String>, committed: Set<String>) -> [String] {
        let retained = committed.intersection(order)
        if retained.isEmpty { return Array(order.reversed().prefix { measured.contains($0) }.reversed()) }
        var accepted = retained
        var start = 0
        while start < order.count {
            if retained.contains(order[start]) { start += 1; continue }
            var end = start
            while end < order.count, !retained.contains(order[end]) { end += 1 }
            let gap = order[start..<end]
            if start == 0 { accepted.formUnion(gap.reversed().prefix { measured.contains($0) }) }
            else if end == order.count { accepted.formUnion(gap.prefix { measured.contains($0) }) }
            else if gap.allSatisfy({ measured.contains($0) }) { accepted.formUnion(gap) }
            start = end
        }
        return order.filter { accepted.contains($0) }
    }
}

/// Row-order index shared by every prioritization pass. Rebuilt only when the
/// order changes, so a 16ms batch does not rebuild a full-history dictionary.
struct ChatPreparationIndex {
    private(set) var order: [String] = []
    private var indices: [String: Int] = [:]

    mutating func update(order newOrder: [String]) {
        guard newOrder != order else { return }
        order = newOrder
        indices = ChatPreparationQueue.indices(for: newOrder)
    }

    func priority(candidates: Set<String>, pivot: String?) -> [String] {
        ChatPreparationQueue.priority(indices: indices, orderCount: order.count,
                                      candidates: candidates, pivot: pivot)
    }
}
