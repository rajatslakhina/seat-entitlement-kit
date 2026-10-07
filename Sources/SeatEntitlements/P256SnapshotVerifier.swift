#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// ES256 (ECDSA over P-256 with SHA-256) verification against a set of pinned
/// public keys, keyed by `keyID` so the server can rotate keys without an app
/// release: ship the next key before the server starts signing with it.
///
/// An unknown `keyID` fails closed. Signatures are raw (r‖s, 64 bytes), the
/// encoding JWS uses for ES256.
public struct P256SnapshotVerifier: SnapshotVerifier {
    // Stored as raw bytes rather than key objects so the type is Sendable on
    // every SDK, whether or not CryptoKit's key types are marked Sendable there.
    private let keys: [String: Data]

    public init(pinnedKeys: [String: P256.Signing.PublicKey]) {
        self.keys = pinnedKeys.mapValues { $0.rawRepresentation }
    }

    public func isValid(signature: Data, for payload: Data, keyID: String) -> Bool {
        guard let raw = keys[keyID],
              let key = try? P256.Signing.PublicKey(rawRepresentation: raw),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(ecdsa, for: payload)
    }
}

/// Server-side signing, included so tests and the demo's simulated backend can
/// mint real ES256 snapshots. An app never holds a signing key.
public struct P256SnapshotSigner: Sendable {
    public let keyID: String
    private let rawKey: Data

    public init(keyID: String, key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.keyID = keyID
        self.rawKey = key.rawRepresentation
    }

    public var publicKey: P256.Signing.PublicKey {
        get throws { try P256.Signing.PrivateKey(rawRepresentation: rawKey).publicKey }
    }

    public func sign(_ snapshot: EntitlementSnapshot) throws -> SignedSnapshot {
        let key = try P256.Signing.PrivateKey(rawRepresentation: rawKey)
        let payload = try SnapshotGate.makeEncoder().encode(snapshot)
        let signature = try key.signature(for: payload)
        return SignedSnapshot(keyID: keyID, payload: payload, signature: signature.rawRepresentation)
    }
}
#endif
