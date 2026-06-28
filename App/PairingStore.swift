import Foundation

/// Persists the single paired vehicle: its VIN, the discovered BLE peripheral
/// identifier (used to re-establish the standing background connection), and the
/// user-tunable RSSI thresholds.
struct PairingStore {
    private let defaults: UserDefaults
    private let ns = "com.knight.teslawalkup"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Defaults for tuning (only set if absent).
        if defaults.object(forKey: "\(ns).rssiNear") == nil { defaults.set(-70, forKey: "\(ns).rssiNear") }
        if defaults.object(forKey: "\(ns).rssiFar") == nil { defaults.set(-85, forKey: "\(ns).rssiFar") }
        if defaults.object(forKey: "\(ns).cooldown") == nil { defaults.set(30, forKey: "\(ns).cooldown") }
        if defaults.object(forKey: "\(ns).unlatchGapMs") == nil { defaults.set(2500, forKey: "\(ns).unlatchGapMs") }
    }

    var pairedVIN: String? { defaults.string(forKey: "\(ns).vin") }
    func setPairedVIN(_ vin: String) { defaults.set(vin, forKey: "\(ns).vin") }

    var carPeripheralID: UUID? {
        guard let s = defaults.string(forKey: "\(ns).peripheralID") else { return nil }
        return UUID(uuidString: s)
    }
    func saveCarPeripheralID(_ id: UUID) { defaults.set(id.uuidString, forKey: "\(ns).peripheralID") }

    // Tuning (dBm / seconds)
    var rssiNear: Int { defaults.integer(forKey: "\(ns).rssiNear") }
    var rssiFar: Int { defaults.integer(forKey: "\(ns).rssiFar") }
    var cooldownSeconds: Int { defaults.integer(forKey: "\(ns).cooldown") }
    func setRSSINear(_ v: Int) { defaults.set(v, forKey: "\(ns).rssiNear") }
    func setRSSIFar(_ v: Int) { defaults.set(v, forKey: "\(ns).rssiFar") }

    var unlatchGapMs: Int { defaults.integer(forKey: "\(ns).unlatchGapMs") }
    func setUnlatchGapMs(_ v: Int) { defaults.set(v, forKey: "\(ns).unlatchGapMs") }

    func clear() {
        for k in ["vin", "peripheralID"] { defaults.removeObject(forKey: "\(ns).\(k)") }
    }
}
