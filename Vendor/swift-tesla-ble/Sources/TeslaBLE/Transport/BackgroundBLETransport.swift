import CoreBluetooth
import Foundation

/// A `MessageTransport` that runs the Tesla GATT session over a peripheral that
/// has ALREADY been connected by an externally-owned `CBCentralManager`.
///
/// This is the background-capable counterpart to `BLETransport`. The standard
/// `BLETransport` owns its own central and *scans by local name*, which iOS
/// throttles/strips in the background. For walk-up automation the app instead
/// owns a `CBCentralManager` created with `CBCentralManagerOptionRestoreIdentifierKey`
/// and keeps a standing `connect(peripheral)` pending; iOS relaunches the app and
/// fires `didConnect` when the car comes in range. At that point the app hands the
/// connected peripheral here and we only do GATT (service/characteristic discovery
/// + framed read/write) — no scanning.
///
/// We do NOT own the central and never call connect/cancel on it; the app manages
/// the connection lifecycle. We only set ourselves as the peripheral's delegate.
@preconcurrency
final class BackgroundBLETransport: NSObject, Sendable {
    private static let maxMessageSize = 1024
    private static let rxTimeout: TimeInterval = 1.0

    private let logger: (any TeslaBLELogger)?

    // CoreBluetooth delegate callbacks for a peripheral are delivered on the
    // queue its owning central was created with. The app creates that central
    // on a dedicated serial queue and passes it here so our state stays confined.
    private let queue: DispatchQueue

    private nonisolated(unsafe) let peripheral: CBPeripheral
    private nonisolated(unsafe) var txCharacteristic: CBCharacteristic?
    private nonisolated(unsafe) var rxCharacteristic: CBCharacteristic?
    private nonisolated(unsafe) var mtu: Int = 20
    private nonisolated(unsafe) var writeType: CBCharacteristicWriteType = .withResponse

    private nonisolated(unsafe) var inputBuffer = Data()
    private nonisolated(unsafe) var lastRxTime: Date?

    private nonisolated(unsafe) var attachContinuation: CheckedContinuation<Void, Error>?
    private nonisolated(unsafe) var receiveContinuations: [CheckedContinuation<Data, Error>] = []
    private nonisolated(unsafe) var attached = false

    /// - Parameters:
    ///   - peripheral: A peripheral already in the `.connected` state, owned by
    ///     the app's central.
    ///   - delegateQueue: The same serial queue the app's `CBCentralManager` was
    ///     created with, so peripheral delegate callbacks are serialized with it.
    ///   - logger: Optional diagnostic sink.
    init(peripheral: CBPeripheral, delegateQueue: DispatchQueue, logger: (any TeslaBLELogger)? = nil) {
        self.peripheral = peripheral
        queue = delegateQueue
        self.logger = logger
        super.init()
    }

    /// Discovers the Tesla service + characteristics on the already-connected
    /// peripheral and enables notifications. Resolves once the session channel is
    /// ready, or throws on timeout / missing service.
    func attach(timeout: TimeInterval = 20) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.queue.async { [self] in
                        guard peripheral.state == .connected else {
                            continuation.resume(throwing: BLEError.notConnected)
                            return
                        }
                        attachContinuation = continuation
                        peripheral.delegate = self
                        peripheral.discoverServices([BLETransport.vehicleServiceUUID])
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BLEError.timeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                queue.async { [self] in
                    if let cont = attachContinuation {
                        attachContinuation = nil
                        if error is BLEError { cont.resume(throwing: error) }
                    }
                }
                throw error
            }
        }
    }

    /// Removes our delegate hooks. Does NOT disconnect — the app owns the
    /// connection and may keep the peripheral for the next walk-up.
    func detach() {
        queue.async { [self] in
            if peripheral.delegate === self {
                peripheral.delegate = nil
            }
            txCharacteristic = nil
            rxCharacteristic = nil
            inputBuffer = Data()
            attached = false
            for cont in receiveContinuations {
                cont.resume(throwing: BLEError.disconnected)
            }
            receiveContinuations.removeAll()
        }
    }

    func send(_ data: Data) throws {
        guard let txCharacteristic else { throw BLEError.notConnected }
        let framed = MessageFramer.encode(data)
        guard framed.count <= Self.maxMessageSize + 2 else { throw BLEError.messageTooLarge }
        for chunk in MessageFramer.fragment(framed, mtu: mtu) {
            peripheral.writeValue(chunk, for: txCharacteristic, type: writeType)
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let message = tryFlush() {
                    continuation.resume(returning: message)
                } else {
                    receiveContinuations.append(continuation)
                }
            }
        }
    }

    private func tryFlush() -> Data? {
        guard inputBuffer.count >= 2 else { return nil }
        if let (message, consumed) = try? MessageFramer.decode(inputBuffer), let message {
            inputBuffer.removeFirst(consumed)
            return message
        }
        return nil
    }
}

// MARK: - CBPeripheralDelegate

extension BackgroundBLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices _: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLETransport.vehicleServiceUUID }) else {
            attachContinuation?.resume(throwing: BLEError.serviceNotFound)
            attachContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([BLETransport.toVehicleUUID, BLETransport.fromVehicleUUID], for: service)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error _: Error?,
    ) {
        guard let characteristics = service.characteristics else {
            attachContinuation?.resume(throwing: BLEError.characteristicsNotFound)
            attachContinuation = nil
            return
        }
        for char in characteristics {
            if char.uuid == BLETransport.toVehicleUUID {
                txCharacteristic = char
            } else if char.uuid == BLETransport.fromVehicleUUID {
                rxCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        if let tx = txCharacteristic, tx.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
            mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        } else {
            writeType = .withResponse
            mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        }
        guard txCharacteristic != nil, rxCharacteristic != nil else {
            attachContinuation?.resume(throwing: BLEError.characteristicsNotFound)
            attachContinuation = nil
            return
        }
        attached = true
        logger?.log(.debug, category: "bg-transport", "Attached. MTU=\(mtu) writeType=\(writeType == .withResponse ? "withResponse" : "withoutResponse")")
        attachContinuation?.resume()
        attachContinuation = nil
    }

    nonisolated func peripheral(
        _: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error _: Error?,
    ) {
        guard characteristic.uuid == BLETransport.fromVehicleUUID, let value = characteristic.value else { return }
        let now = Date()
        if let lastRx = lastRxTime, now.timeIntervalSince(lastRx) > Self.rxTimeout {
            inputBuffer = Data()
        }
        lastRxTime = now
        inputBuffer.append(value)
        while !receiveContinuations.isEmpty, let message = tryFlush() {
            receiveContinuations.removeFirst().resume(returning: message)
        }
    }
}

extension BackgroundBLETransport: MessageTransport {
    func sendMessage(_ data: Data) async throws { try send(data) }
    func receiveMessage() async throws -> Data { try await receive() }
}
