import Foundation

/// Transient search metadata. It never changes text, selection or pasteboard data.
/// The native text bridge preserves this ordinal so the owning scroll view can
/// ask UIKit for the actual range rectangle, including inside code blocks.
public enum TextualFindOccurrenceAttribute: AttributedStringKey {
  public typealias Value = Int
  public static let name = "hermes.findOccurrence"
}
