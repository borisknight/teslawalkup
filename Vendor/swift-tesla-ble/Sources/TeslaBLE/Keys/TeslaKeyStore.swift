import CryptoKit
import Foundation

/// Pluggable persistent storage for per-VIN Tesla ECDH private keys.
///
/// TeslaBLE reads and writes the long-lived signing key through this protocol
/// so applications can plug in whatever storage strategy suits them — an
/// encrypted file, a server-backed vault, an in-memory store for tests, and
/// so on. A ready-to-use Keychain implementation, ``KeychainTeslaKeyStore``,
/// ships with the package as the recommended default.
///
/// ## Key format
///
/// Keys are NIST P-256 (`secp256r1`) ECDH private keys, represented as
/// `CryptoKit.P256.KeyAgreement.PrivateKey`. Exactly one keypair is stored
/// per VIN: the same key must be reused across launches so that the vehicle
/// continues to recognize this client as an enrolled key holder.
///
/// ## Contract
///
/// Conforming types must honor the following invariants:
///
/// - **Load-or-create is the caller's job.** Implementations only load what
///   was previously saved; they must never silently generate a new keypair
///   from ``loadPrivateKey(forVIN:)``. Returning `nil` tells the caller to
///   generate and then ``savePrivateKey(_:forVIN:)``.
/// - **Never lose an existing key.** ``savePrivateKey(_:forVIN:)`` may
///   overwrite, but ``loadPrivateKey(forVIN:)`` must be lossless between
///   saves — losing a key means losing access to the paired vehicle.
/// - **Thread-safe.** Conformances are declared `Sendable`; implementations
///   must be safe to call from any actor or task.
///
/// ## Topics
///
/// ### Reading and writing keys
/// - ``loadPrivateKey(forVIN:)``
/// - ``savePrivateKey(_:forVIN:)``
/// - ``deletePrivateKey(forVIN:)``
public protocol TeslaKeyStore: Sendable {
    /// Returns the previously-saved private key for `vin`, or `nil` if none exists.
    ///
    /// - Parameter vin: The 17-character vehicle identification number.
    /// - Returns: The stored P-256 private key, or `nil` if this VIN has no entry.
    /// - Throws: A storage-specific error if the underlying store was reachable
    ///   but failed (for example a Keychain error distinct from "item not found").
    func loadPrivateKey(forVIN vin: String) throws -> P256.KeyAgreement.PrivateKey?

    /// Persists `key` for `vin`, overwriting any existing entry.
    ///
    /// - Parameters:
    ///   - key: The P-256 private key to persist.
    ///   - vin: The 17-character vehicle identification number.
    /// - Throws: A storage-specific error if the write fails.
    func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey, forVIN vin: String) throws

    /// Removes the stored key for `vin`, if any.
    ///
    /// Idempotent: deleting a VIN with no stored key must not throw.
    ///
    /// - Parameter vin: The 17-character vehicle identification number.
    /// - Throws: A storage-specific error if the delete fails for a reason
    ///   other than "item not found".
    func deletePrivateKey(forVIN vin: String) throws
}
