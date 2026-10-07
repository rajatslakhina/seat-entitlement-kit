import XCTest
@testable import SeatEntitlements

final class SeatLedgerTests: XCTestCase {
    func testHigherVersionWinsAndLowerIsSuperseded() {
        var ledger = SeatLedger()
        let v1 = event(v: 1, .assigned(.user("alice")))
        let v2 = event(v: 2, .assigned(.user("carol")), previous: .user("alice"))
        XCTAssertEqual(ledger.apply(v2), .applied(SeatChange(previous: nil, current: v2, resolvedConflict: false)))
        XCTAssertEqual(ledger.apply(v1), .superseded(currentVersion: 2))
        XCTAssertEqual(ledger.records["S-1"], v2)
    }

    func testExactRedeliveryIsADuplicate() {
        var ledger = SeatLedger()
        let v1 = event(v: 1, .assigned(.user("alice")))
        ledger.apply(v1)
        XCTAssertEqual(ledger.apply(v1), .duplicate)
    }

    func testSameVersionHigherRankedSourceWins() {
        var ledger = SeatLedger()
        let fromMDM = event(v: 4, .assigned(.user("alice")), source: .managedConfig)
        let fromServer = event(v: 4, .assigned(.user("bob")), source: .server)
        ledger.apply(fromServer)
        XCTAssertEqual(ledger.apply(fromMDM), .superseded(currentVersion: 4))
        XCTAssertEqual(ledger.records["S-1"], fromServer)
    }

    func testSameVersionSameSourceConflictResolvesToMoreRestrictiveInEitherOrder() {
        let grant = event(v: 3, .assigned(.user("alice")))
        let refund = event(v: 3, .refunded)
        var first = SeatLedger()
        first.apply(grant)
        let outcome = first.apply(refund)
        XCTAssertEqual(outcome, .applied(SeatChange(previous: grant, current: refund, resolvedConflict: true)))
        var second = SeatLedger()
        second.apply(refund)
        XCTAssertEqual(second.apply(grant), .superseded(currentVersion: 3))
        XCTAssertEqual(first, second)
    }

    /// Restrictiveness decides same-version, same-source conflicts on its own,
    /// not as a side effect of other tie-breaks: the losing payload here
    /// carries no `previousHolder`, which would win every later tie-break.
    func testRestrictivenessRanksRefundedOverExpiredOverUnassigned() {
        let unassigned = event(v: 5, .unassigned)
        let expired = event(v: 5, .expired, previous: .user("alice"))
        let refunded = event(v: 5, .refunded, previous: .user("alice"))
        XCTAssertTrue(refunded.beats(expired))
        XCTAssertTrue(expired.beats(unassigned))
        XCTAssertTrue(refunded.beats(unassigned))
        XCTAssertTrue(unassigned.beats(event(v: 5, .assigned(.user("alice")))))
    }

    func testCapacityRejectsNewSeatsButStillUpdatesKnownOnes() {
        var ledger = SeatLedger(capacity: 2)
        ledger.apply(event("A", v: 1, .assigned(.user("alice"))))
        ledger.apply(event("B", v: 1, .assigned(.user("alice"))))
        XCTAssertEqual(ledger.apply(event("C", v: 1, .assigned(.user("alice")))), .rejectedCapacity)
        XCTAssertEqual(ledger.records.count, 2)
        guard case .applied = ledger.apply(event("A", v: 2, .unassigned)) else {
            return XCTFail("updates to a known seat must not be blocked by capacity")
        }
    }

    func testZeroOrNegativeCapacityIsClampedToOne() {
        XCTAssertEqual(SeatLedger(capacity: 0).capacity, 1)
        XCTAssertEqual(SeatLedger(capacity: Int.min).capacity, 1)
    }

    func testEmptyLedgerQueriesAreEmpty() {
        let ledger = SeatLedger()
        XCTAssertTrue(ledger.seats(in: group).isEmpty)
        XCTAssertTrue(ledger.allSeats.isEmpty)
    }

    // MARK: Convergence (order independence)

    /// The events cover every tie-break: version, source rank, restrictiveness,
    /// holder, duplicates, and a second seat.
    private let mixedEvents: [SeatEvent] = [
        event(v: 1, .assigned(.user("alice"))),
        event(v: 2, .assigned(.user("carol")), previous: .user("alice")),
        event(v: 2, .refunded, source: .storeKit),
        event(v: 2, .unassigned, previous: .user("alice")),
        event(v: 1, .assigned(.user("alice"))), // duplicate
        event("S-2", v: 3, .assigned(.device("ipad-07")), source: .managedConfig),
    ]

