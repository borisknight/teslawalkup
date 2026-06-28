import Foundation

/// TLV metadata AAD construction for AES-GCM signing and response verification.
///
/// Mirrors `extractMetadata` and `responseMetadata` in
/// `internal/authentication/peer.go`. Both paths produce a 32-byte SHA-256
/// checksum over a TLV-encoded metadata blob, which is then handed to
/// AES-GCM-128 as the Additional Authenticated Data. The AAD is what binds a
/// request to its epoch, counter, domain, expiry, and verifier name — any
/// mismatch between the two sides' TLV layout produces a tag mismatch rather
/// than a decryption error, so the tag ordering below is load-bearing and
/// must stay in lockstep with the Go reference.
///
/// Two notable asymmetries between the signing path and the response path:
/// the signing path only emits `TAG_FLAGS` when `message.flags > 0`, while
/// the response path ALWAYS emits it; and the response path additionally
/// binds a `TAG_REQUEST_HASH` (to tie the response to a specific request)
/// and a `TAG_FAULT` (so faulted responses cannot be replayed as successes).
///
/// Fixtures: `Tests/TeslaBLETests/Fixtures/session/signing_aad_vectors.json`
/// and `response_aad_vectors.json`.
enum SessionMetadata {
    enum Error: Swift.Error, Equatable {
        case invalidDomain
        case tlvBuildFailed(String)
    }

    // MARK: - Signing path

    /// Build the AAD for an outbound AES-GCM-PERSONALIZED request. The TLV
    /// order matches `peer.go extractMetadata`:
    ///
    ///     TAG_SIGNATURE_TYPE (=5, AES_GCM_PERSONALIZED)
    ///     TAG_DOMAIN         (=message.toDestination.domain byte)
    ///     TAG_PERSONALIZATION (=verifierName bytes)
    ///     TAG_EPOCH          (=16 bytes)
    ///     TAG_EXPIRES_AT     (=u32 BE)
    ///     TAG_COUNTER        (=u32 BE)
    ///     TAG_FLAGS          (=u32 BE, only added if message.flags > 0)
    ///
    /// Terminated by `TAG_END` + empty message blob.
    static func buildSigningAAD(
        message: UniversalMessage_RoutableMessage,
        verifierName: Data,
        epoch: Data,
        counter: UInt32,
        expiresAt: UInt32,
    ) throws -> Data {
        let domain = try domainByte(fromTo: message)

        var builder = MetadataHash.sha256Context()
        do {
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.signatureType.rawValue),
                value: Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]),
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.domain.rawValue),
                value: Data([domain]),
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.personalization.rawValue),
                value: verifierName,
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.epoch.rawValue),
                value: epoch,
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.expiresAt.rawValue),
                value: expiresAt,
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.counter.rawValue),
                value: counter,
            )
            if message.flags > 0 {
                try builder.addUInt32(
                    tagRaw: UInt8(Signatures_Tag.flags.rawValue),
                    value: message.flags,
                )
            }
        } catch {
            throw Error.tlvBuildFailed(String(describing: error))
        }
        return builder.checksum(over: Data())
    }

    // MARK: - Response path

    /// Build the AAD for verifying a vehicle response (AES-GCM-RESPONSE).
    /// The TLV order matches `peer.go responseMetadata`:
    ///
    ///     TAG_SIGNATURE_TYPE (=9, AES_GCM_RESPONSE)
    ///     TAG_DOMAIN         (=message.fromDestination.domain byte)
    ///     TAG_PERSONALIZATION (=verifierName bytes)
    ///     TAG_COUNTER        (=u32 BE)
    ///     TAG_FLAGS          (=u32 BE, ALWAYS added — differs from signing path)
    ///     TAG_REQUEST_HASH   (=requestID bytes)
    ///     TAG_FAULT          (=u32 BE of signedMessageStatus.signedMessageFault)
    ///
    /// Terminated by `TAG_END` + empty message blob.
    static func buildResponseAAD(
        message: UniversalMessage_RoutableMessage,
        verifierName: Data,
        requestID: Data,
        counter: UInt32,
    ) throws -> Data {
        let domain = try domainByte(fromFrom: message)

        var builder = MetadataHash.sha256Context()
        do {
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.signatureType.rawValue),
                value: Data([UInt8(Signatures_SignatureType.aesGcmResponse.rawValue)]),
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.domain.rawValue),
                value: Data([domain]),
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.personalization.rawValue),
                value: verifierName,
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.counter.rawValue),
                value: counter,
            )
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.flags.rawValue),
                value: message.flags,
            )
            try builder.add(
                tagRaw: UInt8(Signatures_Tag.requestHash.rawValue),
                value: requestID,
            )
            let faultRaw = UInt32(message.signedMessageStatus.signedMessageFault.rawValue)
            try builder.addUInt32(
                tagRaw: UInt8(Signatures_Tag.fault.rawValue),
                value: faultRaw,
            )
        } catch {
            throw Error.tlvBuildFailed(String(describing: error))
        }
        return builder.checksum(over: Data())
    }

    // MARK: - Internals

    private static func domainByte(fromTo message: UniversalMessage_RoutableMessage) throws -> UInt8 {
        let raw = message.toDestination.domain.rawValue
        guard raw >= 0, raw <= 255 else {
            throw Error.invalidDomain
        }
        return UInt8(raw)
    }

    private static func domainByte(fromFrom message: UniversalMessage_RoutableMessage) throws -> UInt8 {
        let raw = message.fromDestination.domain.rawValue
        guard raw >= 0, raw <= 255 else {
            throw Error.invalidDomain
        }
        return UInt8(raw)
    }
}
