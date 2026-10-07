import XCTest
@testable import SeatEntitlements

final class DeciderTests: XCTestCase {
    let policy = GracePolicy(freshFor: 6 * 3_600, offlineGrace: 72 * 3_600, clockSkewTolerance: 300)

    private func decide(_ feature: Feature = docs,
                        context: CheckContext = alice,
                        seats: [SeatEvent] = [event(v: 1, .assigned(.user("alice")))],
                        verifiedAt: Date? = t0,
                        uptimeAtVerification: TimeInterval? = nil,
                        now: Date,
                        uptime: TimeInterval? = nil,
                        floor: Date? = nil,
                        policy: GracePolicy? = nil) -> Decision {
        var ledger = SeatLedger()
        ledger.apply(seats)
        let verification = verifiedAt.map { Verification(verifiedAt: $0, uptimeAtVerification: uptimeAtVerification) }
        return EntitlementDecider.decide(feature: feature, context: context, ledger: ledger,
                                         verification: verification, now: now, uptime: uptime,
                                         wallClockFloor: floor, policy: policy ?? self.policy)
    }

    // MARK: Freshness boundaries

    func testExactlyAtFreshBoundaryIsVerified() {
        XCTAssertEqual(decide(now: t0 + 6 * 3_600), .allow(.verified(age: 6 * 3_600)))
    }

    func testOneSecondPastFreshFailOpenEntersGraceWithExactRemaining() {
        XCTAssertEqual(decide(now: t0 + 6 * 3_600 + 1), .allow(.offlineGrace(remaining: 72 * 3_600 - 1)))
    }

    func testOneSecondPastFreshFailClosedIsDenied() {
        XCTAssertEqual(decide(export, now: t0 + 6 * 3_600 + 1), .deny(.needsFreshState(age: 6 * 3_600 + 1)))
    }

    func testGraceClosesExactlyAtFreshPlusGrace() {
        let end: TimeInterval = (6 + 72) * 3_600
        XCTAssertEqual(decide(now: t0 + end - 1), .allow(.offlineGrace(remaining: 1)))
        XCTAssertEqual(decide(now: t0 + end), .deny(.graceExhausted(age: end)))
    }

    func testWorstCaseOfflineRevocationLatencyMatchesTheDecider() {
        // The README's bound must be the decider's actual behaviour.
        let bound = policy.worstCaseOfflineRevocationLatency
        XCTAssertTrue(decide(now: t0 + bound - 1).isAllowed)
        XCTAssertFalse(decide(now: t0 + bound).isAllowed)
    }

    // MARK: Seats and revocation

    func testNoVerifiedStateDenies() {
        XCTAssertEqual(decide(verifiedAt: nil, now: t0), .deny(.noVerifiedState))
    }

    func testNoSeatInGroup() {
        XCTAssertEqual(decide(seats: [], now: t0), .deny(.noSeat))
        let otherGroup = event(v: 1, .assigned(.user("alice")), group: "other.group")
        XCTAssertEqual(decide(seats: [otherGroup], now: t0), .deny(.noSeat))
    }

    func testKnownRevocationWinsEvenWhenFreshAndEvenBeforeAnyVerification() {
        let moved = event(v: 2, .assigned(.user("carol")), previous: .user("alice"))
        XCTAssertEqual(decide(seats: [moved], now: t0), .deny(.revoked("S-1", version: 2)))
        XCTAssertEqual(decide(seats: [moved], verifiedAt: nil, now: t0), .deny(.revoked("S-1", version: 2)))
    }

    func testAnotherSeatStillGrantsAfterOneIsRevoked() {
        let moved = event("S-1", v: 2, .assigned(.user("carol")), previous: .user("alice"))
        let other = event("S-2", v: 1, .assigned(.user("alice")))
        XCTAssertTrue(decide(seats: [moved, other], now: t0).isAllowed)
    }

    func testDeviceAssignedSeatMatchesWithoutAUser() {
        let shared = event(v: 1, .assigned(.device("ipad-07")))
        let kiosk = CheckContext(userID: nil, deviceID: "ipad-07")
        XCTAssertTrue(decide(context: kiosk, seats: [shared], now: t0).isAllowed)
        let elsewhere = CheckContext(userID: nil, deviceID: "ipad-99")
        XCTAssertEqual(decide(context: elsewhere, seats: [shared], now: t0), .deny(.noSeat))
    }

    // MARK: Expiry

    func testExpiryBeforeLastVerificationIsAFact() {
        let lapsed = event(v: 1, .assigned(.user("alice")), expires: t0 - 1)
        XCTAssertEqual(decide(seats: [lapsed], now: t0 + 10), .deny(.expired("S-1")))
    }

