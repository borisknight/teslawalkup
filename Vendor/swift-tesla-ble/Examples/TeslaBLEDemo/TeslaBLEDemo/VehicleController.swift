//
//  VehicleController.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import CryptoKit
import Foundation
import OSLog
import Security
import SwiftUI
import TeslaBLE

/// Single source of truth wrapping `TeslaVehicleClient` for the demo UI.
///
/// All mutations happen on the main actor so SwiftUI bindings fire on the
/// main thread. Every throwing call to the client funnels through a catch
/// block that assigns `lastError` — the UI shows a single global alert.
@Observable
final class VehicleController {
    // Pairing state
    var pairedVIN: String?
    var isPairing: Bool = false

    // Session state
    var connectionState: ConnectionState = .disconnected
    var drive: DriveState?
    var charge: ChargeState?
    var isLive: Bool = false {
        didSet {
            guard isLive != oldValue else { return }
            defaults.set(isLive, forKey: Self.isLiveKey)
            restartLiveLoop()
        }
    }

    var lastError: String?

    private let keyStore: KeychainTeslaKeyStore
    private let store: PairedVehicleStore
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "controller")

    private var client: TeslaVehicleClient?
    private var stateObserverTask: Task<Void, Never>?
    private var livePollTask: Task<Void, Never>?

    private static let isLiveKey = "\(Constants.bundleIdentifier).isLive"
    private static let drivePollMsKey = "\(Constants.bundleIdentifier).drivePollMs"
    private static let chargePollSecKey = "\(Constants.bundleIdentifier).chargePollSec"

    convenience init() {
        self.init(
            keyStore: KeychainTeslaKeyStore(service: Constants.bundleIdentifier),
            store: PairedVehicleStore(),
        )
    }

    init(
        keyStore: KeychainTeslaKeyStore,
        store: PairedVehicleStore,
        defaults: UserDefaults = .standard,
    ) {
        self.keyStore = keyStore
        self.store = store
        self.defaults = defaults
        pairedVIN = store.pairedVIN
        isLive = defaults.bool(forKey: Self.isLiveKey)
        if defaults.object(forKey: Self.drivePollMsKey) != nil {
            drivePollMs = defaults.integer(forKey: Self.drivePollMsKey)
        }
        if defaults.object(forKey: Self.chargePollSecKey) != nil {
            chargePollSec = defaults.integer(forKey: Self.chargePollSecKey)
        }
    }

    // MARK: - Pairing (Task 6)

    func startPairing(vin: String) async {
        guard vin.count == 17 else {
            lastError = "VIN must be exactly 17 characters."
            return
        }
        guard !isPairing else { return }
        lastError = nil
        isPairing = true
        defer { isPairing = false }

        do {
            let privateKey: P256.KeyAgreement.PrivateKey
            if let existing = try keyStore.loadPrivateKey(forVIN: vin) {
                privateKey = existing
            } else {
                privateKey = KeyPairFactory.generateKeyPair()
                try keyStore.savePrivateKey(privateKey, forVIN: vin)
            }
            let publicKey = KeyPairFactory.publicKeyBytes(of: privateKey)

            let pairingClient = TeslaVehicleClient(vin: vin, keyStore: keyStore)
            do {
                try await pairingClient.connect(mode: .pairing)
                try await pairingClient.send(
                    .security(.addKey(publicKey: publicKey, role: .owner, formFactor: .iosDevice)),
                )
                await pairingClient.disconnect()
            } catch {
                await pairingClient.disconnect()
                throw error
            }

            store.setPairedVIN(vin)
            pairedVIN = vin
        } catch {
            logger.error("pairing failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }

    func clearPairing() {
        guard client == nil else {
            lastError = "Disconnect before forgetting the vehicle."
            return
        }
        if let vin = pairedVIN {
            do {
                try keyStore.deletePrivateKey(forVIN: vin)
            } catch {
                logger.error("delete key failed: \(String(describing: error), privacy: .public)")
                lastError = String(describing: error)
                return
            }
        }
        store.clearPairedVIN()
        pairedVIN = nil
        drive = nil
        charge = nil
        connectionState = .disconnected
    }

    /// Nuclear option for the pairing screen: wipes every Keychain item under
    /// this app's service (including orphans from previously-paired VINs) and
    /// clears the persisted VIN. Safe to call only while no session is active.
    func wipeAllPersistedData() {
        guard client == nil else {
            lastError = "Disconnect before wiping data."
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.bundleIdentifier,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("wipe keychain failed: \(status, privacy: .public)")
            lastError = "Keychain wipe failed (OSStatus \(status))."
            return
        }
        store.clearPairedVIN()
        pairedVIN = nil
        drive = nil
        charge = nil
        connectionState = .disconnected
    }

    // MARK: - Session (Task 5)

    /// Number of `connect(mode: .normal)` attempts before giving up. One
    /// transient retry is enough to absorb CoreBluetooth's back-to-back
    /// reconnect race right after pairing's disconnect, and occasional scan
    /// misses during scene-phase transitions.
    private static let maxConnectAttempts = 2
    private static let connectRetryDelay: Duration = .seconds(1)

    func connect() async {
        guard let vin = pairedVIN else {
            lastError = "No paired vehicle."
            return
        }
        guard client == nil else { return }

        let newClient = TeslaVehicleClient(vin: vin, keyStore: keyStore)
        client = newClient

        // Subscribe to state transitions. This stream never finishes for the
        // lifetime of the client, so we MUST cancel this task in disconnect().
        stateObserverTask = Task { [weak self] in
            for await state in newClient.stateStream {
                guard let self else { return }
                await MainActor.run { self.connectionState = state }
                if Task.isCancelled { return }
            }
        }

        for attempt in 1 ... Self.maxConnectAttempts {
            do {
                try await newClient.connect(mode: .normal)
                isLive = true
                return
            } catch let error as TeslaBLEError where Self.isRetryable(error) && attempt < Self.maxConnectAttempts {
                logger.debug(
                    "connect attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public); retrying",
                )
                try? await Task.sleep(for: Self.connectRetryDelay)
                continue
            } catch {
                logger.error("connect failed: \(String(describing: error), privacy: .public)")
                lastError = String(describing: error)
                await disconnect()
                return
            }
        }
    }

    /// Errors worth retrying once: transient BLE transport failures where a
    /// brief delay typically clears the race. Handshake, auth, and keystore
    /// errors are intentionally excluded — they represent configuration
    /// problems that retrying won't fix.
    private static func isRetryable(_ error: TeslaBLEError) -> Bool {
        switch error {
        case .scanTimeout, .connectionFailed:
            true
        default:
            false
        }
    }

    func disconnect() async {
        isLive = false

        stateObserverTask?.cancel()
        stateObserverTask = nil

        if let client {
            await client.disconnect()
        }
        client = nil

        // The stream task is cancelled; force-publish .disconnected so the UI
        // doesn't sit on the last observed value.
        connectionState = .disconnected
        drive = nil
        charge = nil
    }

    // MARK: - Reads & commands (Task 7)

    func refreshDrive() async {
        guard let client else { return }
        do {
            let drive = try await client.fetchDrive()
            self.drive = drive
        } catch is CancellationError {
            return
        } catch {
            logger.error("fetchDrive failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }

    func refreshCharge() async {
        guard let client else { return }
        do {
            let snapshot = try await client.fetch(.categories([.charge]))
            charge = snapshot.charge
        } catch is CancellationError {
            return
        } catch {
            logger.error("fetchCharge failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }

    /// Drive poll interval in milliseconds.
    var drivePollMs: Int = 500 {
        didSet { defaults.set(drivePollMs, forKey: Self.drivePollMsKey) }
    }

    /// Charge poll interval in seconds.
    var chargePollSec: Int = 5 {
        didSet { defaults.set(chargePollSec, forKey: Self.chargePollSecKey) }
    }

    private func restartLiveLoop() {
        livePollTask?.cancel()
        livePollTask = nil
        guard isLive else { return }

        livePollTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        guard let self else { return }
                        if await MainActor.run(body: { self.connectionState }) == .connected {
                            await self.pollDrive()
                        }
                        let ms = await MainActor.run { self.drivePollMs }
                        try? await Task.sleep(for: .milliseconds(ms))
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        guard let self else { return }
                        if await MainActor.run(body: { self.connectionState }) == .connected {
                            await self.pollCharge()
                        }
                        let sec = await MainActor.run { self.chargePollSec }
                        try? await Task.sleep(for: .seconds(sec))
                    }
                }
            }
        }
    }

    private func pollDrive() async {
        guard let client else { return }
        do {
            let drive = try await client.fetchDrive()
            self.drive = drive
        } catch {
            logger.debug("live poll miss (drive): \(String(describing: error), privacy: .public)")
        }
    }

    private func pollCharge() async {
        guard let client else { return }
        do {
            let snapshot = try await client.fetch(.categories([.charge]))
            charge = snapshot.charge
        } catch {
            logger.debug("live poll miss (charge): \(String(describing: error), privacy: .public)")
        }
    }

    func unlock() async {
        guard let client else { return }
        do {
            try await client.send(.security(.unlock))
        } catch is CancellationError {
            return
        } catch {
            logger.error("unlock failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }

    func honk() async {
        guard let client else { return }
        do {
            try await client.send(.actions(.honk))
        } catch is CancellationError {
            return
        } catch {
            logger.error("honk failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }
}
