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

extension Locked {
    /// Adds `element` to the array, under the lock.
    public func append<Element>(_ element: Element) where Value == [Element] { change { $0.append(element) } }
}

/// A count threads add to.
public final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    public init() {}
    public func add() { lock.withLock { n += 1 } }
    public var value: Int { lock.withLock { n } }
}

/// A flag one thread sets and others read.
public final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}

/// Numbers calls as they come (a fake failing its first, second… call).
public actor Checkpoints {
    private var count = 0
    public init() {}
    public func next() -> Int {
        count += 1
        return count
    }
}
