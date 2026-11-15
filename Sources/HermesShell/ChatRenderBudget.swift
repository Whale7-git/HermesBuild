import Foundation

/// A lightweight budget for expensive rendered hosts, independent of the
/// measured-height dictionary. Costs are conservative weights, not a RAM meter.
enum ChatRenderBudget {
    struct Entry: Equatable {
        let id: String
        let cost: Int
        let lastUse: UInt64
    }

    struct Limits {
        let count: Int
        let cost: Int
    }

    /// Required visible/interactive rows always win, even when one very large
    /// row exceeds the budget. Candidates are already ordered by viewport distance.
    static func window(required: [Entry], candidates: [Entry], limits: Limits) -> Set<String> {
        var ids = Set(required.map(\.id))
        var cost = required.reduce(0) { $0 + max(0, $1.cost) }
        for entry in candidates where !ids.contains(entry.id) {
            let additional = max(0, entry.cost)
            guard ids.count < max(0, limits.count), cost + additional <= max(0, limits.cost) else { continue }
            ids.insert(entry.id)
            cost += additional
        }
        return ids
    }

    /// Least-recently-used hosts are released; geometry is deliberately absent
    /// from this policy so eviction can never alter contentSize or contentOffset.
    static func victims(in entries: [Entry], keeping: Set<String>, limits: Limits) -> [String] {
        var count = entries.count
        var cost = entries.reduce(0) { $0 + max(0, $1.cost) }
        // A normal viewport commit already fits the host limits. Do not
        // allocate a filtered/sorted candidate list on every such frame.
        guard count > max(0, limits.count) || cost > max(0, limits.cost) else {
            return []
        }
        var result: [String] = []
        for entry in entries.filter({ !keeping.contains($0.id) }).sorted(by: {
            $0.lastUse == $1.lastUse ? $0.id < $1.id : $0.lastUse < $1.lastUse
        }) {
            guard count > max(0, limits.count) || cost > max(0, limits.cost) else { break }
            result.append(entry.id)
            count -= 1
            cost -= max(0, entry.cost)
        }
        return result
    }
}
