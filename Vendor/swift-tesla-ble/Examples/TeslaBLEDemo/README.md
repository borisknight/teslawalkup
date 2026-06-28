# TeslaBLEDemo

A minimal SwiftUI example app exercising the `TeslaBLE` package against a real Tesla vehicle. The app covers:

- First-time BLE pairing (`connect(mode: .pairing)` + unsigned `addKey` + reconnect-until-active).
- Reading drive state (`fetchDrive()`) with manual refresh and an opt-in 2-second live-poll toggle.
- Two signed commands: `security.unlock` and `actions.honk`.

## Running

1. Open `Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj` in Xcode 16 or later.
2. Select the `TeslaBLEDemo` scheme.
3. In **Signing & Capabilities**, set a development team — automatic signing is on; no team is baked into the committed project.
4. Build and run on a real iOS 17+ device. CoreBluetooth does not work in the simulator.
5. Enter your vehicle's 17-character VIN, tap **Start pairing**, and follow the prompt on the car's center console (tap your existing owner key card).
6. After authorization completes, the app keeps retrying the signed handshake until the new key is active, then the dashboard auto-connects. Use **Refresh** or flip **Live** to pull drive state; use **Unlock** and **Honk** to prove the signed command path.

## Regenerating the Xcode project

The `.xcodeproj` is committed and does not require any tooling to open. If you modify `project.yml` (e.g. to add files or settings), regenerate with:

    brew install xcodegen   # once
    cd Examples/TeslaBLEDemo
    xcodegen generate

## Caveats

- The keypair is stored in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It is not included in iCloud or device backups; restoring to a new device requires re-pairing.
- The demo runs foreground-only. Background BLE is out of scope.
- The demo is single-vehicle. Use **Forget this vehicle** to clear the stored key + VIN and re-pair a different car.
