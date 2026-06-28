import Foundation

/// Builds `CarServer_Action` bodies for `Command.Actions` cases — the misc
/// VehicleAction commands (honk, flash, windows, homelink, sunroof) that
/// don't fit the Charge or Climate buckets. Infotainment domain.
///
/// Honk and Flash route through Infotainment (not VCSEC RKE), matching
/// `pkg/vehicle/actions.go`.
enum ActionsEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization failed.
        case encodingFailed(String)
    }

    static func encode(_ command: Command.Actions) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .honk:
            vehicleAction.vehicleActionMsg = .vehicleControlHonkHornAction(CarServer_VehicleControlHonkHornAction())
        case .flashLights:
            vehicleAction.vehicleActionMsg = .vehicleControlFlashLightsAction(CarServer_VehicleControlFlashLightsAction())
        case .closeWindows:
            var sub = CarServer_VehicleControlWindowAction()
            sub.action = .close(CarServer_Void())
            vehicleAction.vehicleActionMsg = .vehicleControlWindowAction(sub)
        case .ventWindows:
            var sub = CarServer_VehicleControlWindowAction()
            sub.action = .vent(CarServer_Void())
            vehicleAction.vehicleActionMsg = .vehicleControlWindowAction(sub)
        case let .triggerHomelink(lat, lng):
            var sub = CarServer_VehicleControlTriggerHomelinkAction()
            var loc = CarServer_LatLong()
            loc.latitude = lat
            loc.longitude = lng
            sub.location = loc
            vehicleAction.vehicleActionMsg = .vehicleControlTriggerHomelinkAction(sub)
        case let .changeSunroof(level):
            var sub = CarServer_VehicleControlSunroofOpenCloseAction()
            sub.sunroofLevel = .absoluteLevel(level)
            vehicleAction.vehicleActionMsg = .vehicleControlSunroofOpenCloseAction(sub)
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
