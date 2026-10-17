import Foundation

/// A value that threads share: every read and change takes the lock. For what a notification or a callback on another
/// thread records while a test reads it (an `@unchecked Sendable` class with a bare `var` is a data race).
public final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    public init(_ value: Value) { stored = value }

    public var value: Value { lock.withLock { stored } }

    /// Changes the value in place, under the lock.
    @discardableResult public func change<T>(_ body: (inout Value) throws -> T) rethrows -> T { try lock.withLock { try body(&stored) } }
}
