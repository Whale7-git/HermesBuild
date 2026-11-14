import Foundation

/// Coalesce the latest representable update outside SwiftUI's update pass.
/// Unlike onChange, delivery does not depend on same-frame change notifications.
/// Dismantling invalidates already-scheduled callbacks and releases their value.
@MainActor
final class TextSelectionUpdateRelay<Value> {
  typealias Action = @MainActor @Sendable () -> Void
  typealias Schedule = (@escaping Action) -> Void
  private let schedule: Schedule
  private var pending: Value?
  private var receive: ((Value) -> Void)?
  private var scheduled = false
  private var generation: UInt64 = 0

  init(schedule: @escaping Schedule = { action in DispatchQueue.main.async { action() } }) {
    self.schedule = schedule
  }

  func submit(_ value: Value, receive: @escaping (Value) -> Void) {
    pending = value
    self.receive = receive
    guard !scheduled else { return }
    scheduled = true
    let ticket = generation
    schedule { [weak self] in
      guard let self, ticket == self.generation else { return }
      let value = self.pending
      let receive = self.receive
      self.pending = nil
      self.receive = nil
      self.scheduled = false
      if let value { receive?(value) }
    }
  }

  func cancel() {
    generation &+= 1
    pending = nil
    receive = nil
    scheduled = false
  }
}
