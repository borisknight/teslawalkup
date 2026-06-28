import Foundation
import SwiftProtobuf

// MARK: - VehicleSnapshotMapper

/// Internal bridge from `CarServer_*` protobuf types to the public Swift-native
/// model types in this module.
///
/// This is the only file inside `Sources/` that references `CarServer_*`
/// protobuf types; every other layer works exclusively with the Swift-native
/// models so the protobuf surface never leaks into public API.
enum VehicleSnapshotMapper {
    // MARK: - Public API

    static func map(_ data: CarServer_VehicleData) -> TeslaVehicleSnapshot {
        TeslaVehicleSnapshot(
            charge: data.hasChargeState ? mapCharge(data.chargeState) : nil,
            climate: data.hasClimateState ? mapClimate(data.climateState) : nil,
            drive: data.hasDriveState ? mapDrive(data.driveState) : nil,
            closures: data.hasClosuresState ? mapClosures(data.closuresState) : nil,
            tirePressure: data.hasTirePressureState ? mapTirePressure(data.tirePressureState) : nil,
            media: data.hasMediaState ? mapMedia(data.mediaState) : nil,
            mediaDetail: data.hasMediaDetailState ? mapMediaDetail(data.mediaDetailState) : nil,
            softwareUpdate: data.hasSoftwareUpdateState ? mapSoftwareUpdate(data.softwareUpdateState) : nil,
            chargeSchedule: data.hasChargeScheduleState ? ChargeScheduleState() : nil,
            preconditionSchedule: data.hasPreconditioningScheduleState ? PreconditionScheduleState() : nil,
            parentalControls: data.hasParentalControlsState ? mapParentalControls(data.parentalControlsState) : nil,
        )
    }

    /// Fast path used by high-frequency drive-state polls: extracts only the
    /// drive sub-section from a full `CarServer_VehicleData` payload and
    /// returns an empty `DriveState` if none is present.
    static func mapDrive(_ data: CarServer_VehicleData) -> DriveState {
        guard data.hasDriveState else { return DriveState() }
        return mapDrive(data.driveState)
    }

    // MARK: - Sub-state mappers

    private static func mapCharge(_ pb: CarServer_ChargeState) -> ChargeState {
        ChargeState(
            batteryLevel: Int(pb.batteryLevel),
            batteryRangeMiles: Double(pb.batteryRange),
            estBatteryRangeMiles: Double(pb.estBatteryRange),
            chargingStatus: mapChargingStatus(pb.chargingState),
            chargerVoltage: Int(pb.chargerVoltage),
            chargerCurrent: Int(pb.chargerActualCurrent),
            chargerPower: Int(pb.chargerPower),
            chargeLimitPercent: Int(pb.chargeLimitSoc),
            minutesToFullCharge: Int(pb.minutesToFullCharge),
            chargeRateMph: Double(pb.chargeRateMph),
            chargePortOpen: pb.chargePortDoorOpen,
            chargePortLatched: nil,
        )
    }

    private static func mapClimate(_ pb: CarServer_ClimateState) -> ClimateState {
        ClimateState(
            insideTempCelsius: Double(pb.insideTempCelsius),
            outsideTempCelsius: Double(pb.outsideTempCelsius),
            driverTempSettingCelsius: Double(pb.driverTempSetting),
            passengerTempSettingCelsius: Double(pb.passengerTempSetting),
            fanStatus: Int(pb.fanStatus),
            isClimateOn: pb.isClimateOn,
            seatHeaterFrontLeft: mapSeatHeater(pb.seatHeaterLeft),
            seatHeaterFrontRight: mapSeatHeater(pb.seatHeaterRight),
            seatHeaterRearLeft: mapSeatHeater(pb.seatHeaterRearLeft),
            seatHeaterRearCenter: mapSeatHeater(pb.seatHeaterRearCenter),
            seatHeaterRearRight: mapSeatHeater(pb.seatHeaterRearRight),
            steeringWheelHeater: pb.steeringWheelHeater,
            isBatteryHeaterOn: pb.batteryHeater,
            defrostOn: mapDefrost(pb.defrostMode),
            bioweaponMode: pb.bioweaponModeOn,
        )
    }

