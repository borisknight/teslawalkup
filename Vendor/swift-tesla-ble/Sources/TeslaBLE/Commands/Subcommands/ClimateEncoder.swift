import Foundation

/// Builds `CarServer_Action` bodies for all `Command.Climate` cases — HVAC
/// power, temperature, seat heaters/coolers, keeper modes, and cabin overheat
/// protection. Infotainment domain. Port of `pkg/vehicle/climate.go`.
enum ClimateEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization failed.
        case encodingFailed(String)
        /// A command parameter was invalid (e.g. non-finite temperature).
        case invalidParameter(String)
    }

    static func encode(_ command: Command.Climate) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .on:
            var sub = CarServer_HvacAutoAction()
            sub.powerOn = true
            vehicleAction.vehicleActionMsg = .hvacAutoAction(sub)

        case .off:
            var sub = CarServer_HvacAutoAction()
            sub.powerOn = false
            vehicleAction.vehicleActionMsg = .hvacAutoAction(sub)

        case let .setTemperature(driver, passenger):
            guard driver.isFinite, passenger.isFinite else {
                throw Error.invalidParameter("temperature must be a finite float")
            }
            var sub = CarServer_HvacTemperatureAdjustmentAction()
            sub.driverTempCelsius = driver
            sub.passengerTempCelsius = passenger
            vehicleAction.vehicleActionMsg = .hvacTemperatureAdjustmentAction(sub)

        case let .setSteeringWheelHeater(on):
            var sub = CarServer_HvacSteeringWheelHeaterAction()
            sub.powerOn = on
            vehicleAction.vehicleActionMsg = .hvacSteeringWheelHeaterAction(sub)

        case let .setKeeperMode(mode):
            var sub = CarServer_HvacClimateKeeperAction()
            switch mode {
            case .off: sub.climateKeeperAction = .climateKeeperActionOff
            case .on: sub.climateKeeperAction = .climateKeeperActionOn
            case .dog: sub.climateKeeperAction = .climateKeeperActionDog
            case .camp: sub.climateKeeperAction = .climateKeeperActionCamp
            }
            vehicleAction.vehicleActionMsg = .hvacClimateKeeperAction(sub)

        case let .setPreconditioningMax(enabled, manualOverride):
            var sub = CarServer_HvacSetPreconditioningMaxAction()
            sub.on = enabled
            sub.manualOverride = manualOverride
            vehicleAction.vehicleActionMsg = .hvacSetPreconditioningMaxAction(sub)

        case let .setBioweaponDefenseMode(enabled, manualOverride):
            var sub = CarServer_HvacBioweaponModeAction()
            sub.on = enabled
            sub.manualOverride = manualOverride
            vehicleAction.vehicleActionMsg = .hvacBioweaponModeAction(sub)

        case let .setCabinOverheatProtection(enabled, fanOnly):
            var sub = CarServer_SetCabinOverheatProtectionAction()
            sub.on = enabled
            sub.fanOnly = fanOnly
            vehicleAction.vehicleActionMsg = .setCabinOverheatProtectionAction(sub)

        case let .setCabinOverheatProtectionTemperature(level):
            var sub = CarServer_SetCopTempAction()
            switch level {
            case .low: sub.copActivationTemp = .low
            case .medium: sub.copActivationTemp = .medium
            case .high: sub.copActivationTemp = .high
            }
            vehicleAction.vehicleActionMsg = .setCopTempAction(sub)

        // MARK: - Seats & Auto Climate

        case let .setSeatHeater(level, seat):
            var item = CarServer_HvacSeatHeaterActions.HvacSeatHeaterAction()
            switch level {
            case .off: item.seatHeaterLevel = .seatHeaterOff(CarServer_Void())
            case .low: item.seatHeaterLevel = .seatHeaterLow(CarServer_Void())
            case .medium: item.seatHeaterLevel = .seatHeaterMed(CarServer_Void())
            case .high: item.seatHeaterLevel = .seatHeaterHigh(CarServer_Void())
            }
            switch seat {
            case .frontLeft: item.seatPosition = .carSeatFrontLeft(CarServer_Void())
            case .frontRight: item.seatPosition = .carSeatFrontRight(CarServer_Void())
            case .rearLeft: item.seatPosition = .carSeatRearLeft(CarServer_Void())
            case .rearLeftBack: item.seatPosition = .carSeatRearLeftBack(CarServer_Void())
            case .rearCenter: item.seatPosition = .carSeatRearCenter(CarServer_Void())
            case .rearRight: item.seatPosition = .carSeatRearRight(CarServer_Void())
            case .rearRightBack: item.seatPosition = .carSeatRearRightBack(CarServer_Void())
            case .thirdRowLeft: item.seatPosition = .carSeatThirdRowLeft(CarServer_Void())
            case .thirdRowRight: item.seatPosition = .carSeatThirdRowRight(CarServer_Void())
            }
            var sub = CarServer_HvacSeatHeaterActions()
            sub.hvacSeatHeaterAction = [item]
            vehicleAction.vehicleActionMsg = .hvacSeatHeaterActions(sub)

        case let .setSeatCooler(level, seat):
            var item = CarServer_HvacSeatCoolerActions.HvacSeatCoolerAction()
            switch level {
            case .off: item.seatCoolerLevel = .hvacSeatCoolerLevelOff
            case .low: item.seatCoolerLevel = .hvacSeatCoolerLevelLow
            case .medium: item.seatCoolerLevel = .hvacSeatCoolerLevelMed
            case .high: item.seatCoolerLevel = .hvacSeatCoolerLevelHigh
            }
            switch seat {
            case .frontLeft: item.seatPosition = .hvacSeatCoolerPositionFrontLeft
            case .frontRight: item.seatPosition = .hvacSeatCoolerPositionFrontRight
            }
            var sub = CarServer_HvacSeatCoolerActions()
            sub.hvacSeatCoolerAction = [item]
            vehicleAction.vehicleActionMsg = .hvacSeatCoolerActions(sub)

        case let .autoSeatAndClimate(enabled, positions):
            var sub = CarServer_AutoSeatClimateAction()
            sub.carseat = positions.map { position in
                var cs = CarServer_AutoSeatClimateAction.CarSeat()
                cs.on = enabled
                switch position {
                case .frontLeft: cs.seatPosition = .autoSeatPositionFrontLeft
                case .frontRight: cs.seatPosition = .autoSeatPositionFrontRight
                }
                return cs
            }
            vehicleAction.vehicleActionMsg = .autoSeatClimateAction(sub)
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
