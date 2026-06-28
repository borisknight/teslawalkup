import Foundation

/// Stateless inbound verification for AES-GCM-RESPONSE messages.
///
/// Pulls the nonce, ciphertext, tag, and counter out of the response
/// `signatureData`, rebuilds the AAD through `SessionMetadata.buildResponseAAD`
/// (which binds the response to the originating request via a request-hash
/// TLV), opens the AES-GCM box, and hands the plaintext back to the caller
/// along with the counter so `VehicleSession` can run it through its replay
/// `CounterWindow`. The verifier is deliberately stateless — counter/epoch
/// ownership lives in `VehicleSession` so that sign and verify can be tested
/// against fixtures without a live session.
///
/// Fixture: `Tests/TeslaBLETests/Fixtures/session/response_aad_vectors.json`.
enum InboundVerifier {
    enum Error: Swift.Error, Equatable {
        case missingSignatureData
        case notAnAESGCMResponse
        case missingPayload
        case metadataFailed(String)
        case openFailed(String)
        case authenticationFailure
    }

    /// Compute the request-ID bytes used to match a response to its request.
    /// Port of `peer.go RequestID`.
    ///
    /// For AES-GCM responses: `[SIGNATURE_TYPE_AES_GCM_PERSONALIZED (=5)]`
    /// followed by the request's signer-side 16-byte GCM tag.
    ///
    /// For HMAC-personalized responses, the full tag is used for
    /// non-VCSEC domains; for VCSEC the tag is truncated to 16 bytes.
    static func requestID(forSignedRequest request: UniversalMessage_RoutableMessage) -> Data? {
        guard case let .signatureData(sigData)? = request.subSigData else { return nil }
        switch sigData.sigType {
        case let .aesGcmPersonalizedData(gcm):
            return Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]) + gcm.tag
        case let .hmacPersonalizedData(hm):
            var tag = hm.tag
            if request.toDestination.domain == .vehicleSecurity, tag.count > 16 {
                tag = tag.prefix(16)
            }
            return Data([UInt8(Signatures_SignatureType.hmacPersonalized.rawValue)]) + tag
        default:
            return nil
        }
    }

    /// Open a response message and return the decoded plaintext and counter.
    /// The `requestID` parameter is produced by `requestID(forSignedRequest:)`
    /// on the original outbound message that elicited this response.
    static func openGCMResponse(
        message: UniversalMessage_RoutableMessage,
        sessionKey: SessionKey,
        verifierName: Data,
        requestID: Data,
    ) throws -> (counter: UInt32, plaintext: Data) {
        guard case let .signatureData(sigData)? = message.subSigData else {
            throw Error.missingSignatureData
        }
        guard case let .aesGcmResponseData(gcmResponse)? = sigData.sigType else {
            throw Error.notAnAESGCMResponse
        }
        guard case let .protobufMessageAsBytes(ciphertext)? = message.payload else {
            throw Error.missingPayload
        }

        let aad: Data
        do {
            aad = try SessionMetadata.buildResponseAAD(
                message: message,
                verifierName: verifierName,
                requestID: requestID,
                counter: gcmResponse.counter,
            )
        } catch {
            throw Error.metadataFailed(String(describing: error))
        }

        do {
            let plaintext = try MessageAuthenticator.open(
                ciphertext: ciphertext,
                tag: gcmResponse.tag,
                nonce: gcmResponse.nonce,
                associatedData: aad,
                sessionKey: sessionKey,
            )
            return (gcmResponse.counter, plaintext)
        } catch MessageAuthenticator.Error.authenticationFailure {
            throw Error.authenticationFailure
        } catch {
            throw Error.openFailed(String(describing: error))
        }
    }
}
