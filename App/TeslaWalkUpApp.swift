import SwiftUI
import TeslaBLE

@main
struct TeslaWalkUpApp: App {
    @State private var gateway: VehicleGateway
    // Held for the whole app lifetime. Creating the ProximityEngine here — on
    // every launch, including iOS background relaunches — is what makes
    // CoreBluetooth state restoration work: the central is recreated with its
    // RestoreIdentifier and `willRestoreState` replays the pending connection.
    private let engine: ProximityEngine
    private let location: LocationKeepAlive

    init() {
        DiskLog.log("=== app launch ===")
        let store = PairingStore()
        let keyStore = KeychainTeslaKeyStore(service: "com.knight.teslawalkup")
        let gateway = VehicleGateway(keyStore: keyStore, store: store)
        let engine = ProximityEngine(store: store)
        engine.delegate = gateway
        gateway.engine = engine
        engine.onUpdate = { rssi, note in
            DiskLog.log("ENGINE \(note)\(rssi.map { " rssi=\($0)" } ?? "")")
            Task { @MainActor in gateway.updateTelemetry(rssi: rssi, note: note) }
        }
        _gateway = State(initialValue: gateway)
        self.engine = engine

        // Keep the app alive in the background so RSSI polling keeps running.
        let location = LocationKeepAlive()
        location.start()
        self.location = location
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(gateway)
        }
    }
}
