import CryptoKit
import Foundation
@testable import TeslaBLE

/// Dictionary-backed `TeslaKeyStore` used by unit tests and as a reference
/// implementation for apps wanting to test their ViewModels without a real
/// Keychain.
final class InMemoryTeslaKeyStore: TeslaKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: P256.KeyAgreement.PrivateKey] = [:]

    func loadPrivateKey(forVIN vin: String) throws -> P256.KeyAgreement.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return storage[vin]
    }

    func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey, forVIN vin: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[vin] = key
    }

    func deletePrivateKey(forVIN vin: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: vin)
    }
}
