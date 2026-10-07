#if canImport(SwiftUI) && canImport(CryptoKit)
import CryptoKit
import Foundation
import SeatEntitlements

/// A device clock you can move, in both domains the grace policy reads.
///
/// `advance` models real time passing (wall clock *and* uptime move).
/// `tamperWallClock` models a user changing the date in Settings (only the
/// wall clock moves), which is exactly what the monotonic check defends against.
final class SimulatedClock: EntitlementClock, @unchecked Sendable {
    // @unchecked: every stored property is guarded by `lock`.
    private let lock = NSLock()
    private let base: Date
    private var elapsed: TimeInterval = 0
    private var wallTamper: TimeInterval = 0

    init(base: Date) { self.base = base }

    func now() -> Date { lock.withLock { base.addingTimeInterval(elapsed + wallTamper) } }
    func uptime() -> TimeInterval? { lock.withLock { 10_000 + elapsed } }
    /// The server's clock: true time, unaffected by on-device tampering.
    func serverNow() -> Date { lock.withLock { base.addingTimeInterval(elapsed) } }
    var tamper: TimeInterval { lock.withLock { wallTamper } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { elapsed += max(0, seconds) }
    }

    func tamperWallClock(by seconds: TimeInterval) {
        lock.withLock { wallTamper += seconds }
    }
}

enum SimulatedBackendError: Error, CustomStringConvertible {
    case offline
    var description: String { "device offline (no route to entitlement service)" }
}

/// Stands in for the entitlement service: the roster of record, a sequence
/// counter and an ES256 signing key. In production this is your backend,
/// fed by App Store Server Notifications and the MDM assignment API.
actor SimulatedBackend: EntitlementFeed {
    private var roster: [SeatID: SeatEvent]
    private var sequence: UInt64 = 0
    private var online = true
    private let signer: P256SnapshotSigner
    private let clock: SimulatedClock

    init(seats: [SeatEvent], signer: P256SnapshotSigner, clock: SimulatedClock) {
        var roster: [SeatID: SeatEvent] = [:]
        for seat in seats { roster[seat.seatID] = seat }
        self.roster = roster
        self.signer = signer
        self.clock = clock
    }

    func setOnline(_ value: Bool) { online = value }

    func fetchSnapshot() async throws -> SignedSnapshot {
        guard online else { throw SimulatedBackendError.offline }
        guard sequence < UInt64.max else { throw SimulatedBackendError.offline }
        sequence += 1
        let snapshot = EntitlementSnapshot(sequence: sequence, issuedAt: clock.serverNow(),
                                           seats: roster.values.sorted { $0.seatID < $1.seatID })
        return try signer.sign(snapshot)
    }

    /// An MDM reassignment: bumps the seat's version and records who lost it.
    func assign(_ seatID: SeatID, to holder: Holder) -> SeatEvent? {
        guard let current = roster[seatID], current.version < UInt64.max else { return nil }
        let event = SeatEvent(seatID: seatID, group: current.group, version: current.version + 1,
                              state: .assigned(holder), previousHolder: current.state.holder,
                              source: .server, issuedAt: clock.serverNow(), expiresAt: current.expiresAt)
        roster[seatID] = event
        return event
    }

    func seat(_ seatID: SeatID) -> SeatEvent? { roster[seatID] }
}
#endif
