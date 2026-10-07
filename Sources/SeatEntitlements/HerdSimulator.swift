import Foundation

/// A discrete-time model of a fleet hitting the entitlement backend after one
/// event (an MDM push assigning 5,000 seats, or a cache-wide expiry).
///
/// It exists to make the jitter decision arguable with numbers rather than
/// adjectives: same fleet, same backend capacity, three client strategies.
/// It models *load shape* only. It does not model server collapse under
/// overload, so the synchronized strategies look better here than they would
/// against a real backend that degrades past capacity.
public struct HerdScenario: Hashable, Sendable {
    public static let maximumDevices = 100_000
    public static let maximumBuckets = 10_000

    public let devices: Int
    /// Requests the backend can serve per bucket.
    public let capacityPerBucket: Int
    public let bucketSeconds: TimeInterval
    public let horizonBuckets: Int

    public init(devices: Int, capacityPerBucket: Int, bucketSeconds: TimeInterval = 10, horizonBuckets: Int = 720) {
        self.devices = min(max(devices, 0), Self.maximumDevices)
        self.capacityPerBucket = max(capacityPerBucket, 0)
        let seconds = Saturating.interval(bucketSeconds, ceiling: 86_400)
        self.bucketSeconds = seconds > 0 ? seconds : 1
        self.horizonBuckets = min(max(horizonBuckets, 1), Self.maximumBuckets)
    }
}

public enum HerdStrategy: Hashable, Sendable {
    /// Everyone fires at t0 and retries after the same fixed delay.
    case synchronized(retryAfter: TimeInterval)
    /// Everyone fires at t0; retries use full-jitter backoff. The usual half-fix.
    case synchronizedWithJitteredRetry(RefreshScheduler)
    /// First request at the device's deterministic slot; full-jitter retries.
    case spread(RefreshScheduler)

    public var label: String {
        switch self {
        case .synchronized: return "Synchronized, fixed retry"
        case .synchronizedWithJitteredRetry: return "Synchronized, jittered retry"
        case .spread: return "Spread slot + jittered retry"
        }
    }
}

public struct HerdResult: Hashable, Sendable {
    /// Requests arriving in each bucket.
    public let load: [Int]
    public let peak: Int
    public let totalRequests: Int
    public let served: Int
    /// Devices still unserved when the horizon ended.
    public let unserved: Int
    /// The bucket in which the last device was served, if all were.
    public let drainedAtBucket: Int?

    /// Peak load as a multiple of capacity. `nil` when capacity is zero.
    public func peakOverCapacity(_ scenario: HerdScenario) -> Double? {
        guard scenario.capacityPerBucket > 0 else { return nil }
        return Double(peak) / Double(scenario.capacityPerBucket)
    }
}

public enum HerdSimulator {
    public static func run(_ scenario: HerdScenario, strategy: HerdStrategy, seed: UInt64 = 0x5EA7) -> HerdResult {
        let horizon = scenario.horizonBuckets
        var generator = SplitMix64(seed: seed)
        // queue[b] holds the attempt number of every request arriving in bucket b.
        var queue = [[Int]](repeating: [], count: horizon)
        var load = [Int](repeating: 0, count: horizon)
        var unserved = 0

        func bucket(after seconds: TimeInterval) -> Int {
            Saturating.int((seconds / scenario.bucketSeconds).rounded(.down))
        }

        for device in 0..<scenario.devices {
            var start = 0
            if case .spread(let scheduler) = strategy {
                start = bucket(after: scheduler.offset(forDeviceKey: "device-\(device)"))
            }
            if start >= 0 && start < horizon {
                queue[start].append(0)
            } else {
                unserved += 1
            }
        }

        var served = 0
        var total = 0
        var lastServed: Int?
        for current in 0..<horizon {
            let arrivals = queue[current]
            queue[current] = [] // release memory as the window advances
            load[current] = arrivals.count
            total = Saturating.add(total, arrivals.count)
            let accepted = min(arrivals.count, scenario.capacityPerBucket)
            if accepted > 0 {
                served += accepted
                lastServed = current
            }
            for attempt in arrivals.dropFirst(accepted) {
                let delay: TimeInterval
                switch strategy {
                case .synchronized(let fixed):
                    delay = Saturating.interval(fixed, ceiling: 86_400)
                case .synchronizedWithJitteredRetry(let scheduler), .spread(let scheduler):
                    delay = scheduler.retryDelay(attempt: attempt, using: &generator)
                }
                let steps = max(1, Saturating.int((delay / scenario.bucketSeconds).rounded(.up)))
                let next = Saturating.add(current, steps)
                if next < horizon {
                    queue[next].append(Saturating.add(attempt, 1))
                } else {
                    unserved += 1
                }
            }
        }

        return HerdResult(load: load,
                          peak: load.max() ?? 0,
                          totalRequests: total,
                          served: served,
                          unserved: unserved,
                          drainedAtBucket: unserved == 0 ? lastServed : nil)
    }
}
