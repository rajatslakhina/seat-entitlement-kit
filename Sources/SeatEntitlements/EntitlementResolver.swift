import Foundation

/// The server feed: returns the latest signed snapshot for this subject.
public protocol EntitlementFeed: Sendable {
    func fetchSnapshot() async throws -> SignedSnapshot
}

/// Both clock domains the grace policy needs. Injected so tests can move time.
public protocol EntitlementClock: Sendable {
    func now() -> Date
    /// Monotonic seconds since boot, or nil where unavailable.
    func uptime() -> TimeInterval?
}

public struct SystemEntitlementClock: EntitlementClock {
    public init() {}
    public func now() -> Date { Date() }
    public func uptime() -> TimeInterval? { ProcessInfo.processInfo.systemUptime }
}

public enum RefreshOutcome: Hashable, Sendable {
    case adopted(sequence: UInt64, changes: Int)
    case rejected(SnapshotRejection)
    case transportFailed(String)
}

/// The one place feature code asks "may this user on this device use this
/// feature right now?".
///
/// Every input channel (the server snapshot, pushed seat events from
/// StoreKit's `Transaction.updates` or the server, the shared cache and
/// revocation journal written by a Suite sibling) converges on one
/// `SeatLedger` through the same order-independent merge. Feature code never
/// sees which channel spoke last, so Apple's still-thin multiseat semantics can
/// change behind the adapters without touching a single feature gate.
///
/// Concurrency guarantees:
/// * `refresh()` is single-flight: concurrent callers share one fetch.
/// * Snapshots are *merged*, never swapped in. A revocation pushed while a
///   fetch is suspended survives the (older) response that lands afterwards.
/// * Verification time only moves forward, the persisted high-water mark and
///   wall-clock floor only rise, so interleaved adoptions cannot regress
///   freshness or reopen a rollback window.
/// * Pushed revocations are journalled before `ingest` returns, so they
///   survive a relaunch and reach Suite siblings; pushed grants are not.
public actor EntitlementResolver {
    public static let maximumSubscribers = 64
    /// The wall-clock floor is persisted when it has advanced this far.
    public static let floorPersistInterval: TimeInterval = 60

    public nonisolated let context: CheckContext
    public nonisolated let policy: GracePolicy

    private let verifier: any SnapshotVerifier
    private let store: any SnapshotStore
    private let highWater: any HighWaterMarkStore
    private let feed: any EntitlementFeed
    private let clock: any EntitlementClock
    private let journal: any RevocationJournal
    private let clockFloor: any ClockFloorStore

    private var ledger: SeatLedger
    private var verification: Verification?
    private var newestAdoptedSequence: UInt64?
    private var wallFloor: Date?
    private var persistedFloor: Date?
    private var inFlight: Task<RefreshOutcome, Never>?
    private var inFlightGeneration: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<SeatChange>.Continuation] = [:]

    public private(set) var lastRejection: SnapshotRejection?
    public private(set) var fetchCount = 0
    /// Calls to `refresh()`, joined or not. Lets tests prove two callers were
    /// really concurrent before asserting they shared one fetch.
    public private(set) var refreshRequests = 0

    public init(context: CheckContext,
                policy: GracePolicy = .standard,
                verifier: any SnapshotVerifier,
                store: any SnapshotStore,
                highWater: any HighWaterMarkStore,
                feed: any EntitlementFeed,
                clock: any EntitlementClock = SystemEntitlementClock(),
                journal: any RevocationJournal = InMemoryRevocationJournal(),
                clockFloor: any ClockFloorStore = InMemoryClockFloor(),
                ledgerCapacity: Int = SeatLedger.defaultCapacity) {
        self.context = context
        self.policy = policy
        self.verifier = verifier
        self.store = store
        self.highWater = highWater
        self.feed = feed
        self.clock = clock
        self.journal = journal
        self.clockFloor = clockFloor
        self.ledger = SeatLedger(capacity: ledgerCapacity)
    }

    deinit {
        // Consumers iterating `changes()` must not wait forever on a resolver
        // that no longer exists.
        for continuation in subscribers.values { continuation.finish() }
    }

    // MARK: Reads

    public func decide(_ feature: Feature) -> Decision {
        let now = clock.now()
        observeWallClock(now)
        return EntitlementDecider.decide(feature: feature, context: context, ledger: ledger,
                                         verification: verification, now: now, uptime: clock.uptime(),
                                         wallClockFloor: wallFloor, policy: policy)
    }

    public func seats() -> [SeatEvent] { ledger.allSeats }
    public func currentVerification() -> Verification? { verification }
    public func currentWallClockFloor() -> Date? { wallFloor }
    public var subscriberCount: Int { subscribers.count }

    /// When this device should next refresh: its deterministic slot after the
    /// last verification. `nil` before anything has been verified (refresh now).
    public func nextScheduledRefresh(using scheduler: RefreshScheduler) -> Date? {
        guard let verification else { return nil }
        return scheduler.nextRefresh(after: verification.verifiedAt, deviceKey: context.deviceID)
    }

    // MARK: Writes

    /// Launch path: load the persisted wall-clock floor, adopt whatever a Suite
    /// sibling last wrote to the shared store (re-verified here; a sibling is
    /// not trusted just for being one), then replay the revocation journal.
    /// Returns nil when the shared store is empty.
    public func bootstrap() async -> RefreshOutcome? {
        if let persisted = await clockFloor.load(), !persisted.timeIntervalSince1970.isNaN {
            wallFloor = max(wallFloor ?? persisted, persisted)
            persistedFloor = max(persistedFloor ?? persisted, persisted)
        }
        var outcome: RefreshOutcome?
        if let signed = await store.load() {
            outcome = await adopt(signed, fromNetwork: false)
        }
        let journalled = await journal.load()
        publish(ledger.apply(journalled))
        return outcome
    }

    /// Fetch and adopt the latest snapshot. Concurrent callers share one fetch.
    public func refresh() async -> RefreshOutcome {
        refreshRequests &+= 1
        if let inFlight { return await inFlight.value }
        inFlightGeneration &+= 1
        let generation = inFlightGeneration
        let task = Task { await self.performRefresh() }
        inFlight = task
        let outcome = await task.value
        // Only clear the slot if it still holds *our* task.
        if inFlightGeneration == generation { inFlight = nil }
        return outcome
    }

    /// Apply pushed seat events (StoreKit `Transaction.updates`, a server
    /// push). Adapters verify these before they get here, StoreKit by its own
    /// JWS check. Pushed events change seats but never freshness: only a
    /// signed snapshot proves the *whole* state is current.
    ///
    /// Applied events that do not grant this holder anything are journalled
    /// before this returns, so a revocation survives a relaunch and reaches
    /// Suite siblings. Grants stay in memory until a signed snapshot confirms them.
    @discardableResult
    public func ingest(_ events: [SeatEvent]) async -> [SeatLedger.Outcome] {
        let outcomes = ledger.apply(events)
        publish(outcomes)
        var durable: [SeatEvent] = []
        for case .applied(let change) in outcomes where change.current.state.holder?.matches(context) != true {
            durable.append(change.current)
        }
        if !durable.isEmpty { await journal.record(durable) }
        return outcomes
    }

    /// Fan-out of every applied change. Each subscriber gets its own bounded
    /// buffer (newest kept), so one slow consumer cannot grow memory or stall
    /// the others. Pair with `ChangeDeduplicator` on the consumer side.
    public func changes(bufferingNewest limit: Int = 64) -> AsyncStream<SeatChange> {
        let (stream, continuation) = AsyncStream<SeatChange>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, limit)))
        guard subscribers.count < Self.maximumSubscribers else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    // MARK: Internals

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Raise the in-memory wall-clock floor, and persist it once it has moved
    /// far enough to be worth a write. Persisting is fire-and-forget: the
    /// in-memory floor already protects this process.
    private func observeWallClock(_ now: Date) {
        guard !now.timeIntervalSince1970.isNaN else { return }
        let floor = max(wallFloor ?? now, now)
        wallFloor = floor
        let due = persistedFloor.map { floor.timeIntervalSince($0) >= Self.floorPersistInterval } ?? true
        guard due else { return }
        persistedFloor = floor
        let store = clockFloor
        Task { await store.raise(to: floor) }
    }

    private func performRefresh() async -> RefreshOutcome {
        fetchCount &+= 1
        let signed: SignedSnapshot
        do {
            signed = try await feed.fetchSnapshot()
        } catch {
            return .transportFailed(String(describing: error))
        }
        return await adopt(signed, fromNetwork: true)
    }

    private func adopt(_ signed: SignedSnapshot, fromNetwork: Bool) async -> RefreshOutcome {
        let mark = await highWater.load()
        // Everything below the await re-reads actor state; nothing read before
        // the suspension is reused after it.
        let receivedAt = clock.now()
        // Freshness is never judged against the server's clock alone: a device
        // whose clock runs slow would otherwise reject every snapshot. Only
        // absurd dates (more than a year ahead of this device) are refused.
        let opened = SnapshotGate.open(signed, verifier: verifier, highWater: mark,
                                       now: receivedAt, skewTolerance: GracePolicy.ceiling)
        let snapshot: EntitlementSnapshot
        switch opened {
        case .failure(let rejection):
            lastRejection = rejection
            return .rejected(rejection)
        case .success(let value):
            snapshot = value
        }

        // Merge (not replace) and advance freshness monotonically, before any
        // further suspension, so the state is consistent at every await.
        let outcomes = ledger.apply(snapshot.seats)
        publish(outcomes)
        let candidate = Verification(verifiedAt: min(snapshot.issuedAt, receivedAt),
                                     uptimeAtVerification: fromNetwork ? clock.uptime() : nil)
        if Self.shouldReplace(verification, with: candidate) { verification = candidate }
        observeWallClock(receivedAt)
        let isNewest = newestAdoptedSequence.map { snapshot.sequence >= $0 } ?? true
        if isNewest { newestAdoptedSequence = snapshot.sequence }
        lastRejection = nil

        await highWater.raise(to: snapshot.sequence)
        // Share with Suite siblings, unless a newer snapshot was adopted while
        // we were suspended above. Snapshots read from the store are never
        // written back.
        if fromNetwork, isNewest, newestAdoptedSequence == snapshot.sequence {
            await store.save(signed)
        }
        await compactJournal(against: snapshot)

        let applied = outcomes.reduce(0) { count, outcome in
            if case .applied = outcome { return count + 1 }
            return count
        }
        return .adopted(sequence: snapshot.sequence, changes: applied)
    }

    /// Verification moves forward only. An equal time replaces the current
    /// one only to *gain* a monotonic reading, never to lose it.
    static func shouldReplace(_ current: Verification?, with candidate: Verification) -> Bool {
        guard let current else { return true }
        if candidate.verifiedAt > current.verifiedAt { return true }
        if candidate.verifiedAt == current.verifiedAt {
            return current.uptimeAtVerification == nil && candidate.uptimeAtVerification != nil
        }
        return false
    }

    /// Drop journal entries that *signed* state has caught up with: the
    /// snapshot itself holds the same event or one that beats it. (Comparing
    /// against the ledger would be wrong: the ledger already contains every
    /// pushed event, so nothing would ever stay journalled.)
    private func compactJournal(against snapshot: EntitlementSnapshot) async {
        var signedSeats: [SeatID: SeatEvent] = [:]
        for seat in snapshot.seats {
            if let existing = signedSeats[seat.seatID], !seat.beats(existing) { continue }
            signedSeats[seat.seatID] = seat
        }
        let entries = await journal.load()
        let settled = entries.filter { entry in
            guard let signed = signedSeats[entry.seatID] else { return false }
            return signed == entry || signed.beats(entry)
        }
        if !settled.isEmpty { await journal.remove(settled) }
    }

    private func publish(_ outcomes: [SeatLedger.Outcome]) {
        for case .applied(let change) in outcomes {
            for continuation in subscribers.values {
                continuation.yield(change)
            }
        }
    }
}
