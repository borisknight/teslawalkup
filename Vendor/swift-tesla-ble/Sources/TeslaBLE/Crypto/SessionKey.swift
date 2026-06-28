import CryptoKit
import Foundation

/// The 16-byte AES-GCM-128 session key derived from a freshly-computed ECDH
/// shared secret.
///
/// Derivation is deliberately `SHA1(shared_x)[0..<16]` — a straight SHA-1
/// of the 32-byte shared X-coordinate, truncated to the first 16 bytes.
/// This is NOT a modern KDF and would fail a design review in isolation;
/// it is required for wire compatibility with the vehicle firmware, which
/// uses the same derivation on its side. Mirrors `NativeECDHKey.Exchange`
/// in `Vendor/tesla-vehicle-command/internal/authentication/native.go` — do
/// not change it.
///
/// Security rationale for why this is acceptable here:
/// - The SHA-1 input is the X-coordinate of a random P-256 point, which is
///   already pseudorandom and high-entropy, so SHA-1's collision weaknesses
///   do not reduce the strength of the resulting AES key in practice.
/// - The output is used only as a symmetric key for AES-GCM, not as a
///   commitment or collision-resistant fingerprint.
///
/// Fixture: `Tests/TeslaBLETests/Fixtures/crypto/session_key_vectors.json`.
struct SessionKey: Sendable, Equatable {
    /// The raw 16 bytes of the derived key.
    let rawBytes: Data

    /// CryptoKit-friendly view over the same bytes.
    var symmetric: SymmetricKey {
        SymmetricKey(data: rawBytes)
    }

    /// Derive a SessionKey from the raw 32-byte shared X coordinate. See the
    /// type-level doc comment for why this is SHA-1 truncation rather than
    /// HKDF — it is a wire-compat requirement, not a KDF recommendation.
    static func derive(fromSharedSecret sharedX: Data) -> SessionKey {
        precondition(sharedX.count == 32, "ECDH shared-X must be 32 bytes")
        let digest = Insecure.SHA1.hash(data: sharedX)
        let truncated = Data(digest.prefix(16))
        return SessionKey(rawBytes: truncated)
    }
}
