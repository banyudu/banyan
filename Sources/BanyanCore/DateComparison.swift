import Foundation

public extension Date {
    /// The macOS 27.2 SDK weak-links Date's `>=` and `<=` overloads, but the
    /// matching runtime does not export them. Comparing the underlying interval
    /// avoids a null symbol call while preserving inclusive boundary semantics.
    func isAtOrAfter(_ other: Date) -> Bool {
        timeIntervalSinceReferenceDate >= other.timeIntervalSinceReferenceDate
    }

    func isAtOrBefore(_ other: Date) -> Bool {
        timeIntervalSinceReferenceDate <= other.timeIntervalSinceReferenceDate
    }
}
