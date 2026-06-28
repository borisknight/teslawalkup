@testable import TeslaBLE
import XCTest

final class VINHelperTests: XCTestCase {
    func testKnownVINProducesExpectedLocalName() {
        // Golden value: SHA1("5YJSA1E26JF000001") first 8 bytes as lowercase hex.
        // Verified via: python3 -c "import hashlib; h=hashlib.sha1(b'5YJSA1E26JF000001').digest()[:8].hex(); print(h)"
        let vin = "5YJSA1E26JF000001"
        let expected = "S5ee30306c8ef7c3fC"
        XCTAssertEqual(VINHelper.bleLocalName(for: vin), expected)
    }

    func testEmptyVINProducesValidName() {
        // SHA1("") first 8 bytes = 0xda39a3ee5e6b4b0d
        let expected = "Sda39a3ee5e6b4b0dC"
        XCTAssertEqual(VINHelper.bleLocalName(for: ""), expected)
    }

    func testFormatAlwaysStartsAndEndsWithSAndC() {
        let name = VINHelper.bleLocalName(for: "ABCDEFG")
        XCTAssertTrue(name.hasPrefix("S"))
        XCTAssertTrue(name.hasSuffix("C"))
        XCTAssertEqual(name.count, 18) // "S" + 16 hex + "C"
    }
}
