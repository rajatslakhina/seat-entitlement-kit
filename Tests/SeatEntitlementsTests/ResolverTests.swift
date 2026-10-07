import XCTest
@testable import SeatEntitlements

final class ResolverTests: XCTestCase {
    private let granted = event(v: 1, .assigned(.user("alice")))
    private let movedToCarol = event(v: 2, .assigned(.user("carol")), previous: .user("alice"))

    private func makeResolver(feed: any EntitlementFeed,
                              store: any SnapshotStore = InMemorySnapshotStore(),
                              highWater: any HighWaterMarkStore = InMemoryHighWaterMark(),
                              clock: TestClock = TestClock(),
                              journal: any RevocationJournal = InMemoryRevocationJournal(),
                              clockFloor: any ClockFloorStore = InMemoryClockFloor()) -> EntitlementResolver {
        EntitlementResolver(context: alice, policy: GracePolicy(freshFor: 6 * 3_600, offlineGrace: 72 * 3_600),
                            verifier: FakeVerifier(), store: store, highWater: highWater, feed: feed, clock: clock,
                            journal: journal, clockFloor: clockFloor)
    }

    func testRefreshAdoptsVerifiesSharesAndRaisesHighWater() async {
        let snapshot = signed(EntitlementSnapshot(sequence: 7, issuedAt: t0, seats: [granted]))
        let store = InMemorySnapshotStore()
        let mark = InMemoryHighWaterMark()
        let resolver = makeResolver(feed: GatedFeed([snapshot], open: true), store: store, highWater: mark)
        let outcome = await resolver.refresh()
        XCTAssertEqual(outcome, .adopted(sequence: 7, changes: 1))
        let decision = await resolver.decide(docs)
        XCTAssertEqual(decision, .allow(.verified(age: 0)))
        let shared = await store.load()
        XCTAssertEqual(shared, snapshot)
        let water = await mark.load()
        XCTAssertEqual(water, 7)
    }

