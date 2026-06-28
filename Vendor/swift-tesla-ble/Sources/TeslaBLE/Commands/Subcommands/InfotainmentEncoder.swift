import Foundation

/// Builds `CarServer_Action` bodies for `Command.Infotainment` cases —
/// software update scheduling/cancel and vehicle rename. Infotainment domain.
/// A catch-all for commands that don't belong in Security/Charge/Climate/
/// Actions/Media.
enum InfotainmentEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization failed.
        case encodingFailed(String)
    }

    static func encode(_ command: Command.Infotainment) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case let .scheduleSoftwareUpdate(offsetSeconds):
            var sub = CarServer_VehicleControlScheduleSoftwareUpdateAction()
            sub.offsetSec = offsetSeconds
            vehicleAction.vehicleActionMsg = .vehicleControlScheduleSoftwareUpdateAction(sub)

        case .cancelSoftwareUpdate:
            vehicleAction.vehicleActionMsg = .vehicleControlCancelSoftwareUpdateAction(
                CarServer_VehicleControlCancelSoftwareUpdateAction(),
            )

        case let .setVehicleName(name):
            var sub = CarServer_SetVehicleNameAction()
            sub.vehicleName = name
            vehicleAction.vehicleActionMsg = .setVehicleNameAction(sub)
        }

        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