    private static func mapDrive(_ pb: CarServer_DriveState) -> DriveState {
        let shiftState = mapShift(pb.shiftState)
        let speedMph: Double? = pb.optionalSpeedFloat != nil ? Double(pb.speedFloat) : nil
        let powerKW: Int? = pb.optionalPower != nil ? Int(pb.power) : nil
        let odometerHundredthsMile: Int? = pb.optionalOdometerInHundredthsOfAMile != nil
            ? Int(pb.odometerInHundredthsOfAMile) : nil
        let destination: String? = pb.optionalActiveRouteDestination != nil
            ? pb.activeRouteDestination : nil
        let minutesToArrival: Double? = pb.optionalActiveRouteMinutesToArrival != nil
            ? Double(pb.activeRouteMinutesToArrival) : nil
        let milesToArrival: Double? = pb.optionalActiveRouteMilesToArrival != nil
            ? Double(pb.activeRouteMilesToArrival) : nil

        return DriveState(
            shiftState: shiftState,
            speedMph: speedMph,
            powerKW: powerKW,
            odometerHundredthsMile: odometerHundredthsMile,
            activeRouteDestination: destination,
            activeRouteMinutesToArrival: minutesToArrival,
            activeRouteMilesToArrival: milesToArrival,
        )
    }

    private static func mapClosures(_ pb: CarServer_ClosuresState) -> ClosuresState {
        let sunroofState: ClosuresState.SunroofState? = pb.hasSunRoofState
            ? mapSunroof(pb.sunRoofState) : nil
        let sunroofPercentOpen: Int? = pb.optionalSunRoofPercentOpen != nil
            ? Int(pb.sunRoofPercentOpen) : nil
        let sentryModeActive: Bool? = pb.hasSentryModeState
            ? mapSentry(pb.sentryModeState) : nil

        return ClosuresState(
            frontDriverDoor: pb.optionalDoorOpenDriverFront != nil ? pb.doorOpenDriverFront : nil,
            frontPassengerDoor: pb.optionalDoorOpenPassengerFront != nil ? pb.doorOpenPassengerFront : nil,
            rearDriverDoor: pb.optionalDoorOpenDriverRear != nil ? pb.doorOpenDriverRear : nil,
            rearPassengerDoor: pb.optionalDoorOpenPassengerRear != nil ? pb.doorOpenPassengerRear : nil,
            frontTrunk: pb.optionalDoorOpenTrunkFront != nil ? pb.doorOpenTrunkFront : nil,
            rearTrunk: pb.optionalDoorOpenTrunkRear != nil ? pb.doorOpenTrunkRear : nil,
            locked: pb.optionalLocked != nil ? pb.locked : nil,
            windowDriverFront: pb.optionalWindowOpenDriverFront != nil ? pb.windowOpenDriverFront : nil,
            windowPassengerFront: pb.optionalWindowOpenPassengerFront != nil ? pb.windowOpenPassengerFront : nil,
            windowDriverRear: pb.optionalWindowOpenDriverRear != nil ? pb.windowOpenDriverRear : nil,
            windowPassengerRear: pb.optionalWindowOpenPassengerRear != nil ? pb.windowOpenPassengerRear : nil,
            sunroofState: sunroofState,
            sunroofPercentOpen: sunroofPercentOpen,
            sentryModeActive: sentryModeActive,
            valetMode: pb.optionalValetMode != nil ? pb.valetMode : nil,
            isUserPresent: pb.optionalIsUserPresent != nil ? pb.isUserPresent : nil,
        )
    }

    private static func mapTirePressure(_ pb: CarServer_TirePressureState) -> TirePressureState {
        TirePressureState(
            frontLeft: TirePressureState.Tire(
                pressureBar: pb.optionalTpmsPressureFl != nil ? Double(pb.tpmsPressureFl) : nil,
                hasWarning: pb.optionalTpmsHardWarningFl != nil || pb.optionalTpmsSoftWarningFl != nil
                    ? (pb.tpmsHardWarningFl || pb.tpmsSoftWarningFl) : nil,
            ),
            frontRight: TirePressureState.Tire(
                pressureBar: pb.optionalTpmsPressureFr != nil ? Double(pb.tpmsPressureFr) : nil,
                hasWarning: pb.optionalTpmsHardWarningFr != nil || pb.optionalTpmsSoftWarningFr != nil
                    ? (pb.tpmsHardWarningFr || pb.tpmsSoftWarningFr) : nil,
            ),
            rearLeft: TirePressureState.Tire(
                pressureBar: pb.optionalTpmsPressureRl != nil ? Double(pb.tpmsPressureRl) : nil,
                hasWarning: pb.optionalTpmsHardWarningRl != nil || pb.optionalTpmsSoftWarningRl != nil
                    ? (pb.tpmsHardWarningRl || pb.tpmsSoftWarningRl) : nil,
            ),
            rearRight: TirePressureState.Tire(
                pressureBar: pb.optionalTpmsPressureRr != nil ? Double(pb.tpmsPressureRr) : nil,
                hasWarning: pb.optionalTpmsHardWarningRr != nil || pb.optionalTpmsSoftWarningRr != nil
                    ? (pb.tpmsHardWarningRr || pb.tpmsSoftWarningRr) : nil,
            ),
            recommendedColdFrontBar: pb.optionalTpmsRcpFrontValue != nil
                ? Double(pb.tpmsRcpFrontValue) : nil,
            recommendedColdRearBar: pb.optionalTpmsRcpRearValue != nil
                ? Double(pb.tpmsRcpRearValue) : nil,
        )
    }

