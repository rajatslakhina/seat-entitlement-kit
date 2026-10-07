import Foundation

/// A change that reached the ledger. Consumers deduplicate on
/// `(seatID, version)`, so redelivery is harmless.
public struct SeatChange: Hashable, Sendable {
    public let previous: SeatEvent?
    public let current: SeatEvent
    /// True when the incoming event shared a version with the stored one but
    /// carried a different payload, and won the tie-break.
    public let resolvedConflict: Bool

    public var seatID: SeatID { current.seatID }
    public var version: UInt64 { current.version }
}

/// The per-device view of every seat that matters to this device: one
/// last-writer-wins register per seat, ordered by `SeatEvent.beats`.
///
/// Because the winner of any two events is decided by a strict total order on
/// their contents, applying the same set of events in any order, any number of
/// times, yields the same ledger. That property is what lets StoreKit
/// updates, the server feed, MDM pushes and sibling-app snapshots all write
/// here without coordinating with each other.
public struct SeatLedger: Sendable, Equatable {
    public enum Outcome: Hashable, Sendable {
        case applied(SeatChange)
        /// Exactly this event is already stored.
        case duplicate
        /// A stored event beats the incoming one (older version, or the same
        /// version from a lower-ranked source / less restrictive payload).
        case superseded(currentVersion: UInt64)
        /// The ledger is full and the event is for a seat it does not know.
        case rejectedCapacity
    }

    /// A device tracks the seats relevant to its users, not an organisation's
    /// whole roster. The bound keeps a buggy or hostile feed from growing the
    /// ledger (and the shared cache) without limit.
    public static let defaultCapacity = 4_096

    public let capacity: Int
    public private(set) var records: [SeatID: SeatEvent] = [:]

    public init(capacity: Int = SeatLedger.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public mutating func apply(_ event: SeatEvent) -> Outcome {
        guard let stored = records[event.seatID] else {
            guard records.count < capacity else { return .rejectedCapacity }
            records[event.seatID] = event
            return .applied(SeatChange(previous: nil, current: event, resolvedConflict: false))
        }
        if stored == event { return .duplicate }
        guard event.beats(stored) else { return .superseded(currentVersion: stored.version) }
        records[event.seatID] = event
        return .applied(SeatChange(previous: stored, current: event,
                                   resolvedConflict: stored.version == event.version))
    }

    @discardableResult
    public mutating func apply<S: Sequence>(_ events: S) -> [Outcome] where S.Element == SeatEvent {
        events.map { apply($0) }
    }

    /// Removes each given event only if it is still the stored winner for its
    /// seat. Used to compact a journal once signed state has caught up.
    public mutating func remove(_ events: [SeatEvent]) {
        for event in events where records[event.seatID] == event {
            records[event.seatID] = nil
        }
    }

    /// Seats in `group`, sorted by id for stable presentation.
    public func seats(in group: ProductGroupID) -> [SeatEvent] {
        records.values.filter { $0.group == group }.sorted { $0.seatID < $1.seatID }
    }

    public var allSeats: [SeatEvent] {
        records.values.sorted { $0.seatID < $1.seatID }
    }
}

/// Consumer-side idempotency for fan-out: remembers the winning event per
/// seat and admits a change only if it beats what the consumer already acted
/// on. Redelivery, replays and out-of-order delivery are all no-ops. Memory is
/// bounded by the number of seats.
public struct ChangeDeduplicator: Sendable {
    private var acted: [SeatID: SeatEvent] = [:]

    public init() {}

    /// Returns true if the change is new and should be acted on.
    public mutating func admit(_ change: SeatChange) -> Bool {
        if let seen = acted[change.seatID], !change.current.beats(seen) { return false }
        acted[change.seatID] = change.current
        return true
    }
}