    func testTransportFailureLeavesAdoptedStateUntouched() async {
        // One good snapshot, then the feed runs dry (throws).
        let feed = GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true)
        let resolver = makeResolver(feed: feed)
        _ = await resolver.refresh()
        let outcome = await resolver.refresh()
        guard case .transportFailed = outcome else { return XCTFail("expected transport failure, got \(outcome)") }
        let seats = await resolver.seats()
        XCTAssertEqual(seats, [granted])
        let verification = await resolver.currentVerification()
        XCTAssertEqual(verification?.verifiedAt, t0)
        let decision = await resolver.decide(docs)
        XCTAssertEqual(decision, .allow(.verified(age: 0)))
    }

    func testBadSignatureIsRejectedAndNotShared() async {
        let good = signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))
        let forged = SignedSnapshot(keyID: "k1", payload: good.payload, signature: Data("forged".utf8))
        let store = InMemorySnapshotStore()
        let resolver = makeResolver(feed: GatedFeed([forged], open: true), store: store)
        let outcome = await resolver.refresh()
        XCTAssertEqual(outcome, .rejected(.badSignature))
        let rejection = await resolver.lastRejection
        XCTAssertEqual(rejection, .badSignature)
        let shared = await store.load()
        XCTAssertNil(shared)
        let seats = await resolver.seats()
        XCTAssertTrue(seats.isEmpty)
    }

    // MARK: Single flight

    func testConcurrentRefreshesShareOneFetch() async {
        let snapshot = signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))
        let feed = GatedFeed([snapshot])
        let resolver = makeResolver(feed: feed)
        async let first = resolver.refresh()
        async let second = resolver.refresh()
        // Both callers must be inside refresh() while the fetch is still held.
        let bothWaiting = await eventually {
            let calls = await feed.calls
            let requests = await resolver.refreshRequests
            return calls == 1 && requests == 2
        }
        XCTAssertTrue(bothWaiting)
        await feed.open()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [.adopted(sequence: 1, changes: 1), .adopted(sequence: 1, changes: 1)])
        let calls = await feed.calls
        XCTAssertEqual(calls, 1, "a second fetch means single-flight is broken")
        let fetches = await resolver.fetchCount
        XCTAssertEqual(fetches, 1)
    }

    func testSequentialRefreshesEachFetch() async {
        let feed = GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted])),
                              signed(EntitlementSnapshot(sequence: 2, issuedAt: t0, seats: [granted]))], open: true)
        let resolver = makeResolver(feed: feed)
        _ = await resolver.refresh()
        let second = await resolver.refresh()
        XCTAssertEqual(second, .adopted(sequence: 2, changes: 0))
        let calls = await feed.calls
        XCTAssertEqual(calls, 2, "a finished fetch must not be reused")
    }

    // MARK: The race that motivates merge-not-replace

    /// A revocation pushed while a fetch is suspended must survive the older
    /// snapshot that lands afterwards. Replacing the ledger with the snapshot
    /// (the obvious implementation) re-grants the seat and fails this test.
    func testPushedRevocationSurvivesSlowerOlderSnapshot() async {
        let stale = signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))
        let feed = GatedFeed([stale])
        let resolver = makeResolver(feed: feed)
        async let refreshed = resolver.refresh()
        let suspended = await eventually { await feed.calls == 1 }
        XCTAssertTrue(suspended)
        await resolver.ingest([movedToCarol])
        await feed.open()
        let outcome = await refreshed
        XCTAssertEqual(outcome, .adopted(sequence: 1, changes: 0))
        let decision = await resolver.decide(docs)
        XCTAssertEqual(decision, .deny(.revoked("S-1", version: 2)))
        let seats = await resolver.seats()
        XCTAssertEqual(seats, [movedToCarol])
    }

    // MARK: Suite siblings and rollback

    func testSiblingBootstrapRejectsRestoredOlderCache() async {
        let old = signed(EntitlementSnapshot(sequence: 3, issuedAt: t0, seats: [granted]))
        let resolver = makeResolver(feed: GatedFeed([], open: true), store: InMemorySnapshotStore(old),
                                    highWater: InMemoryHighWaterMark(9))
        let outcome = await resolver.bootstrap()
        XCTAssertEqual(outcome, .rejected(.rolledBack(sequence: 3, highWater: 9)))
        let decision = await resolver.decide(docs)
        XCTAssertEqual(decision, .deny(.noSeat))
    }

    func testSiblingBootstrapAdoptsWithoutMonotonicReading() async {
        let current = signed(EntitlementSnapshot(sequence: 9, issuedAt: t0, seats: [granted]))
        let clock = TestClock()
        let resolver = makeResolver(feed: GatedFeed([], open: true), store: InMemorySnapshotStore(current),
                                    highWater: InMemoryHighWaterMark(9), clock: clock)
        let outcome = await resolver.bootstrap()
        XCTAssertEqual(outcome, .adopted(sequence: 9, changes: 1))
        let verification = await resolver.currentVerification()
        XCTAssertEqual(verification, Verification(verifiedAt: t0, uptimeAtVerification: nil))
        // With no monotonic reading, a wall clock moved far back is a rollback.
        clock.setWall(t0.addingTimeInterval(-86_400))
        let decision = await resolver.decide(docs)
        XCTAssertEqual(decision, .deny(.clockRollback))
    }

    func testEmptySharedStoreBootstrapsToNil() async {
        let resolver = makeResolver(feed: GatedFeed([], open: true))
        let outcome = await resolver.bootstrap()
        XCTAssertNil(outcome)
    }

    func testVerificationNeverMovesBackwards() async {
        let newer = signed(EntitlementSnapshot(sequence: 5, issuedAt: t0.addingTimeInterval(600), seats: [granted]))
        let olderIssuedSameSequence = signed(EntitlementSnapshot(sequence: 5, issuedAt: t0, seats: [granted]))
        let clock = TestClock(now: t0.addingTimeInterval(600))
        let store = InMemorySnapshotStore()
        let resolver = makeResolver(feed: GatedFeed([newer], open: true), store: store, clock: clock)
        _ = await resolver.refresh()
        // A sibling then writes an older-issued snapshot with the same sequence
        // (it passes the high-water check), and this app re-reads the store.
        await store.save(olderIssuedSameSequence)
        let outcome = await resolver.bootstrap()
        XCTAssertEqual(outcome, .adopted(sequence: 5, changes: 0))
        let verification = await resolver.currentVerification()
        XCTAssertEqual(verification?.verifiedAt, t0.addingTimeInterval(600))
        XCTAssertNotNil(verification?.uptimeAtVerification, "the older sibling copy must not erase the monotonic reading")
    }

    func testMonotonicReadingFromOwnRefreshDefeatsClockTamper() async {
        let clock = TestClock()
        let resolver = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true),
                                    clock: clock)
        _ = await resolver.refresh()
        clock.advance(100 * 3_600)
        clock.setWall(t0) // user rewinds the date
        let decision = await resolver.decide(docs)
        XCTAssertEqual(decision, .deny(.graceExhausted(age: 100 * 3_600)))
    }

    // MARK: Fan-out

    func testSubscribersReceiveAppliedChangesOnly() async {
        let resolver = makeResolver(feed: GatedFeed([], open: true))
        let stream = await resolver.changes()
        let marker = event("S-9", v: 1, .unassigned)
        await resolver.ingest([granted, granted, movedToCarol, granted])
        await resolver.ingest([marker])
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(first?.current, granted)
        XCTAssertEqual(second?.current, movedToCarol)
        XCTAssertEqual(second?.previous, granted)
        // Exactly two changes came from the first batch: the next one is the marker.
        XCTAssertEqual(third?.current, marker)
    }

    func testCancelledSubscriberIsRemoved() async {
        let resolver = makeResolver(feed: GatedFeed([], open: true))
        let stream = await resolver.changes()
        let consumer = Task { for await _ in stream {} }
        let registered = await resolver.subscriberCount
        XCTAssertEqual(registered, 1)
        consumer.cancel()
        let removed = await eventually { await resolver.subscriberCount == 0 }
        XCTAssertTrue(removed, "terminated subscribers must not accumulate")
    }

    func testSubscriberCapFinishesExtraStreams() async {
        let resolver = makeResolver(feed: GatedFeed([], open: true))
        var streams: [AsyncStream<SeatChange>] = []
        for _ in 0..<EntitlementResolver.maximumSubscribers {
            streams.append(await resolver.changes())
        }
        let overflow = await resolver.changes()
        var iterator = overflow.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next, "the stream past the cap must be finished immediately")
        let count = await resolver.subscriberCount
        XCTAssertEqual(count, EntitlementResolver.maximumSubscribers)
        XCTAssertEqual(streams.count, EntitlementResolver.maximumSubscribers)
    }

    func testNextScheduledRefreshUsesDeviceSlot() async {
        let resolver = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true))
        let scheduler = RefreshScheduler(interval: 3_600, spreadWindow: 600)
        let before = await resolver.nextScheduledRefresh(using: scheduler)
        XCTAssertNil(before)
        _ = await resolver.refresh()
        let after = await resolver.nextScheduledRefresh(using: scheduler)
        XCTAssertEqual(after, scheduler.nextRefresh(after: t0, deviceKey: alice.deviceID))
    }

    // MARK: Review round 1 regressions

    /// Re-reading the snapshot this process just saved (same time, no uptime)
    /// must not erase the monotonic reading from its own refresh.
    func testBootstrapOfOwnSavedSnapshotKeepsMonotonicReading() async {
        let clock = TestClock()
        let store = InMemorySnapshotStore()
        let resolver = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true),
                                    store: store, clock: clock)
        _ = await resolver.refresh()
        _ = await resolver.bootstrap()
        clock.advance(100 * 3_600)
        clock.setWall(t0.addingTimeInterval(60))
        let decision = await resolver.decide(export)
        XCTAssertEqual(decision, .deny(.needsFreshState(age: 100 * 3_600)))
    }

    /// Rewind the clock and reboot: no monotonic reading survives, so the
    /// persisted wall-clock floor is the only defence.
    func testPersistedClockFloorCatchesRewindAfterReboot() async {
        let store = InMemorySnapshotStore()
        let floor = InMemoryClockFloor()
        let mark = InMemoryHighWaterMark()
        let firstBoot = TestClock(uptime: 1_000)
        let before = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true),
                                  store: store, highWater: mark, clock: firstBoot, clockFloor: floor)
        _ = await before.refresh()
        firstBoot.advance(100 * 3_600)
        _ = await before.decide(docs) // the app was used 100 h later; floor observed
        let persisted = await eventually { await floor.load() == t0.addingTimeInterval(100 * 3_600) }
        XCTAssertTrue(persisted)

        // Reboot (uptime restarts) and rewind the wall clock to just after t0.
        let secondBoot = TestClock(now: t0.addingTimeInterval(60), uptime: 10)
        let after = makeResolver(feed: GatedFeed([], open: true), store: store, highWater: mark,
                                 clock: secondBoot, clockFloor: floor)
        _ = await after.bootstrap()
        let decision = await after.decide(docs)
        XCTAssertEqual(decision, .deny(.clockRollback))
    }

    /// A device clock that runs slow must not be locked out of fresh snapshots.
    func testSlowDeviceClockStillAdoptsAndCountsFromReceipt() async {
        let slow = TestClock(now: t0.addingTimeInterval(-600))
        let resolver = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true),
                                    clock: slow)
        let outcome = await resolver.refresh()
        XCTAssertEqual(outcome, .adopted(sequence: 1, changes: 1))
        let verification = await resolver.currentVerification()
        XCTAssertEqual(verification?.verifiedAt, t0.addingTimeInterval(-600))
        let decision = await resolver.decide(export)
        XCTAssertEqual(decision, .allow(.verified(age: 0)))
    }

    func testAbsurdlyFutureDatedSnapshotIsStillRefused() async {
        let farFuture = t0.addingTimeInterval(2 * GracePolicy.ceiling)
        let resolver = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: farFuture, seats: [granted]))], open: true))
        let outcome = await resolver.refresh()
        XCTAssertEqual(outcome, .rejected(.futureDated(issuedAt: farFuture)))
    }

    /// A pushed revocation must survive the process dying before the next
    /// signed snapshot, and must reach a Suite sibling sharing the journal.
    func testPushedRevocationSurvivesRelaunchViaJournal() async {
        let store = InMemorySnapshotStore()
        let journal = InMemoryRevocationJournal()
        let mark = InMemoryHighWaterMark()
        let first = makeResolver(feed: GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted]))], open: true),
                                 store: store, highWater: mark, journal: journal)
        _ = await first.refresh()
        await first.ingest([movedToCarol])
        let journalled = await journal.load()
        XCTAssertEqual(journalled, [movedToCarol])

        let relaunched = makeResolver(feed: GatedFeed([], open: true), store: store, highWater: mark, journal: journal)
        _ = await relaunched.bootstrap()
        let decision = await relaunched.decide(docs)
        XCTAssertEqual(decision, .deny(.revoked("S-1", version: 2)))
    }

    /// Pushed grants are not journalled: a forged journal can only deny.
    func testPushedGrantsAreNeverJournalled() async {
        let journal = InMemoryRevocationJournal()
        let resolver = makeResolver(feed: GatedFeed([], open: true), journal: journal)
        let backToAlice = event(v: 3, .assigned(.user("alice")), previous: .user("carol"))
        await resolver.ingest([movedToCarol, backToAlice])
        let journalled = await journal.load()
        XCTAssertEqual(journalled, [movedToCarol], "only the event that removed access may be durable")
    }

    func testJournalIsCompactedOnlyWhenSignedStateCatchesUp() async {
        let journal = InMemoryRevocationJournal()
        let feed = GatedFeed([signed(EntitlementSnapshot(sequence: 1, issuedAt: t0, seats: [granted])),
                              signed(EntitlementSnapshot(sequence: 2, issuedAt: t0, seats: [movedToCarol]))], open: true)
        let resolver = makeResolver(feed: feed, journal: journal)
        await resolver.ingest([movedToCarol])
        _ = await resolver.refresh() // snapshot 1 still says alice: keep the entry
        let kept = await journal.load()
        XCTAssertEqual(kept, [movedToCarol])
        _ = await resolver.refresh() // snapshot 2 contains the revocation: drop it
        let compacted = await journal.load()
        XCTAssertTrue(compacted.isEmpty)
    }

    func testBootstrapNeverWritesTheSharedStore() async {
        let store = CountingStore(signed(EntitlementSnapshot(sequence: 4, issuedAt: t0, seats: [granted])))
        let resolver = makeResolver(feed: GatedFeed([], open: true), store: store)
        _ = await resolver.bootstrap()
        let saves = await store.saves
        XCTAssertEqual(saves, 0, "a reader must never re-write what it read")
    }

    /// A network adoption suspended at its high-water write must not save its
    /// (older) snapshot over a newer one adopted from the store meanwhile.
    func testSuspendedOlderAdoptionDoesNotOverwriteNewerSharedSnapshot() async {
        let newer = signed(EntitlementSnapshot(sequence: 10, issuedAt: t0, seats: [granted]))
        let older = signed(EntitlementSnapshot(sequence: 9, issuedAt: t0, seats: [granted]))
        let store = CountingStore(newer)
        let mark = GatedHighWater()
        let resolver = makeResolver(feed: GatedFeed([older], open: true), store: store, highWater: mark)
        async let network = resolver.refresh()
        let networkHeld = await eventually { await mark.pendingRaises == 1 }
        XCTAssertTrue(networkHeld)
        async let launch = resolver.bootstrap()
        let bothHeld = await eventually { await mark.pendingRaises == 2 }
        XCTAssertTrue(bothHeld)
        await mark.release()
        _ = await (network, launch)
        let shared = await store.load()
        XCTAssertEqual(shared, newer)
        let saves = await store.saves
        XCTAssertEqual(saves, 0)
    }

    func testFinishedResolverFinishesItsStreams() async {
        var resolver: EntitlementResolver? = makeResolver(feed: GatedFeed([], open: true))
        guard let stream = await resolver?.changes() else { return XCTFail("no stream") }
        resolver = nil
        // Bounded wait: a broken implementation fails here instead of hanging the suite.
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "a consumer must not hang on a deallocated resolver")
    }
}
