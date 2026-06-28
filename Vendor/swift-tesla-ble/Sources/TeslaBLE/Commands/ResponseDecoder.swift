import Foundation

/// Decodes command response bytes into a small `CommandResult` outcome enum.
///
/// Infotainment responses are `CarServer_Response` (check `actionStatus.result`).
/// VCSEC responses are `VCSEC_FromVCSECMessage` with a oneOf `subMessage` — only
/// the `.commandStatus` variant carries an explicit operation outcome; other
/// variants are treated as informational `.ok`.
enum ResponseDecoder {
    /// The decoded outcome of a command.
    enum CommandResult: Sendable, Equatable {
        case ok
        case okWithPayload(Data)
        case vehicleError(code: Int, reason: String?)
    }

    enum Error: Swift.Error, Equatable {
        /// Protobuf deserialization failed.
        case decodingFailed(String)
        /// Response bytes did not match the expected message type for the domain.
        case unexpectedMessageType(String)
    }

    /// Decode an Infotainment-domain response. Returns `.ok` if
    /// `actionStatus.result` indicates success, `.vehicleError` otherwise.
    static func decodeInfotainment(_ bytes: Data) throws -> CommandResult {
        let response: CarServer_Response
        do {
            response = try CarServer_Response(serializedBytes: bytes)
        } catch {
            throw Error.decodingFailed("CarServer_Response: \(error)")
        }

        let status = response.actionStatus
        switch status.result {
        case .operationstatusOk:
            return .ok
        case .rror:
            // Codegen quirk: the "error" case was generated as `.rror` after
            // protoc stripped the leading E from ERROR. CarServer only has
            // ok and error — there's no wait case on this enum (unlike VCSEC).
            let reason = Self.reasonString(from: status)
            return .vehicleError(code: status.result.rawValue, reason: reason)
        case .UNRECOGNIZED:
            return .vehicleError(code: status.result.rawValue, reason: "unrecognized status")
        }
    }

    /// Decode a VCSEC-domain response. Returns `.ok` if the `commandStatus`
    /// indicates operation success, `.vehicleError` otherwise.
    static func decodeVCSEC(_ bytes: Data) throws -> CommandResult {
        let response: VCSEC_FromVCSECMessage
        do {
            response = try VCSEC_FromVCSECMessage(serializedBytes: bytes)
        } catch {
            throw Error.decodingFailed("VCSEC_FromVCSECMessage: \(error)")
        }

        // `commandStatus` is a oneOf sub-message in VCSEC_FromVCSECMessage.
        // Check whether the active subMessage is `.commandStatus`; if it is
        // something else (vehicleStatus, whitelistInfo, etc.) or nil, treat
        // the response as informational and return `.ok`.
        guard case let .commandStatus(status) = response.subMessage else {
            return .ok
        }
        switch status.operationStatus {
        case .operationstatusOk:
            return .ok
        case .operationstatusWait:
            return .vehicleError(code: status.operationStatus.rawValue, reason: "busy (wait)")
        case .rror:
            // VCSEC codegen quirk: `.rror` is the "error" case.
            return .vehicleError(code: status.operationStatus.rawValue, reason: "error")
        case .UNRECOGNIZED:
            return .vehicleError(code: status.operationStatus.rawValue, reason: "unrecognized status")
        }
    }

    private static func reasonString(from status: CarServer_ActionStatus) -> String? {
        if status.hasResultReason, !status.resultReason.plainText.isEmpty {
            return status.resultReason.plainText
        }
        return nil
    }
}
