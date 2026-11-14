/// A selected document must not be replaced underneath UIKit's text handles.
/// Keep only the latest publication and apply it once interaction has ended.
struct TextualSelectionPublication<Value: Equatable> {
  private(set) var displayed: Value?
  private(set) var pending: Value?

  mutating func receive(_ value: Value, interacting: Bool) -> Value? {
    pending = value
    return resume(interacting: interacting)
  }

  mutating func resume(interacting: Bool) -> Value? {
    guard !interacting, let value = pending else { return nil }
    pending = nil
    guard value != displayed else { return nil }
    displayed = value
    return value
  }

  mutating func cancel() { pending = nil }
}
