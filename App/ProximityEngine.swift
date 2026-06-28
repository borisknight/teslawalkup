import CoreBluetooth
import CryptoKit
import Foundation
import OSLog

/// The hard part. Owns a `CBCentralManager` configured for **state preservation
/// and restoration** and keeps a **standing pending connection** to the paired
/// car's peripheral. This is what survives the app being backgrounded or killed:
///
///  - iOS does NOT reliably deliver a peripheral's local name in a background
///    scan, and the car doesn't advertise its GATT service UUID — so background
///    *scanning* for the car is a dead end (this is why naive apps fail and fall
///    back to beacons).
///  - Instead we discover the car's peripheral ONCE in the foreground (by its
///    VIN-derived local name), persist its `CBPeripheral.identifier`, then call
///    `connect(peripheral)` with no timeout. That pending connection is honored
///    by iOS whenever the car is in range — even after the app is terminated,
///    because the central is created with a `RestoreIdentifier`. iOS relaunches
///    us into the background and replays the connection via `willRestoreState`.
///
/// On connect we RSSI-gate (don't fire across a parking lot) and, once you're at
/// the door, hand the connected peripheral to `VehicleGateway` to run the signed
/// session and crack the driver door.
@MainActor
protocol ProximityEngineDelegate: AnyObject {
    /// Called on the engine's queue context (already hopped to main) when the
    /// car is connected AND within the "at the door" RSSI threshold AND the
    /// arrival guards (was-away + cooldown) pass. The delegate should run the
    /// Tesla session over `peripheral` using `delegateQueue`.
    func proximityEngine(_ engine: ProximityEngine, arrivedAt peripheral: CBPeripheral, delegateQueue: DispatchQueue) async
}

final class ProximityEngine: NSObject {
    static let restoreIdentifier = "com.knight.teslawalkup.central"

    private let logger = Logger(subsystem: "com.knight.teslawalkup", category: "proximity")
    private let queue = DispatchQueue(label: "com.knight.teslawalkup.central", qos: .userInitiated)
    private let store: PairingStore

    weak var delegate: (any ProximityEngineDelegate)?

    /// Live telemetry for the UI: (rssi, human-readable note). Called frequently
    /// from the BLE queue; the receiver hops to main.
    var onUpdate: (@Sendable (Int?, String) -> Void)?

    private var central: CBCentralManager!
    private var carPeripheral: CBPeripheral?

    // Foreground one-time discovery
    private var setupTargetLocalName: String?
    private var onDiscovered: ((CBPeripheral) -> Void)?

    // Arrival gating
    private var wasAway = true
    private var lastFire = Date.distantPast
    private var rssiPollWork: DispatchWorkItem?
    private var handingOff = false

