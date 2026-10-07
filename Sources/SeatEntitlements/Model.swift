import Foundation

// MARK: - Identifiers

/// A seat bought by an organisation (Volume Purchasing) or a group, and
/// assigned to one holder at a time by device management or by Apple.
public struct SeatID: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: SeatID, rhs: SeatID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// A subscription group shared by every app in a Suite (up to 15 apps).
public struct ProductGroupID: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: ProductGroupID, rhs: ProductGroupID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Who a seat is assigned to. Volume Purchasing assigns to a managed user
/// *or* to a device (shared iPads), so both shapes are first-class.
public enum Holder: Hashable, Codable, Sendable, CustomStringConvertible {
    case user(String)
    case device(String)

    public func matches(_ context: CheckContext) -> Bool {
        switch self {
        case .user(let id): return context.userID == id
        case .device(let id): return context.deviceID == id
        }
    }

    /// Deterministic key used only to make the merge order total.
    var sortKey: String {
        switch self {
        case .user(let id): return "u:" + id
        case .device(let id): return "d:" + id
        }
    }

    public var description: String {
        switch self {
        case .user(let id): return "user \(id)"
        case .device(let id): return "device \(id)"
        }
    }
}

/// "This user on this device", the question every feature gate asks.
public struct CheckContext: Hashable, Sendable {
    public let userID: String?
    public let deviceID: String
    public init(userID: String?, deviceID: String) {
        self.userID = userID
        self.deviceID = deviceID
    }
}

// MARK: - Seat events

/// Where an event came from. Higher rank wins a same-version tie.
///
/// The server feed (relayed App Store Server Notifications) outranks the
/// on-device StoreKit view, which outranks managed configuration pushed by MDM:
/// the further from the ledger of record, the lower the rank.
public enum EventSource: String, Codable, Sendable, CaseIterable {
    case managedConfig
    case storeKit
    case server

    var rank: Int {
        switch self {
        case .managedConfig: return 0
        case .storeKit: return 1
        case .server: return 2
        }
    }
}

/// The state a seat is in after an event.
public enum SeatState: Hashable, Codable, Sendable, CustomStringConvertible {
    case assigned(Holder)
    case unassigned
    case expired
    case refunded

    /// Used for "revoke wins" when two different payloads share a version.
    var restrictiveness: Int {
        switch self {
        case .assigned: return 0
        case .unassigned: return 1
        case .expired: return 2
        case .refunded: return 3
        }
    }

    var holderKey: String {
        if case .assigned(let holder) = self { return holder.sortKey }
        return ""
    }

    public var holder: Holder? {
        if case .assigned(let holder) = self { return holder }
        return nil
    }

    public var description: String {
        switch self {
        case .assigned(let holder): return "assigned to \(holder)"
        case .unassigned: return "unassigned"
        case .expired: return "expired"
        case .refunded: return "refunded"
        }
    }
}

/// One fact about one seat, stamped with a per-seat version issued by the
/// ledger of record. Events are the only way state changes.
///
/// `previousHolder` is set by the issuer when a seat moves away from someone
/// ("reassigned from Alice"). It travels *inside* the event rather than being
/// derived locally, because a locally derived "previous holder" depends on
/// arrival order and would break convergence.
public struct SeatEvent: Hashable, Codable, Sendable {
    public let seatID: SeatID
    public let group: ProductGroupID
    public let version: UInt64
    public let state: SeatState
    public let previousHolder: Holder?
    public let source: EventSource
    public let issuedAt: Date
    /// End of the paid period. `nil` means no known end (for example a
    /// perpetual volume licence).
    public let expiresAt: Date?

