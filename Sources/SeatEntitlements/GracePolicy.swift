import Foundation

/// How long verified entitlement state may be trusted, and how far it may be
/// stretched when the device cannot reach the server.
///
/// The two numbers are a direct trade-off between availability and revocation
/// latency: a seat reassigned by MDM while a device is offline keeps working
/// on that device for at most `freshFor + offlineGrace` (for fail-open
/// features). Leads pick these per product, and this type makes the bound
/// explicit instead of leaving it to whatever a cache TTL happened to be.
public struct GracePolicy: Hashable, Sendable {
    /// One year. No sane policy exceeds it; clamping keeps date arithmetic finite.
    public static let ceiling: TimeInterval = 365 * 24 * 3_600

    public let freshFor: TimeInterval
    public let offlineGrace: TimeInterval
    public let clockSkewTolerance: TimeInterval

    /// Inputs are sanitised rather than trusted: NaN or negative becomes 0,
    /// infinity or anything above a year becomes one year.
    public init(freshFor: TimeInterval, offlineGrace: TimeInterval, clockSkewTolerance: TimeInterval = 300) {
        self.freshFor = Saturating.interval(freshFor, ceiling: Self.ceiling)
        self.offlineGrace = Saturating.interval(offlineGrace, ceiling: Self.ceiling)
        self.clockSkewTolerance = Saturating.interval(clockSkewTolerance, ceiling: Self.ceiling)
    }

    public static let standard = GracePolicy(freshFor: 6 * 3_600, offlineGrace: 72 * 3_600)

    /// Worst-case time a revoked seat keeps a fail-open feature working on a
    /// device that never reconnects.
    public var worstCaseOfflineRevocationLatency: TimeInterval { freshFor + offlineGrace }
}

/// Why access was allowed.
public enum AllowBasis: Hashable, Sendable {
    /// State verified within `freshFor`.
    case verified(age: TimeInterval)
    /// Stale, but inside the offline grace window; `remaining` until it closes.
    case offlineGrace(remaining: TimeInterval)
}

/// Why access was denied. Every case is something a UI can explain.
public enum DenyReason: Hashable, Sendable {
    /// No seat in the group is assigned to this user or device.
    case noSeat
    /// A seat that was this holder's has moved away or been revoked; known
    /// revocations are honoured immediately, whatever the freshness.
    case revoked(SeatID, version: UInt64)
    /// The paid period ended before the last verification, and no renewal was seen.
    case expired(SeatID)
    /// Nothing has ever been verified on this device.
    case noVerifiedState
    /// The wall clock is earlier than the last verification time, so state age
    /// cannot be trusted (and no monotonic reading was available to fall back on).
    case clockRollback
    /// A fail-closed feature needs state verified within `freshFor`.
    case needsFreshState(age: TimeInterval)
    /// A fail-open feature ran past the offline grace window.
    case graceExhausted(age: TimeInterval)
}

public enum Decision: Hashable, Sendable {
    case allow(AllowBasis)
    case deny(DenyReason)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// When the device last verified signed state, in both clock domains.
public struct Verification: Hashable, Sendable {
    /// Device wall-clock time the state counts as verified at:
    /// `min(server issuedAt, device clock at receipt)`. Never fresher than the
    /// server says, never fresher than the moment it arrived, and immune to a
    /// device clock that runs slow (the server's `issuedAt` is only compared
    /// with the device clock through this `min`).
    public let verifiedAt: Date
    /// Device uptime when it was verified, if this process saw it happen.
    /// Uptime is monotonic within a boot and cannot be moved by the user.
    public let uptimeAtVerification: TimeInterval?

    public init(verifiedAt: Date, uptimeAtVerification: TimeInterval?) {
        self.verifiedAt = verifiedAt
        self.uptimeAtVerification = uptimeAtVerification
    }
}

/// The pure decision function. No I/O, no clocks of its own: everything it
/// needs is passed in, so every branch is unit-testable at its boundary.
public enum EntitlementDecider {
    public static func decide(feature: Feature,
                              context: CheckContext,
                              ledger: SeatLedger,
                              verification: Verification?,
                              now: Date,
                              uptime: TimeInterval?,
                              wallClockFloor: Date? = nil,
                              policy: GracePolicy) -> Decision {
        let seats = ledger.seats(in: feature.group)

        // 1. Find this holder's seat. Prefer one whose paid period runs longest.
        let mine = seats
            .filter { $0.state.holder?.matches(context) == true }
            .max { lhs, rhs in
                (lhs.expiresAt ?? .distantFuture) < (rhs.expiresAt ?? .distantFuture)
            }

        guard let seat = mine else {
            // 2. Known revocations win over any amount of grace.
            if let lost = seats.first(where: { $0.previousHolder?.matches(context) == true }) {
                return .deny(.revoked(lost.seatID, version: lost.version))
            }
            return .deny(.noSeat)
        }

        guard let verification else { return .deny(.noVerifiedState) }

        // 3. Age of the verified state. Take the larger of the wall-clock age
        //    and the monotonic age, so moving the clock back cannot shrink it.
        //    `wallClockFloor` is the latest wall time this device has ever
        //    observed (persisted across launches and reboots); "now" is never
        //    earlier than it, which closes the rewind-then-reboot gap where no
        //    monotonic reading survives.
        var monotonicAge: TimeInterval?
        if let then = verification.uptimeAtVerification, let uptime, uptime >= then {
            monotonicAge = uptime - then
        }
        if now.timeIntervalSince1970.isNaN { return .deny(.clockRollback) }
        var effectiveNow = now
        if let floor = wallClockFloor, !floor.timeIntervalSince1970.isNaN, floor > now {
            if floor.timeIntervalSince(now) > policy.clockSkewTolerance && monotonicAge == nil {
                return .deny(.clockRollback)
            }
            effectiveNow = floor
        }
        let wallAge = effectiveNow.timeIntervalSince(verification.verifiedAt)
        if wallAge.isNaN { return .deny(.clockRollback) }
        if wallAge < -policy.clockSkewTolerance && monotonicAge == nil {
            return .deny(.clockRollback)
        }
        let age = max(max(wallAge, 0), monotonicAge ?? 0)

        // 4. Expiry. If the period ended *before* we last verified, the server
        //    already had a chance to tell us about a renewal and did not: that
        //    is a fact. If it ended *after*, renewal is merely unconfirmed.
        var unconfirmedSince: TimeInterval?
        if let expiresAt = seat.expiresAt, expiresAt <= effectiveNow {
            if expiresAt <= verification.verifiedAt { return .deny(.expired(seat.seatID)) }
            unconfirmedSince = effectiveNow.timeIntervalSince(expiresAt)
        }

        if age <= policy.freshFor && unconfirmedSince == nil {
            return .allow(.verified(age: age))
        }

        // 5. Stale (or renewal unconfirmed): the feature's failure mode decides.
        switch feature.failureMode {
        case .failClosed:
            return .deny(.needsFreshState(age: age))
        case .failOpen:
            var remaining = policy.freshFor + policy.offlineGrace - age
            if let since = unconfirmedSince {
                remaining = min(remaining, policy.offlineGrace - since)
            }
            guard remaining > 0 else { return .deny(.graceExhausted(age: age)) }
            return .allow(.offlineGrace(remaining: remaining))
        }
    }
}
