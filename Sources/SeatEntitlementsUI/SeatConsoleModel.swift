#if canImport(SwiftUI) && canImport(CryptoKit)
import Combine
import CryptoKit
import Foundation
import SeatEntitlements

/// Everything the console needs that is a product decision rather than
/// library code. The app owns it and passes it in.
public struct SeatConsoleScenario: Sendable {
    public let context: CheckContext
    public let features: [Feature]
    public let initialSeats: [SeatEvent]
    /// The seat the "reassign" buttons move away from and back to the user.
    public let primarySeat: SeatID
    public let reassignTarget: Holder
    public let policy: GracePolicy
    public let scheduler: RefreshScheduler
    public let herd: HerdScenario
    public let startDate: Date

    public init(context: CheckContext, features: [Feature], initialSeats: [SeatEvent], primarySeat: SeatID,
                reassignTarget: Holder, policy: GracePolicy, scheduler: RefreshScheduler,
                herd: HerdScenario, startDate: Date) {
        self.context = context
        self.features = features
        self.initialSeats = initialSeats
        self.primarySeat = primarySeat
        self.reassignTarget = reassignTarget
        self.policy = policy
        self.scheduler = scheduler
        self.herd = herd
        self.startDate = startDate
    }
}

/// Scripted starting states, so a screenshot (or a reviewer) can land on an
/// interesting state without tapping. Selected with `-scenario <name>`.
public enum ConsoleScript: String, Sendable, CaseIterable {
    /// One successful refresh; every feature verified.
    case fresh
    /// Refresh, lose the network, MDM reassigns the seat (push not delivered),
    /// 30 hours pass: fail-open features run on grace, fail-closed ones stop.
    case offlineReassign
    /// Reassigned while online: the push lands and access ends immediately.
    case onlineRevoke
}

@MainActor
public final class SeatConsoleModel: ObservableObject {
    public struct FeatureRow: Identifiable {
        public let feature: Feature
        public let decision: Decision
        public var id: String { feature.id }
    }

    public enum Tone: Sendable { case info, good, warning, bad }

    public struct LogLine: Identifiable {
        public let id: Int
        public let stamp: String
        public let text: String
        public let tone: Tone
    }

    public struct HerdRow: Identifiable {
        public let strategy: HerdStrategy
        public let result: HerdResult
        /// Load per bar, downsampled for drawing.
        public let bars: [Int]
        public var id: String { strategy.label }
    }

    public static let maximumLogLines = 60

    @Published public private(set) var rows: [FeatureRow] = []
    @Published public private(set) var seats: [SeatEvent] = []
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var isOnline = true
    @Published public private(set) var isBusy = false
    @Published public private(set) var isClockTampered = false
    @Published public private(set) var clockSummary = ""
    @Published public private(set) var verificationSummary = "Never verified"
    @Published public private(set) var nextRefreshSummary = ""
    @Published public private(set) var herdRows: [HerdRow] = []

    public let scenario: SeatConsoleScenario
    private let clock: SimulatedClock
    private let backend: SimulatedBackend
    private let store = InMemorySnapshotStore()
    // Device-wide state a Suite sibling shares: keychain items and the App
    // Group journal in production, in-memory here.
    private let highWater = InMemoryHighWaterMark()
    private let journal = InMemoryRevocationJournal()
    private let clockFloor = InMemoryClockFloor()
    private let verifier: P256SnapshotVerifier
    private let resolver: EntitlementResolver
    private var firstSignedSnapshot: SignedSnapshot?
    private var nextLogID = 0
    private var started = false

    public init(scenario: SeatConsoleScenario) {
        self.scenario = scenario
        let clock = SimulatedClock(base: scenario.startDate)
        let signer = P256SnapshotSigner(keyID: "ent-2026-10")
        // If the key cannot be derived the verifier pins nothing and every
        // snapshot is rejected: failing closed is visible in the log.
        let pinned = (try? signer.publicKey).map { [signer.keyID: $0] } ?? [:]
        let verifier = P256SnapshotVerifier(pinnedKeys: pinned)
        self.clock = clock
        self.verifier = verifier
        self.backend = SimulatedBackend(seats: scenario.initialSeats, signer: signer, clock: clock)
        self.resolver = EntitlementResolver(context: scenario.context, policy: scenario.policy,
                                            verifier: verifier, store: store, highWater: highWater,
                                            feed: backend, clock: clock, journal: journal, clockFloor: clockFloor)
    }

