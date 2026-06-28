import CoreBluetooth
import CryptoKit
import Foundation
import Observation
import OSLog
import TeslaBLE
import UIKit

/// App-side brain. Owns pairing + the arrival handler that runs the signed Tesla
/// session and cracks the driver door. Acts as the `ProximityEngine`'s delegate.
@MainActor
@Observable
final class VehicleGateway {
    enum Phase: Equatable {
        case unpaired
        case pairing
        case armed              // background watch active
        case opening
        case idleMessage(String)
    }

    private(set) var phase: Phase = .unpaired
    var pairedVIN: String? { store.pairedVIN }
    var lastEvent: String = ""

    // Live proximity telemetry for the debug UI.
    var liveRSSI: Int?
    var engineNote: String = ""

    /// Live-tunable approach trigger (dBm). Lower (more negative) = fires from
    /// farther away / earlier in the approach. Persisted via PairingStore.
    var triggerRSSI: Int = -70 {
        didSet { store.setRSSINear(triggerRSSI) }
    }

    /// Live-tunable "hold" duration (ms): how long we keep re-sending the unlatch
    /// to simulate HOLDING the door-release button (a tap only partially
    /// unlatches; a hold pushes the door fully open). Persisted.
    var holdMs: Int = 2000 {
        didSet { store.setUnlatchGapMs(holdMs) }
    }

    private let keyStore: KeychainTeslaKeyStore
    private let store: PairingStore
    private let logger = Logger(subsystem: "com.knight.teslawalkup", category: "gateway")

    /// Verbose public log sink for the TeslaBLE library. View in Console.app →
    /// filter subsystem "TeslaBLE". publicMessages so values aren't redacted
    /// while we're debugging on a dev device.
    static let debugLogger = OSLogTeslaBLELogger(subsystem: "TeslaBLE", minimumLevel: .debug, publicMessages: true)

    /// Set by the app after construction so we can kick off background discovery
    /// right after a successful pairing.
    weak var engine: ProximityEngine?

    init(keyStore: KeychainTeslaKeyStore, store: PairingStore) {
        self.keyStore = keyStore
        self.store = store
        phase = store.pairedVIN == nil ? .unpaired : .armed
        triggerRSSI = store.rssiNear
        holdMs = store.unlatchGapMs

        // Migrate the signing key to "after first unlock" accessibility so it's
        // readable while the phone is LOCKED (background opens). Re-saving
        // refreshes accessibility (save is delete-then-add). Runs at launch while
        // the device is unlocked, so no re-pair is needed.
        if let vin = store.pairedVIN, let key = try? keyStore.loadPrivateKey(forVIN: vin) {
            try? keyStore.savePrivateKey(key, forVIN: vin)
            DiskLog.log("KEY migrated to afterFirstUnlock accessibility")
        }
    }

    /// Live telemetry sink from the ProximityEngine (already on main).
    func updateTelemetry(rssi: Int?, note: String) {
        if let rssi { liveRSSI = rssi }
        engineNote = note
    }

    // MARK: - Pairing (foreground, one time)

