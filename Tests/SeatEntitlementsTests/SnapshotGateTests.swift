import XCTest
@testable import SeatEntitlements
#if canImport(CryptoKit)
import CryptoKit
#endif

final class SnapshotGateTests: XCTestCase {
    private let snapshot = EntitlementSnapshot(sequence: 5, issuedAt: t0,
                                               seats: [event(v: 1, .assigned(.user("alice")))])

    private func open(_ signed: SignedSnapshot, highWater: UInt64 = 0, now: Date = t0,
                      verifier: any SnapshotVerifier = FakeVerifier()) -> Result<EntitlementSnapshot, SnapshotRejection> {
        SnapshotGate.open(signed, verifier: verifier, highWater: highWater, now: now, skewTolerance: 300)
    }

    func testValidSnapshotOpensAndRoundTrips() {
        XCTAssertEqual(try open(signed(snapshot)).get(), snapshot)
    }

    func testTamperedPayloadIsRejected() {
        let good = signed(snapshot)
        var bytes = [UInt8](good.payload)
        guard let index = bytes.indices.last else { return XCTFail("empty payload") }
        bytes[index] ^= 0x01
        let tampered = SignedSnapshot(keyID: good.keyID, payload: Data(bytes), signature: good.signature)
        XCTAssertEqual(open(tampered), .failure(.badSignature))
    }

    func testUnknownKeyIsRejected() {
        XCTAssertEqual(open(signed(snapshot, keyID: "k-retired")), .failure(.badSignature))
    }

    func testValidSignatureOverGarbageIsUndecodable() {
        let payload = Data("not json".utf8)
        let garbage = SignedSnapshot(keyID: "k1", payload: payload, signature: FakeVerifier.sign(payload, keyID: "k1"))
        XCTAssertEqual(open(garbage), .failure(.undecodable))
    }

    func testOlderThanHighWaterIsRolledBack() {
        XCTAssertEqual(open(signed(snapshot), highWater: 6), .failure(.rolledBack(sequence: 5, highWater: 6)))
    }

    func testEqualToHighWaterIsAcceptedAsIdempotentReload() {
        XCTAssertNoThrow(try open(signed(snapshot), highWater: 5).get())
    }

    func testFutureDatedBeyondSkewIsRejectedButWithinSkewIsAccepted() {
        XCTAssertEqual(open(signed(snapshot), now: t0.addingTimeInterval(-301)),
                       .failure(.futureDated(issuedAt: t0)))
        XCTAssertNoThrow(try open(signed(snapshot), now: t0.addingTimeInterval(-300)).get())
    }

    #if canImport(CryptoKit)
    func testES256RoundTripTamperAndRotation() throws {
        let current = P256SnapshotSigner(keyID: "2026-10")
        let next = P256SnapshotSigner(keyID: "2027-01")
        let verifier = P256SnapshotVerifier(pinnedKeys: [current.keyID: try current.publicKey,
                                                         next.keyID: try next.publicKey])
        let signedNow = try current.sign(snapshot)
        XCTAssertEqual(try open(signedNow, verifier: verifier).get(), snapshot)
        // Rotation: the next key is already pinned, so its snapshots verify too.
        XCTAssertNoThrow(try open(try next.sign(snapshot), verifier: verifier).get())

        var bytes = [UInt8](signedNow.payload)
        bytes[bytes.count / 2] ^= 0x20
        let tampered = SignedSnapshot(keyID: signedNow.keyID, payload: Data(bytes), signature: signedNow.signature)
        XCTAssertEqual(open(tampered, verifier: verifier), .failure(.badSignature))

        // Right signature, wrong key id: fails closed.
        let relabelled = SignedSnapshot(keyID: next.keyID, payload: signedNow.payload, signature: signedNow.signature)
        XCTAssertEqual(open(relabelled, verifier: verifier), .failure(.badSignature))

        let unpinned = P256SnapshotVerifier(pinnedKeys: [:])
        XCTAssertEqual(open(signedNow, verifier: unpinned), .failure(.badSignature))
    }
    #endif

    func testSuiteManifestLimits() throws {
        let fifteen = (1...15).map { "com.example.app\($0)" }
        XCTAssertEqual(try SuiteManifest(group: group, memberBundleIDs: fifteen).memberBundleIDs.count, 15)
        XCTAssertThrowsError(try SuiteManifest(group: group, memberBundleIDs: fifteen + ["com.example.app16"])) {
            XCTAssertEqual($0 as? SuiteManifest.ManifestError, .tooManyMembers(16))
        }
        XCTAssertThrowsError(try SuiteManifest(group: group, memberBundleIDs: [])) {
            XCTAssertEqual($0 as? SuiteManifest.ManifestError, .empty)
        }
        XCTAssertThrowsError(try SuiteManifest(group: group, memberBundleIDs: ["a", "b", "a"])) {
            XCTAssertEqual($0 as? SuiteManifest.ManifestError, .duplicateMember("a"))
        }
        XCTAssertTrue(try SuiteManifest(group: group, memberBundleIDs: ["a"]).contains(bundleID: "a"))
    }
}
