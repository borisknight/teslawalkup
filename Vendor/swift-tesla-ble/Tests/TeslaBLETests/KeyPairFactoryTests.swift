import CryptoKit
@testable import TeslaBLE
import XCTest

final class KeyPairFactoryTests: XCTestCase {
    func testGenerateKeyPairReturnsUniqueKeys() {
        let a = KeyPairFactory.generateKeyPair()
        let b = KeyPairFactory.generateKeyPair()
        XCTAssertNotEqual(a.rawRepresentation, b.rawRepresentation)
    }

    func testPublicKeyBytesAre65BytesUncompressed() {
        let key = KeyPairFactory.generateKeyPair()
        let bytes = KeyPairFactory.publicKeyBytes(of: key)
        XCTAssertEqual(bytes.count, 65)
        XCTAssertEqual(bytes.first, 0x04) // uncompressed SEC1 marker
    }
}
