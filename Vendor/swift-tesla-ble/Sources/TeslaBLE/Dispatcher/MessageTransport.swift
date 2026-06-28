import Foundation

/// Abstraction over a fully-deframed message channel so `Dispatcher` can run
/// against either the real `BLETransport` or a test double without caring about
/// the underlying medium. Implementations own all framing/chunking: `sendMessage`
/// takes a serialized protobuf blob and `receiveMessage` returns one.
protocol MessageTransport: Sendable {
    func sendMessage(_ data: Data) async throws
    func receiveMessage() async throws -> Data
}

extension BLETransport: MessageTransport {
    func sendMessage(_ data: Data) async throws {
        try send(data)
    }

    func receiveMessage() async throws -> Data {
        try await receive()
    }
}
