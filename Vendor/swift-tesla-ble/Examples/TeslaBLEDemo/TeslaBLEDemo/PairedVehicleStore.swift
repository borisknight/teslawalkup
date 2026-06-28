//
//  PairedVehicleStore.swift
//  TeslaBLEDemo
//
//  Created by Jiaxin Shou on 2026/4/14.
//

import Foundation

/// Tiny `UserDefaults` wrapper persisting a single paired VIN.
///
/// The demo intentionally supports one vehicle at a time; clearing resets the
/// app to the pairing screen.
struct PairedVehicleStore {
    private let defaults: UserDefaults
    private let key = "\(Constants.bundleIdentifier).pairedVIN"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pairedVIN: String? {
        defaults.string(forKey: key)
    }

    func setPairedVIN(_ vin: String) {
        defaults.set(vin, forKey: key)
    }

    func clearPairedVIN() {
        defaults.removeObject(forKey: key)
    }
}
