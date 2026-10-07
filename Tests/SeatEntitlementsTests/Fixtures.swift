import Foundation
@testable import SeatEntitlements

let group: ProductGroupID = "com.example.suite.pro"
let alice = CheckContext(userID: "alice", deviceID: "ipad-07")
let t0 = Date(timeIntervalSince1970: 1_790_000_000)

let docs = Feature(id: "docs", displayName: "Open documents", group: group, failureMode: .failOpen)
let export = Feature(id: "export", displayName: "Export PDF", group: group, failureMode: .failClosed)

func event(_ seat: SeatID = "S-1", v version: UInt64, _ state: SeatState, previous: Holder? = nil,
           source: EventSource = .server, issued: Date = t0, expires: Date? = nil,
           group: ProductGroupID = group) -> SeatEvent {
    SeatEvent(seatID: seat, group: group, version: version, state: state, previousHolder: previous,
              source: source, issuedAt: issued, expiresAt: expires)
}

/// A deterministic stand-in for ES256 so the gate logic runs on Linux:
/// the "signature" is the key id followed by the payload reversed. Any change
/// to the payload or key id invalidates it, which is all the gate relies on.
struct FakeVerifier: SnapshotVerifier {
    var trustedKeys: Set<String> = ["k1"]
    func isValid(signature: Data, for payload: Data, keyID: String) -> Bool {
        trustedKeys.contains(keyID) && signature == FakeVerifier.sign(payload, keyID: keyID)
    }
    static func sign(_ payload: Data, keyID: String) -> Data {
        Data(keyID.utf8) + Data(payload.reversed())
    }
}

func signed(_ snapshot: EntitlementSnapshot, keyID: String = "k1") -> SignedSnapshot {
    // Encoding a value type with no custom coding cannot fail; a failure here
    // is a test bug and should crash the test, not be swallowed.
    let payload = try! SnapshotGate.makeEncoder().encode(snapshot)
    return SignedSnapshot(keyID: keyID, payload: payload, signature: FakeVerifier.sign(payload, keyID: keyID))
}

final class TestClock: EntitlementClock, @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    private let lock = NSLock()
    private var wall: Date
    private var up: TimeInterval?

    init(now: Date = t0, uptime: TimeInterval? = 1_000) {
        wall = now
        up = uptime
    }

    func now() -> Date { lock.withLock { wall } }
    func uptime() -> TimeInterval? { lock.withLock { up } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            up = up.map { $0 + seconds }
        }
    }
    func setWall(_ date: Date) { lock.withLock { wall = date } }
}

struct FeedError: Error {}

/// A feed whose responses are held at a gate until the test opens it, so a
/// test can act while a fetch is suspended.
actor GatedFeed: EntitlementFeed {
    private var responses: [SignedSnapshot]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen: Bool
    private(set) var calls = 0

    init(_ responses: [SignedSnapshot], open: Bool = false) {
        self.responses = responses
        self.isOpen = open
    }

    func fetchSnapshot() async throws -> SignedSnapshot {
        calls += 1
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard !responses.isEmpty else { throw FeedError() }
        return responses.removeFirst()
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Poll an async condition with a hard deadline, instead of sleeping and hoping.
func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

/// Counts writes, so tests can prove a code path never writes the shared store.
actor CountingStore: SnapshotStore {
    private var stored: SignedSnapshot?
    private(set) var saves = 0
    init(_ initial: SignedSnapshot? = nil) { stored = initial }
    func load() -> SignedSnapshot? { stored }
    func save(_ snapshot: SignedSnapshot) {
        saves += 1
        stored = snapshot
    }
}

/// A high-water store whose `raise` can be held, to suspend `adopt` at its
/// second await and interleave another adoption there.
actor GatedHighWater: HighWaterMarkStore {
    private var value: UInt64 = 0
    private var armed = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pendingRaises = 0

    func load() -> UInt64 { value }
    func raise(to newValue: UInt64) async {
        if armed {
            pendingRaises += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        value = max(value, newValue)
    }
    func release() {
        armed = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
