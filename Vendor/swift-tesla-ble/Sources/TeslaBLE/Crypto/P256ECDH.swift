import CryptoKit
import Foundation

/// Thin adapter around CryptoKit's `P256.KeyAgreement` that surfaces the
/// shared ECDH X-coordinate in the exact byte layout the vehicle expects.
///
/// The vehicle performs static-ECDH over NIST P-256. Both sides compute the
/// scalar-multiplied point and take its X-coordinate as the raw 32-byte
/// big-endian shared secret — the Y-coordinate and the leading SEC1 `0x04`
/// tag are discarded. `SharedSecret.withUnsafeBytes` already returns exactly
/// this form for P-256, so this wrapper is mostly format validation plus a
/// narrowed error surface. Mirrors `NativeECDHKey.Exchange` in
/// `internal/authentication/native.go`.
enum P256ECDH {
    enum Error: Swift.Error, Equatable {
        case invalidPrivateKeyLength
        case invalidPrivateKey
        case invalidPublicKey
        case invalidSharedPoint
    }

    /// Computes the shared secret X-coordinate between a local private key
    /// (given as its 32-byte raw scalar) and a peer public key (given as its
    /// 65-byte uncompressed SEC1 encoding, i.e. `0x04 || X || Y`).
    ///
    /// Returns the 32-byte big-endian X coordinate of the shared point.
    static func sharedSecret(
        localScalar: Data,
        peerPublicUncompressed: Data,
    ) throws -> Data {
        guard localScalar.count == 32 else {
            throw Error.invalidPrivateKeyLength
        }
        let privateKey: P256.KeyAgreement.PrivateKey
        do {
            privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: localScalar)
        } catch {
            throw Error.invalidPrivateKey
        }

        let publicKey: P256.KeyAgreement.PublicKey
        do {
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicUncompressed)
        } catch {
            throw Error.invalidPublicKey
        }

        let secret: SharedSecret
        do {
            secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch {
            throw Error.invalidSharedPoint
        }
        return secret.withUnsafeBytes { Data($0) }
    }
}
