import CryptoKit
@testable import TeslaBLE
import XCTest

final class KeychainTeslaKeyStoreTests: XCTestCase {
    private var store: KeychainTeslaKeyStore!
    private let vin = "TEST_VIN_0001"

    override func setUp() {
        super.setUp()
        let uniqueService = "TeslaBLETests.\(UUID().uuidString)"
        store = KeychainTeslaKeyStore(service: uniqueService)
    }

    override func tearDown() {
        try? store.deletePrivateKey(forVIN: vin)
        store = nil
        super.tearDown()
    }

    func testLoadFromEmptyReturnsNil() throws {
        XCTAssertNil(try store.loadPrivateKey(forVIN: vin))
    }

    func testSaveThenLoadRoundTrip() throws {
        let original = P256.KeyAgreement.PrivateKey()
        try store.savePrivateKey(original, forVIN: vin)

        let loaded = try store.loadPrivateKey(forVIN: vin)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rawRepresentation, original.rawRepresentation)
    }

    func testSaveOverwritesExisting() throws {
        let first = P256.KeyAgreement.PrivateKey()
        let second = P256.KeyAgreement.PrivateKey()
        try store.savePrivateKey(first, forVIN: vin)
        try store.savePrivateKey(second, forVIN: vin)

        let loaded = try store.loadPrivateKey(forVIN: vin)
        XCTAssertEqual(loaded?.rawRepresentation, second.rawRepresentation)
    }

    func testDeleteRemovesKey() throws {
        let key = P256.KeyAgreement.PrivateKey()
        try store.savePrivateKey(key, forVIN: vin)
        try store.deletePrivateKey(forVIN: vin)
        XCTAssertNil(try store.loadPrivateKey(forVIN: vin))
    }

    func testDeleteOnEmptyIsIdempotent() throws {
        XCTAssertNoThrow(try store.deletePrivateKey(forVIN: vin))
    }
}
