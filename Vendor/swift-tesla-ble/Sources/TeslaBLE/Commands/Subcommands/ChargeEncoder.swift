import Foundation

/// Builds `CarServer_Action` bodies for all `Command.Charge` cases —
/// start/stop, limits, schedules, and departure/precondition policies.
/// Infotainment domain. Port of `pkg/vehicle/charge.go`.
enum ChargeEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization failed.
        case encodingFailed(String)
        /// A command parameter was outside its accepted range (e.g. charge
        /// limit percent, charging amps).
        case invalidParameter(String)
    }

    static func encode(_ command: Command.Charge) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .start:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .start(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .stop:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .stop(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .startMaxRange:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .startMaxRange(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .startStandardRange:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .startStandard(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case let .setLimit(percent):
            guard (0 ... 100).contains(percent) else {
                throw Error.invalidParameter("charge limit percent out of range: \(percent)")
            }
            var sub = CarServer_ChargingSetLimitAction()
            sub.percent = percent
            vehicleAction.vehicleActionMsg = .chargingSetLimitAction(sub)

        case let .setAmps(amps):
            guard amps > 0, amps <= 80 else {
                throw Error.invalidParameter("charging amps out of range: \(amps)")
            }
            var sub = CarServer_SetChargingAmpsAction()
            sub.chargingAmps = amps
            vehicleAction.vehicleActionMsg = .setChargingAmpsAction(sub)

        case .openPort:
            vehicleAction.vehicleActionMsg = .chargePortDoorOpen(CarServer_ChargePortDoorOpen())

        case .closePort:
            vehicleAction.vehicleActionMsg = .chargePortDoorClose(CarServer_ChargePortDoorClose())

        case let .setLowPowerMode(enabled):
            var sub = CarServer_SetLowPowerModeAction()
            sub.lowPowerMode = enabled
            vehicleAction.vehicleActionMsg = .setLowPowerModeAction(sub)

        case let .setKeepAccessoryPowerMode(enabled):
            var sub = CarServer_SetKeepAccessoryPowerModeAction()
            sub.keepAccessoryPowerMode = enabled
            vehicleAction.vehicleActionMsg = .setKeepAccessoryPowerModeAction(sub)

        // MARK: - Schedules

        case let .addSchedule(input):
            var schedule = CarServer_ChargeSchedule()
            schedule.id = input.id
            schedule.name = input.name
            schedule.daysOfWeek = input.daysOfWeek
            schedule.startEnabled = input.startEnabled
            schedule.startTime = input.startTimeMinutes
            schedule.endEnabled = input.endEnabled
            schedule.endTime = input.endTimeMinutes
            schedule.oneTime = input.oneTime
            schedule.enabled = input.enabled
            schedule.latitude = input.latitude
            schedule.longitude = input.longitude
            vehicleAction.vehicleActionMsg = .addChargeScheduleAction(schedule)

        case let .removeSchedule(id):
            var sub = CarServer_RemoveChargeScheduleAction()
            sub.id = id
            vehicleAction.vehicleActionMsg = .removeChargeScheduleAction(sub)

        case let .batchRemoveSchedules(home, work, other):
            var sub = CarServer_BatchRemoveChargeSchedulesAction()
            sub.home = home
            sub.work = work
            sub.other = other
            vehicleAction.vehicleActionMsg = .batchRemoveChargeSchedulesAction(sub)

        case let .addPreconditionSchedule(input):
            var schedule = CarServer_PreconditionSchedule()
            schedule.id = input.id
            schedule.name = input.name
            schedule.daysOfWeek = input.daysOfWeek
            schedule.preconditionTime = input.preconditionTimeMinutes
            schedule.oneTime = input.oneTime
            schedule.enabled = input.enabled
            schedule.latitude = input.latitude
            schedule.longitude = input.longitude
            vehicleAction.vehicleActionMsg = .addPreconditionScheduleAction(schedule)

        case let .removePreconditionSchedule(id):
            var sub = CarServer_RemovePreconditionScheduleAction()
            sub.id = id
            vehicleAction.vehicleActionMsg = .removePreconditionScheduleAction(sub)

        case let .batchRemovePreconditionSchedules(home, work, other):
            var sub = CarServer_BatchRemovePreconditionSchedulesAction()
            sub.home = home
            sub.work = work
            sub.other = other
            vehicleAction.vehicleActionMsg = .batchRemovePreconditionSchedulesAction(sub)

        case let .scheduleDeparture(input):
            var sub = CarServer_ScheduledDepartureAction()
            sub.enabled = true
            sub.departureTime = input.departureTimeMinutes
            sub.offPeakHoursEndTime = input.offPeakHoursEndTimeMinutes
            sub.preconditioningTimes = Self.preconditioningTimes(for: input.preconditioning)
            sub.offPeakChargingTimes = Self.offPeakChargingTimes(for: input.offpeak)
            vehicleAction.vehicleActionMsg = .scheduledDepartureAction(sub)

        case let .scheduleCharging(enabled, timeAfterMidnightMinutes):
            var sub = CarServer_ScheduledChargingAction()
            sub.enabled = enabled
            sub.chargingTime = timeAfterMidnightMinutes
            vehicleAction.vehicleActionMsg = .scheduledChargingAction(sub)

        case .clearScheduledDeparture:
            var sub = CarServer_ScheduledDepartureAction()
            sub.enabled = false
            sub.departureTime = 0
            vehicleAction.vehicleActionMsg = .scheduledDepartureAction(sub)
        }

        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }

    private static func preconditioningTimes(
        for policy: Command.Charge.ScheduleDepartureInput.ChargingPolicy,
    ) -> CarServer_PreconditioningTimes {
        var t = CarServer_PreconditioningTimes()
        switch policy {
        case .off: break
        case .allDays: t.times = .allWeek(CarServer_Void())
        case .weekdays: t.times = .weekdays(CarServer_Void())
        }
        return t
    }

    private static func offPeakChargingTimes(
        for policy: Command.Charge.ScheduleDepartureInput.ChargingPolicy,
    ) -> CarServer_OffPeakChargingTimes {
        var t = CarServer_OffPeakChargingTimes()
        switch policy {
        case .off: break
        case .allDays: t.times = .allWeek(CarServer_Void())
        case .weekdays: t.times = .weekdays(CarServer_Void())
        }
        return t
    }
}
