import Foundation

/// Snapshot only the explicitly opened message's images. No history fetch or
/// cross-session aggregation is needed to move between these pages.
struct ImageGallerySelection: Equatable {
    let ids: [String]
    private(set) var selected: String
    var index: Int { ids.firstIndex(of: selected) ?? 0 }

    init(ids: [String], selected: String) {
        var seen = Set<String>()
        self.ids = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.selected = self.ids.contains(selected) ? selected : (self.ids.first ?? "")
    }
    mutating func select(_ id: String) {
        if ids.contains(id) { selected = id }
    }
    mutating func step(_ delta: Int) {
        guard !ids.isEmpty else { return }
        // Clamp before adding so malformed/accessibility input cannot overflow.
        let shift = min(ids.count, max(-ids.count, delta))
        selected = ids[min(ids.count - 1, max(0, index + shift))]
    }
}
