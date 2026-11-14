import Foundation

/// A completed document may merge once it is safe. Beginning a selection must
/// never dismantle the native view that already owns that selection.
struct ParagraphMergeState: Equatable {
    private(set) var enabled: Bool

    init(finished: Bool) { enabled = finished }

    mutating func update(finished: Bool, selecting: Bool) {
        if !finished { enabled = false }
        else if !selecting { enabled = true }
    }
}