    // MARK: Lifecycle

    public func start(script: ConsoleScript) async {
        guard !started else { return }
        started = true
        herdRows = Self.runHerd(scenario.herd, scheduler: scenario.scheduler)
        await perform {
            await self.refreshStep()
            switch script {
            case .fresh:
                break
            case .offlineReassign:
                await self.setOnlineStep(false)
                await self.reassignStep(to: self.scenario.reassignTarget)
                self.advanceStep(hours: 30)
            case .onlineRevoke:
                await self.reassignStep(to: self.scenario.reassignTarget)
            }
        }
    }

    // MARK: Actions (each is serialized: buttons are disabled while busy)

    public func refresh() async { await perform { await self.refreshStep() } }
    public func setOnline(_ online: Bool) async { await perform { await self.setOnlineStep(online) } }
    public func advance(hours: Double) async { await perform { self.advanceStep(hours: hours) } }

    public func reassignAway() async {
        await perform { await self.reassignStep(to: self.scenario.reassignTarget) }
    }

    public func reassignBack() async {
        let me: Holder = scenario.context.userID.map(Holder.user) ?? .device(scenario.context.deviceID)
        await perform { await self.reassignStep(to: me) }
    }

    /// Redeliver the oldest known event for the primary seat, as a flaky push
    /// channel would. The ledger must ignore it.
    public func replayStaleEvent() async {
        await perform {
            guard let original = self.scenario.initialSeats.first(where: { $0.seatID == self.scenario.primarySeat }) else { return }
            let outcomes = await self.resolver.ingest([original])
            for outcome in outcomes {
                switch outcome {
                case .superseded(let current):
                    self.append("Replayed v\(original.version) of \(original.seatID): ignored, ledger holds v\(current)", .good)
                case .duplicate:
                    self.append("Replayed v\(original.version): duplicate, no-op", .good)
                case .applied:
                    self.append("Replayed v\(original.version): applied (it was still current)", .info)
                case .rejectedCapacity:
                    self.append("Replayed event rejected: ledger full", .bad)
                }
            }
        }
    }

    /// A Suite sibling launches with a restored (older) copy of the shared
    /// cache. It shares the device's high-water mark, so it must refuse it.
    public func siblingLaunchWithRestoredCache() async {
        await perform {
            // The attack only means something once the device has accepted a
            // newer snapshot than the one being restored, so take one first.
            if let first = self.firstSignedSnapshot, await self.highWater.load() <= self.sequence(of: first) {
                await self.refreshStep()
            }
            guard let old = self.firstSignedSnapshot else {
                self.append("No snapshot cached yet: refresh first", .warning)
                return
            }
            let sibling = EntitlementResolver(context: self.scenario.context, policy: self.scenario.policy,
                                              verifier: self.verifier, store: InMemorySnapshotStore(old),
                                              highWater: self.highWater, feed: self.backend, clock: self.clock,
                                              journal: self.journal, clockFloor: self.clockFloor)
            switch await sibling.bootstrap() {
            case .rejected(.rolledBack(let sequence, let mark))?:
                self.append("Sibling app: restored cache #\(sequence) refused (device has seen #\(mark))", .good)
            case .adopted(let sequence, _)?:
                self.append("Sibling app: cache #\(sequence) accepted (no newer snapshot seen yet)", .info)
            case .rejected(let other)?:
                self.append("Sibling app: cache rejected (\(other))", .warning)
            case .transportFailed(let message)?:
                self.append("Sibling app: \(message)", .warning)
            case nil:
                self.append("Sibling app: shared cache empty", .warning)
            }
        }
    }

    /// Move the wall clock back two days, as a user could in Settings, or
    /// put it right again.
    public func toggleClockTamper() async {
        await perform {
            if self.isClockTampered {
                self.clock.tamperWallClock(by: 48 * 3_600)
                self.isClockTampered = false
                self.append("Wall clock restored", .info)
            } else {
                self.clock.tamperWallClock(by: -48 * 3_600)
                self.isClockTampered = true
                self.append("Wall clock moved back 48h. Age is the larger of wall-clock age (from the device's clock floor) and monotonic uptime age, so decisions do not loosen; a successful refresh re-anchors both clocks", .warning)
            }
        }
    }

    // MARK: Steps