    private static func mapMedia(_ pb: CarServer_MediaState) -> MediaState {
        MediaState(
            nowPlayingArtist: pb.optionalNowPlayingArtist != nil ? pb.nowPlayingArtist : nil,
            nowPlayingTitle: pb.optionalNowPlayingTitle != nil ? pb.nowPlayingTitle : nil,
            audioVolume: pb.optionalAudioVolume != nil ? Double(pb.audioVolume) : nil,
            audioVolumeMax: pb.optionalAudioVolumeMax != nil ? Double(pb.audioVolumeMax) : nil,
            remoteControlEnabled: pb.optionalRemoteControlEnabled != nil
                ? pb.remoteControlEnabled : nil,
        )
    }

    private static func mapMediaDetail(_ pb: CarServer_MediaDetailState) -> MediaDetailState {
        MediaDetailState(
            nowPlayingDurationSeconds: pb.optionalNowPlayingDuration != nil
                ? Double(pb.nowPlayingDuration) : nil,
            nowPlayingElapsedSeconds: pb.optionalNowPlayingElapsed != nil
                ? Double(pb.nowPlayingElapsed) : nil,
            nowPlayingAlbum: pb.optionalNowPlayingAlbum != nil ? pb.nowPlayingAlbum : nil,
            nowPlayingStation: pb.optionalNowPlayingStation != nil ? pb.nowPlayingStation : nil,
            nowPlayingSource: pb.optionalNowPlayingSourceString != nil
                ? pb.nowPlayingSourceString : nil,
            a2dpSourceName: pb.optionalA2DpSourceName != nil ? pb.a2DpSourceName : nil,
        )
    }

    private static func mapSoftwareUpdate(_ pb: CarServer_SoftwareUpdateState) -> SoftwareUpdateState {
        SoftwareUpdateState(
            version: pb.optionalVersion != nil ? pb.version : nil,
            downloadPercent: pb.optionalDownloadPerc != nil ? Int(pb.downloadPerc) : nil,
            installPercent: pb.optionalInstallPerc != nil ? Int(pb.installPerc) : nil,
            expectedDurationSeconds: pb.optionalExpectedDurationSec != nil
                ? Int(pb.expectedDurationSec) : nil,
        )
    }

    private static func mapParentalControls(_ pb: CarServer_ParentalControlsState) -> ParentalControlsState {
        ParentalControlsState(
            active: pb.optionalParentalControlsActive != nil ? pb.parentalControlsActive : nil,
            pinSet: pb.optionalParentalControlsPinSet != nil ? pb.parentalControlsPinSet : nil,
        )
    }

    // MARK: - Enum helpers

    private static func mapChargingStatus(
        _ pb: CarServer_ChargeState.ChargingState,
    ) -> ChargeState.ChargingStatus? {
        guard let type = pb.type else { return nil }
        switch type {
        case .disconnected: return .disconnected
        case .charging: return .charging
        case .complete: return .complete
        case .stopped: return .stopped
        case .starting: return .starting
        case .unknown, .noPower, .calibrating: return .disconnected
        }
    }

    private static func mapShift(_ pb: CarServer_ShiftState) -> DriveState.ShiftState? {
        guard let type = pb.type else { return nil }
        switch type {
        case .p: return .park
        case .r: return .reverse
        case .n: return .neutral
        case .d: return .drive
        case .invalid, .sna: return nil
        }
    }

    private static func mapSunroof(
        _ pb: CarServer_ClosuresState.SunRoofState,
    ) -> ClosuresState.SunroofState? {
        guard let type = pb.type else { return nil }
        switch type {
        case .closed: return .closed
        case .open: return .open
        case .vent: return .vent
        case .moving: return .moving
        case .calibrating: return .calibrating
        case .unknown: return .unknown
        }
    }

    private static func mapSentry(
        _ pb: CarServer_ClosuresState.SentryModeState,
    ) -> Bool? {
        guard let type = pb.type else { return nil }
        switch type {
        case .off: return false
        case .idle, .armed, .aware, .panic, .quiet: return true
        }
    }

    private static func mapDefrost(
        _ pb: CarServer_ClimateState.DefrostMode,
    ) -> Bool? {
        guard let type = pb.type else { return nil }
        switch type {
        case .off: return false
        case .normal, .max: return true
        }
    }

    private static func mapSeatHeater(_ rawLevel: Int32) -> ClimateState.SeatHeaterLevel? {
        ClimateState.SeatHeaterLevel(rawValue: Int(rawLevel))
    }
}