    public init(seatID: SeatID, group: ProductGroupID, version: UInt64, state: SeatState,
                previousHolder: Holder? = nil, source: EventSource, issuedAt: Date, expiresAt: Date? = nil) {
        self.seatID = seatID
        self.group = group
        self.version = version
        self.state = state
        self.previousHolder = previousHolder
        self.source = source
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// A strict total order over every field, so that "which event wins" never
    /// depends on arrival order. Returns true if `self` beats `other`.
    ///
    /// Order: version, then source rank, then the more restrictive state
    /// (revoke wins), then the earlier expiry (`nil` = least restrictive),
    /// then deterministic tie-breaks on the remaining fields.
    func beats(_ other: SeatEvent) -> Bool {
        if version != other.version { return version > other.version }
        if source.rank != other.source.rank { return source.rank > other.source.rank }
        if state.restrictiveness != other.state.restrictiveness {
            return state.restrictiveness > other.state.restrictiveness
        }
        if state.holderKey != other.state.holderKey { return state.holderKey < other.state.holderKey }
        let lhsExpiry = Self.orderKey(expiresAt?.timeIntervalSince1970)
        let rhsExpiry = Self.orderKey(other.expiresAt?.timeIntervalSince1970)
        if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
        let lhsPrevious = previousHolder?.sortKey ?? ""
        let rhsPrevious = other.previousHolder?.sortKey ?? ""
        if lhsPrevious != rhsPrevious { return lhsPrevious < rhsPrevious }
        if group != other.group { return group < other.group }
        let lhsIssued = Self.orderKey(issuedAt.timeIntervalSince1970)
        let rhsIssued = Self.orderKey(other.issuedAt.timeIntervalSince1970)
        if lhsIssued != rhsIssued { return lhsIssued > rhsIssued }
        if seatID != other.seatID { return seatID < other.seatID }
        // Last resort for values the keys above cannot separate (NaN and
        // infinite dates share an order key): compare raw bit patterns, which
        // are total and never trap. (Formatting such a `Date`, for example via
        // `String(reflecting:)`, traps in Foundation, so it must not be used here.)
        let lhsBits = Self.bits(issuedAt, expiresAt)
        let rhsBits = Self.bits(other.issuedAt, other.expiresAt)
        if lhsBits.0 != rhsBits.0 { return lhsBits.0 < rhsBits.0 }
        return lhsBits.1 < rhsBits.1 // equal bits: identical events, neither wins
    }

    private static func bits(_ issued: Date, _ expires: Date?) -> (UInt64, UInt64) {
        (issued.timeIntervalSince1970.bitPattern, expires.map { $0.timeIntervalSince1970.bitPattern } ?? .max)
    }

    /// NaN never compares equal to itself, which would make the order
    /// non-total; map it (and nil) to +infinity.
    private static func orderKey(_ value: Double?) -> Double {
        guard let value, !value.isNaN else { return .infinity }
        return value
    }
}

// MARK: - Features and suites

/// What a feature does when the entitlement state is stale.
///
/// This is a product decision, made per feature, not per app: reading your
/// own documents offline should keep working through a bounded grace window
/// (`failOpen`); minting a paid export or spending server compute should not
/// (`failClosed`).
public enum FailureMode: String, Codable, Sendable {
    case failOpen
    case failClosed
}

public struct Feature: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let group: ProductGroupID
    public let failureMode: FailureMode

    public init(id: String, displayName: String, group: ProductGroupID, failureMode: FailureMode) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.failureMode = failureMode
    }
}

/// The apps that share one subscription group. Apple caps a Suite at 15 apps;
/// a manifest that disagrees is a configuration error, caught at init.
public struct SuiteManifest: Hashable, Sendable {
    public static let maximumMembers = 15

    public enum ManifestError: Error, Equatable {
        case empty
        case tooManyMembers(Int)
        case duplicateMember(String)
    }

    public let group: ProductGroupID
    public let memberBundleIDs: [String]

    public init(group: ProductGroupID, memberBundleIDs: [String]) throws {
        guard !memberBundleIDs.isEmpty else { throw ManifestError.empty }
        guard memberBundleIDs.count <= Self.maximumMembers else {
            throw ManifestError.tooManyMembers(memberBundleIDs.count)
        }
        var seen = Set<String>()
        for id in memberBundleIDs where !seen.insert(id).inserted {
            throw ManifestError.duplicateMember(id)
        }
        self.group = group
        self.memberBundleIDs = memberBundleIDs
    }

    public func contains(bundleID: String) -> Bool { memberBundleIDs.contains(bundleID) }
}
