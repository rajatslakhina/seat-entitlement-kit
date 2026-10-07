#if canImport(SwiftUI) && canImport(CryptoKit)
import SeatEntitlements
import SwiftUI

/// An operator console for the entitlement resolver: what every feature gate
/// answers right now, why, and what changes when the network, the clock or
/// the MDM roster moves underneath it. A second tab runs the rollout-herd model.
public struct SeatConsoleView: View {
    public enum Tab: String, Hashable, Sendable {
        case access
        case herd
    }

    @StateObject private var model: SeatConsoleModel
    @State private var tab: Tab
    private let script: ConsoleScript

    @MainActor
    public init(scenario: SeatConsoleScenario, script: ConsoleScript = .fresh, initialTab: Tab = .access) {
        _model = StateObject(wrappedValue: SeatConsoleModel(scenario: scenario))
        _tab = State(initialValue: initialTab)
        self.script = script
    }

    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack { AccessScreen(model: model) }
                .tabItem { Label("Access", systemImage: "person.badge.key") }
                .tag(Tab.access)
            NavigationStack { HerdScreen(model: model) }
                .tabItem { Label("Rollout herd", systemImage: "chart.bar.xaxis") }
                .tag(Tab.herd)
        }
        .task { await model.start(script: script) }
    }
}

// MARK: - Access

private struct AccessScreen: View {
    @ObservedObject var model: SeatConsoleModel

    var body: some View {
        List {
            Section {
                ForEach(model.rows) { row in
                    FeatureRowView(row: row)
                }
                if model.rows.isEmpty {
                    Text("Resolving…").foregroundStyle(.secondary)
                }
            } header: {
                Text("May \(model.scenario.context.userID ?? "this device") use…")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.verificationSummary)
                    Text(model.clockSummary)
                    Text(model.nextRefreshSummary)
                }
                .font(.caption2)
            }

            Section("Simulate") {
                ControlsView(model: model)
            }

