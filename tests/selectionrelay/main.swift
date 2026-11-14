import Foundation

@MainActor private final class WeakRelayProbe {
    weak var value: TextSelectionUpdateRelay<String>?
    init(_ value: TextSelectionUpdateRelay<String>?) { self.value = value }
}

@main struct SelectionRelayTests {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        var callbacks: [TextSelectionUpdateRelay<String>.Action] = []
        let relay = TextSelectionUpdateRelay<String> { callbacks.append($0) }
        var received: [String] = []
        relay.submit("empty first pass") { received.append($0) }
        relay.submit("populated final pass") { received.append($0) }
        expect(received.isEmpty, "representable updates must not mutate observed selection during the update pass")
        expect(callbacks.count == 1, "many preference changes schedule a single latest delivery")
        callbacks.removeFirst()()
        expect(received == ["populated final pass"], "the final populated layout survives same-frame coalescing")
        relay.submit("new width") { received.append($0) }
        callbacks.removeFirst()()
        expect(received.last == "new width", "size-only updates can refresh the model after initial delivery")
        relay.submit("old host") { received.append($0) }
        relay.cancel()
        relay.submit("replacement host") { received.append($0) }
        expect(callbacks.count == 2, "a replacement schedules a new generation independently of a stale callback")
        callbacks.removeFirst()()
        expect(!received.contains("old host") && received.last == "new width", "dismantled host cannot overwrite the replacement")
        callbacks.removeFirst()()
        expect(received.last == "replacement host", "the replacement receives its current layout")
        relay.submit("first callback") { value in
            received.append(value)
            relay.submit("reentrant update") { received.append($0) }
        }
        callbacks.removeFirst()()
        expect(received.last == "first callback" && callbacks.count == 1, "reentrant layout updates get a later pass")
        callbacks.removeFirst()()
        expect(received.last == "reentrant update", "reentrant delivery is not lost")
        var obsolete: TextSelectionUpdateRelay<String>? = TextSelectionUpdateRelay { callbacks.append($0) }
        let weakRelay = WeakRelayProbe(obsolete)
        obsolete?.submit("released host") { received.append($0) }
        obsolete = nil
        expect(weakRelay.value == nil, "scheduled delivery does not retain an unmounted host")
        callbacks.removeFirst()()
        expect(!received.contains("released host"), "released hosts never publish")
        let before = received.count
        relay.submit("cancelled pending") { received.append($0) }
        relay.cancel()
        relay.cancel()
        callbacks.removeFirst()()
        expect(received.count == before, "repeated cancellation is safe and drops pending values")
        print("SELECTION_RELAY_PASS \(checks) assertions (production delivery; UIKit gestures require device)")
    }
}
