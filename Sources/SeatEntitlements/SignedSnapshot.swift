import Foundation

/// The server's full view of the seats relevant to one subject, at one point
/// in a monotonically increasing sequence. Revoked seats are included as
/// tombstones (`unassigned`, `refunded`, …), never omitted, so a snapshot can be
/// *merged* into the ledger instead of replacing it.
public struct EntitlementSnapshot: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let issuedAt: Date
    public let seats: [SeatEvent]

    public init(sequence: UInt64, issuedAt: Date, seats: [SeatEvent]) {
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.seats = seats
    }
}

/// Opaque signed bytes plus the signature over exactly those bytes.
///
/// The design is verify-then-parse: the verifier sees raw `payload` bytes and
/// only after it succeeds are they decoded. No canonical-JSON step exists that
/// an attacker could make disagree with the signer.
public struct SignedSnapshot: Codable, Hashable, Sendable {
    public let keyID: String
    public let payload: Data
    public let signature: Data

    public init(keyID: String, payload: Data, signature: Data) {
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }
}

/// Verifies a signature over raw bytes. Production uses an ES256 (P-256)
/// key pinned in the app; see `P256SnapshotVerifier` on Apple platforms.
public protocol SnapshotVerifier: Sendable {
    func isValid(signature: Data, for payload: Data, keyID: String) -> Bool
}

/// Shared storage for the signed snapshot, written by whichever Suite sibling
/// refreshed last and read by all of them (an App Group container in production).
public protocol SnapshotStore: Sendable {
    func load() async -> SignedSnapshot?
    func save(_ snapshot: SignedSnapshot) async
}

/// The highest snapshot sequence this device has ever accepted. Lives somewhere
/// a backup restore or a copied container cannot roll back (a
/// `ThisDeviceOnly` keychain item in a shared access group, in production).
public protocol HighWaterMarkStore: Sendable {
    func load() async -> UInt64
    /// Raises the mark; never lowers it.
    func raise(to value: UInt64) async
}

public enum SnapshotRejection: Error, Hashable, Sendable {
    case badSignature
    case undecodable
    /// Older than a snapshot this device already accepted: a restored backup,
    /// a stale sibling write, or a replayed response.
    case rolledBack(sequence: UInt64, highWater: UInt64)
    /// Issued further in the future than clock skew can explain.
    case futureDated(issuedAt: Date)
}

public enum SnapshotGate {
    /// Fresh coder instances per call: no shared mutable coder state across actors.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Verify, decode, then apply the anti-rollback and freshness rules.
    /// A snapshot equal to the high-water mark is accepted (an idempotent reload).
    public static func open(_ signed: SignedSnapshot,
                            verifier: any SnapshotVerifier,
                            highWater: UInt64,
                            now: Date,
                            skewTolerance: TimeInterval) -> Result<EntitlementSnapshot, SnapshotRejection> {
        guard verifier.isValid(signature: signed.signature, for: signed.payload, keyID: signed.keyID) else {
            return .failure(.badSignature)
        }
        guard let snapshot = try? makeDecoder().decode(EntitlementSnapshot.self, from: signed.payload) else {
            return .failure(.undecodable)
        }
        guard snapshot.sequence >= highWater else {
            return .failure(.rolledBack(sequence: snapshot.sequence, highWater: highWater))
        }
        let tolerance = Saturating.interval(skewTolerance, ceiling: GracePolicy.ceiling)
        let lead = snapshot.issuedAt.timeIntervalSince(now)
        guard !lead.isNaN, lead <= tolerance else {
            return .failure(.futureDated(issuedAt: snapshot.issuedAt))
        }
        return .success(snapshot)
    }
}

// MARK: - In-memory implementations (tests, previews, the demo)

public actor InMemorySnapshotStore: SnapshotStore {
    private var stored: SignedSnapshot?
    public init(_ initial: SignedSnapshot? = nil) { stored = initial }
    public func load() -> SignedSnapshot? { stored }
    public func save(_ snapshot: SignedSnapshot) { stored = snapshot }
}

public actor InMemoryHighWaterMark: HighWaterMarkStore {
    private var value: UInt64
    public init(_ initial: UInt64 = 0) { value = initial }
    public func load() -> UInt64 { value }
    public func raise(to newValue: UInt64) { value = max(value, newValue) }
}

// MARK: - Durability ports for state that is not in a signed snapshot

/// Device-local clock evidence, persisted across launches and reboots (a
/// `ThisDeviceOnly` keychain item in a shared access group, in production):
/// the latest wall-clock time this device has observed (the *floor*), and the
/// last network verification with its monotonic reading and boot id.
///
/// Since 1.1.0 the store can also *reset* the floor and persist the last
/// verification. Both have default implementations, so a 1.0.x conformer
/// still compiles: it keeps the 1.0 behaviour (floor only rises, monotonic
/// evidence lasts one process).
public protocol ClockFloorStore: Sendable {
    func load() async -> Date?
    /// Raises the floor; never lowers it.
    func raise(to date: Date) async
    /// Replaces the floor. Called only after a network-fresh, signed refresh,
    /// which proves the state is current whatever the device clock says, so a
    /// floor poisoned by a clock once set forward cannot lock out a device
    /// that is online and verified.
    func reset(to date: Date) async
    func loadVerification() async -> Verification?
    func saveVerification(_ verification: Verification) async
}

extension ClockFloorStore {
    public func reset(to date: Date) async { await raise(to: date) }
    public func loadVerification() async -> Verification? { nil }
    public func saveVerification(_ verification: Verification) async {}
}

/// Durable storage for *pushed* seat events that reduce this holder's access
/// (a seat reassigned away, refunded, expired), shared with Suite siblings
/// (App Group in production).
///
/// Pushed events are not signed snapshots, so the journal deliberately never
/// stores an event that would *grant* this holder anything: a forged or
/// corrupted journal can only deny access (fail closed), never unlock it.
/// Grants arrive durably only inside a signed snapshot.
///
/// The interface is merge-based (`record`) rather than save-the-whole-list,
/// so concurrent writers interleaving at `await` cannot lose each other's
/// entries.
public protocol RevocationJournal: Sendable {
    func load() async -> [SeatEvent]
    func record(_ events: [SeatEvent]) async
    /// Removes exactly these entries (if still present and unchanged), once a
    /// signed snapshot has caught up with them.
    func remove(_ events: [SeatEvent]) async
}

public actor InMemoryClockFloor: ClockFloorStore {
    private var floor: Date?
    private var verification: Verification?
    public init(_ initial: Date? = nil) { floor = initial }
    public func load() -> Date? { floor }
    public func raise(to date: Date) {
        guard !date.timeIntervalSince1970.isNaN else { return }
        floor = max(floor ?? date, date)
    }
    public func reset(to date: Date) {
        guard !date.timeIntervalSince1970.isNaN else { return }
        floor = date
    }
    public func loadVerification() -> Verification? { verification }
    public func saveVerification(_ verification: Verification) { self.verification = verification }
}

public actor InMemoryRevocationJournal: RevocationJournal {
    private var ledger: SeatLedger
    public init(capacity: Int = SeatLedger.defaultCapacity) { ledger = SeatLedger(capacity: capacity) }
    public func load() -> [SeatEvent] { ledger.allSeats }
    public func record(_ events: [SeatEvent]) { ledger.apply(events) }
    public func remove(_ events: [SeatEvent]) { ledger.remove(events) }
}