    private func refreshStep() async {
        let outcome = await resolver.refresh()
        switch outcome {
        case .adopted(let sequence, let changes):
            append("Snapshot #\(sequence) verified (ES256) and merged, \(changes) seat change(s)", .good)
            if firstSignedSnapshot == nil { firstSignedSnapshot = await store.load() }
        case .rejected(let rejection):
            append("Snapshot rejected: \(rejection)", .bad)
        case .transportFailed(let message):
            append("Refresh failed: \(message)", .warning)
        }
    }

    private func setOnlineStep(_ online: Bool) async {
        await backend.setOnline(online)
        isOnline = online
        append(online ? "Network restored" : "Network lost", online ? .info : .warning)
    }

    private func advanceStep(hours: Double) {
        clock.advance(by: hours * 3_600)
        append("\(Self.format(hours * 3_600)) passed", .info)
    }

    private func reassignStep(to holder: Holder) async {
        if await backend.seat(scenario.primarySeat)?.state.holder == holder {
            append("MDM: \(scenario.primarySeat) is already assigned to \(holder); nothing to do", .info)
            return
        }
        guard let event = await backend.assign(scenario.primarySeat, to: holder) else {
            append("Reassignment failed: unknown seat", .bad)
            return
        }
        append("MDM: \(event.seatID) \(event.state) (v\(event.version))", .info)
        if isOnline {
            let outcomes = await resolver.ingest([event])
            let applied = outcomes.contains { if case .applied = $0 { return true } else { return false } }
            append(applied ? "Push delivered and applied immediately" : "Push delivered, already known", .good)
        } else {
            append("Push not delivered: device offline", .warning)
        }
    }

    // MARK: Plumbing

    /// Sequence number inside a signed snapshot, or 0 if it cannot be read.
    private func sequence(of signed: SignedSnapshot) -> UInt64 {
        (try? SnapshotGate.makeDecoder().decode(EntitlementSnapshot.self, from: signed.payload))?.sequence ?? 0
    }

    private func perform(_ work: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        await work()
        await reload()
        isBusy = false
    }

    private func reload() async {
        var newRows: [FeatureRow] = []
        for feature in scenario.features {
            newRows.append(FeatureRow(feature: feature, decision: await resolver.decide(feature)))
        }
        rows = newRows
        seats = await resolver.seats()
        let now = clock.now()
        let tamper = clock.tamper
        clockSummary = "Device clock " + Self.timestamp(now) + (tamper != 0 ? " (tampered)" : "")
        if let verification = await resolver.currentVerification() {
            verificationSummary = "Signed state verified " + Self.timestamp(verification.verifiedAt)
                + (verification.uptimeAtVerification == nil ? "" : " (monotonic reading held)")
        } else {
            verificationSummary = "Never verified"
        }
        if let next = await resolver.nextScheduledRefresh(using: scenario.scheduler) {
            let slot = scenario.scheduler.offset(forDeviceKey: scenario.context.deviceID)
            nextRefreshSummary = "Next refresh " + Self.timestamp(next) + " (slot +\(Self.format(slot)) in window)"
                + (next < now ? ", overdue" : "")
        } else {
            nextRefreshSummary = "Refresh due now"
        }
    }

    private func append(_ text: String, _ tone: Tone) {
        nextLogID += 1
        log.insert(LogLine(id: nextLogID, stamp: Self.timestamp(clock.now()), text: text, tone: tone), at: 0)
        if log.count > Self.maximumLogLines { log.removeLast(log.count - Self.maximumLogLines) }
    }

    // MARK: Herd

    nonisolated static func runHerd(_ herd: HerdScenario, scheduler: RefreshScheduler) -> [HerdRow] {
        let strategies: [HerdStrategy] = [
            .synchronized(retryAfter: 30),
            .synchronizedWithJitteredRetry(scheduler),
            .spread(scheduler),
        ]
        return strategies.map { strategy in
            let result = HerdSimulator.run(herd, strategy: strategy)
            return HerdRow(strategy: strategy, result: result, bars: downsample(result.load, to: 48))
        }
    }

    /// Max-pooling so a one-bucket spike is never averaged away.
    nonisolated static func downsample(_ values: [Int], to count: Int) -> [Int] {
        guard count > 0, !values.isEmpty else { return [] }
        let size = max(1, (values.count + count - 1) / count)
        return stride(from: 0, to: values.count, by: size).map { start in
            values[start..<min(start + size, values.count)].max() ?? 0
        }
    }

    // MARK: Formatting

    nonisolated static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "∞" }
        let total = Saturating.int(abs(seconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours >= 48 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(total % 60)s"
    }
}
#endif
