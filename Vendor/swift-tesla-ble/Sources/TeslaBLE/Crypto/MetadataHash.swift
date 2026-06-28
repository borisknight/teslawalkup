import CryptoKit
import Foundation

/// Streaming TLV metadata builder used by every signing and verifying path in
/// the TeslaBLE crypto stack. Mirrors `internal/authentication/metadata.go`.
///
/// Wire format: a sequence of `[tag][length][value...]` triples, where tags
/// are raw `Signatures_Tag` enum values, lengths are a single byte, and
/// values are ≤ 255 bytes. Crucially the tags MUST appear in strictly
/// ascending order — the vehicle side hashes in the same order, and swapping
/// two tags would produce a different digest and fail verification. The
/// builder enforces this at runtime via `lastTag` and throws `.outOfOrder`.
///
/// The serialized TLV is not stored anywhere; it is streamed directly into
/// the hash context as it is built, and the final digest is what both sides
/// actually compare. `checksum(over:)` terminates the input with the
/// `TAG_END` (0xFF) terminator followed by a "message" blob — plain TLV
/// hashes pass an empty message; the HMAC handshake path passes the encoded
/// `SessionInfo` here.
///
/// Two hash contexts are supported:
/// - `sha256Context()` — plain SHA-256. Used for AES-GCM AAD (request and
///   response metadata).
/// - `hmacContext(sessionKey:label:)` — HMAC-SHA-256 keyed with a subkey
///   derived as `HMAC-SHA256(sessionKey, label_utf8)`, then the outer HMAC
///   is keyed with that subkey. Labels used by the protocol are
///   `"authenticated command"` (HMAC-personalized signing path) and
///   `"session info"` (handshake verification).
///
/// Fixtures: `Tests/TeslaBLETests/Fixtures/crypto/metadata_sha256_vectors.json`
/// and `metadata_hmac_vectors.json`.
struct MetadataHash {
    enum Error: Swift.Error, Equatable {
        case outOfOrder(tag: Int, previous: Int)
        case valueTooLong(Int)
    }

    // MARK: - Hash context abstraction

    /// Internal enum because CryptoKit's hash function types don't share a
    /// protocol we can store uniformly. We branch on the enum in `update`
    /// and `finalize`.
    private enum Context {
        case sha256(SHA256)
        case hmacSHA256(HMAC<SHA256>)

        mutating func update(_ data: Data) {
            switch self {
            case var .sha256(h):
                h.update(data: data)
                self = .sha256(h)
            case var .hmacSHA256(h):
                h.update(data: data)
                self = .hmacSHA256(h)
            }
        }

        func finalize() -> Data {
            switch self {
            case let .sha256(h):
                Data(h.finalize())
            case let .hmacSHA256(h):
                Data(h.finalize())
            }
        }
    }

    // MARK: - Constants

    /// Raw value of `Signatures_Tag.end` — the terminator byte. See
    /// `Sources/TeslaBLE/Generated/signatures.pb.swift:40`.
    static let tagEnd: UInt8 = 255

    // MARK: - Stored state

    private var context: Context
    private var lastTag: Int

    private init(context: Context) {
        self.context = context
        lastTag = -1
    }

    // MARK: - Factories

    /// Plain SHA256 context.
    static func sha256Context() -> MetadataHash {
        MetadataHash(context: .sha256(SHA256()))
    }

    /// HMAC-SHA256 context keyed with a subkey derived from the session key
    /// and the label string. The subkey is `HMAC-SHA256(sessionKey, label)`
    /// (see `native.go` `NativeSession.subkey`), and the outer MAC is a fresh
    /// `HMAC<SHA256>` keyed on that subkey.
    static func hmacContext(sessionKey: SessionKey, label: String) -> MetadataHash {
        let labelBytes = Data(label.utf8)
        var inner = HMAC<SHA256>(key: sessionKey.symmetric)
        inner.update(data: labelBytes)
        let subkey = SymmetricKey(data: Data(inner.finalize()))
        return MetadataHash(context: .hmacSHA256(HMAC<SHA256>(key: subkey)))
    }

    // MARK: - Mutation

    /// Add a TLV entry. `tagRaw` is the raw enum value of `Signatures_Tag`.
    mutating func add(tagRaw: UInt8, value: Data) throws {
        let tagInt = Int(tagRaw)
        if tagInt < lastTag {
            throw Error.outOfOrder(tag: tagInt, previous: lastTag)
        }
        if value.count > 255 {
            throw Error.valueTooLong(value.count)
        }
        lastTag = tagInt
        context.update(Data([tagRaw]))
        context.update(Data([UInt8(value.count)]))
        context.update(value)
    }

    /// Convenience: add a UInt32 as 4 big-endian bytes.
    mutating func addUInt32(tagRaw: UInt8, value: UInt32) throws {
        var be = value.bigEndian
        let bytes = withUnsafeBytes(of: &be) { Data($0) }
        try add(tagRaw: tagRaw, value: bytes)
    }

    // MARK: - Finalization

    /// Terminate with the TAG_END byte + `message` blob and return the final
    /// digest / tag bytes. This mutates and consumes the builder — do not call
    /// twice.
    mutating func checksum(over message: Data) -> Data {
        context.update(Data([Self.tagEnd]))
        context.update(message)
        return context.finalize()
    }
}
