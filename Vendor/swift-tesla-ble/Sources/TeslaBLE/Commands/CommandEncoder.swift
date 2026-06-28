import Foundation

/// Top-level dispatcher that routes a `Command` to the matching per-area
/// `*Encoder` type and returns a `(UniversalMessage_Domain, Data)` pair ready
/// for `Dispatcher.send`.
///
/// Infotainment-area encoders return just the body (domain is always
/// `.infotainment`). `SecurityEncoder` returns both because its cases span
/// both VCSEC and Infotainment domains.
enum CommandEncoder {
    enum Error: Swift.Error, Equatable {
        /// Protobuf serialization or command-level validation failed.
        case encodingFailed(String)
    }

    static func encode(_ command: Command) throws -> (domain: UniversalMessage_Domain, body: Data) {
        switch command {
        case let .security(s):
            return try SecurityEncoder.encode(s)
        case let .charge(c):
            let body = try ChargeEncoder.encode(c)
            return (.infotainment, body)
        case let .climate(cl):
            let body = try ClimateEncoder.encode(cl)
            return (.infotainment, body)
        case let .actions(a):
            let body = try ActionsEncoder.encode(a)
            return (.infotainment, body)
        case let .media(m):
            let body = try MediaEncoder.encode(m)
            return (.infotainment, body)
        case let .infotainment(i):
            let body = try InfotainmentEncoder.encode(i)
            return (.infotainment, body)
        }
    }
}