    func testExpiryAfterVerificationIsUnconfirmedAndUsesGraceFromExpiry() {
        let seat = event(v: 1, .assigned(.user("alice")), expires: t0 + 3_600)
        // One hour fresh state, but the paid period ended 30 minutes ago.
        let now = t0 + 3_600 + 1_800
        XCTAssertEqual(decide(seats: [seat], now: now), .allow(.offlineGrace(remaining: 72 * 3_600 - 1_800)))
        XCTAssertEqual(decide(export, seats: [seat], now: now), .deny(.needsFreshState(age: 5_400)))
        XCTAssertEqual(decide(seats: [seat], now: t0 + 3_600 + 72 * 3_600),
                       .deny(.graceExhausted(age: 73 * 3_600)))
    }

    func testFutureExpiryDoesNotAffectFreshAccess() {
        let seat = event(v: 1, .assigned(.user("alice")), expires: t0 + 86_400)
        XCTAssertEqual(decide(seats: [seat], now: t0 + 60), .allow(.verified(age: 60)))
    }

    // MARK: Clocks

    func testWallClockBehindVerificationWithoutMonotonicIsRollback() {
        XCTAssertEqual(decide(now: t0 - 3_600), .deny(.clockRollback))
    }

    func testSmallNegativeSkewIsToleratedAsAgeZero() {
        XCTAssertEqual(decide(now: t0 - 120), .allow(.verified(age: 0)))
    }

    func testMonotonicAgeDefeatsWallClockRollback() {
        // Verified at uptime 1,000; 80 hours of uptime later the user sets the
        // wall clock back to the verification time. Monotonic age still says 80h.
        let decision = decide(uptimeAtVerification: 1_000, now: t0, uptime: 1_000 + 80 * 3_600)
        XCTAssertEqual(decision, .deny(.graceExhausted(age: 80 * 3_600)))
    }

    func testMonotonicIgnoredAfterReboot() {
        // Uptime smaller than at verification means a reboot: fall back to wall age.
        XCTAssertEqual(decide(uptimeAtVerification: 50_000, now: t0 + 60, uptime: 10),
                       .allow(.verified(age: 60)))
    }

    func testNaNWallClockIsTreatedAsRollback() {
        XCTAssertEqual(decide(now: Date(timeIntervalSince1970: .nan)), .deny(.clockRollback))
    }

    // MARK: Policy sanitising

    func testPolicySanitisesNaNNegativeAndInfinity() {
        let hostile = GracePolicy(freshFor: .nan, offlineGrace: -5, clockSkewTolerance: .infinity)
        XCTAssertEqual(hostile.freshFor, 0)
        XCTAssertEqual(hostile.offlineGrace, 0)
        XCTAssertEqual(hostile.clockSkewTolerance, GracePolicy.ceiling)
        // A zero policy allows only state verified this instant, and never grace.
        XCTAssertEqual(decide(now: t0, policy: hostile), .allow(.verified(age: 0)))
        XCTAssertEqual(decide(now: t0 + 1, policy: hostile), .deny(.graceExhausted(age: 1)))
    }

    func testHugePolicyClampsToOneYear() {
        let huge = GracePolicy(freshFor: 1e300, offlineGrace: .greatestFiniteMagnitude)
        XCTAssertEqual(huge.freshFor, GracePolicy.ceiling)
        XCTAssertEqual(huge.worstCaseOfflineRevocationLatency, 2 * GracePolicy.ceiling)
    }

    // MARK: Wall-clock floor

    func testClockFloorAheadWithoutMonotonicIsRollback() {
        XCTAssertEqual(decide(now: t0.addingTimeInterval(60), floor: t0.addingTimeInterval(100 * 3_600)),
                       .deny(.clockRollback))
    }

    func testClockFloorWithinSkewIsUsedAsNow() {
        XCTAssertEqual(decide(now: t0, floor: t0.addingTimeInterval(200)), .allow(.verified(age: 200)))
    }

    func testClockFloorWithMonotonicAgesFromTheFloor() {
        let decision = decide(uptimeAtVerification: 1_000, now: t0, uptime: 1_000 + 3_600,
                              floor: t0.addingTimeInterval(10 * 3_600))
        XCTAssertEqual(decision, .allow(.offlineGrace(remaining: 68 * 3_600)))
    }

    func testFloorBehindNowChangesNothing() {
        XCTAssertEqual(decide(now: t0.addingTimeInterval(60), floor: t0), .allow(.verified(age: 60)))
    }
}
