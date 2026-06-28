import Foundation
@testable import TeslaBLE
import XCTest

final class CommandEncoderTests: XCTestCase {
    // MARK: - Security

    func testSecurityLockEncodesRKELock() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.lock))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .rkeaction(action)? = unsigned.subMessage else {
            XCTFail("expected rkeaction"); return
        }
        XCTAssertEqual(action, .rkeActionLock)
    }

    func testSecurityUnlockEncodesRKEUnlock() throws {
        let (_, body) = try CommandEncoder.encode(.security(.unlock))
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .rkeaction(a)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(a, .rkeActionUnlock)
    }

    func testSecurityWakeAutoSecureRemoteDrive() throws {
        let cases: [(Command.Security, VCSEC_RKEAction_E)] = [
            (.wakeVehicle, .rkeActionWakeVehicle),
            (.remoteDrive, .rkeActionRemoteDrive),
            (.autoSecure, .rkeActionAutoSecureVehicle),
        ]
        for (cmd, expected) in cases {
            let (_, body) = try CommandEncoder.encode(.security(cmd))
            let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
            guard case let .rkeaction(a)? = unsigned.subMessage else {
                XCTFail("\(cmd): not an rkeaction"); continue
            }
            XCTAssertEqual(a, expected, "\(cmd)")
        }
    }

    func testSecurityOpenTrunkEncodesClosureRequest() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.openTrunk))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else {
            XCTFail("expected closureMoveRequest"); return
        }
        XCTAssertEqual(req.rearTrunk, .closureMoveTypeOpen)
    }

    func testSecurityCloseTrunkEncodesRearTrunkClose() throws {
        let (_, body) = try CommandEncoder.encode(.security(.closeTrunk))
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.rearTrunk, .closureMoveTypeClose)
    }

    func testSecurityOpenFrunkEncodesFrontTrunkOpen() throws {
        let (_, body) = try CommandEncoder.encode(.security(.openFrunk))
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.frontTrunk, .closureMoveTypeOpen)
    }

    func testSecurityAddKeyEncodesWhitelistOperation() throws {
        // 65-byte uncompressed SEC1 public key (0x04 || X || Y).
        var publicKey = Data([0x04])
        publicKey.append(Data(repeating: 0xAB, count: 32))
        publicKey.append(Data(repeating: 0xCD, count: 32))

        let (domain, body) = try CommandEncoder.encode(
            .security(.addKey(publicKey: publicKey, role: .owner, formFactor: .cloudKey)),
        )
        XCTAssertEqual(domain, .vehicleSecurity)

        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .whitelistOperation(whitelist)? = unsigned.subMessage else {
            XCTFail("expected whitelistOperation"); return
        }
        guard case let .addKeyToWhitelistAndAddPermissions(permChange)? = whitelist.subMessage else {
            XCTFail("expected addKeyToWhitelistAndAddPermissions"); return
        }
        XCTAssertEqual(permChange.key.publicKeyRaw, publicKey)
        XCTAssertEqual(permChange.keyRole, .owner)
        XCTAssertTrue(whitelist.hasMetadataForKey)
        XCTAssertEqual(whitelist.metadataForKey.keyFormFactor, .cloudKey)
    }

    func testSecurityAddKeyRejectsShortPublicKey() {
        let badKey = Data(repeating: 0x04, count: 33)
        XCTAssertThrowsError(
            try CommandEncoder.encode(
                .security(.addKey(publicKey: badKey, role: .driver, formFactor: .nfcCard)),
            ),
        ) { error in
            guard case SecurityEncoder.Error.encodingFailed = error else {
                XCTFail("expected encodingFailed, got \(error)"); return
            }
        }
    }

    // MARK: - Charge

    func testChargeStartStop() throws {
        let (startDomain, startBody) = try CommandEncoder.encode(.charge(.start))
        XCTAssertEqual(startDomain, .infotainment)
        let startAction = try CarServer_Action(serializedBytes: startBody)
        guard case let .chargingStartStopAction(startSub)? = startAction.vehicleAction.vehicleActionMsg else {
            XCTFail("expected chargingStartStopAction"); return
        }
        if case .start? = startSub.chargingAction {} else { XCTFail("expected .start") }

        let (_, stopBody) = try CommandEncoder.encode(.charge(.stop))
        let stopAction = try CarServer_Action(serializedBytes: stopBody)
        guard case let .chargingStartStopAction(stopSub)? = stopAction.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        if case .stop? = stopSub.chargingAction {} else { XCTFail("expected .stop") }
    }

    func testChargeSetLimit() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.setLimit(percent: 80)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .chargingSetLimitAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertEqual(sub.percent, 80)
    }

    func testChargeSetLimitOutOfRangeThrows() {
        XCTAssertThrowsError(try CommandEncoder.encode(.charge(.setLimit(percent: 150)))) { error in
            guard case ChargeEncoder.Error.invalidParameter = error else {
                XCTFail("expected invalidParameter, got \(error)"); return
            }
        }
    }

    func testChargeSetAmps() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.setAmps(32)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .setChargingAmpsAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.chargingAmps, 32)
    }

    func testChargePortOpenClose() throws {
        let (_, openBody) = try CommandEncoder.encode(.charge(.openPort))
        let openAction = try CarServer_Action(serializedBytes: openBody)
        if case .chargePortDoorOpen? = openAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected chargePortDoorOpen")
        }
        let (_, closeBody) = try CommandEncoder.encode(.charge(.closePort))
        let closeAction = try CarServer_Action(serializedBytes: closeBody)
        if case .chargePortDoorClose? = closeAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected chargePortDoorClose")
        }
    }

    // MARK: - Climate

    func testClimateOnOff() throws {
        let (_, onBody) = try CommandEncoder.encode(.climate(.on))
        let onAction = try CarServer_Action(serializedBytes: onBody)
        guard case let .hvacAutoAction(onSub)? = onAction.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(onSub.powerOn)

        let (_, offBody) = try CommandEncoder.encode(.climate(.off))
        let offAction = try CarServer_Action(serializedBytes: offBody)
        guard case let .hvacAutoAction(offSub)? = offAction.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertFalse(offSub.powerOn)
    }

    func testClimateSetTemperature() throws {
        let (_, body) = try CommandEncoder.encode(.climate(.setTemperature(driver: 22.5, passenger: 21.0)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacTemperatureAdjustmentAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.driverTempCelsius, 22.5)
        XCTAssertEqual(sub.passengerTempCelsius, 21.0)
    }

    // MARK: - Actions

    func testActionsHonkFlash() throws {
        let (_, honkBody) = try CommandEncoder.encode(.actions(.honk))
        let honkAction = try CarServer_Action(serializedBytes: honkBody)
        if case .vehicleControlHonkHornAction? = honkAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlHonkHornAction")
        }
        let (_, flashBody) = try CommandEncoder.encode(.actions(.flashLights))
        let flashAction = try CarServer_Action(serializedBytes: flashBody)
        if case .vehicleControlFlashLightsAction? = flashAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlFlashLightsAction")
        }
    }

    // MARK: - Phase 4b additions

    func testMediaTogglePlayback() throws {
        let (domain, body) = try CommandEncoder.encode(.media(.togglePlayback))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .mediaPlayAction? = action.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected mediaPlayAction")
        }
    }

    func testMediaNextPrevious() throws {
        let (_, nextBody) = try CommandEncoder.encode(.media(.nextTrack))
        let nextAction = try CarServer_Action(serializedBytes: nextBody)
        if case .mediaNextTrack? = nextAction.vehicleAction.vehicleActionMsg {} else { XCTFail() }

        let (_, prevBody) = try CommandEncoder.encode(.media(.previousTrack))
        let prevAction = try CarServer_Action(serializedBytes: prevBody)
        if case .mediaPreviousTrack? = prevAction.vehicleAction.vehicleActionMsg {} else { XCTFail() }
    }

    func testMediaSetVolume() throws {
        let (_, body) = try CommandEncoder.encode(.media(.setVolume(5.5)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .mediaUpdateVolume(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        if case let .volumeAbsoluteFloat(v)? = sub.mediaVolume {
            XCTAssertEqual(v, 5.5)
        } else {
            XCTFail("expected volumeAbsoluteFloat")
        }
    }

    func testMediaSetVolumeOutOfRange() {
        XCTAssertThrowsError(try CommandEncoder.encode(.media(.setVolume(99)))) { error in
            guard case MediaEncoder.Error.invalidParameter = error else { XCTFail(); return }
        }
    }

    func testSecuritySentryModeRoutesToInfotainment() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.setSentryMode(true)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlSetSentryModeAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertTrue(sub.on)
    }

    func testSecurityValetMode() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.setValetMode(enabled: true, password: "1234")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlSetValetModeAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertTrue(sub.on)
        XCTAssertEqual(sub.password, "1234")
    }

    func testClimateSteeringWheelHeater() throws {
        let (_, body) = try CommandEncoder.encode(.climate(.setSteeringWheelHeater(true)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacSteeringWheelHeaterAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertTrue(sub.powerOn)
    }

    func testClimateKeeperMode() throws {
        let (_, body) = try CommandEncoder.encode(.climate(.setKeeperMode(.dog)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacClimateKeeperAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertEqual(sub.climateKeeperAction, .climateKeeperActionDog)
    }

    func testActionsCloseWindows() throws {
        let (_, body) = try CommandEncoder.encode(.actions(.closeWindows))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlWindowAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        if case .close? = sub.action {} else { XCTFail("expected .close") }
    }

    func testActionsVentWindows() throws {
        let (_, body) = try CommandEncoder.encode(.actions(.ventWindows))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlWindowAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        if case .vent? = sub.action {} else { XCTFail("expected .vent") }
    }

    func testActionsHomelink() throws {
        let (_, body) = try CommandEncoder.encode(.actions(.triggerHomelink(latitude: 37.5, longitude: -122.3)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlTriggerHomelinkAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertEqual(sub.location.latitude, 37.5)
        XCTAssertEqual(sub.location.longitude, -122.3)
    }

    // MARK: - Wave 1 additions

    // Group A — Security VCSEC closures

    func testSecurityActuateTrunk() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.actuateTrunk))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.rearTrunk, .closureMoveTypeMove)
    }

    func testSecurityOpenTonneau() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.openTonneau))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.tonneau, .closureMoveTypeOpen)
    }

    func testSecurityCloseTonneau() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.closeTonneau))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.tonneau, .closureMoveTypeClose)
    }

    func testSecurityStopTonneau() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.stopTonneau))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .closureMoveRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.tonneau, .closureMoveTypeStop)
    }

    // Group B — Security VCSEC whitelist remove

    func testSecurityRemoveKey() throws {
        var publicKey = Data([0x04])
        publicKey.append(Data(repeating: 0x11, count: 32))
        publicKey.append(Data(repeating: 0x22, count: 32))

        let (domain, body) = try CommandEncoder.encode(.security(.removeKey(publicKey: publicKey)))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .whitelistOperation(whitelist)? = unsigned.subMessage else { XCTFail(); return }
        guard case let .removePublicKeyFromWhitelist(pk)? = whitelist.subMessage else { XCTFail(); return }
        XCTAssertEqual(pk.publicKeyRaw, publicKey)
    }

    func testSecurityRemoveKeyRejectsShortKey() {
        let badKey = Data(repeating: 0x04, count: 33)
        XCTAssertThrowsError(try CommandEncoder.encode(.security(.removeKey(publicKey: badKey)))) { error in
            guard case SecurityEncoder.Error.encodingFailed = error else { XCTFail(); return }
        }
    }

    // Group C — Security Infotainment eraseGuestData

    func testSecurityEraseGuestData() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.eraseGuestData(reason: "test")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .eraseUserDataAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.reason, "test")
    }

    // Group D — Actions sunroof

    func testActionsChangeSunroof() throws {
        let (domain, body) = try CommandEncoder.encode(.actions(.changeSunroof(level: 50)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlSunroofOpenCloseAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        guard case let .absoluteLevel(level)? = sub.sunroofLevel else { XCTFail(); return }
        XCTAssertEqual(level, 50)
    }

    // Group E — Climate advanced

    func testClimateSetPreconditioningMax() throws {
        let (domain, body) = try CommandEncoder.encode(.climate(.setPreconditioningMax(enabled: true, manualOverride: true)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacSetPreconditioningMaxAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(sub.on)
        XCTAssertTrue(sub.manualOverride)
    }

    func testClimateSetBioweaponDefenseMode() throws {
        let (domain, body) = try CommandEncoder.encode(.climate(.setBioweaponDefenseMode(enabled: true, manualOverride: false)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacBioweaponModeAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(sub.on)
        XCTAssertFalse(sub.manualOverride)
    }

    func testClimateSetCabinOverheatProtection() throws {
        let (domain, body) = try CommandEncoder.encode(.climate(.setCabinOverheatProtection(enabled: true, fanOnly: true)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .setCabinOverheatProtectionAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(sub.on)
        XCTAssertTrue(sub.fanOnly)
    }

    // Group I — Cabin overheat temperature level

    func testClimateSetCabinOverheatProtectionTemperature() throws {
        let (domain, body) = try CommandEncoder.encode(.climate(.setCabinOverheatProtectionTemperature(level: .medium)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .setCopTempAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.copActivationTemp, .medium)
    }

    // Group F — Charge power modes

    func testChargeSetLowPowerMode() throws {
        let (domain, body) = try CommandEncoder.encode(.charge(.setLowPowerMode(true)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .setLowPowerModeAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(sub.lowPowerMode)
    }

    func testChargeSetKeepAccessoryPowerMode() throws {
        let (domain, body) = try CommandEncoder.encode(.charge(.setKeepAccessoryPowerMode(false)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .setKeepAccessoryPowerModeAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertFalse(sub.keepAccessoryPowerMode)
    }

    // Group G — Media relative volume and favorites

    func testMediaVolumeUp() throws {
        let (domain, body) = try CommandEncoder.encode(.media(.volumeUp))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .mediaUpdateVolume(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        guard case let .volumeDelta(delta)? = sub.mediaVolume else { XCTFail(); return }
        XCTAssertEqual(delta, 1)
    }

    func testMediaVolumeDown() throws {
        let (domain, body) = try CommandEncoder.encode(.media(.volumeDown))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .mediaUpdateVolume(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        guard case let .volumeDelta(delta)? = sub.mediaVolume else { XCTFail(); return }
        XCTAssertEqual(delta, -1)
    }

    func testMediaNextFavorite() throws {
        let (domain, body) = try CommandEncoder.encode(.media(.nextFavorite))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .mediaNextFavorite? = action.vehicleAction.vehicleActionMsg {} else { XCTFail() }
    }

    func testMediaPreviousFavorite() throws {
        let (domain, body) = try CommandEncoder.encode(.media(.previousFavorite))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .mediaPreviousFavorite? = action.vehicleAction.vehicleActionMsg {} else { XCTFail() }
    }

    // Group H — Infotainment (software update / vehicle name)

    func testInfotainmentScheduleSoftwareUpdate() throws {
        let (domain, body) = try CommandEncoder.encode(.infotainment(.scheduleSoftwareUpdate(offsetSeconds: 300)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlScheduleSoftwareUpdateAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.offsetSec, 300)
    }

    func testInfotainmentCancelSoftwareUpdate() throws {
        let (domain, body) = try CommandEncoder.encode(.infotainment(.cancelSoftwareUpdate))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .vehicleControlCancelSoftwareUpdateAction? = action.vehicleAction.vehicleActionMsg {} else { XCTFail() }
    }

    func testInfotainmentSetVehicleName() throws {
        let (domain, body) = try CommandEncoder.encode(.infotainment(.setVehicleName("My Tesla")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .setVehicleNameAction(sub)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.vehicleName, "My Tesla")
    }

    // MARK: - StateQuery

    func testStateQueryDriveOnly() throws {
        let body = try StateQueryEncoder.encode(.driveOnly)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .getVehicleData(get)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(get.hasGetDriveState)
        XCTAssertFalse(get.hasGetChargeState)
    }

    func testStateQueryAllIncludesCharge() throws {
        let body = try StateQueryEncoder.encode(.all)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .getVehicleData(get)? = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(get.hasGetDriveState)
        XCTAssertTrue(get.hasGetChargeState)
        XCTAssertTrue(get.hasGetClimateState)
    }

    // MARK: - ResponseDecoder

    func testResponseDecoderInfotainmentOk() throws {
        var status = CarServer_ActionStatus()
        status.result = .operationstatusOk
        var response = CarServer_Response()
        response.actionStatus = status
        let bytes = try response.serializedData()

        let result = try ResponseDecoder.decodeInfotainment(bytes)
        XCTAssertEqual(result, .ok)
    }

    func testResponseDecoderInfotainmentError() throws {
        var status = CarServer_ActionStatus()
        status.result = .rror
        var response = CarServer_Response()
        response.actionStatus = status
        let bytes = try response.serializedData()

        let result = try ResponseDecoder.decodeInfotainment(bytes)
        guard case .vehicleError = result else {
            XCTFail("expected vehicleError, got \(result)"); return
        }
    }

    func testResponseDecoderVCSECOk() throws {
        var response = VCSEC_FromVCSECMessage()
        var status = VCSEC_CommandStatus()
        status.operationStatus = .operationstatusOk
        response.commandStatus = status
        let bytes = try response.serializedData()

        let result = try ResponseDecoder.decodeVCSEC(bytes)
        XCTAssertEqual(result, .ok)
    }

    // MARK: - Group J: PIN-protected security (10)

    func testSecurityResetPin() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.resetPin))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .vehicleControlResetPinToDriveAction? = action.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlResetPinToDriveAction")
        }
    }

    func testSecurityResetValetPin() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.resetValetPin))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .vehicleControlResetValetPinAction? = action.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlResetValetPinAction")
        }
    }

    func testSecuritySetGuestMode() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.setGuestMode(true)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .guestModeAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected guestModeAction"); return
        }
        XCTAssertTrue(sub.guestModeActive)
    }

    func testSecuritySetPinToDrive() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.setPinToDrive(enabled: true, password: "1234")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .vehicleControlSetPinToDriveAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected vehicleControlSetPinToDriveAction"); return
        }
        XCTAssertTrue(sub.on)
        XCTAssertEqual(sub.password, "1234")
    }

    func testSecurityClearPinToDrive() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.clearPinToDrive))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .vehicleControlResetPinToDriveAdminAction? = action.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlResetPinToDriveAdminAction")
        }
    }

    func testSecurityActivateSpeedLimit() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.activateSpeedLimit(pin: "5678")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .drivingSpeedLimitAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected drivingSpeedLimitAction"); return
        }
        XCTAssertTrue(sub.activate)
        XCTAssertEqual(sub.pin, "5678")
    }

    func testSecurityDeactivateSpeedLimit() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.deactivateSpeedLimit(pin: "5678")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .drivingSpeedLimitAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected drivingSpeedLimitAction"); return
        }
        XCTAssertFalse(sub.activate)
        XCTAssertEqual(sub.pin, "5678")
    }

    func testSecuritySetSpeedLimit() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.setSpeedLimit(mph: 65.5)))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .drivingSetSpeedLimitAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected drivingSetSpeedLimitAction"); return
        }
        XCTAssertEqual(sub.limitMph, 65.5, accuracy: 0.001)
    }

    func testSecurityClearSpeedLimitPin() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.clearSpeedLimitPin(pin: "9999")))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .drivingClearSpeedLimitPinAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected drivingClearSpeedLimitPinAction"); return
        }
        XCTAssertEqual(sub.pin, "9999")
    }

    func testSecurityClearSpeedLimitPinAdmin() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.clearSpeedLimitPinAdmin))
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        if case .drivingClearSpeedLimitPinAdminAction? = action.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected drivingClearSpeedLimitPinAdminAction")
        }
    }

    // MARK: - Group K: Charge schedules (9)

    func testChargeAddSchedule() throws {
        let input = Command.Charge.ChargeScheduleInput(
            id: 1_234_567_890,
            name: "home",
            daysOfWeek: 0b1111111,
            startEnabled: true,
            startTimeMinutes: 7 * 60,
            endEnabled: true,
            endTimeMinutes: 9 * 60,
            enabled: true,
        )
        let (_, body) = try CommandEncoder.encode(.charge(.addSchedule(input)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .addChargeScheduleAction(schedule)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected addChargeScheduleAction"); return
        }
        XCTAssertEqual(schedule.id, 1_234_567_890)
        XCTAssertEqual(schedule.name, "home")
        XCTAssertEqual(schedule.startTime, 7 * 60)
        XCTAssertEqual(schedule.endTime, 9 * 60)
        XCTAssertTrue(schedule.enabled)
        XCTAssertTrue(schedule.startEnabled)
        XCTAssertTrue(schedule.endEnabled)
    }

    func testChargeRemoveSchedule() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.removeSchedule(id: 42)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .removeChargeScheduleAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected removeChargeScheduleAction"); return
        }
        XCTAssertEqual(sub.id, 42)
    }

    func testChargeBatchRemoveSchedules() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.batchRemoveSchedules(home: true, work: false, other: true)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .batchRemoveChargeSchedulesAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected batchRemoveChargeSchedulesAction"); return
        }
        XCTAssertTrue(sub.home)
        XCTAssertFalse(sub.work)
        XCTAssertTrue(sub.other)
    }

    func testChargeAddPreconditionSchedule() throws {
        let input = Command.Charge.PreconditionScheduleInput(
            id: 99,
            name: "morning",
            daysOfWeek: 0b0011111,
            preconditionTimeMinutes: 6 * 60 + 30,
            oneTime: false,
            enabled: true,
        )
        let (_, body) = try CommandEncoder.encode(.charge(.addPreconditionSchedule(input)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .addPreconditionScheduleAction(schedule)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected addPreconditionScheduleAction"); return
        }
        XCTAssertEqual(schedule.id, 99)
        XCTAssertEqual(schedule.name, "morning")
        XCTAssertEqual(schedule.preconditionTime, 6 * 60 + 30)
        XCTAssertTrue(schedule.enabled)
    }

    func testChargeRemovePreconditionSchedule() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.removePreconditionSchedule(id: 77)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .removePreconditionScheduleAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected removePreconditionScheduleAction"); return
        }
        XCTAssertEqual(sub.id, 77)
    }

    func testChargeBatchRemovePreconditionSchedules() throws {
        let (_, body) = try CommandEncoder.encode(
            .charge(.batchRemovePreconditionSchedules(home: false, work: true, other: true)),
        )
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .batchRemovePreconditionSchedulesAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected batchRemovePreconditionSchedulesAction"); return
        }
        XCTAssertFalse(sub.home)
        XCTAssertTrue(sub.work)
        XCTAssertTrue(sub.other)
    }

    func testChargeScheduleDeparture() throws {
        let input = Command.Charge.ScheduleDepartureInput(
            departureTimeMinutes: 8 * 60,
            offPeakHoursEndTimeMinutes: 7 * 60,
            preconditioning: .weekdays,
            offpeak: .allDays,
        )
        let (_, body) = try CommandEncoder.encode(.charge(.scheduleDeparture(input)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .scheduledDepartureAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected scheduledDepartureAction"); return
        }
        XCTAssertTrue(sub.enabled)
        XCTAssertEqual(sub.departureTime, 8 * 60)
        XCTAssertEqual(sub.offPeakHoursEndTime, 7 * 60)
        if case .weekdays? = sub.preconditioningTimes.times {} else {
            XCTFail("expected preconditioningTimes .weekdays")
        }
        if case .allWeek? = sub.offPeakChargingTimes.times {} else {
            XCTFail("expected offPeakChargingTimes .allWeek")
        }
    }

    func testChargeScheduleCharging() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.scheduleCharging(enabled: true, timeAfterMidnightMinutes: 120)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .scheduledChargingAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected scheduledChargingAction"); return
        }
        XCTAssertTrue(sub.enabled)
        XCTAssertEqual(sub.chargingTime, 120)
    }

    func testChargeClearScheduledDeparture() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.clearScheduledDeparture))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .scheduledDepartureAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected scheduledDepartureAction"); return
        }
        XCTAssertFalse(sub.enabled)
        XCTAssertEqual(sub.departureTime, 0)
    }

    // MARK: - Group L: Climate seats & auto (3)

    func testClimateSetSeatHeater() throws {
        let (_, body) = try CommandEncoder.encode(.climate(.setSeatHeater(level: .high, seat: .frontLeft)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacSeatHeaterActions(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected hvacSeatHeaterActions"); return
        }
        XCTAssertEqual(sub.hvacSeatHeaterAction.count, 1)
        let item = sub.hvacSeatHeaterAction[0]
        if case .seatHeaterHigh? = item.seatHeaterLevel {} else { XCTFail("expected seatHeaterHigh") }
        if case .carSeatFrontLeft? = item.seatPosition {} else { XCTFail("expected carSeatFrontLeft") }
    }

    func testClimateSetSeatCooler() throws {
        let (_, body) = try CommandEncoder.encode(.climate(.setSeatCooler(level: .medium, seat: .frontRight)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .hvacSeatCoolerActions(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected hvacSeatCoolerActions"); return
        }
        XCTAssertEqual(sub.hvacSeatCoolerAction.count, 1)
        let item = sub.hvacSeatCoolerAction[0]
        XCTAssertEqual(item.seatCoolerLevel, .hvacSeatCoolerLevelMed)
        XCTAssertEqual(item.seatPosition, .hvacSeatCoolerPositionFrontRight)
    }

    func testClimateAutoSeatAndClimate() throws {
        let (_, body) = try CommandEncoder.encode(
            .climate(.autoSeatAndClimate(enabled: true, positions: [.frontLeft, .frontRight])),
        )
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .autoSeatClimateAction(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail("expected autoSeatClimateAction"); return
        }
        XCTAssertEqual(sub.carseat.count, 2)
        XCTAssertTrue(sub.carseat.allSatisfy(\.on))
        let positions = Set(sub.carseat.map(\.seatPosition))
        XCTAssertTrue(positions.contains(.autoSeatPositionFrontLeft))
        XCTAssertTrue(positions.contains(.autoSeatPositionFrontRight))
    }

    // MARK: - VehicleQuery encoder + decoder

    func testQueryKeySummaryEncodesInformationRequest() throws {
        let (domain, body) = try VehicleQueryEncoder.encode(.keySummary)
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .informationRequest(req)? = unsigned.subMessage else {
            XCTFail("expected informationRequest"); return
        }
        XCTAssertEqual(req.informationRequestType, .getWhitelistInfo)
    }

    func testQueryKeyInfoEncodesSlot() throws {
        let (domain, body) = try VehicleQueryEncoder.encode(.keyInfo(slot: 3))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .informationRequest(req)? = unsigned.subMessage else {
            XCTFail(); return
        }
        XCTAssertEqual(req.informationRequestType, .getWhitelistEntryInfo)
        if case let .slot(s)? = req.key {
            XCTAssertEqual(s, 3)
        } else {
            XCTFail("expected slot key")
        }
    }

    func testQueryBodyControllerStateEncoding() throws {
        let (domain, body) = try VehicleQueryEncoder.encode(.bodyControllerState)
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case let .informationRequest(req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.informationRequestType, .getStatus)
    }

    func testQueryNearbyChargingEncoding() throws {
        let (domain, body) = try VehicleQueryEncoder.encode(
            .nearbyCharging(includeMetadata: true, radiusMiles: 50, count: 10),
        )
        XCTAssertEqual(domain, .infotainment)
        let action = try CarServer_Action(serializedBytes: body)
        guard case let .getNearbyChargingSites(sub)? = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertTrue(sub.includeMetaData)
        XCTAssertEqual(sub.radius, 50)
        XCTAssertEqual(sub.count, 10)
    }

    func testQueryDecodeKeySummaryFromFromVCSEC() throws {
        var whitelist = VCSEC_WhitelistInfo()
        whitelist.numberOfEntries = 2
        var from = VCSEC_FromVCSECMessage()
        from.whitelistInfo = whitelist
        let bytes = try from.serializedData()

        let result = try VehicleQueryDecoder.decode(.keySummary, from: bytes)
        guard case let .keySummary(info) = result else {
            XCTFail("expected .keySummary"); return
        }
        XCTAssertEqual(info.numberOfEntries, 2)
    }

    func testQueryDecodeBodyControllerStateFromFromVCSEC() throws {
        var status = VCSEC_VehicleStatus()
        status.vehicleLockState = .vehiclelockstateLocked
        var from = VCSEC_FromVCSECMessage()
        from.vehicleStatus = status
        let bytes = try from.serializedData()

        let result = try VehicleQueryDecoder.decode(.bodyControllerState, from: bytes)
        guard case let .bodyControllerState(decoded) = result else {
            XCTFail("expected .bodyControllerState"); return
        }
        XCTAssertEqual(decoded.vehicleLockState, .vehiclelockstateLocked)
    }

    func testQueryDecodeRejectsWrongSubMessage() {
        var cmdStatus = VCSEC_CommandStatus()
        cmdStatus.operationStatus = .operationstatusOk
        var from = VCSEC_FromVCSECMessage()
        from.commandStatus = cmdStatus
        let bytes = (try? from.serializedData()) ?? Data()

        XCTAssertThrowsError(try VehicleQueryDecoder.decode(.keySummary, from: bytes)) { error in
            guard case VehicleQueryDecoder.Error.unexpectedMessageType = error else {
                XCTFail("expected unexpectedMessageType, got \(error)"); return
            }
        }
    }
}
