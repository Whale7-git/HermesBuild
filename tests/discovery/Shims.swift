#if !canImport(Combine)
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
#endif
