import Foundation
@testable import TeslaBLE
import XCTest

private extension Data {
    init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }
}

/// Fixture-driven tests for the TeslaBLE Crypto layer. Each JSON fixture in
/// Tests/TeslaBLETests/Fixtures/crypto/ drives a parametric XCTest method.
final class CryptoVectorTests: XCTestCase {
    // MARK: - Fixture loading

    private struct WindowFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let counter: UInt32
            let window: UInt64
            let newCounter: UInt32
            let expectedCounter: UInt32
            let expectedWindow: UInt64
            let expectedOk: Bool
        }
    }

    private func loadJSON<T: Decodable>(_: T.Type, named filename: String) throws -> T {
        guard let url = Bundle.module.url(forResource: "Fixtures/crypto/\(filename)", withExtension: nil) else {
            XCTFail("Missing fixture: Fixtures/crypto/\(filename)")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Window tests

    func testSlidingWindowVectors() throws {
        let fixture = try loadJSON(WindowFixture.self, named: "window_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty, "fixture has no cases")

        for testCase in fixture.cases {
            var window = CounterWindow(counter: testCase.counter, history: testCase.window, initialized: true)
            let ok = window.accept(testCase.newCounter)
            XCTAssertEqual(
                ok, testCase.expectedOk,
                "[\(testCase.name)] ok mismatch",
            )
            XCTAssertEqual(
                window.counter, testCase.expectedCounter,
                "[\(testCase.name)] counter mismatch",
            )
            XCTAssertEqual(
                window.history, testCase.expectedWindow,
                "[\(testCase.name)] history mismatch",
            )
        }
    }

    // MARK: - Session key derivation tests

    private struct SessionKeyFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let localScalarHex: String
            let peerPublicHex: String
            let sharedXHex: String
            let sessionKeyHex: String
        }
    }

    func testSessionKeyVectors() throws {
        let fixture = try loadJSON(SessionKeyFixture.self, named: "session_key_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let rawScalar = try XCTUnwrap(Data(hex: testCase.localScalarHex))
            // Go's big.Int.Bytes() strips leading zeros; P-256 scalars are 32 bytes big-endian.
            var localScalar = Data(count: 32 - rawScalar.count)
            localScalar.append(rawScalar)
            let peerPublic = try XCTUnwrap(Data(hex: testCase.peerPublicHex))
            let expectedSharedX = try XCTUnwrap(Data(hex: testCase.sharedXHex))
            let expectedSessionKey = try XCTUnwrap(Data(hex: testCase.sessionKeyHex))

            let sharedX = try P256ECDH.sharedSecret(
                localScalar: localScalar,
                peerPublicUncompressed: peerPublic,
            )
            XCTAssertEqual(
                sharedX, expectedSharedX,
                "[\(testCase.name)] shared X mismatch",
            )

            let derivedKey = SessionKey.derive(fromSharedSecret: sharedX)
            XCTAssertEqual(
                derivedKey.rawBytes, expectedSessionKey,
                "[\(testCase.name)] session key mismatch",
            )
        }
    }

    // MARK: - Metadata TLV checksum tests

    private struct MetadataSHA256Fixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let hashType: String
            let items: [Item]
            let messageHex: String
            let expectedChecksumHex: String

            struct Item: Decodable {
                let tag: Int
                let valueHex: String
            }
        }
    }

    func testMetadataSHA256Vectors() throws {
        let fixture = try loadJSON(MetadataSHA256Fixture.self, named: "metadata_sha256_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            XCTAssertEqual(testCase.hashType, "sha256", "[\(testCase.name)] unexpected hash type")

            var builder = MetadataHash.sha256Context()
            for item in testCase.items {
                let value = try XCTUnwrap(Data(hex: item.valueHex))
                try builder.add(tagRaw: UInt8(item.tag), value: value)
            }
            let message = try XCTUnwrap(Data(hex: testCase.messageHex))
            let expected = try XCTUnwrap(Data(hex: testCase.expectedChecksumHex))
            let actual = builder.checksum(over: message)
            XCTAssertEqual(actual, expected, "[\(testCase.name)] checksum mismatch")
        }
    }

    private struct MetadataHMACFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let sessionKeyHex: String
            let label: String
            let items: [Item]
            let messageHex: String
            let expectedChecksumHex: String

            struct Item: Decodable {
                let tag: String // decimal as string in the dumped fixture
                let valueHex: String
            }
        }
    }

    func testMetadataHMACVectors() throws {
        let fixture = try loadJSON(MetadataHMACFixture.self, named: "metadata_hmac_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let keyBytes = try XCTUnwrap(Data(hex: testCase.sessionKeyHex))
            let sessionKey = SessionKey(rawBytes: keyBytes)
            var builder = MetadataHash.hmacContext(sessionKey: sessionKey, label: testCase.label)
            for item in testCase.items {
                let tagInt = try XCTUnwrap(Int(item.tag))
                let value = try XCTUnwrap(Data(hex: item.valueHex))
                try builder.add(tagRaw: UInt8(tagInt), value: value)
            }
            let message = try XCTUnwrap(Data(hex: testCase.messageHex))
            let expected = try XCTUnwrap(Data(hex: testCase.expectedChecksumHex))
            let actual = builder.checksum(over: message)
            XCTAssertEqual(actual, expected, "[\(testCase.name)] HMAC checksum mismatch")
        }
    }

    // MARK: - MetadataHash error-path tests

    func testMetadataHashOutOfOrderThrows() throws {
        var builder = MetadataHash.sha256Context()
        try builder.add(tagRaw: 1, value: Data([0x01]))
        try builder.add(tagRaw: 2, value: Data([0x02]))

        XCTAssertThrowsError(try builder.add(tagRaw: 1, value: Data([0x03]))) { error in
            guard case let MetadataHash.Error.outOfOrder(tag, previous) = error else {
                XCTFail("expected outOfOrder, got \(error)")
                return
            }
            XCTAssertEqual(tag, 1)
            XCTAssertEqual(previous, 2)
        }
    }

    func testMetadataHashValueTooLongThrows() throws {
        var builder = MetadataHash.sha256Context()
        let tooLong = Data(repeating: 0x42, count: 256)
        XCTAssertThrowsError(try builder.add(tagRaw: 1, value: tooLong)) { error in
            guard case let MetadataHash.Error.valueTooLong(length) = error else {
                XCTFail("expected valueTooLong, got \(error)")
                return
            }
            XCTAssertEqual(length, 256)
        }
    }

    // MARK: - CounterWindow uninitialized path

    func testCounterWindowFirstUseAcceptsAnyValue() {
        var window = CounterWindow()
        XCTAssertFalse(window.initialized)
        XCTAssertTrue(window.accept(12345))
        XCTAssertTrue(window.initialized)
        XCTAssertEqual(window.counter, 12345)
        XCTAssertEqual(window.history, 0)
    }

    func testCounterWindowHistoryZeroAfterLargeJump() {
        var window = CounterWindow(counter: 5, history: 0b111, initialized: true)
        XCTAssertTrue(window.accept(200))
        XCTAssertEqual(window.counter, 200)
        XCTAssertEqual(window.history, 0, "history must clear on shifts ≥ 64")
    }

    // MARK: - P256ECDH error paths

    func testP256ECDHRejectsShortPrivateKey() {
        let shortScalar = Data(repeating: 0x01, count: 31)
        let fakePublic = Data(repeating: 0x04, count: 65)
        XCTAssertThrowsError(try P256ECDH.sharedSecret(
            localScalar: shortScalar,
            peerPublicUncompressed: fakePublic,
        )) { error in
            XCTAssertEqual(error as? P256ECDH.Error, .invalidPrivateKeyLength)
        }
    }

    func testP256ECDHRejectsMalformedPublicKey() {
        let scalar = Data(repeating: 0x01, count: 32)
        let bogusPublic = Data(repeating: 0x00, count: 65) // not a valid SEC1 point
        XCTAssertThrowsError(try P256ECDH.sharedSecret(
            localScalar: scalar,
            peerPublicUncompressed: bogusPublic,
        )) { error in
            XCTAssertEqual(error as? P256ECDH.Error, .invalidPublicKey)
        }
    }

    // MARK: - AES-GCM round-trip tests

    private struct GCMFixture: Decodable {
        let description: String
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let sessionKeyHex: String
            let nonceHex: String
            let plaintextHex: String
            let aadHex: String
            let ciphertextHex: String
            let tagHex: String
        }
    }

    func testGCMRoundtripVectors() throws {
        let fixture = try loadJSON(GCMFixture.self, named: "gcm_roundtrip_vectors.json")
        XCTAssertFalse(fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let keyBytes = try XCTUnwrap(Data(hex: testCase.sessionKeyHex))
            let nonce = try XCTUnwrap(Data(hex: testCase.nonceHex))
            let plaintext = try XCTUnwrap(Data(hex: testCase.plaintextHex))
            let aad = try XCTUnwrap(Data(hex: testCase.aadHex))
            let expectedCT = try XCTUnwrap(Data(hex: testCase.ciphertextHex))
            let expectedTag = try XCTUnwrap(Data(hex: testCase.tagHex))

            let sessionKey = SessionKey(rawBytes: keyBytes)

            // Seal with the fixed nonce and assert byte-for-byte agreement.
            let sealed = try MessageAuthenticator.sealFixed(
                plaintext: plaintext,
                associatedData: aad,
                nonce: nonce,
                sessionKey: sessionKey,
            )
            XCTAssertEqual(sealed.ciphertext, expectedCT, "[\(testCase.name)] ciphertext mismatch")
            XCTAssertEqual(sealed.tag, expectedTag, "[\(testCase.name)] tag mismatch")

            // Open it back and confirm plaintext.
            let opened = try MessageAuthenticator.open(
                ciphertext: expectedCT,
                tag: expectedTag,
                nonce: nonce,
                associatedData: aad,
                sessionKey: sessionKey,
            )
            XCTAssertEqual(opened, plaintext, "[\(testCase.name)] open mismatch")
        }
    }
}
