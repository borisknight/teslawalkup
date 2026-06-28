import CryptoKit
import Foundation

/// Utilities for generating and encoding Tesla-compatible P-256 key pairs.
///
/// Tesla vehicles expect the client's long-lived identity key to be a NIST
/// P-256 ECDH keypair. `KeyPairFactory` provides the two small helpers
/// needed at enrollment time: one to generate a fresh keypair, and one to
/// emit the public half in the exact on-the-wire format the vehicle's
/// whitelist (`addKey`) accepts.
///
/// Consumers typically call ``generateKeyPair()`` once per VIN, persist the
/// result through a ``TeslaKeyStore``, and pass ``publicKeyBytes(of:)`` into
/// the pairing flow.
public enum KeyPairFactory {
    /// Generates a fresh NIST P-256 ECDH private key using `CryptoKit`.
    ///
    /// - Returns: A newly-generated `P256.KeyAgreement.PrivateKey`. Each call
    ///   produces an independent key; persist it via ``TeslaKeyStore`` if
    ///   you intend to reuse it.
    public static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    /// Returns the key's public component in the 65-byte uncompressed SEC1
    /// encoding required by Tesla's `addKey` whitelist request.
    ///
    /// The encoding is `0x04 || X || Y`, where `X` and `Y` are the 32-byte
    /// big-endian affine coordinates of the public point on P-256. This is
    /// exactly what `P256.KeyAgreement.PublicKey.x963Representation` emits,
    /// and it is the format the vehicle validates against when adding a new
    /// client key to its whitelist.
    ///
    /// Typical usage during pairing:
    ///
    /// ```swift
    /// let key = KeyPairFactory.generateKeyPair()
    /// let publicKey = KeyPairFactory.publicKeyBytes(of: key)
    /// try await mobileSession.sendAddKeyRequest(publicKey: publicKey, role: .driver)
    /// ```
    ///
    /// - Parameter key: The P-256 private key whose public half should be encoded.
    /// - Returns: A 65-byte `Data` containing `0x04 || X || Y`.
    public static func publicKeyBytes(of key: P256.KeyAgreement.PrivateKey) -> Data {
        key.publicKey.x963Representation
    }
}