    func testLedgerConvergesUnderEveryPermutation() {
        let violation = Convergence.firstViolation(mixedEvents) { events in
            var ledger = SeatLedger()
            ledger.apply(events)
            return ledger.records
        }
        XCTAssertNil(violation, "ledger result depended on arrival order")
    }

    /// Proves the convergence check can fail: a last-arrival-wins reducer,
    /// the obvious naive cache, must be caught by the same harness.
    func testConvergenceHarnessCatchesLastArrivalWins() {
        let violation = Convergence.firstViolation(mixedEvents) { events in
            var records: [SeatID: SeatEvent] = [:]
            for event in events { records[event.seatID] = event }
            return records
        }
        XCTAssertNotNil(violation)
    }

    /// And a reducer that orders by version only (ignoring the tie-breaks).
    func testConvergenceHarnessCatchesVersionOnlyOrdering() {
        let violation = Convergence.firstViolation(mixedEvents) { events in
            var records: [SeatID: SeatEvent] = [:]
            for event in events where (records[event.seatID]?.version ?? 0) <= event.version {
                records[event.seatID] = event
            }
            return records
        }
        XCTAssertNotNil(violation)
    }

    func testOrderIsTotalForEveryPairInTheFixture() {
        for a in mixedEvents {
            for b in mixedEvents {
                if a == b {
                    XCTAssertFalse(a.beats(b))
                } else {
                    XCTAssertNotEqual(a.beats(b), b.beats(a), "\(a) vs \(b) is not strictly ordered")
                }
            }
        }
    }

    func testNaNDatesStillOrderStrictly() {
        // NaN and +infinity map to the same order key, so these two events tie
        // on every key and only the final deterministic fallback separates them.
        let a = event(v: 1, .assigned(.user("alice")), issued: Date(timeIntervalSince1970: .nan))
        let b = event(v: 1, .assigned(.user("alice")), issued: Date(timeIntervalSince1970: .infinity))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.beats(b), b.beats(a))
        var forward = SeatLedger()
        forward.apply([a, b])
        var backward = SeatLedger()
        backward.apply([b, a])
        let forwardBits = forward.records["S-1"]?.issuedAt.timeIntervalSince1970.bitPattern
        let backwardBits = backward.records["S-1"]?.issuedAt.timeIntervalSince1970.bitPattern
        XCTAssertNotNil(forwardBits)
        XCTAssertEqual(forwardBits, backwardBits, "the NaN tie must resolve the same way in both orders")
    }

    // MARK: Deduplication

    func testDeduplicatorAdmitsEachWinnerOnce() {
        var dedup = ChangeDeduplicator()
        let v1 = SeatChange(previous: nil, current: event(v: 1, .assigned(.user("alice"))), resolvedConflict: false)
        let v2 = SeatChange(previous: nil, current: event(v: 2, .unassigned), resolvedConflict: false)
        XCTAssertTrue(dedup.admit(v1))
        XCTAssertFalse(dedup.admit(v1), "redelivery must be a no-op")
        XCTAssertTrue(dedup.admit(v2))
        XCTAssertFalse(dedup.admit(v1), "older change after newer must be ignored")
        let conflictWinner = SeatChange(previous: nil, current: event(v: 2, .refunded), resolvedConflict: true)
        XCTAssertTrue(dedup.admit(conflictWinner), "a same-version winner must still be acted on")
        XCTAssertFalse(dedup.admit(conflictWinner))
    }
}

enum Convergence {
    /// Applies every permutation of `events` and returns one that disagrees
    /// with the first ordering, or nil if all agree.
    static func firstViolation(_ events: [SeatEvent],
                               reducer: ([SeatEvent]) -> [SeatID: SeatEvent]) -> [SeatEvent]? {
        let reference = reducer(events)
        var violation: [SeatEvent]?
        permute(events, count: events.count) { ordering in
            if violation == nil && reducer(ordering) != reference { violation = ordering }
        }
        return violation
    }

    /// Heap's algorithm.
    private static func permute(_ items: [SeatEvent], count: Int, _ visit: ([SeatEvent]) -> Void) {
        var items = items
        var c = [Int](repeating: 0, count: count)
        visit(items)
        var i = 0
        while i < count {
            if c[i] < i {
                items.swapAt(i % 2 == 0 ? 0 : c[i], i)
                visit(items)
                c[i] += 1
                i = 0
            } else {
                c[i] = 0
                i += 1
            }
        }
    }
}