            Section("Seat ledger (merged, version-ordered)") {
                if model.seats.isEmpty {
                    Text("No seats known yet").foregroundStyle(.secondary)
                }
                ForEach(model.seats, id: \.seatID) { seat in
                    HStack {
                        Text(seat.seatID.rawValue).font(.callout.monospaced())
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(seat.state.description).font(.caption)
                            Text("v\(seat.version) · \(seat.source.rawValue)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Event log") {
                if model.log.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(model.log) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(line.tone.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.text).font(.caption)
                            Text(line.stamp).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Seat entitlements")
    }
}

private struct FeatureRowView: View {
    let row: SeatConsoleModel.FeatureRow

    var body: some View {
        let presentation = DecisionPresentation(row.decision)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.feature.displayName).font(.body.weight(.semibold))
                    Spacer()
                    Text(row.feature.failureMode == .failOpen ? "fail-open" : "fail-closed")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(presentation.headline).font(.subheadline).foregroundStyle(presentation.color)
                Text(presentation.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ControlsView: View {
    @ObservedObject var model: SeatConsoleModel

    var body: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 8) {
            action("Refresh", "arrow.clockwise") { await model.refresh() }
            action(model.isOnline ? "Go offline" : "Go online",
                   model.isOnline ? "wifi.slash" : "wifi") { await model.setOnline(!model.isOnline) }
            action("MDM: reassign away", "person.crop.circle.badge.minus") { await model.reassignAway() }
            action("MDM: assign back", "person.crop.circle.badge.plus") { await model.reassignBack() }
            action("+12 hours", "clock.arrow.circlepath") { await model.advance(hours: 12) }
            action(model.isClockTampered ? "Restore clock" : "Clock back 48h",
                   model.isClockTampered ? "clock.arrow.2.circlepath" : "clock.badge.exclamationmark") {
                await model.toggleClockTamper()
            }
            action("Replay old event", "arrow.uturn.backward") { await model.replayStaleEvent() }
            action("Sibling + old cache", "square.stack.3d.up.slash") { await model.siblingLaunchWithRestoredCache() }
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    private func action(_ title: String, _ symbol: String, _ work: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await work() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Herd

private struct HerdScreen: View {
    @ObservedObject var model: SeatConsoleModel

    var body: some View {
        let herd = model.scenario.herd
        List {
            Section {
                Text("\(herd.devices) devices assigned in one MDM push hit a backend that serves \(herd.capacityPerBucket) requests per \(Saturating.int(herd.bucketSeconds))s. Same fleet, same backend, three client strategies.")
                    .font(.callout)
            }
            if !model.herdRows.isEmpty {
                Section("Peak load vs capacity") {
                    ForEach(model.herdRows) { row in
                        LabeledContent(row.strategy.label, value: ratioText(row, herd))
                            .foregroundStyle((row.result.peakOverCapacity(herd) ?? 0) > 1 ? Color.red : Color.green)
                    }
                }
            }
            ForEach(model.herdRows) { row in
                Section(row.strategy.label) {
                    HerdBars(values: row.bars, capacity: herd.capacityPerBucket)
                        .frame(height: 90)
                    LabeledContent("Peak load", value: peakText(row, herd))
                    LabeledContent("Requests sent", value: "\(row.result.totalRequests)")
                    LabeledContent("All devices served", value: drainText(row, herd))
                }
            }
            if model.herdRows.isEmpty {
                Text("Running model…").foregroundStyle(.secondary)
            }
            Section {
                Text("The model counts load only; it does not simulate a backend degrading past capacity, which flatters both synchronized strategies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Rollout herd")
    }

    private func ratioText(_ row: SeatConsoleModel.HerdRow, _ herd: HerdScenario) -> String {
        guard let ratio = row.result.peakOverCapacity(herd) else { return "\(row.result.peak)" }
        return "\(ratio.formatted(.number.precision(.fractionLength(1))))×"
    }

    private func peakText(_ row: SeatConsoleModel.HerdRow, _ herd: HerdScenario) -> String {
        guard let ratio = row.result.peakOverCapacity(herd) else { return "\(row.result.peak)" }
        return "\(row.result.peak) (\(ratio.formatted(.number.precision(.fractionLength(1))))× capacity)"
    }

    private func drainText(_ row: SeatConsoleModel.HerdRow, _ herd: HerdScenario) -> String {
        guard let bucket = row.result.drainedAtBucket else {
            return "No — \(row.result.unserved) left at horizon"
        }
        let seconds = Double(bucket + 1) * herd.bucketSeconds
        return "after " + SeatConsoleModel.format(seconds)
    }
}

private struct HerdBars: View {
    let values: [Int]
    let capacity: Int

    var body: some View {
        GeometryReader { proxy in
            let top = max(values.max() ?? 0, capacity, 1)
            let count = max(values.count, 1)
            let width = proxy.size.width / CGFloat(count)
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Rectangle()
                            .fill(value > capacity ? Color.red : Color.accentColor)
                            .frame(width: max(width - 1, 0.5),
                                   height: proxy.size.height * CGFloat(value) / CGFloat(top))
                            .frame(width: width)
                    }
                }
                Rectangle()
                    .fill(Color.orange)
                    .frame(height: 1)
                    .offset(y: -proxy.size.height * CGFloat(capacity) / CGFloat(top))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .accessibilityLabel("Load over time, peak \(values.max() ?? 0), capacity line at \(capacity)")
    }
}

// MARK: - Presentation

struct DecisionPresentation {
    let symbol: String
    let color: Color
    let headline: String
    let detail: String

    init(_ decision: Decision) {
        switch decision {
        case .allow(.verified(let age)):
            self.init(symbol: "checkmark.seal.fill", color: .green, headline: "Allowed: verified",
                      detail: "Signed state is \(SeatConsoleModel.format(age)) old")
        case .allow(.offlineGrace(let remaining)):
            self.init(symbol: "checkmark.circle", color: .orange, headline: "Allowed on offline grace",
                      detail: "Grace closes in \(SeatConsoleModel.format(remaining)) unless the device reconnects")
        case .deny(.noSeat):
            self.init(symbol: "xmark.circle", color: .secondary, headline: "No seat",
                      detail: "No seat in this group is assigned to this user or device")
        case .deny(.revoked(let seat, let version)):
            self.init(symbol: "person.crop.circle.badge.xmark", color: .red, headline: "Seat reassigned",
                      detail: "\(seat) moved away at v\(version); known revocations apply immediately")
        case .deny(.expired(let seat)):
            self.init(symbol: "calendar.badge.exclamationmark", color: .red, headline: "Expired",
                      detail: "\(seat) ended before the last verification")
        case .deny(.noVerifiedState):
            self.init(symbol: "questionmark.circle", color: .secondary, headline: "Not verified yet",
                      detail: "Nothing signed has been verified on this device")
        case .deny(.clockRollback):
            self.init(symbol: "clock.badge.exclamationmark", color: .red, headline: "Clock moved back",
                      detail: "State age cannot be trusted")
        case .deny(.needsFreshState(let age)):
            self.init(symbol: "lock.fill", color: .red, headline: "Needs a fresh check",
                      detail: "Fail-closed feature; state is \(SeatConsoleModel.format(age)) old")
        case .deny(.graceExhausted(let age)):
            self.init(symbol: "hourglass.bottomhalf.filled", color: .red, headline: "Offline grace used up",
                      detail: "State is \(SeatConsoleModel.format(age)) old")
        }
    }

    private init(symbol: String, color: Color, headline: String, detail: String) {
        self.symbol = symbol
        self.color = color
        self.headline = headline
        self.detail = detail
    }
}

extension SeatConsoleModel.Tone {
    var color: Color {
        switch self {
        case .info: return .blue
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}
#endif
