import Foundation

/// One setting in `Settings.store`: `@Pref("key") var name: Type = default`. Enums are stored by raw value.
/// Writes post `Settings.changed` with the key, so open windows apply the change at once.
@propertyWrapper
public struct Pref<Value> {
    public let key: String
    public let defaultValue: Value
    private let decode: (Any) -> Value?
    private let encode: (Value) -> Any

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
        decode = { $0 as? Value }
        encode = { $0 }
    }

    public init(wrappedValue: Value, _ key: String) where Value: RawRepresentable, Value.RawValue == String {
        self.key = key
        defaultValue = wrappedValue
        decode = { ($0 as? String).flatMap(Value.init(rawValue:)) }
        encode = { $0.rawValue }
    }

    public var wrappedValue: Value {
        get { Settings.store.object(forKey: key).flatMap(decode) ?? defaultValue }
        nonmutating set {
            Settings.store.set(encode(newValue), forKey: key)
            NotificationCenter.default.post(name: Settings.changed, object: key)
        }
    }
}

/// Lets `Settings.resetAll()` find the keys of every `@Pref`.
protocol PrefKey { var key: String { get } }
extension Pref: PrefKey {}
