import Foundation

/// Arithmetic that clamps instead of trapping.
///
/// Every numeric conversion reachable from the public API goes through here, so
/// a hostile or corrupt input (a `NaN` grace window, an attempt counter of
/// `Int.max`, a `Retry-After` of `1e300`) degrades to a bounded value instead of
/// crashing the app. Ceilings are derived from `Int.max`, never a 64-bit
/// literal, so the same code is correct where `Int` is 32 bits wide.
public enum Saturating {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) != (b < 0) ? .min : .max
    }

    /// `Int(Double)` without the trap: NaN becomes 0, out-of-range values clamp.
    ///
    /// `Double(Int.max)` rounds *up* to 2^63 (or 2^31 on 32-bit), which is not
    /// representable as `Int`, so the comparison is `>=`, not `>`.
    public static func int(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }

    /// A time interval that is finite and non-negative. NaN and negative
    /// values become 0; +infinity becomes `ceiling`.
    public static func interval(_ value: TimeInterval, ceiling: TimeInterval = .greatestFiniteMagnitude) -> TimeInterval {
        guard !value.isNaN, value > 0 else { return 0 }
        guard value.isFinite else { return ceiling }
        return min(value, ceiling)
    }
}
