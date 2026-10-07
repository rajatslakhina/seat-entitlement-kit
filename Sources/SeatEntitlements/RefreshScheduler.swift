import Foundation

/// FNV-1a (64-bit) over UTF-8. Used instead of `Hasher`, which is randomly
/// seeded per process: a device's refresh slot must be the same on every
/// launch and in every Suite sibling, or the spreading stops being a schedule.
public enum StableHash {
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// SplitMix64: a tiny, seedable generator so jitter is reproducible in tests
/// and simulations. Production can pass `SystemRandomNumberGenerator`.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// When to refresh, and how to back off, without stampeding the backend.
///
/// Two separate mechanisms, because they solve two separate herds:
/// * **Scheduled refreshes** are spread by a *deterministic* per-device offset
///   inside `spreadWindow`. Deterministic, so a device keeps its slot across
///   launches and Suite siblings agree on it; spread, so 5,000 iPads assigned
///   in one MDM push do not all refresh on the same second six hours later.
/// * **Retries after failure** use exponential backoff with *full jitter*
///   (a uniform draw in `0...min(cap, base·2^attempt)`), so a fleet that failed
///   together does not retry together. A server `Retry-After` is a floor.
public struct RefreshScheduler: Hashable, Sendable {
    public let interval: TimeInterval
    public let spreadWindow: TimeInterval
    public let backoffBase: TimeInterval
    public let backoffCap: TimeInterval

    public init(interval: TimeInterval = 6 * 3_600,
                spreadWindow: TimeInterval = 3_600,
                backoffBase: TimeInterval = 30,
                backoffCap: TimeInterval = 3_600) {
        self.interval = Saturating.interval(interval, ceiling: GracePolicy.ceiling)
        self.spreadWindow = Saturating.interval(spreadWindow, ceiling: GracePolicy.ceiling)
        self.backoffBase = Saturating.interval(backoffBase, ceiling: GracePolicy.ceiling)
        self.backoffCap = Saturating.interval(backoffCap, ceiling: GracePolicy.ceiling)
    }

    /// This device's fixed offset inside the spread window, in `0..<spreadWindow`
    /// (millisecond resolution). Zero when the window is zero.
    public func offset(forDeviceKey key: String) -> TimeInterval {
        let windowMillis = Saturating.int(spreadWindow * 1_000)
        guard windowMillis > 0 else { return 0 }
        let slot = StableHash.fnv1a64(key) % UInt64(windowMillis)
        return Double(slot) / 1_000
    }

    public func nextRefresh(after lastSuccess: Date, deviceKey: String) -> Date {
        lastSuccess.addingTimeInterval(interval + offset(forDeviceKey: deviceKey))
    }

    /// The exponential ceiling for `attempt` (0-based), before jitter.
    /// Negative attempts count as 0; large ones saturate at `backoffCap`
    /// without ever computing an overflowing power of two.
    public func backoffCeiling(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt, 0), 62)
        let ceiling = backoffBase * Double(UInt64(1) << UInt64(exponent))
        return min(backoffCap, ceiling.isFinite ? ceiling : backoffCap)
    }

    public func retryDelay<G: RandomNumberGenerator>(attempt: Int,
                                                      retryAfter: TimeInterval? = nil,
                                                      using generator: inout G) -> TimeInterval {
        let ceiling = backoffCeiling(attempt: attempt)
        let jittered = ceiling > 0 ? Double.random(in: 0...ceiling, using: &generator) : 0
        let floor = retryAfter.map { Saturating.interval($0, ceiling: GracePolicy.ceiling) } ?? 0
        return max(jittered, floor)
    }
}
