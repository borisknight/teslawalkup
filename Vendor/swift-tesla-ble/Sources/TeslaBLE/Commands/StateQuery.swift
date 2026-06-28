import Foundation

/// Individual categories of vehicle state that can be requested via
/// ``TeslaVehicleClient/fetch(_:timeout:)``.
public enum StateCategory: String, Sendable, CaseIterable {
    /// Charging subsystem: battery level, charge rate, charger connection.
    case charge
    /// HVAC setpoints and cabin temperatures.
    case climate
    /// Drive state: gear, speed, heading, shift lever.
    case drive
    /// GPS location and heading.
    case location
    /// Door, trunk, frunk, window, and lock status.
    case closures
    /// Charge schedule entries.
    case chargeSchedule
    /// Preconditioning schedule entries.
    case preconditioningSchedule
    /// Tire pressure readings.
    case tirePressure
    /// Now-playing summary (track, source).
    case media
    /// Extended media metadata beyond the summary subset.
    case mediaDetail
    /// Software update availability and installation status.
    case softwareUpdate
    /// Parental controls configuration.
    case parentalControls
}

/// Shape of a state fetch passed to ``TeslaVehicleClient/fetch(_:timeout:)``.
///
/// ``all`` fetches every supported category in a single round trip, which
/// is convenient but incurs the largest response payload and highest
/// latency. ``driveOnly`` fetches just the drive subset, trading
/// completeness for the lowest latency when polling while driving. Use
/// ``categories(_:)`` to request an explicit subset when ``all`` is too
/// much and ``driveOnly`` is too little.
public enum StateQuery: Sendable, Equatable {
    /// Request every category in ``StateCategory``.
    case all
    /// Request only ``StateCategory/drive``. Lowest-latency fast path.
    case driveOnly
    /// Request the listed categories.
    case categories(Set<StateCategory>)
}

/// Encoder for the `getVehicleData` infotainment action used by
/// `TeslaVehicleClient.fetch(_:)`. Returns serialized `CarServer_Action`
/// bytes targeting `UniversalMessage_Domain.infotainment`.
enum StateQueryEncoder {
    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
    }

    static func encode(_ query: StateQuery) throws -> Data {
        let categories: Set<StateCategory> = switch query {
        case .all:
            Set(StateCategory.allCases)
        case .driveOnly:
            [.drive]
        case let .categories(cats):
            cats
        }

        var get = CarServer_GetVehicleData()
        for category in categories {
            switch category {
            case .charge:
                get.getChargeState = CarServer_GetChargeState()
            case .climate:
                get.getClimateState = CarServer_GetClimateState()
            case .drive:
                get.getDriveState = CarServer_GetDriveState()
            case .location:
                get.getLocationState = CarServer_GetLocationState()
            case .closures:
                get.getClosuresState = CarServer_GetClosuresState()
            case .chargeSchedule:
                get.getChargeScheduleState = CarServer_GetChargeScheduleState()
            case .preconditioningSchedule:
                get.getPreconditioningScheduleState = CarServer_GetPreconditioningScheduleState()
            case .tirePressure:
                get.getTirePressureState = CarServer_GetTirePressureState()
            case .media:
                get.getMediaState = CarServer_GetMediaState()
            case .mediaDetail:
                get.getMediaDetailState = CarServer_GetMediaDetailState()
            case .softwareUpdate:
                get.getSoftwareUpdateState = CarServer_GetSoftwareUpdateState()
            case .parentalControls:
                get.getParentalControlsState = CarServer_GetParentalControlsState()
            }
        }

        var vehicleAction = CarServer_VehicleAction()
        vehicleAction.getVehicleData = get
        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
