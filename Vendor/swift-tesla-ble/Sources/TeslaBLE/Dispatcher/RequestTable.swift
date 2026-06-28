import Foundation

/// Token-keyed map of pending continuations used by `Dispatcher` to match
/// inbound responses, drive timeouts, and wake waiters on shutdown. Not an
/// actor: all access happens inside `Dispatcher`'s actor isolation, so the
/// caller provides the serialization.
///
/// The "token" is a per-domain route identifier chosen by `Dispatcher`:
/// - **VCSEC:** a fresh random 16-byte routing address per request. VCSEC
///   responses are matched back by `toDestination.routingAddress` rather
///   than `request_uuid`, because the vehicle does not reliably echo the
///   request UUID for VCSEC responses (see `internal/dispatcher/dispatcher.go:259`
///   where Go deliberately skips the UUID copy for VCSEC).
/// - **Infotainment / other:** the 16-byte `RoutableMessage.uuid`, since
///   the vehicle echoes it in `request_uuid` on the response.
///
/// This struct only stores and looks up by token — it doesn't care which
/// scheme the caller used. Collision probability across schemes is 2⁻¹²⁸,
/// and in practice the address pool and uuid pool don't share namespaces
/// at all because VCSEC and Infotainment tokens are chosen independently.
struct RequestTable {
    enum Error: Swift.Error, Equatable {
        case duplicateRequestID
        case noSuchRequest
    }

    typealias Continuation = CheckedContinuation<UniversalMessage_RoutableMessage, Swift.Error>

    private var entries: [Data: Continuation] = [:]

    mutating func register(token: Data, continuation: Continuation) throws {
        if entries[token] != nil {
            throw Error.duplicateRequestID
        }
        entries[token] = continuation
    }

    /// Returns true if a matching continuation was resumed, false if the
    /// token was unknown (e.g. already timed out or never registered).
    @discardableResult
    mutating func complete(token: Data, with message: UniversalMessage_RoutableMessage) -> Bool {
        guard let continuation = entries.removeValue(forKey: token) else {
            return false
        }
        continuation.resume(returning: message)
        return true
    }

    @discardableResult
    mutating func fail(token: Data, error: Swift.Error) -> Bool {
        guard let continuation = entries.removeValue(forKey: token) else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    /// Wakes every pending continuation with `error`. Called from
    /// `Dispatcher.stop()` to guarantee no caller is left suspended.
    mutating func cancelAll(error: Swift.Error) {
        let snapshot = entries
        entries.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    func contains(token: Data) -> Bool {
        entries[token] != nil
    }
}
