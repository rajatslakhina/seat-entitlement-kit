# SeatEntitlements

**"May this user, on this device, use this feature right now?"** answered in one place for seats an organisation bought, MDM reassigns, up to 15 apps in a Suite share, and devices that are often offline.

[![CI](https://github.com/rajatslakhina/seat-entitlement-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/seat-entitlement-kit/actions/workflows/ci.yml)
![Swift 6 language mode](https://img.shields.io/badge/Swift-6%20language%20mode-orange) ![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

**Demo app: [seat-entitlement-kit-demo-app](https://github.com/rajatslakhina/seat-entitlement-kit-demo-app)**, a SwiftUI console that consumes this package by release tag. Its CI runs it on an iOS Simulator and captures the screenshots below.

<p align="center">
  <img src="https://raw.githubusercontent.com/rajatslakhina/seat-entitlement-kit-demo-app/main/Demo/Screenshots/2-offline-grace.png" width="30%" alt="30 hours offline after an undelivered reassignment: fail-open on grace, fail-closed blocked">
  <img src="https://raw.githubusercontent.com/rajatslakhina/seat-entitlement-kit-demo-app/main/Demo/Screenshots/3-revoked-online.png" width="30%" alt="Reassignment pushed online: revoked immediately">
  <img src="https://raw.githubusercontent.com/rajatslakhina/seat-entitlement-kit-demo-app/main/Demo/Screenshots/4-rollout-herd.png" width="30%" alt="Rollout herd model">
</p>

---

## The problem

Apple's Volume Purchasing for subscriptions goes live on **22 October 2026** ([Mac Observer](https://www.macobserver.com/news/app-store-subscriptions-bought-by-the-seat/), [Apple Developer News](https://developer.apple.com/news/)): an organisation buys seats with one In-App Purchase and assigns them through device management. Group Purchases follow this winter, Multiseat has been on by default in App Store Connect since 16 September, and Bundles/Suites let one subscription unlock up to 15 apps ([Apple — Bundles and Suites](https://developer.apple.com/app-store/subscriptions/bundles-and-suites/)). These dates come from those announcements; check them against Apple's current pages before you plan around them. Apple's pages explain the business flow. They say almost nothing about the part an engineering lead has to design: **what happens on a device when a seat moves.**

That question decomposes into a classic system-design problem:

| Concern | What goes wrong without a design |
| --- | --- |
| **Several sources of truth.** StoreKit's on-device view, your server feed (App Store Server Notifications relayed by your backend) and MDM managed config all describe the same seat. | Whichever arrived last wins, so a delayed StoreKit update re-grants a seat the server already revoked. |
| **Suite siblings share state.** Up to 15 apps read one cache. | One app writes an old snapshot over a newer one, or a restored backup brings a revoked seat back. |
| **Offline devices.** A school iPad cart is offline for a weekend. | Either the app locks students out the moment Wi-Fi drops, or a revoked seat keeps working forever. |
| **Fleet-scale refresh.** 5,000 seats assigned in one MDM push. | Every device refreshes on the same second, now and every six hours after. |

## The design

```
             StoreKit Transaction.updates ─┐
  server push (App Store Server Notif.) ───┤  verified SeatEvents      ┌──────────────────────┐
           MDM managed configuration ──────┘ ───────────────────────▶ │                      │
                                                                       │      SeatLedger      │  one LWW register per seat,
  EntitlementFeed ──▶ SignedSnapshot ──▶ SnapshotGate ──merge────────▶ │  (strict total order │  ordered by SeatEvent.beats
   (single-flight     (ES256 bytes)     verify → decode →              │   over every field)  │
    refresh)                            anti-rollback → skew           └──────────┬───────────┘
        ▲                                     │                                   │
        │                        HighWaterMarkStore (keychain)       EntitlementDecider (pure)
  RefreshScheduler                  SnapshotStore (App Group)        GracePolicy · FailureMode
  slot + full-jitter backoff          shared with Suite siblings      wall + monotonic clocks
                                                                                  │
                                                         EntitlementResolver (actor) ──▶ Decision
                                                                                  └──▶ AsyncStream<SeatChange> fan-out
```

Feature code calls one method, `await resolver.decide(feature)`, and gets back a `Decision` that says *why*: `.allow(.verified(age:))`, `.allow(.offlineGrace(remaining:))`, or `.deny(.revoked / .noSeat / .expired / .needsFreshState / .graceExhausted / .clockRollback / .noVerifiedState)`. Apple's multiseat semantics can change behind the input adapters without touching a single feature gate.

### What's in it

| Type | Responsibility |
| --- | --- |
| `SeatEvent`, `SeatState`, `Holder`, `EventSource` | One fact about one seat, with a per-seat version issued by the ledger of record. `previousHolder` travels inside the event ("moved from Alice"), so revocation is never inferred from arrival order. |
| `SeatLedger` | Last-writer-wins register per seat, ordered by `SeatEvent.beats`, a strict total order over every field. Apply any set of events in any order, any number of times: same ledger. Bounded (`capacity`, default 4,096). |
| `EntitlementDecider` | The pure decision function. No I/O and no clock of its own, so every branch is tested at its boundary. |
| `GracePolicy`, `FailureMode` | `freshFor` + `offlineGrace`, sanitised (NaN/negative → 0, infinity → one year). `worstCaseOfflineRevocationLatency = freshFor + offlineGrace`, and a test checks that the decider really cuts off at that instant. Each feature is `failOpen` or `failClosed`. |
| `SignedSnapshot`, `SnapshotGate`, `P256SnapshotVerifier` | Verify-then-parse: the verifier sees raw bytes, then they are decoded, then anti-rollback (`sequence >= highWater`) and future-dating checks run. ES256 with pinned keys selected by `keyID`, so keys can rotate without an app release. |
| `SnapshotStore`, `HighWaterMarkStore`, `ClockFloorStore`, `RevocationJournal` | Ports for the App Group cache shared by Suite siblings, the device-only high-water mark, the persisted wall-clock floor, and the journal that makes pushed revocations durable. In-memory implementations ship for tests and the demo. |
| `RefreshScheduler`, `StableHash`, `SplitMix64` | A deterministic per-device refresh slot (FNV-1a, not `Hasher`, so the slot survives relaunch and siblings agree on it) plus full-jitter exponential backoff with `Retry-After` as a floor. |
| `HerdSimulator` | A discrete-time model of a fleet hitting the backend, used to argue the jitter decision with numbers (see below). |
| `EntitlementResolver` | The actor that ties it together: single-flight `refresh()`, `bootstrap()` (clock floor, then a sibling's cache, then the revocation journal), `ingest()` for pushed events, `decide()`, and a bounded `AsyncStream<SeatChange>` fan-out (64 subscribers max, newest-64 buffer each, cleaned up on cancellation). `ChangeDeduplicator` makes consumers idempotent. |
| `SeatEntitlementsUI` | `SeatConsoleView`, the operator console the demo app runs (SwiftUI + CryptoKit, Apple platforms only). |

## Design decisions, trade-offs and rejected alternatives

**1. Merge snapshots, never swap them in.** A snapshot is the server's full view at sequence *S*, with revoked seats included as tombstones. It is merged seat by seat through the same order as pushed events. *Why:* a revocation pushed while a fetch is suspended must survive the older response that lands afterwards. `testPushedRevocationSurvivesSlowerOlderSnapshot` holds a fetch open, pushes the revocation, then releases a stale snapshot. *Rejected:* "replace the cache with the latest response", the obvious implementation, which re-grants the seat in exactly that race.

**2. A strict total order, not "highest version wins".** Same-version ties are real: StoreKit and the server can describe the same transition, and MDM can echo it. The order is version, then source rank (server > StoreKit > managed config), then **revoke wins** (refunded > expired > unassigned > assigned), then deterministic tie-breaks, with a final fallback so even a decoded NaN date cannot make two different events incomparable. *Trade-off:* a same-version conflict resolves towards *less* access, so a user may be briefly denied and then re-granted by the next version. That is the right failure direction for paid seats. *Proof:* `testLedgerConvergesUnderEveryPermutation` applies all 720 orderings of a six-event fixture. The same harness is fed a last-arrival-wins reducer and a version-only reducer, and must flag both (`testConvergenceHarnessCatchesLastArrivalWins`, `…VersionOnlyOrdering`), so the check is shown to be able to fail.

**3. Known revocations are honoured immediately and durably; staleness is a separate question.** If the ledger knows a seat moved away from this holder, the answer is `.deny(.revoked)` regardless of freshness, grace, or whether anything was ever verified. Grace only covers *not knowing*. A pushed revocation is written to the `RevocationJournal` before `ingest` returns, so it survives the process being killed and reaches Suite siblings. The journal is compacted only when a *signed* snapshot contains the same event or a newer one. Only changes that take a seat *away from this holder* are journalled; other holders' seat moves are not, so the journal cannot fill with entries no snapshot compacts. *The asymmetry is deliberate:* pushed events are not signed snapshots, so the journal never stores an event that would grant this holder anything. A forged or corrupted journal can deny access but never unlock it, and pushed grants become durable only when a signed snapshot confirms them. (`testPushedRevocationSurvivesRelaunchViaJournal`, `testPushedGrantsAreNeverJournalled`, `testJournalIsCompactedOnlyWhenSignedStateCatchesUp`)

**4. Fail-open vs fail-closed is a per-feature product decision.** Opening your own notebooks offline keeps working through the grace window. Exporting a graded PDF or spending server AI compute requires state verified within `freshFor`. *Rejected:* one app-wide TTL, which forces the same availability/abuse trade-off onto features with very different costs.

**5. The revocation-latency bound is a number you can state.** With the demo's policy (fresh 6 h, grace 72 h), a seat reassigned while a device is offline keeps fail-open features working for at most **78 hours**, and fail-closed features for at most **6 hours**. Online, a server push lands immediately, and the scheduled refresh is the fallback. *Trade-off:* a longer grace means fewer locked-out students on a dead Wi-Fi weekend and a longer tail for a reassigned seat. The library makes the bound explicit; it does not pick it for you.

**6. Clocks: a fresh refresh is the anchor, and between refreshes the larger age wins.** *(Reworked in 1.1.0 after review.)*
* **A snapshot this process fetched is a new proof.** It is aged from its *receipt* on the device's own clock, with a monotonic uptime reading and a boot id. It also re-anchors the persisted **wall-clock floor** (the latest wall time the device has seen). As a result, no device-clock error can lock out a device that is online and verified: running fast (`testFastDeviceClockIsFreshRightAfterRefresh`), running slow (`testSlowDeviceClockStillAdoptsAndCountsFromReceipt`), rewound (`testRefreshAfterClockRewindRenewsFreshness`), or set forward once (`testOnlineRefreshClearsAFloorPoisonedByAClockSetForward`). 1.0.0 got the fast, rewound and set-forward cases wrong.
* **Between refreshes, age is `max(wall-clock age, monotonic age)`, and "now" is never earlier than the floor.**
  * Moving the date back cannot shrink the age while a monotonic reading exists (`testMonotonicReadingFromOwnRefreshDefeatsClockTamper`).
  * The reading is persisted with its boot id, so it survives an app relaunch within the same boot (`testPersistedMonotonicReadingSurvivesRelaunchInSameBoot`). It is ignored after a reboot (`testPersistedMonotonicReadingIgnoredAcrossBoots`).
  * After a reboot the floor takes over. A wall clock more than `clockSkewTolerance` behind it is a `.clockRollback` denial (`testPersistedClockFloorCatchesRewindAfterReboot`).
* Snapshots read from the shared store (written by a sibling) are aged from `min(server issuedAt, device clock)` and only ever move verification forward.

*Limits, stated plainly:*
* The floor only knows wall times the app actually observed. A user who goes offline, **reboots**, and rewinds the clock can recover the time the app was not running, up to the full grace window. Closing that needs server-attested time (or a trusted time source), which is out of scope.
* A refresh trusts the feed to return *current* state. A feed that serves a cached old snapshot with a sequence at or above the high-water mark is still treated as fresh from receipt.
* The floor is persisted fire-and-forget once it has moved 60 s, so a crash can lose up to that much of it.

**7. Anti-rollback lives somewhere a backup can't restore.** The App Group cache can be rolled back (backup restore, a Suite sibling writing late), so every reader re-verifies it and rejects any sequence below the device's high-water mark, which belongs in a `ThisDeviceOnly` keychain item. Sibling write races are therefore *detected*, not prevented: the worst case is a refused cache and a refresh, never a resurrected seat. *Rejected:* `NSFileCoordinator` locking alone, because it cannot defend against restored state.

**8. Verify, then parse.** The signature covers the exact bytes stored. No canonical-JSON step exists that a signer and verifier could disagree on. Unknown `keyID` fails closed.

**9. Spread the schedule, jitter the retries.** These are two different herds, so they get two mechanisms. `HerdSimulator`, 5,000 devices, a backend serving 250 requests per 10 s, horizon 2 h:

| Strategy | Peak load | Requests sent | All served after |
| --- | --- | --- | --- |
| Synchronized, fixed 30 s retry | 5,000 (20.0× capacity) | 52,500 | 9 m 40 s |
| Synchronized, full-jitter retry | 5,000 (20.0× capacity) | 17,191 | 9 m 30 s |
| **Deterministic 1 h slot + full-jitter retry** | **27 (0.1× capacity)** | **5,000** | **60 m** |

Backoff: 30 s base, 600 s cap, full jitter, default seed. Jittered retries alone cut total requests by about two thirds (wasted retries by 74%), but do nothing about the first spike. The slot removes the spike entirely, at the price of a one-hour spread, which is exactly the trade a lead has to sign off on. *Caveat, stated plainly:* the model counts load only. It does not simulate a backend degrading under 20× load, which flatters both synchronized rows. Every number in this table is pinned by `testHerdTableNumbersInTheReadme`.

**10. Bounded everything.** Ledger capacity, subscriber count, per-subscriber buffers, scenario sizes, and `Saturating` arithmetic for every conversion reachable from the public API (`Int(Double)`, `2^attempt`, `Retry-After: 1e300`). Ceilings derive from `Int.max`, never a 64-bit literal.

### What it deliberately does not do

* **No StoreKit or MDM adapter ships.** The iOS 27 multiseat transaction fields are not yet documented well enough to map honestly, so the library defines the `SeatEvent` port and leaves the adapter to the app. That is the point of the port.
* **No keychain or App Group implementation ships**, only the ports and in-memory versions. The production mapping is given in decisions 3, 6 and 7.
* **Pushed grants are not durable** until a signed snapshot confirms them (decision 3). After a relaunch, a seat reassigned away and then back by push stays denied until the next successful refresh, which fails closed.
* The demo's "server" is a simulated backend holding a real ES256 key in-process.

## Install

```swift
.package(url: "https://github.com/rajatslakhina/seat-entitlement-kit.git", from: "1.1.0")
```

```swift
.product(name: "SeatEntitlements", package: "seat-entitlement-kit"),    // core, no UI, builds on Linux too
.product(name: "SeatEntitlementsUI", package: "seat-entitlement-kit"),  // optional console view
```

## Usage

```swift
let resolver = EntitlementResolver(
    context: CheckContext(userID: managedUserID, deviceID: deviceID),
    policy: GracePolicy(freshFor: 6 * 3_600, offlineGrace: 72 * 3_600),
    verifier: P256SnapshotVerifier(pinnedKeys: ["ent-2026-10": serverPublicKey]),
    store: appGroupSnapshotStore,      // your SnapshotStore
    highWater: keychainHighWaterMark,  // your HighWaterMarkStore
    feed: entitlementAPI               // your EntitlementFeed
)

_ = await resolver.bootstrap()         // adopt what a Suite sibling already verified
_ = await resolver.refresh()           // single-flight; safe to call from many places

// From StoreKit's Transaction.updates or a server push, via your adapter:
await resolver.ingest(seatEvents)

switch await resolver.decide(exportFeature) {
case .allow: export()
case .deny(let reason): showPaywallOrExplanation(reason)
}
```

## Verification

- `swift build --build-tests -Xswiftc -warnings-as-errors` from a deleted `.build`, then `swift test`, on Linux (Swift 6.1.2): **96 tests, 0 failures**. The ES256 test is compiled only where CryptoKit exists, so Linux runs 96 and macOS runs 97.
- Mutation check: **27 hand-made source mutations, each killed by at least one test.**
  - The original 20 cover: single-flight removed, known-revocation check removed, restrictiveness tie-break removed, monotonic clock ignored, high-water ignored, dedup always admits, grace boundary off by one, wrong FNV prime, subscriber cleanup removed, verification allowed to regress, snapshot replaces the ledger, clock floor ignored, grants journalled, journal compacted against the ledger instead of signed state, store-save guard removed, bootstrap writing the store, journal not replayed, `deinit` not finishing streams, strict future-date check, and every change published twice.
  - Seven more were added for 1.1.0: network adoption kept forward-only, no floor reset on refresh, boot id ignored, persisted evidence not loaded, journal applied after the store, every non-granting event journalled, and aging from `issuedAt` instead of receipt.
  - Two mutations first *survived* an earlier suite (restrictiveness, and publish-twice). The tests that now kill them were added because of that.
- CI ([Actions](https://github.com/rajatslakhina/seat-entitlement-kit/actions)), on every push to `main`:
  - **Linux**, `swift:6.0` container: `swift build --build-tests -Xswiftc -warnings-as-errors`, then `swift test`.
  - **macOS** (`macos-15`): the same warnings-as-errors build, which also compiles the SwiftUI module; `swift test` (89 tests, including the CryptoKit ES256 round trip); and `xcodebuild` of every module for `generic/platform=iOS Simulator` with warnings as errors.
  - The first macOS run failed on a real Swift 6 isolation error in the SwiftUI module, which Linux cannot compile. It was fixed before `v1.0.0` was tagged.
- Releases: `v1.0.0`, then `v1.1.0` with the clock-model fixes from the second independent review (additive API: `ClockFloorStore.reset/loadVerification/saveVerification` and `EntitlementClock.bootID` have default implementations, so 1.0 conformers still compile).
- Simulator: this package has no app. The [demo app](https://github.com/rajatslakhina/seat-entitlement-kit-demo-app#verification)'s CI builds it against this release, installs it on an iOS Simulator, launches four scripted states and captures the screenshots above. It has not been run by hand on a developer Mac: the scheduled job that builds these repos was granted Simulator access, but Xcode had an unrelated project open, so it did not touch it.

## License

MIT
