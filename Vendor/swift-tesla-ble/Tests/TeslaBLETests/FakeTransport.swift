import Foundation
@testable import TeslaBLE

/// Scriptable `MessageTransport` for `Dispatcher` scenario tests.
///
/// Usage pattern in tests:
/// 1. Instantiate `FakeTransport()`.
/// 2. Pre-populate scripted inbound messages via `enqueueInbound(_:)`.
/// 3. Pass the instance to the Dispatcher under test.
/// 4. After the test interaction, pull captured outbound bytes via
///    `await transport.sentMessages`.
///
/// Concurrency: an `actor` so that `receiveMessage` and `enqueueInbound`
/// serialize access to the inbound queue safely.
actor FakeTransport: MessageTransport {
    enum Error: Swift.Error {
        case receiveCancelled
        case receiveStubbedFailure(String)
    }

    private var sent: [Data] = []
    private var pendingInbound: [Data] = []
    private var pendingReceiveContinuations: [CheckedContinuation<Data, Swift.Error>] = []
    private var stubbedError: Swift.Error?
    private var closed = false

    // MARK: - Protocol conformance

    func sendMessage(_ data: Data) async throws {
        if closed { throw Error.receiveCancelled }
        sent.append(data)
    }

    func receiveMessage() async throws -> Data {
        if let err = stubbedError {
            stubbedError = nil
            throw err
        }
        if !pendingInbound.isEmpty {
            return pendingInbound.removeFirst()
        }
        if closed {
            throw Error.receiveCancelled
        }
        return try await withCheckedThrowingContinuation { cont in
            pendingReceiveContinuations.append(cont)
        }
    }

    // MARK: - Test helpers

    /// Append a message to the inbound queue. If a receiver is currently
    /// suspended it is woken up immediately.
    func enqueueInbound(_ data: Data) {
        if !pendingReceiveContinuations.isEmpty {
            let cont = pendingReceiveContinuations.removeFirst()
            cont.resume(returning: data)
            return
        }
        pendingInbound.append(data)
    }

    /// Stub the next `receiveMessage` call to fail with the supplied error.
    func stubNextReceiveFailure(_ error: Swift.Error) {
        stubbedError = error
        if !pendingReceiveContinuations.isEmpty {
            let cont = pendingReceiveContinuations.removeFirst()
            cont.resume(throwing: error)
            stubbedError = nil
        }
    }

    /// Close the transport, waking any suspended receiver with a cancellation
    /// error.
    func close() {
        closed = true
        let snapshot = pendingReceiveContinuations
        pendingReceiveContinuations.removeAll()
        for c in snapshot {
            c.resume(throwing: Error.receiveCancelled)
        }
    }

    var sentMessages: [Data] {
        sent
    }

    var pendingReceiveCount: Int {
        pendingReceiveContinuations.count
    }

    func clearSent() {
        sent.removeAll()
    }
}
