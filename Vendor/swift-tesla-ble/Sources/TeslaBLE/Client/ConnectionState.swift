import Foundation

/// Lifecycle state of a ``TeslaVehicleClient`` BLE session.
///
/// Observe transitions via ``TeslaVehicleClient/stateStream``. The client
/// walks forward through these cases during ``TeslaVehicleClient/connect(mode:timeout:)``
/// and returns to ``disconnected`` on teardown or peer disconnect.
public enum ConnectionState: Sendable, Equatable {
    /// No BLE session. Initial state, and the state after
    /// ``TeslaVehicleClient/disconnect()`` or any fatal error.
    case disconnected
    /// Scanning for the vehicle's BLE advertisement by VIN-derived local name.
    case scanning
    /// BLE peripheral discovered; CoreBluetooth connect in progress.
    case connecting
    /// Transport is up and the per-domain session handshake is running.
    case handshaking
    /// Fully connected; commands and queries can be dispatched.
    case connected
}
