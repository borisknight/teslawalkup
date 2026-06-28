import Foundation

/// Framing for Tesla BLE's TX/RX characteristics: every message carries a
/// 2-byte big-endian length header (`[lenHi, lenLo, payload...]`) and is then
/// split into MTU-sized chunks for the actual GATT writes, since CoreBluetooth
/// writes are capped by the negotiated MTU. `decode(_:)` reassembles the stream
/// on the receiving side, returning the payload once the full length has arrived.
enum MessageFramer {
    /// Encodes `payload` with a 2-byte big-endian length prefix.
    static func encode(_ payload: Data) -> Data {
        let length = UInt16(payload.count)
        var framed = Data(capacity: 2 + payload.count)
        framed.append(UInt8(length >> 8))
        framed.append(UInt8(length & 0xFF))
        framed.append(payload)
        return framed
    }

    /// Attempts to decode one message from the buffer.
    ///
    /// - Returns: `(message, bytesConsumed)` on success, or `(nil, 0)` if the
    ///   buffer does not yet contain a complete frame.
    static func decode(_ buffer: Data) throws -> (Data?, Int) {
        guard buffer.count >= 2 else { return (nil, 0) }
        let length = Int(buffer[buffer.startIndex]) << 8
            | Int(buffer[buffer.startIndex + 1])
        guard length > 0 else { return (nil, 0) }
        let totalNeeded = 2 + length
        guard buffer.count >= totalNeeded else { return (nil, 0) }
        let message = buffer[buffer.startIndex + 2 ..< buffer.startIndex + totalNeeded]
        return (Data(message), totalNeeded)
    }

    /// Splits `data` into chunks of at most `mtu` bytes.
    static func fragment(_ data: Data, mtu: Int) -> [Data] {
        var chunks: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + mtu, data.endIndex)
            chunks.append(Data(data[offset ..< end]))
            offset = end
        }
        return chunks
    }
}
