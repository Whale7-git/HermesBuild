import Foundation

private final class Notifications: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier] = []
    func record(_ object: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        values.append(ObjectIdentifier(object))
    }
    var observed: [ObjectIdentifier] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@main struct SelectionActivityTests {
    @MainActor static func main() {
        var checks = 0
        func expect(_ value: Bool, _ description: String) {
            checks += 1
            precondition(value, description)
        }
        let events = Notifications()
        let observer = NotificationCenter.default.addObserver(
            forName: TextualSelectionActivity.didChangeNotification, object: nil, queue: nil
        ) { notification in
            if let object = notification.object as AnyObject? { events.record(object) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let message = TextualSelectionActivity()
        let otherMessage = TextualSelectionActivity()
        let first = NSObject(), second = NSObject(), other = NSObject()
        expect(!message.isSelecting && events.observed.isEmpty, "idle messages do not publish")
        message.update(first, selecting: true)
        expect(message.isSelecting && events.observed == [ObjectIdentifier(message)],
               "read-only selection starts notify the scroll container")
        for _ in 0..<1000 { message.update(first, selecting: true) }
        expect(events.observed.count == 1, "dragging a handle does not emit a notification per range change")
        message.update(second, selecting: true)
        message.update(first, selecting: false)
        expect(message.isSelecting && events.observed.count == 1,
               "another fragment holding selection keeps the message pinned")
        otherMessage.update(other, selecting: true)
        expect(events.observed.last == ObjectIdentifier(otherMessage) && events.observed.count == 2,
               "another message has its own independent transition")
        message.update(second, selecting: false)
        expect(!message.isSelecting && otherMessage.isSelecting && events.observed.count == 3,
               "the last fragment ending selection unpins only its message")
        message.update(second, selecting: false)
        message.update(first, selecting: false)
        expect(events.observed.count == 3, "repeated retirement is idempotent")
        otherMessage.update(other, selecting: false)
        expect(!otherMessage.isSelecting && events.observed.count == 4,
               "ending the final selection emits a wakeup without another stream frame")
        message.update(first, selecting: true)
        message.update(first, selecting: false)
        expect(events.observed.suffix(2).allSatisfy { $0 == ObjectIdentifier(message) },
               "a reused fragment can begin and finish another selection")
        print("SELECTION_ACTIVITY_PASS \(checks) assertions (production transitions/notifications; native gestures require device)")
    }
}
