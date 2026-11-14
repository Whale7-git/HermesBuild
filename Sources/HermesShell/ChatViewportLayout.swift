import Foundation

/// Upright content coordinates, shared by UIKit and the Linux regression tests.
/// Heights come from the mounted SwiftUI views, never from text-length estimates.
enum ChatViewportLayout {
    struct Row: Equatable {
        let id: String
        let height: Double
    }

    struct Frame: Equatable {
        let id: String
        let top: Double
        let height: Double
        var bottom: Double { top + height }
    }

    struct Anchor {
        let id: String
        let offsetInRow: Double
    }

    static func frames(for rows: [Row]) -> [Frame] {
        var top = 0.0
        return rows.map { row in
            let height = row.height.isFinite ? max(1, row.height) : 1
            defer { top += height }
            return Frame(id: row.id, top: top, height: height)
        }
    }

    /// Apply already-validated, sorted row-height deltas in one tail pass.
    /// Earlier implementation shifted the entire suffix once per changed row
    /// (O(rows × changes)); opening several tool cards at once amplified that.
    /// The cumulative offset preserves the exact old frame coordinates.
    static func applyHeightDeltas(to frames: inout [Frame],
                                  sortedChanges: [(index: Int, delta: Double)]) {
        guard let first = sortedChanges.first else { return }
        precondition(first.index >= 0 && first.index < frames.count)
        var change = 0
        var precedingShift = 0.0
        for index in first.index..<frames.count {
            let old = frames[index]
            var ownDelta = 0.0
            if change < sortedChanges.count && sortedChanges[change].index == index {
                ownDelta = sortedChanges[change].delta
                change += 1
            }
            frames[index] = Frame(id: old.id, top: old.top + precedingShift,
                                  height: old.height + ownDelta)
            precedingShift += ownDelta
        }
        precondition(change == sortedChanges.count,
                     "geometry deltas must have unique, ascending committed indices")
    }

    /// Keep several visible edges, so deleting the first visible row can still
    /// preserve its surviving neighbour at the same screen coordinate.
    static func anchors(in frames: [Frame], offset: Double, viewport: Double) -> [Anchor] {
        frames[intersecting(in: frames, lower: offset, upper: offset + viewport)]
            .map { Anchor(id: $0.id, offsetInRow: offset - $0.top) }
    }

    /// Binary searches keep every pan tick independent of total history length.
    /// Bounds are exclusive: touching the viewport has zero visible pixels.
    static func intersecting(in frames: [Frame], lower: Double, upper: Double) -> Range<Int> {
        guard lower.isFinite, upper.isFinite, upper > lower else { return 0..<0 }
        var low = 0
        var high = frames.count
        while low < high {
            let middle = low + (high - low) / 2
            if frames[middle].bottom <= lower { low = middle + 1 }
            else { high = middle }
        }
        let start = low
        high = frames.count
        while low < high {
            let middle = low + (high - low) / 2
            if frames[middle].top < upper { low = middle + 1 }
            else { high = middle }
        }
        return start..<low
    }

    /// A target cannot be aligned until measured rows below it can fill the
    /// viewport. Otherwise a temporary clamp would land on an earlier message.
    static func navigationOffset(in frames: [Frame], id: String, offsetInRow: Double,
                                 viewport: Double, measurementPending: Bool) -> Double? {
        let frameByID = index(for: frames)
        guard viewport.isFinite, viewport > 0, offsetInRow.isFinite,
              let frame = frameByID[id] else { return nil }
        let within = min(max(0, offsetInRow), max(0, frame.height - 1))
        if measurementPending && (frames.last?.bottom ?? 0) < frame.top + within + viewport { return nil }
        return offset(after: frames, frameByID: frameByID, anchors: [.init(id: id, offsetInRow: within)],
            previous: frame.top, viewport: viewport, following: false)
    }

    /// One index per commit instead of one linear scan per anchor.
    static func index(for frames: [Frame]) -> [String: Frame] {
        Dictionary(frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Indexed form used by the controller: O(1) per anchor after a single pass
    /// over the frames, instead of O(anchors × rows).
    static func offset(after frames: [Frame], frameByID: [String: Frame], anchors: [Anchor],
                       previous: Double, viewport: Double, following: Bool) -> Double {
        let maximum = max(0, (frames.last?.bottom ?? 0) - viewport)
        if following { return maximum }
        for anchor in anchors {
            if let frame = frameByID[anchor.id] {
                // A collapsed row may no longer contain the old reading point.
                // Keep its last remaining point visible instead of skipping it.
                let within = min(anchor.offsetInRow, max(0, frame.height - 1))
                return min(maximum, max(0, frame.top + within))
            }
        }
        return min(maximum, max(0, previous))
    }

    /// Legacy signature kept for the geometry tests: builds the index once and
    /// forwards, so callers that already hold an index use the overload above.
    static func offset(after frames: [Frame], anchors: [Anchor], previous: Double,
                       viewport: Double, following: Bool) -> Double {
        offset(after: frames, frameByID: index(for: frames), anchors: anchors,
               previous: previous, viewport: viewport, following: following)
    }
}
