import Foundation

/// Real measurements reused only while the owning Layout cache is valid. The
/// layout must invalidate this cache in updateCache, even if count is unchanged.
/// It deliberately does not infer content stability from a subview's index.
struct TextualBlockMeasurementCache<Context: Equatable, Size> {
  private struct Entry {
    let width: Double?
    let count: Int
    let sizes: [Size]
  }

  private var context: Context?
  private var entries: [Entry] = []

  mutating func invalidate() {
    context = nil
    entries.removeAll(keepingCapacity: true)
  }

  mutating func sizes(
    width: Double?, count: Int, context: Context, measure: (Int) -> Size
  ) -> [Size] {
    if self.context != context {
      invalidate()
      self.context = context
    }
    if let previous = entries.last, previous.count != count { entries.removeAll(keepingCapacity: true) }
    // NaN is not a stable proposal. Do not let an invalid probe poison later
    // finite, infinite or unspecified-width measurements.
    if width?.isNaN == true { return (0..<count).map(measure) }
    if let index = entries.firstIndex(where: { $0.width == width && $0.count == count }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      return entry.sizes
    }
    let sizes = (0..<count).map(measure)
    // SwiftUI can probe several proposals. Keep a small per-layout LRU rather
    // than retaining every resize width for the lifetime of a long document.
    entries.append(Entry(width: width, count: count, sizes: sizes))
    if entries.count > 3 { entries.removeFirst(entries.count - 3) }
    return sizes
  }
}
