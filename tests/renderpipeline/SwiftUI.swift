// Minimal compile-time surface for headless document tests, not a UI renderer.
@_exported import Foundation
@_exported import Combine

public protocol ObservableObject: AnyObject {}
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}
public struct EnvironmentValues {
    private var values: [ObjectIdentifier: Any] = [:]
    public init() {}
    public subscript<Key: EnvironmentKey>(_ key: Key.Type) -> Key.Value {
        get { values[ObjectIdentifier(key)] as? Key.Value ?? Key.defaultValue }
        set { values[ObjectIdentifier(key)] = newValue }
    }
}
