import CryptoKit
import Foundation
import Security

/// Keychain-backed default implementation of ``TeslaKeyStore``.
///
/// This is the recommended default for apps that do not need a bespoke
/// storage strategy: it persists the P-256 private key into the iOS/macOS
/// Keychain under `kSecClassGenericPassword` and returns it on subsequent
/// launches.
///
/// ## Keychain accessibility
///
/// Items are stored with:
///
/// - `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
///   so the key is only readable while the device is unlocked and is
///   **never** included in iCloud Keychain, iCloud backups, or device-to-device
///   migration. If the user restores to a new device, they must re-enroll
///   the vehicle.
/// - The service string provided to ``init(service:)``.
/// - An account of the form `"privateKey-<VIN>"`.
///
/// ## Encoding
///
/// The key is serialized via `P256.KeyAgreement.PrivateKey.x963Representation`,
/// which is a 97-byte blob containing the uncompressed SEC1 public point
/// (`0x04 || X || Y`, 65 bytes) followed by the 32-byte private scalar.
///
/// ## Generation
///
/// This store does **not** auto-generate a key on load: ``loadPrivateKey(forVIN:)``
/// returns `nil` if no entry exists. Callers are expected to detect `nil`,
/// generate a new keypair via ``KeyPairFactory/generateKeyPair()``, and then
/// persist it with ``savePrivateKey(_:forVIN:)``.
///
/// ## Thread safety
///
/// `KeychainTeslaKeyStore` is a value type with no mutable state; calls
/// are safe from any thread or actor. The underlying Keychain API already
/// serializes concurrent access.
public struct KeychainTeslaKeyStore: TeslaKeyStore {
    private let service: String

    /// Creates a key store scoped to the given Keychain service string.
    ///
    /// - Parameter service: The `kSecAttrService` value used for all Keychain
    ///   items written by this store. Choose a stable string — typically your
    ///   app's bundle identifier or a suffix of it — because changing it
    ///   effectively orphans previously-saved keys.
    public init(service: String) {
        self.service = service
    }

    /// Loads the stored P-256 key for `vin`, or returns `nil` if none exists.
    ///
    /// - Parameter vin: The 17-character vehicle identification number.
    /// - Returns: The stored private key, or `nil` if the Keychain has no
    ///   matching entry for this service/VIN pair.
    /// - Throws: ``TeslaBLEError/keychain(_:)`` with the raw `OSStatus` if
    ///   the Keychain reports an error other than `errSecItemNotFound`, or
    ///   a CryptoKit decoding error if the stored blob is corrupt.
    public func loadPrivateKey(forVIN vin: String) throws -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: vin),
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TeslaBLEError.keychain(status)
        }
        return try P256.KeyAgreement.PrivateKey(x963Representation: data)
    }

    /// Persists `key` in the Keychain, overwriting any existing entry for `vin`.
    ///
    /// Internally performs a delete-then-add so that the accessibility class
    /// of the stored item is always refreshed to
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
    ///
    /// - Parameters:
    ///   - key: The P-256 private key to persist.
    ///   - vin: The 17-character vehicle identification number.
    /// - Throws: ``TeslaBLEError/keychain(_:)`` if the underlying
    ///   `SecItemAdd` fails.
    public func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey, forVIN vin: String) throws {
        try deletePrivateKey(forVIN: vin)
        let data = key.x963Representation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: vin),
            kSecValueData as String: data,
            // AfterFirstUnlock (not WhenUnlocked) so the key is readable while the
            // phone is LOCKED in a pocket — required for background door opens.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TeslaBLEError.keychain(status)
        }
    }

    /// Removes the stored key for `vin` from the Keychain.
    ///
    /// Idempotent: returns successfully if no entry exists.
    ///
    /// - Parameter vin: The 17-character vehicle identification number.
    /// - Throws: ``TeslaBLEError/keychain(_:)`` if `SecItemDelete` returns an
    ///   error other than `errSecItemNotFound`.
    public func deletePrivateKey(forVIN vin: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: vin),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TeslaBLEError.keychain(status)
        }
    }

    private func account(for vin: String) -> String {
        "privateKey-\(vin)"
    }
}