    func startPairing(vin rawVIN: String) async {
        let vin = rawVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard vin.count == 17 else {
            lastEvent = "VIN must be exactly 17 characters."
            return
        }
        phase = .pairing
        lastEvent = "Scanning for car over Bluetooth…"
        do {
            let privateKey: P256.KeyAgreement.PrivateKey
            if let existing = try keyStore.loadPrivateKey(forVIN: vin) {
                privateKey = existing
            } else {
                privateKey = KeyPairFactory.generateKeyPair()
                try keyStore.savePrivateKey(privateKey, forVIN: vin)
            }
            let publicKey = KeyPairFactory.publicKeyBytes(of: privateKey)

            let client = TeslaVehicleClient(vin: vin, keyStore: keyStore, logger: Self.debugLogger)
            try await client.connect(mode: .pairing)
            lastEvent = "Connected ✔︎ — sending key request. WATCH THE CAR SCREEN and tap your card."
            try await client.send(.security(.addKey(publicKey: publicKey, role: .owner, formFactor: .iosDevice)))
            // Hold the BLE link open so the car can present the add-key prompt and
            // you have time to tap the card on the console (don't disconnect early).
            try? await Task.sleep(for: .seconds(20))
            await client.disconnect()

            store.setPairedVIN(vin)
            lastEvent = "Key request sent. Did the car ask for a card tap? Check Controls → Locks for the new key."

            // Discover + remember the car's peripheral for the background watch.
            engine?.discoverAndRemember(vin: vin) { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastEvent = ok
                        ? "Background watch armed — walk away and back to test."
                        : "Paired, but couldn't find the car to arm. Stay near the car and retry discovery."
                    self.phase = ok ? .armed : .idleMessage("Discovery failed")
                }
            }
        } catch {
            logger.error("pairing failed: \(String(describing: error), privacy: .public)")
            lastEvent = "Pairing failed: \(error)"
            phase = .unpaired
        }
    }

    func reDiscover() {
        guard let vin = store.pairedVIN else { return }
        lastEvent = "Discovering car…"
        engine?.discoverAndRemember(vin: vin) { [weak self] ok in
            Task { @MainActor in
                self?.lastEvent = ok ? "Armed." : "Couldn't find the car. Be near it + awake, retry."
                self?.phase = ok ? .armed : .idleMessage("Discovery failed")
            }
        }
    }

    func forget() {
        if let vin = store.pairedVIN { try? keyStore.deletePrivateKey(forVIN: vin) }
        store.clear()
        phase = .unpaired
        lastEvent = "Forgotten. Remove the key in the car: Controls → Locks."
    }

    /// Open the driver door the way both the in-app button and the Tesla app do:
    /// TWO unlatch pushes, each over its OWN fresh connection. A single
    /// connection can go marginal during the gap (especially when triggered from
    /// a distance) and drop the 2nd push — a fresh connect per push is exactly
    /// like tapping the button twice, which reliably opens the door. No explicit
    /// unlock: the unlatch implies it, matching the Tesla app's two-press flow.
    /// Manual button (app in foreground): fresh foreground connect, then pulse.
    func openDoor() async {
        guard let vin = store.pairedVIN else { return }
        phase = .opening
        lastEvent = "Connecting…"
        let client = TeslaVehicleClient(vin: vin, keyStore: keyStore)
        do {
            try await client.connect(mode: .normal)
            await pulseUnlatch(client)
        } catch {
            lastEvent = "Open failed: \(error)"
            logger.error("openDoor failed: \(String(describing: error), privacy: .public)")
        }
        await client.disconnect()
        phase = store.pairedVIN == nil ? .unpaired : .armed
    }

    /// The latch needs a full unlatch→re-latch cycle to finish before another
    /// unlatch lands (rapid-fire doesn't help). Send ONE unlatch every
    /// `pulseIntervalMs` for the configured window — repeated clean chances to
    /// pull the door open by its edge.
    private func pulseUnlatch(_ client: TeslaVehicleClient) async {
        let deadline = Date().addingTimeInterval(Double(holdMs) / 1000.0)
        var pulses = 0
        repeat {
            // Stop as soon as you've actually pulled the door open/ajar.
            if pulses > 0, await doorIsOpen(client) {
                DiskLog.log("DOOR open — stopping after \(pulses) pulses")
                lastEvent = "Door open ✔︎ (\(pulses) pulses) \(Self.now())"
                return
            }
            try? await client.send(.security(.openDriverDoor))
            pulses += 1
            DiskLog.log("UNLATCH pulse #\(pulses)")
            lastEvent = "Unlatch #\(pulses) — PULL THE DOOR"
            try? await Task.sleep(for: .milliseconds(Self.pulseIntervalMs))
        } while Date() < deadline
        DiskLog.log("WINDOW ended (\(pulses) pulses)")
        lastEvent = "Window ended (\(pulses) unlatches) \(Self.now())"
    }

    /// True once the driver door has actually moved off the latch — so we can
    /// stop pulsing the instant you pull it open.
    private func doorIsOpen(_ client: TeslaVehicleClient) async -> Bool {
        guard case let .bodyControllerState(s)? = try? await client.query(.bodyControllerState) else {
            return false
        }
        switch s.closureStatuses.frontDriverDoor {
        case .closurestateOpen, .closurestateAjar, .closurestateOpening:
            return true
        default:
            return false
        }
    }

    /// Spacing between unlatch pulses — enough for the latch's full
    /// unlatch→re-latch cycle to complete before the next one.
    private static let pulseIntervalMs = 2000
}

// MARK: - ProximityEngineDelegate

extension VehicleGateway: ProximityEngineDelegate {
    /// On arrival the engine has already gated (RSSI + was-away + cooldown). This
    /// can run with the app BACKGROUNDED/KILLED, so we must NOT scan (iOS throttles
    /// background scans). Instead we fire the unlatch pulses over the engine's
    /// already-connected peripheral via `connect(using:)`. A background-task
    /// assertion keeps us alive for the full window.
    func proximityEngine(_ engine: ProximityEngine, arrivedAt peripheral: CBPeripheral, delegateQueue q: DispatchQueue) async {
        guard let vin = store.pairedVIN else { return }
        phase = .opening
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "TeslaWalkUp.openDoor")
        defer { UIApplication.shared.endBackgroundTask(bgTask) }

        DiskLog.log("ARRIVAL: opening via engine peripheral (bg-capable)")
        let client = TeslaVehicleClient(vin: vin, keyStore: keyStore)
        do {
            try await client.connect(using: peripheral, delegateQueue: q, mode: .normal)
            DiskLog.log("ARRIVAL: session up, pulsing")
            await pulseUnlatch(client)
        } catch {
            lastEvent = "Open failed: \(error)"
            DiskLog.log("ARRIVAL ERROR: \(error)")
            logger.error("arrival open failed: \(String(describing: error), privacy: .public)")
        }
        await client.disconnect()
        phase = store.pairedVIN == nil ? .unpaired : .armed
    }

    private static func now() -> String {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f.string(from: Date())
    }
}
