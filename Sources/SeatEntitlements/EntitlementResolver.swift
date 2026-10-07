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
    /// An identifier for the current boot, so persisted uptime readings can be
    /// trusted across app launches within one boot. Default: nil (unknown).
    func bootID() -> String?
}

extension EntitlementClock {
    public func bootID() -> String? { nil }
}

public struct SystemEntitlementClock: EntitlementClock {
    public init() {}
    public func now() -> Date { Date() }

    /// Seconds since boot, *including time asleep*. A clock that pauses during
    /// sleep (`ProcessInfo.systemUptime`) would let an iPad that slept offline
    /// all weekend recover the whole weekend with a clock rewind.
    public func uptime() -> TimeInterval? {
        #if canImport(Darwin)
        // CLOCK_MONOTONIC_RAW is mach_continuous_time: it keeps counting in sleep.
        let nanos = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard nanos > 0 else { return ProcessInfo.processInfo.systemUptime }
        return Double(nanos) / 1_000_000_000
        #elseif os(Linux)
        var spec = timespec()
        guard clock_gettime(CLOCK_BOOTTIME, &spec) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1_000_000_000
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }

    /// A per-boot identifier: `kern.bootsessionuuid` on Apple platforms (unlike
    /// `kern.boottime`, it does not change when the calendar clock is stepped),
    /// the kernel's boot id on Linux.
    public func bootID() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        #else
        let id = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)
        return id?.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
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
/// * A snapshot this process fetched is a fresh proof: it resets verification
///   to *receipt* time and resets the wall-clock floor, so no device clock
///   error (fast, slow, rewound, or set forward once) can lock out a device
///   that is online and verified. Snapshots read from the shared store only
///   ever move verification forward, and the high-water mark only rises, so
///   interleaved adoptions cannot reopen a rollback window.
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
    /// Bumped by every floor reset; queued raises from before it are dropped.
    private var floorGeneration: UInt64 = 0
    /// Server `issuedAt` of the last snapshot accepted as a fresh network proof.
    private var lastNetworkIssuedAt: Date?
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
                                         bootID: clock.bootID(), wallClockFloor: wallFloor, policy: policy)
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

    /// Launch path, in this order: the persisted clock evidence (wall-clock
    /// floor and last network verification, whose monotonic reading still
    /// holds if this is the same boot), then the revocation journal, then
    /// whatever a Suite sibling last wrote to the shared store (re-verified
    /// here; a sibling is not trusted just for being one). The journal goes
    /// before the store so that no `decide` running during the store's
    /// suspensions can see a journalled revocation un-applied.
    /// Returns nil when the shared store is empty.
    public func bootstrap() async -> RefreshOutcome? {
        if let persisted = await clockFloor.load(), !persisted.timeIntervalSince1970.isNaN {
            wallFloor = max(wallFloor ?? persisted, persisted)
            persistedFloor = max(persistedFloor ?? persisted, persisted)
        }
        if let evidence = await clockFloor.loadVerification() {
            if let issued = evidence.serverIssuedAt {
                lastNetworkIssuedAt = max(lastNetworkIssuedAt ?? issued, issued)
            }
            if Self.shouldReplace(verification, with: evidence) { verification = evidence }
        }
        let journalled = await journal.load()
        publish(ledger.apply(journalled))
        guard let signed = await store.load() else { return nil }
        return await adopt(signed, fromNetwork: false)
    }

    /// Fetch and adopt the latest snapshot. Concurrent callers share one fetch.
    public func refresh() async -> RefreshOutcome {
        refreshRequests &+= 1
        if let inFlight { return await inFlight.value }
        inFlightGeneration &+= 1
        let generation = inFlightGeneration
        let task = Task { await self.performRefresh(generation: generation) }
        inFlight = task
        return await task.value
    }

    /// Apply pushed seat events (StoreKit `Transaction.updates`, a server
    /// push). Adapters verify these before they get here, StoreKit by its own
    /// JWS check. Pushed events change seats but never freshness: only a
    /// signed snapshot proves the *whole* state is current.
    ///
    /// Applied events that take a seat *away from this holder* are journalled
    /// before this returns, so a revocation survives a relaunch and reaches
    /// Suite siblings. Grants (and other holders' seat moves) stay in memory
    /// until a signed snapshot confirms them.
    @discardableResult
    public func ingest(_ events: [SeatEvent]) async -> [SeatLedger.Outcome] {
        let outcomes = ledger.apply(events)
        publish(outcomes)
        var durable: [SeatEvent] = []
        for case .applied(let change) in outcomes where Self.revokes(change, from: context) {
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

    /// True when a change leaves this holder without a seat it had (or that
    /// the issuer says it had). Never true for a change that grants it one.
    static func revokes(_ change: SeatChange, from context: CheckContext) -> Bool {
        guard change.current.state.holder?.matches(context) != true else { return false }
        return change.current.previousHolder?.matches(context) == true
            || change.previous?.state.holder?.matches(context) == true
    }

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
        let generation = floorGeneration
        Task { await self.persistFloor(floor, generation: generation) }
    }

    /// Persist a raised floor unless a reset has happened since it was observed
    /// (a stale raise must not re-poison a floor that a fresh proof just reset).
    private func persistFloor(_ floor: Date, generation: UInt64) async {
        guard generation == floorGeneration else { return }
        await clockFloor.raise(to: floor)
    }

    private func performRefresh(generation: UInt64) async -> RefreshOutcome {
        fetchCount &+= 1
        let outcome: RefreshOutcome
        do {
            let signed = try await feed.fetchSnapshot()
            outcome = await adopt(signed, fromNetwork: true)
        } catch {
            outcome = .transportFailed(String(describing: error))
        }
        // Free the slot on the actor *before* the result is handed out, so a
        // caller arriving after this point starts a new fetch instead of
        // joining a finished one.
        if inFlightGeneration == generation { inFlight = nil }
        return outcome
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
        var freshEvidence: Verification?
        // A network snapshot is a *new* proof only if the server's clock has
        // moved past the last one; a replayed (or cached) snapshot is not.
        var isNewProof = fromNetwork
        if isNewProof, let last = lastNetworkIssuedAt, snapshot.issuedAt <= last { isNewProof = false }
        if isNewProof {
            // A snapshot this process just fetched is a new proof that the
            // state is current. Age it from receipt on the device's own clock,
            // whatever that clock says, and re-anchor the wall-clock floor to it.
            let evidence = Verification(verifiedAt: receivedAt, uptimeAtVerification: clock.uptime(),
                                        bootID: clock.bootID(), serverIssuedAt: snapshot.issuedAt)
            verification = evidence
            freshEvidence = evidence
            lastNetworkIssuedAt = snapshot.issuedAt
            wallFloor = receivedAt
            persistedFloor = receivedAt
            floorGeneration &+= 1
        } else {
            let candidate = Verification(verifiedAt: min(snapshot.issuedAt, receivedAt),
                                         uptimeAtVerification: nil)
            if Self.shouldReplace(verification, with: candidate) { verification = candidate }
            observeWallClock(receivedAt)
        }
        let isNewest = newestAdoptedSequence.map { snapshot.sequence >= $0 } ?? true
        if isNewest { newestAdoptedSequence = snapshot.sequence }
        lastRejection = nil

        if let freshEvidence {
            await clockFloor.reset(to: freshEvidence.verifiedAt)
            await clockFloor.saveVerification(freshEvidence)
        }
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