    init(store: PairingStore) {
        self.store = store
        super.init()
        // Creating the central with a RestoreIdentifier is what makes the app
        // relaunchable for BLE events. The app MUST recreate this engine on every
        // launch (cold, or background relaunch) for restoration to work.
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ],
        )
    }

    // MARK: - Tuning (persisted, override in PairingStore)

    /// RSSI (dBm) at/above which we consider you "at the door". Closer to 0 = nearer.
    private var nearThreshold: Int { store.rssiNear }
    /// RSSI below which we consider you "gone", which re-arms a single fire.
    private var farThreshold: Int { store.rssiFar }
    /// Minimum seconds between auto-unlatches.
    private var cooldown: TimeInterval { TimeInterval(store.cooldownSeconds) }

    // MARK: - Foreground one-time setup

    /// Scan in the foreground to find the paired car's peripheral and persist its
    /// identifier. Matches by the VIN-derived BLE local name. Call this once,
    /// right after pairing, with Bluetooth powered on and the car awake/in range.
    func discoverAndRemember(vin: String, timeout: TimeInterval = 20, completion: @escaping (Bool) -> Void) {
        let target = Self.bleLocalName(forVIN: vin)
        queue.async { [self] in
            setupTargetLocalName = target
            onDiscovered = { [weak self] peripheral in
                guard let self else { return }
                store.saveCarPeripheralID(peripheral.identifier)
                carPeripheral = peripheral
                DispatchQueue.main.async { completion(true) }
                arm() // immediately begin the standing pending connection
            }
            guard central.state == .poweredOn else {
                logger.error("discover: BT not powered on")
                DispatchQueue.main.async { completion(false) }
                return
            }
            logger.debug("discover: scanning for \(target, privacy: .public)")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, onDiscovered != nil else { return }
                central.stopScan()
                onDiscovered = nil
                logger.error("discover: timed out")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // MARK: - Arming the background watch

    /// Establish (or re-establish) the standing pending connection to the saved
    /// car peripheral. Safe to call repeatedly; a no-op if already pending.
    func arm() {
        queue.async { [self] in
            guard central.state == .poweredOn else {
                onUpdate?(nil, "arm: Bluetooth not ready (state \(central.state.rawValue), need 5)")
                return
            }
            guard let id = store.carPeripheralID else {
                onUpdate?(nil, "arm: no saved car — tap Re-discover")
                return
            }
            let peripheral = carPeripheral ?? central.retrievePeripherals(withIdentifiers: [id]).first
            guard let peripheral else {
                onUpdate?(nil, "arm: couldn't retrieve saved peripheral")
                return
            }
            carPeripheral = peripheral
            peripheral.delegate = self
            switch peripheral.state {
            case .connected:
                // Already connected (e.g. didConnect fired earlier) — make sure
                // we're actually polling, since didConnect won't fire again.
                onUpdate?(nil, "arm: already connected — starting signal reads")
                beginRSSIPolling()
            case .connecting:
                onUpdate?(nil, "arm: already connecting…")
            default:
                // No timeout: iOS honors this whenever the car is in range, even
                // after app termination, relaunching us via state restoration.
                onUpdate?(nil, "arm: connecting to car (state \(peripheral.state.rawValue))…")
                central.connect(peripheral, options: nil)
            }
        }
    }

    // MARK: - RSSI gating after connect

    private func beginRSSIPolling() {
        scheduleRSSIRead(after: 0)
    }

    private func scheduleRSSIRead(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = carPeripheral, p.state == .connected, !handingOff else { return }
            p.readRSSI()
        }
        rssiPollWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate(rssi: Int) {
        if rssi < farThreshold { wasAway = true }
        let nearEnough = rssi >= nearThreshold
        let offCooldown = Date().timeIntervalSince(lastFire) > cooldown
        let note: String
        if !nearEnough { note = "\(rssi) dBm · not near (need ≥ \(nearThreshold))" }
        else if !wasAway { note = "\(rssi) dBm · near, but haven't left yet (go away first)" }
        else if !offCooldown { note = "\(rssi) dBm · near, cooling down" }
        else { note = "\(rssi) dBm · GATE PASSED → opening" }
        onUpdate?(rssi, note)
        guard nearEnough, wasAway, offCooldown, !handingOff, let peripheral = carPeripheral else {
            scheduleRSSIRead(after: 0.5)
            return
        }
        // Gate passed — hand off to the vehicle session.
        wasAway = false
        lastFire = Date()
        handingOff = true
        logger.debug("arrival gate passed (rssi \(rssi)); handing off to session")
        let q = queue
        Task { @MainActor [weak self] in
            guard let self else { return }
            await delegate?.proximityEngine(self, arrivedAt: peripheral, delegateQueue: q)
            // Session finished. Reset gate state on the central's queue and, if
            // still connected, resume RSSI polling to catch the next leave/return.
            q.async { [weak self] in
                guard let self else { return }
                self.handingOff = false
                if let p = self.carPeripheral, p.state == .connected {
                    p.delegate = self
                    self.scheduleRSSIRead(after: 1.0)
                }
            }
        }
    }

    // MARK: - VIN → BLE local name  (S + hex(sha1(VIN)[0..<8]) + C)

    static func bleLocalName(forVIN vin: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(vin.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "S\(hex)C"
    }
}

// MARK: - CBCentralManagerDelegate

extension ProximityEngine: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.debug("central state: \(central.state.rawValue)")
        onUpdate?(nil, "Bluetooth state \(central.state.rawValue) (5 = on)")
        if central.state == .poweredOn {
            arm() // (re)establish the pending connection once BT is ready
        }
    }

    // Called when iOS relaunches the app for a BLE event. Recover the peripheral
    // we had a pending connection to so delegate callbacks resume.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        logger.debug("willRestoreState: \(restored.count) peripheral(s)")
        onUpdate?(nil, "willRestoreState: restored \(restored.count) peripheral(s)")
        if let p = restored.first(where: { $0.identifier == store.carPeripheralID }) ?? restored.first {
            carPeripheral = p
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Foreground one-time setup only.
        guard let target = setupTargetLocalName else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name == target else { return }
        central.stopScan()
        setupTargetLocalName = nil
        let cb = onDiscovered
        onDiscovered = nil
        logger.debug("discover: matched \(peripheral.identifier, privacy: .public)")
        cb?(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.debug("didConnect \(peripheral.identifier, privacy: .public)")
        onUpdate?(nil, "connected — reading signal")
        peripheral.delegate = self
        beginRSSIPolling()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("didFailToConnect: \(String(describing: error), privacy: .public)")
        onUpdate?(nil, "connect FAILED: \(error?.localizedDescription ?? "unknown") — retrying")
        // Re-issue the pending connect.
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.debug("didDisconnect \(peripheral.identifier, privacy: .public)")
        onUpdate?(nil, "disconnected (left range) — re-armed, waiting to reconnect")
        wasAway = true // you (and the car link) went away; arm a fresh fire
        handingOff = false
        rssiPollWork?.cancel()
        // Re-establish the standing pending connection for the next walk-up.
        if peripheral.identifier == store.carPeripheralID || carPeripheral == nil {
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate (RSSI only; the session transport takes over the
// delegate after handoff)

extension ProximityEngine: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else {
            scheduleRSSIRead(after: 1.0)
            return
        }
        evaluate(rssi: RSSI.intValue)
    }
}
