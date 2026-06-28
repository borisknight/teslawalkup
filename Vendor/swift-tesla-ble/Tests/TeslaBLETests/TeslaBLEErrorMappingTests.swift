@testable import TeslaBLE
import XCTest

final class TeslaBLEErrorMappingTests: XCTestCase {
    func testBluetoothUnavailableDescription() {
        let error = TeslaBLEError.bluetoothUnavailable
        XCTAssertEqual(error.errorDescription, "Bluetooth is unavailable")
    }

    func testConnectionFailedCarriesUnderlying() throws {
        let error = TeslaBLEError.connectionFailed(underlying: "peer disconnected")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(try XCTUnwrap(error.errorDescription?.contains("peer disconnected")))
    }

    func testKeychainCarriesStatus() throws {
        let error = TeslaBLEError.keychain(-25300)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(try XCTUnwrap(error.errorDescription?.contains("-25300")))
    }

    func testHandshakeFailedCarriesUnderlying() throws {
        let error = TeslaBLEError.handshakeFailed(underlying: "vehicle asleep")
        XCTAssertTrue(try XCTUnwrap(error.errorDescription?.contains("vehicle asleep")))
    }

    func testFetchFailedCarriesUnderlying() throws {
        let error = TeslaBLEError.fetchFailed(underlying: "timeout")
        XCTAssertTrue(try XCTUnwrap(error.errorDescription?.contains("timeout")))
    }

    func testAddKeyFailedCarriesUnderlying() throws {
        let error = TeslaBLEError.addKeyFailed(underlying: "no response")
        XCTAssertTrue(try XCTUnwrap(error.errorDescription?.contains("no response")))
    }
}
