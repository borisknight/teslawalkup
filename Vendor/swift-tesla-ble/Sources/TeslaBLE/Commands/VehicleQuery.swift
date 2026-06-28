import Foundation
import SwiftProtobuf

/// Structured-response queries dispatched through
/// ``TeslaVehicleClient/query(_:timeout:)``.
///
/// ``VehicleQuery`` exists as a separate type from ``Command`` because
/// queries return typed payloads instead of a `Void` acknowledgement. Each
/// case has its own response shape (VCSEC whitelist metadata, body
/// controller state, nearby superchargers, and so on), so the result is
/// modeled as a sibling enum ``VehicleQueryResult``.
///
/// Queries travel the same signed transport path as ``Command``; only the
/// decoding differs.
public enum VehicleQuery: Sendable, Equatable {
    /// Lists every key registered in the VCSEC whitelist with slot metadata.
    ///
    /// Yields ``VehicleQueryResult/keySummary(_:)`` wrapping the raw
    /// `VCSEC_WhitelistInfo` protobuf.
    case keySummary

    /// Returns detailed information for a single whitelist slot.
    ///
    /// Pair with ``keySummary`` to discover valid slot indices. Yields
    /// ``VehicleQueryResult/keyInfo(_:)``.
    ///
    /// - Parameter slot: Whitelist slot index as reported by ``keySummary``.
    case keyInfo(slot: UInt32)

    /// Returns VCSEC body-controller state: closures, lock status, user
    /// presence, and whether Infotainment is asleep.
    ///
    /// Because this query targets the VCSEC domain it remains answerable
    /// even when Infotainment is asleep, unlike the closures subset of
    /// ``TeslaVehicleClient/fetch(_:timeout:)``. Yields
    /// ``VehicleQueryResult/bodyControllerState(_:)``.
    case bodyControllerState

    /// Returns nearby Supercharger sites as seen by the vehicle's navigation
    /// system. Dispatched on the Infotainment domain.
    ///
    /// - Parameters:
    ///   - includeMetadata: `true` to include site metadata such as stall
    ///     count and amenities.
    ///   - radiusMiles: Search radius in miles, or `0` to let the vehicle
    ///     pick a default.
    ///   - count: Maximum number of results, or `0` for the vehicle default.
    case nearbyCharging(includeMetadata: Bool = false, radiusMiles: Int32 = 0, count: Int32 = 0)
}

/// Typed result of a ``VehicleQuery``. Each case wraps the raw generated
/// protobuf message so callers can project into their own types as needed.
public enum VehicleQueryResult: Sendable {
    /// Result of ``VehicleQuery/keySummary``.
    case keySummary(VCSEC_WhitelistInfo)
    /// Result of ``VehicleQuery/keyInfo(slot:)``.
    case keyInfo(VCSEC_WhitelistEntryInfo)
    /// Result of ``VehicleQuery/bodyControllerState``.
    case bodyControllerState(VCSEC_VehicleStatus)
    /// Result of ``VehicleQuery/nearbyCharging(includeMetadata:radiusMiles:count:)``.
    case nearbyCharging(CarServer_NearbyChargingSites)
}

/// Encodes a `VehicleQuery` into the `(domain, body)` pair used by
/// `Dispatcher.send`. Separate from `CommandEncoder` because the two APIs
/// have different return types.
enum VehicleQueryEncoder {
    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
    }

    static func encode(_ query: VehicleQuery) throws -> (domain: UniversalMessage_Domain, body: Data) {
        switch query {
        case .keySummary:
            var req = VCSEC_InformationRequest()
            req.informationRequestType = .getWhitelistInfo
            var unsigned = VCSEC_UnsignedMessage()
            unsigned.subMessage = .informationRequest(req)
            return try (.vehicleSecurity, serialize(unsigned))

        case let .keyInfo(slot):
            var req = VCSEC_InformationRequest()
            req.informationRequestType = .getWhitelistEntryInfo
            req.slot = slot
            var unsigned = VCSEC_UnsignedMessage()
            unsigned.subMessage = .informationRequest(req)
            return try (.vehicleSecurity, serialize(unsigned))

        case .bodyControllerState:
            var req = VCSEC_InformationRequest()
            req.informationRequestType = .getStatus
            var unsigned = VCSEC_UnsignedMessage()
            unsigned.subMessage = .informationRequest(req)
            return try (.vehicleSecurity, serialize(unsigned))

        case let .nearbyCharging(includeMetadata, radiusMiles, count):
            var sub = CarServer_GetNearbyChargingSites()
            sub.includeMetaData = includeMetadata
            sub.radius = radiusMiles
            sub.count = count
            var vehicleAction = CarServer_VehicleAction()
            vehicleAction.vehicleActionMsg = .getNearbyChargingSites(sub)
            var action = CarServer_Action()
            action.vehicleAction = vehicleAction
            return try (.infotainment, serialize(action))
        }
    }

    private static func serialize(_ message: some SwiftProtobuf.Message) throws -> Data {
        do {
            return try message.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}

/// Decodes raw response bytes from `Dispatcher.send` into a typed
/// `VehicleQueryResult`. Mirrors `VehicleQueryEncoder` — one branch per case.
enum VehicleQueryDecoder {
    enum Error: Swift.Error, Equatable {
        case decodingFailed(String)
        case unexpectedMessageType(String)
    }

    static func decode(_ query: VehicleQuery, from bytes: Data) throws -> VehicleQueryResult {
        switch query {
        case .keySummary:
            let message = try parseVCSEC(bytes)
            guard case let .whitelistInfo(info)? = message.subMessage else {
                throw Error.unexpectedMessageType("expected whitelistInfo, got \(describe(message.subMessage))")
            }
            return .keySummary(info)

        case .keyInfo:
            let message = try parseVCSEC(bytes)
            guard case let .whitelistEntryInfo(info)? = message.subMessage else {
                throw Error.unexpectedMessageType("expected whitelistEntryInfo, got \(describe(message.subMessage))")
            }
            return .keyInfo(info)

        case .bodyControllerState:
            let message = try parseVCSEC(bytes)
            guard case let .vehicleStatus(status)? = message.subMessage else {
                throw Error.unexpectedMessageType("expected vehicleStatus, got \(describe(message.subMessage))")
            }
            return .bodyControllerState(status)

        case .nearbyCharging:
            let response: CarServer_Response
            do {
                response = try CarServer_Response(serializedBytes: bytes)
            } catch {
                throw Error.decodingFailed("CarServer_Response: \(error)")
            }
            guard case let .getNearbyChargingSites(sites)? = response.responseMsg else {
                throw Error.unexpectedMessageType("expected getNearbyChargingSites in response")
            }
            return .nearbyCharging(sites)
        }
    }

    private static func parseVCSEC(_ bytes: Data) throws -> VCSEC_FromVCSECMessage {
        do {
            return try VCSEC_FromVCSECMessage(serializedBytes: bytes)
        } catch {
            throw Error.decodingFailed("VCSEC_FromVCSECMessage: \(error)")
        }
    }

    private static func describe(_ subMessage: VCSEC_FromVCSECMessage.OneOf_SubMessage?) -> String {
        switch subMessage {
        case .vehicleStatus: "vehicleStatus"
        case .commandStatus: "commandStatus"
        case .whitelistInfo: "whitelistInfo"
        case .whitelistEntryInfo: "whitelistEntryInfo"
        case .nominalError: "nominalError"
        case .none: "none"
        }
    }
}
