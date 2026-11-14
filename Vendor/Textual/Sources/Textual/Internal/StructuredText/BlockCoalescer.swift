import Foundation

/// Groups consecutive plain paragraphs so one native text view can own them.
///
/// Pure index math: no `AttributedString`, SwiftUI or UIKit dependency, so the
/// grouping rule can be exercised by the Linux regression tests. The view layer
/// decides which blocks are plain paragraphs and turns a group back into a range
/// of the source document.
///
/// There is deliberately no size budget here. Coalescing only runs for finished
/// messages, where the document no longer changes; a budget would make grouping
/// depend on the final character count and split a pair at 4,001 characters
/// while never splitting a single long paragraph.
enum BlockCoalescer {
  /// Separator runs have no paragraph intent. Check their original characters
  /// without allocating/trimming a second copy of every finished paragraph.
  static func isBlank<Characters: Sequence>(_ characters: Characters) -> Bool
    where Characters.Element == Character {
    let whitespace = CharacterSet.whitespacesAndNewlines
    return characters.allSatisfy { $0.unicodeScalars.allSatisfy(whitespace.contains) }
  }

  struct Item: Equatable {
    /// Paragraph without math or inline attachments.
    let isMergeable: Bool
    /// True when this block starts exactly where the previous one ends.
    /// A gap would drop characters if the ranges were joined.
    let isContiguousWithPrevious: Bool
  }

  /// Returns inclusive index ranges, one per rendered block.
  static func groups(_ items: [Item]) -> [ClosedRange<Int>] {
    guard !items.isEmpty else { return [] }

    var groups: [ClosedRange<Int>] = []
    var start = 0

    for index in 1..<items.count {
      let item = items[index]
      let canMerge = item.isMergeable
        && items[index - 1].isMergeable
        && item.isContiguousWithPrevious

      if !canMerge {
        groups.append(start...(index - 1))
        start = index
      }
    }

    groups.append(start...(items.count - 1))
    return groups
  }
}
