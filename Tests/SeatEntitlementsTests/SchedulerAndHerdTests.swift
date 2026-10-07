import XCTest
@testable import SeatEntitlements

final class SchedulerAndHerdTests: XCTestCase {
    // MARK: Stable hash

    /// Published FNV-1a 64 test vectors. `Hasher` is reseeded per process and
    /// could never match fixed constants, so this pins cross-launch stability.
    func testFNV1a64MatchesPublishedVectors() {
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    // MARK: Scheduled spread

    func testOffsetsStayInsideTheWindowAndActuallySpread() {
        let scheduler = RefreshScheduler(spreadWindow: 3_600)
        let offsets = (0..<500).map { scheduler.offset(forDeviceKey: "device-\($0)") }
        XCTAssertTrue(offsets.allSatisfy { $0 >= 0 && $0 < 3_600 })
        // Each 6-minute tenth of the window gets a share of devices.
        var deciles = [Int](repeating: 0, count: 10)
        for offset in offsets { deciles[min(9, Int(offset / 360))] += 1 }
        XCTAssertTrue(deciles.allSatisfy { $0 >= 20 }, "offsets clumped: \(deciles)")
    }

    func testZeroOrNaNWindowGivesZeroOffset() {
        XCTAssertEqual(RefreshScheduler(spreadWindow: 0).offset(forDeviceKey: "x"), 0)
        XCTAssertEqual(RefreshScheduler(spreadWindow: .nan).offset(forDeviceKey: "x"), 0)
        XCTAssertEqual(RefreshScheduler(spreadWindow: -10).offset(forDeviceKey: "x"), 0)
    }

    func testNextRefreshIsIntervalPlusDeviceSlot() {
        let scheduler = RefreshScheduler(interval: 6 * 3_600, spreadWindow: 3_600)
        let slot = scheduler.offset(forDeviceKey: "ipad-07")
        XCTAssertEqual(scheduler.nextRefresh(after: t0, deviceKey: "ipad-07"),
                       t0.addingTimeInterval(6 * 3_600 + slot))
    }

    // MARK: Backoff

    func testBackoffCeilingGrowsThenSaturatesWithoutTrapping() {
        let scheduler = RefreshScheduler(backoffBase: 30, backoffCap: 3_600)
        XCTAssertEqual(scheduler.backoffCeiling(attempt: 0), 30)
        XCTAssertEqual(scheduler.backoffCeiling(attempt: 3), 240)
        XCTAssertEqual(scheduler.backoffCeiling(attempt: 7), 3_600)
        XCTAssertEqual(scheduler.backoffCeiling(attempt: Int.max), 3_600)
        XCTAssertEqual(scheduler.backoffCeiling(attempt: -5), 30)
        XCTAssertEqual(scheduler.backoffCeiling(attempt: Int.min), 30)
    }

    func testFullJitterStaysInBoundsAndIsNotDegenerate() {
        let scheduler = RefreshScheduler(backoffBase: 30, backoffCap: 3_600)
        var generator = SplitMix64(seed: 42)
        let delays = (0..<200).map { _ in scheduler.retryDelay(attempt: 4, using: &generator) }
        XCTAssertTrue(delays.allSatisfy { $0 >= 0 && $0 <= 480 })
        XCTAssertGreaterThan(Set(delays).count, 150, "jitter collapsed to a few values")
        XCTAssertLessThan(delays.min() ?? 480, 100)
        XCTAssertGreaterThan(delays.max() ?? 0, 380)
    }

    func testRetryAfterIsAFloorAndHostileValuesAreClamped() {
        let scheduler = RefreshScheduler(backoffBase: 30, backoffCap: 60)
        var generator = SplitMix64(seed: 1)
        XCTAssertEqual(scheduler.retryDelay(attempt: 0, retryAfter: 900, using: &generator), 900)
        let ignored = scheduler.retryDelay(attempt: 0, retryAfter: .nan, using: &generator)
        XCTAssertTrue(ignored >= 0 && ignored <= 30)
        XCTAssertEqual(scheduler.retryDelay(attempt: 0, retryAfter: .infinity, using: &generator), GracePolicy.ceiling)
    }

    func testZeroBaseNeverDividesOrTraps() {
        let scheduler = RefreshScheduler(backoffBase: 0, backoffCap: 0)
        var generator = SplitMix64(seed: 3)
        XCTAssertEqual(scheduler.retryDelay(attempt: 10, using: &generator), 0)
    }

    // MARK: Herd model

    private let fleet = HerdScenario(devices: 5_000, capacityPerBucket: 250, bucketSeconds: 10, horizonBuckets: 720)
    private let scheduler = RefreshScheduler(spreadWindow: 3_600, backoffBase: 30, backoffCap: 600)

    func testSynchronizedFleetPeaksAtFleetSize() {
        let result = HerdSimulator.run(fleet, strategy: .synchronized(retryAfter: 30))
        XCTAssertEqual(result.peak, 5_000)
        XCTAssertEqual(result.load.first, 5_000)
        XCTAssertEqual(result.served, 5_000)
    }

    /// Pins every number in the README's herd table (default seed). If the
    /// model or the scheduler changes, this fails and the table must be redone.
    func testHerdTableNumbersInTheReadme() {
        let fixed = HerdSimulator.run(fleet, strategy: .synchronized(retryAfter: 30))
        XCTAssertEqual([fixed.peak, fixed.totalRequests, fixed.drainedAtBucket ?? -1], [5_000, 52_500, 57])
        let jittered = HerdSimulator.run(fleet, strategy: .synchronizedWithJitteredRetry(scheduler))
        XCTAssertEqual([jittered.peak, jittered.totalRequests, jittered.drainedAtBucket ?? -1], [5_000, 17_191, 56])
        let spread = HerdSimulator.run(fleet, strategy: .spread(scheduler))
        XCTAssertEqual([spread.peak, spread.totalRequests, spread.drainedAtBucket ?? -1], [27, 5_000, 359])
    }

    /// Jitter on retries cuts wasted requests but cannot touch the first spike.
    func testJitteredRetryCutsWasteButNotTheFirstSpike() {
        let fixed = HerdSimulator.run(fleet, strategy: .synchronized(retryAfter: 30))
        let jittered = HerdSimulator.run(fleet, strategy: .synchronizedWithJitteredRetry(scheduler))
        XCTAssertEqual(jittered.peak, fixed.peak)
        XCTAssertLessThan(jittered.totalRequests, fixed.totalRequests / 2)
    }

    func testSpreadSlotsKeepPeakUnderCapacity() {
        let result = HerdSimulator.run(fleet, strategy: .spread(scheduler))
        XCTAssertLessThanOrEqual(result.peak, fleet.capacityPerBucket)
        XCTAssertEqual(result.totalRequests, 5_000, "no request should fail, so none should retry")
        XCTAssertEqual(result.unserved, 0)
        XCTAssertNotNil(result.drainedAtBucket)
    }

    func testEveryStrategyConservesDevices() {
        let strategies: [HerdStrategy] = [.synchronized(retryAfter: 30), .synchronizedWithJitteredRetry(scheduler), .spread(scheduler)]
        let tight = HerdScenario(devices: 3_000, capacityPerBucket: 7, bucketSeconds: 10, horizonBuckets: 100)
        for strategy in strategies {
            let result = HerdSimulator.run(tight, strategy: strategy)
            XCTAssertEqual(result.served + result.unserved, 3_000, strategy.label)
            XCTAssertGreaterThan(result.unserved, 0, "capacity cannot serve everyone in the horizon")
            XCTAssertNil(result.drainedAtBucket)
        }
    }

    func testZeroCapacityTerminatesWithEveryoneUnserved() {
        let dead = HerdScenario(devices: 100, capacityPerBucket: 0, bucketSeconds: 10, horizonBuckets: 50)
        let result = HerdSimulator.run(dead, strategy: .synchronized(retryAfter: 0))
        XCTAssertEqual(result.served, 0)
        XCTAssertEqual(result.unserved, 100)
        XCTAssertNil(result.peakOverCapacity(dead))
    }

    func testEmptyFleetAndHostileScenarioInputs() {
        let empty = HerdSimulator.run(HerdScenario(devices: 0, capacityPerBucket: 10), strategy: .spread(scheduler))
        XCTAssertEqual(empty.peak, 0)
        XCTAssertEqual(empty.totalRequests, 0)
        let hostile = HerdScenario(devices: Int.max, capacityPerBucket: -4, bucketSeconds: .nan, horizonBuckets: Int.min)
        XCTAssertEqual(hostile.devices, HerdScenario.maximumDevices)
        XCTAssertEqual(hostile.capacityPerBucket, 0)
        XCTAssertEqual(hostile.bucketSeconds, 1)
        XCTAssertEqual(hostile.horizonBuckets, 1)
    }

    func testSimulationIsDeterministicForASeed() {
        let a = HerdSimulator.run(fleet, strategy: .synchronizedWithJitteredRetry(scheduler), seed: 9)
        let b = HerdSimulator.run(fleet, strategy: .synchronizedWithJitteredRetry(scheduler), seed: 9)
        let c = HerdSimulator.run(fleet, strategy: .synchronizedWithJitteredRetry(scheduler), seed: 10)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.load, c.load, "seed must actually drive the jitter")
    }

    // MARK: Saturating arithmetic

    func testSaturatingConversionsNeverTrap() {
        XCTAssertEqual(Saturating.int(.nan), 0)
        XCTAssertEqual(Saturating.int(.infinity), .max)
        XCTAssertEqual(Saturating.int(-.infinity), .min)
        XCTAssertEqual(Saturating.int(Double(Int.max)), .max)
        XCTAssertEqual(Saturating.int(-3.7), -3)
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.min, 2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.interval(-1), 0)
        XCTAssertEqual(Saturating.interval(.infinity, ceiling: 10), 10)
    }
}
