import CryptoKit
import Foundation

/// AES-GCM-128 seal / open primitives used on the signing and verification
/// paths. This is a thin adapter over CryptoKit's `AES.GCM` that exposes the
/// exact wire shape the vehicle expects:
///
/// - 12-byte nonces and 16-byte tags (CryptoKit defaults, but the wire
///   format stores nonce, ciphertext, and tag in separate protobuf fields
///   rather than as a concatenated sealed box, so we split them on the way
///   out and reassemble on the way in).
/// - `sealFixed` exists because the AAD construction and tag production are
///   verified against Go-generated test vectors that pre-specify the nonce;
///   production signing uses the random-nonce `seal` variant.
///
/// Fixture: `Tests/TeslaBLETests/Fixtures/crypto/gcm_roundtrip_vectors.json`.
enum MessageAuthenticator {
    enum Error: Swift.Error, Equatable {
        case sealFailed(String)
        case openFailed(String)
        case authenticationFailure
        case invalidNonce
    }

    struct Sealed {
        let ciphertext: Data
        let tag: Data
    }

    /// Seal plaintext with a caller-supplied fixed nonce. This form exists for
    /// fixture testing and for any future replay-of-previous-request path.
    /// The production signer uses `seal(plaintext:associatedData:sessionKey:)`
    /// which generates a random nonce.
    static func sealFixed(
        plaintext: Data,
        associatedData: Data,
        nonce: Data,
        sessionKey: SessionKey,
    ) throws -> Sealed {
        guard nonce.count == 12 else {
            throw Error.invalidNonce
        }
        let gcmNonce: AES.GCM.Nonce
        do {
            gcmNonce = try AES.GCM.Nonce(data: nonce)
        } catch {
            throw Error.invalidNonce
        }
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: sessionKey.symmetric,
                nonce: gcmNonce,
                authenticating: associatedData,
            )
            return Sealed(ciphertext: box.ciphertext, tag: Data(box.tag))
        } catch {
            throw Error.sealFailed(String(describing: error))
        }
    }

    /// Seal plaintext with a freshly-generated random nonce. Used by the
    /// production signer path. Returns nonce alongside ciphertext and tag.
    static func seal(
        plaintext: Data,
        associatedData: Data,
        sessionKey: SessionKey,
    ) throws -> (nonce: Data, ciphertext: Data, tag: Data) {
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: sessionKey.symmetric,
                authenticating: associatedData,
            )
            return (Data(box.nonce), box.ciphertext, Data(box.tag))
        } catch {
            throw Error.sealFailed(String(describing: error))
        }
    }

    /// Open a sealed box. Throws `.authenticationFailure` on tag mismatch (the
    /// security-critical case that upper layers must translate to replay /
    /// tamper errors), or `.openFailed` for other CryptoKit failures.
    static func open(
        ciphertext: Data,
        tag: Data,
        nonce: Data,
        associatedData: Data,
        sessionKey: SessionKey,
    ) throws -> Data {
        guard nonce.count == 12 else {
            throw Error.invalidNonce
        }
        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let box = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: ciphertext,
                tag: tag,
            )
            return try AES.GCM.open(box, using: sessionKey.symmetric, authenticating: associatedData)
        } catch CryptoKitError.authenticationFailure {
            throw Error.authenticationFailure
        } catch {
            throw Error.openFailed(String(describing: error))
        }
    }
}
