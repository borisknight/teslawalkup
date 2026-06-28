import Foundation

/// Stateless outbound signing for AES-GCM-PERSONALIZED requests.
///
/// Given a plaintext protobuf body and the caller's session state, this
/// builds the signing AAD (epoch / counter / expiry / domain / verifier
/// name, in the TLV order the vehicle expects), seals the plaintext with
/// AES-GCM-128, and writes the ciphertext into `message.payload` plus the
/// matching `Signatures_AES_GCM_Personalized_Signature_Data` into
/// `message.subSigData`. The caller (`VehicleSession`) owns the counter and
/// epoch; keeping this file stateless lets sign/verify be exercised against
/// fixtures with a fixed nonce and known counter.
///
/// Fixture: `Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json`.
enum OutboundSigner {
    enum Error: Swift.Error, Equatable {
        case metadataFailed(String)
        case sealFailed(String)
    }

    /// Signs and encrypts `plaintext` in-place into `message` using
    /// AES-GCM-PERSONALIZED. The supplied counter and expiresAt are copied
    /// into the gcm signature data; the caller must ensure counter is
    /// monotonically increasing and not repeating.
    static func signGCM(
        plaintext: Data,
        message: inout UniversalMessage_RoutableMessage,
        sessionKey: SessionKey,
        localPublicKey: Data,
        verifierName: Data,
        epoch: Data,
        counter: UInt32,
        expiresAt: UInt32,
    ) throws {
        let aad: Data
        do {
            aad = try SessionMetadata.buildSigningAAD(
                message: message,
                verifierName: verifierName,
                epoch: epoch,
                counter: counter,
                expiresAt: expiresAt,
            )
        } catch {
            throw Error.metadataFailed(String(describing: error))
        }

        let sealed: (nonce: Data, ciphertext: Data, tag: Data)
        do {
            sealed = try MessageAuthenticator.seal(
                plaintext: plaintext,
                associatedData: aad,
                sessionKey: sessionKey,
            )
        } catch {
            throw Error.sealFailed(String(describing: error))
        }

        var gcmData = Signatures_AES_GCM_Personalized_Signature_Data()
        gcmData.epoch = epoch
        gcmData.nonce = sealed.nonce
        gcmData.counter = counter
        gcmData.expiresAt = expiresAt
        gcmData.tag = sealed.tag

        var identity = Signatures_KeyIdentity()
        identity.identityType = .publicKey(localPublicKey)

        var sigData = Signatures_SignatureData()
        sigData.signerIdentity = identity
        sigData.sigType = .aesGcmPersonalizedData(gcmData)

        message.subSigData = .signatureData(sigData)
        message.payload = .protobufMessageAsBytes(sealed.ciphertext)
    }
}
