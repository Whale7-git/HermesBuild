// Headless declarations only; never linked into the application. The tests run
// the production selection aggregator and Foundation notification delivery.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
