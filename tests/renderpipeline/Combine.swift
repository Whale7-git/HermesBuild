// Headless test module; never linked into the app. Implements only the
// synchronous current-value subscription semantics used by the document.
import Foundation

public final class AnyCancellable {
    private var onCancel: (() -> Void)?
    public init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel?(); onCancel = nil }
    deinit { cancel() }
}

public final class CurrentValuePublisher<Value> {
    private var value: Value
    private var observers: [UUID: (Value) -> Void] = [:]
    init(_ value: Value) { self.value = value }
    public func sink(receiveValue: @escaping (Value) -> Void) -> AnyCancellable {
        let id = UUID()
        observers[id] = receiveValue
        receiveValue(value)
        return AnyCancellable { [weak self] in self?.observers.removeValue(forKey: id) }
    }
    func send(_ value: Value) {
        self.value = value
        for observer in Array(observers.values) { observer(value) }
    }
}

@propertyWrapper
public struct Published<Value> {
    private final class Storage {
        var value: Value
        let publisher: CurrentValuePublisher<Value>
        init(_ value: Value) { self.value = value; publisher = CurrentValuePublisher(value) }
    }
    private let storage: Storage
    public init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    public var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue; storage.publisher.send(newValue) }
    }
    public var projectedValue: CurrentValuePublisher<Value> { storage.publisher }
}
