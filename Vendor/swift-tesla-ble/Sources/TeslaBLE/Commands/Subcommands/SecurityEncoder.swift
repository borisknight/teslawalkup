import Foundation
import SwiftProtobuf

/// Builds bodies for all `Command.Security` cases. Unique among the
/// per-area encoders: returns `(domain, body)` because Security cases span
/// two domains. VCSEC closures and RKE actions (lock/unlock/trunk/tonneau)
/// plus whitelist key ops emit `VCSEC_UnsignedMessage`; sentry/valet/PIN/
/// guest-mode/speed-limit cases emit `CarServer_Action` on Infotainment.
/// Tesla splits these by hardware — closures live on VCSEC, driver-facing
/// policy lives on Infotainment — so this encoder straddles both.
enum SecurityEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization failed or input validation rejected a key.
        case encodingFailed(String)
    }

    static func encode(_ command: Command.Security) throws -> (domain: UniversalMessage_Domain, body: Data) {
        switch command {
        // MARK: - VCSEC: Closures & RKE

        case .lock, .unlock, .wakeVehicle, .remoteDrive, .autoSecure,
             .openTrunk, .closeTrunk, .openFrunk, .openDriverDoor,
             .actuateTrunk, .openTonneau, .closeTonneau, .stopTonneau:
            let body = try encodeVCSEC(command)
            return (.vehicleSecurity, body)

        // MARK: - VCSEC: Whitelist

        case let .addKey(publicKey, role, formFactor):
            let body = try encodeAddKey(publicKey: publicKey, role: role, formFactor: formFactor)
            return (.vehicleSecurity, body)

        case let .removeKey(publicKey):
            let body = try encodeRemoveKey(publicKey: publicKey)
            return (.vehicleSecurity, body)

        // MARK: - Infotainment: Sentry, Valet, Guest

        case let .setSentryMode(on):
            var sub = CarServer_VehicleControlSetSentryModeAction()
            sub.on = on
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .vehicleControlSetSentryModeAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .setValetMode(enabled, password):
            var sub = CarServer_VehicleControlSetValetModeAction()
            sub.on = enabled
            sub.password = password
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .vehicleControlSetValetModeAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .eraseGuestData(reason):
            var sub = CarServer_EraseUserDataAction()
            sub.reason = reason
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .eraseUserDataAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        // MARK: - Infotainment: PIN & Speed Limit

        case .resetPin:
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .vehicleControlResetPinToDriveAction(
                CarServer_VehicleControlResetPinToDriveAction(),
            )
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case .resetValetPin:
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .vehicleControlResetValetPinAction(
                CarServer_VehicleControlResetValetPinAction(),
            )
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .setGuestMode(on):
            var sub = CarServer_VehicleState.GuestMode()
            sub.guestModeActive = on
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .guestModeAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .setPinToDrive(enabled, password):
            var sub = CarServer_VehicleControlSetPinToDriveAction()
            sub.on = enabled
            sub.password = password
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .vehicleControlSetPinToDriveAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case .clearPinToDrive:
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .vehicleControlResetPinToDriveAdminAction(
                CarServer_VehicleControlResetPinToDriveAdminAction(),
            )
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .activateSpeedLimit(pin):
            var sub = CarServer_DrivingSpeedLimitAction()
            sub.activate = true
            sub.pin = pin
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .drivingSpeedLimitAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .deactivateSpeedLimit(pin):
            var sub = CarServer_DrivingSpeedLimitAction()
            sub.activate = false
            sub.pin = pin
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .drivingSpeedLimitAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .setSpeedLimit(mph):
            var sub = CarServer_DrivingSetSpeedLimitAction()
            sub.limitMph = mph
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .drivingSetSpeedLimitAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case let .clearSpeedLimitPin(pin):
            var sub = CarServer_DrivingClearSpeedLimitPinAction()
            sub.pin = pin
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .drivingClearSpeedLimitPinAction(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))

        case .clearSpeedLimitPinAdmin:
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .drivingClearSpeedLimitPinAdminAction(
                CarServer_DrivingClearSpeedLimitPinAdminAction(),
            )
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))
        }
    }

    /// Produces the unsigned `WhitelistOperation.addKeyToWhitelistAndAddPermissions`
    /// payload — must go out the unsigned dispatcher path because this command
    /// is what bootstraps the session. See `Command.Security.addKey` for the
    /// pairing flow.
    private static func encodeAddKey(
        publicKey: Data,
        role: Command.KeyRole,
        formFactor: Command.KeyFormFactor,
    ) throws -> Data {
        guard publicKey.count == 65 else {
            throw Error.encodingFailed("addKey publicKey must be 65-byte uncompressed SEC1 (got \(publicKey.count))")
        }
        var pubKey = VCSEC_PublicKey()
        pubKey.publicKeyRaw = publicKey

        var permChange = VCSEC_PermissionChange()
        permChange.key = pubKey
        permChange.keyRole = Self.mapRole(role)

        var whitelist = VCSEC_WhitelistOperation()
        whitelist.subMessage = .addKeyToWhitelistAndAddPermissions(permChange)
        var metadata = VCSEC_KeyMetadata()
        metadata.keyFormFactor = Self.mapFormFactor(formFactor)
        whitelist.metadataForKey = metadata

        var unsigned = VCSEC_UnsignedMessage()
        unsigned.subMessage = .whitelistOperation(whitelist)
        return try serialize(unsigned)
    }

    private static func encodeRemoveKey(publicKey: Data) throws -> Data {
        guard publicKey.count == 65 else {
            throw Error.encodingFailed("removeKey publicKey must be 65-byte uncompressed SEC1 (got \(publicKey.count))")
        }
        var pubKey = VCSEC_PublicKey()
        pubKey.publicKeyRaw = publicKey

        var whitelist = VCSEC_WhitelistOperation()
        whitelist.subMessage = .removePublicKeyFromWhitelist(pubKey)

        var unsigned = VCSEC_UnsignedMessage()
        unsigned.subMessage = .whitelistOperation(whitelist)
        return try serialize(unsigned)
    }

    private static func mapRole(_ role: Command.KeyRole) -> Keys_Role {
        switch role {
        case .owner: .owner
        case .driver: .driver
        }
    }

    private static func mapFormFactor(_ formFactor: Command.KeyFormFactor) -> VCSEC_KeyFormFactor {
        switch formFactor {
        case .unknown: .unknown
        case .nfcCard: .nfcCard
        case .iosDevice: .iosDevice
        case .androidDevice: .androidDevice
        case .cloudKey: .cloudKey
        }
    }

    private static func encodeVCSEC(_ command: Command.Security) throws -> Data {
        var unsigned = VCSEC_UnsignedMessage()
        switch command {
        case .lock:
            unsigned.subMessage = .rkeaction(.rkeActionLock)
        case .unlock:
            unsigned.subMessage = .rkeaction(.rkeActionUnlock)
        case .wakeVehicle:
            unsigned.subMessage = .rkeaction(.rkeActionWakeVehicle)
        case .remoteDrive:
            unsigned.subMessage = .rkeaction(.rkeActionRemoteDrive)
        case .autoSecure:
            unsigned.subMessage = .rkeaction(.rkeActionAutoSecureVehicle)
        case .openTrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.rearTrunk = .closureMoveTypeOpen
            unsigned.subMessage = .closureMoveRequest(req)
        case .closeTrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.rearTrunk = .closureMoveTypeClose
            unsigned.subMessage = .closureMoveRequest(req)
        case .openFrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.frontTrunk = .closureMoveTypeOpen
            unsigned.subMessage = .closureMoveRequest(req)
        case .openDriverDoor:
            var req = VCSEC_ClosureMoveRequest()
            req.frontDriverDoor = .closureMoveTypeOpen
            unsigned.subMessage = .closureMoveRequest(req)
        case .actuateTrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.rearTrunk = .closureMoveTypeMove
            unsigned.subMessage = .closureMoveRequest(req)
        case .openTonneau:
            var req = VCSEC_ClosureMoveRequest()
            req.tonneau = .closureMoveTypeOpen
            unsigned.subMessage = .closureMoveRequest(req)
        case .closeTonneau:
            var req = VCSEC_ClosureMoveRequest()
            req.tonneau = .closureMoveTypeClose
            unsigned.subMessage = .closureMoveRequest(req)
        case .stopTonneau:
            var req = VCSEC_ClosureMoveRequest()
            req.tonneau = .closureMoveTypeStop
            unsigned.subMessage = .closureMoveRequest(req)
        case .addKey, .removeKey, .setSentryMode, .setValetMode, .eraseGuestData,
             .resetPin, .resetValetPin, .setGuestMode, .setPinToDrive, .clearPinToDrive,
             .activateSpeedLimit, .deactivateSpeedLimit, .setSpeedLimit,
             .clearSpeedLimitPin, .clearSpeedLimitPinAdmin:
            // Unreachable — these are routed outside the VCSEC path in the outer switch.
            throw Error.encodingFailed("encodeVCSEC called for non-RKE/non-closure command")
        }
        return try serialize(unsigned)
    }

    private static func serialize(_ message: some SwiftProtobuf.Message) throws -> Data {
        do {
            return try message.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
