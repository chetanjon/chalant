import Foundation

/// Time, injected.
///
/// Part 2 §3 is explicit: `Date()` is never called inside `Core`, so that
/// recency decay in `BiasSelector` is deterministic under test. Named `Clock`
/// to match the spec, which shadows the standard library protocol of the same
/// name inside this module.
public protocol Clock: Sendable {
    func now() -> Date
}

/// The real one. Shell-side; tests use a fake that returns a fixed instant.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}
