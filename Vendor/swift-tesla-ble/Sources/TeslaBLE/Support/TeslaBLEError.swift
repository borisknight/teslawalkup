import Foundation

/// Errors thrown by TeslaBLE public APIs.
///
/// Consumers typically `switch` on these cases when deciding whether to
/// surface an error to the user, retry, or re-pair.
public enum TeslaBLEError: Error, Sendable {
    /// The host Bluetooth adapter is off, unauthorized, or otherwise unavailable.
    case bluetoothUnavailable
    /// The scan ran for its full timeout without discovering the target VIN.
    case scanTimeout
    /// The BLE peripheral connect attempt failed at the Core Bluetooth layer.
    case connectionFailed(underlying: String)
    /// The peripheral did not expose the Tesla vehicle GATT service.
    case serviceNotFound
    /// The Tesla service was found but required characteristics were not.
    case characteristicsNotFound
    /// An operation requiring an active session was called while disconnected.
    case notConnected
    /// An outgoing message exceeded the maximum GATT payload size.
    case messageTooLarge
    /// The per-domain session handshake could not complete.
    case handshakeFailed(underlying: String)
    /// A ``TeslaVehicleClient/fetch(_:timeout:)`` or ``TeslaVehicleClient/query(_:timeout:)``
    /// request failed to encode, transport, or decode.
    case fetchFailed(underlying: String)
    /// The unsigned VCSEC addKey pairing request was rejected by the vehicle.
    case addKeyFailed(underlying: String)
    /// A keychain operation backing the key store failed with the given `OSStatus`.
    case keychain(OSStatus)
    /// A command was sent but the vehicle did not respond within the timeout.
    case commandTimeout
    /// The vehicle accepted the command envelope but returned an error outcome.
    ///
    /// - Parameters:
    ///   - code: Vehicle-reported error code.
    ///   - reason: Optional human-readable reason string, when provided.
    case commandRejected(code: Int, reason: String?)
}

extension TeslaBLEError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is unavailable"
        case .scanTimeout:
            "Vehicle not found within scan timeout"
        case let .connectionFailed(underlying):
            "BLE connection failed: \(underlying)"
        case .serviceNotFound:
            "Tesla vehicle service not found on peripheral"
        case .characteristicsNotFound:
            "Tesla vehicle characteristics not found"
        case .notConnected:
            "Not connected to a vehicle"
        case .messageTooLarge:
            "Outgoing message exceeds maximum size"
        case let .handshakeFailed(underlying):
            "Session handshake failed: \(underlying)"
        case let .fetchFailed(underlying):
            "Vehicle data fetch failed: \(underlying)"
        case let .addKeyFailed(underlying):
            "AddKey request failed: \(underlying)"
        case let .keychain(status):
            "Keychain error (OSStatus \(status))"
        case .commandTimeout:
            "Command timed out waiting for vehicle response"
        case let .commandRejected(code, reason):
            "Vehicle rejected command (code \(code))\(reason.map { ": \($0)" } ?? "")"
        }
    }
}
