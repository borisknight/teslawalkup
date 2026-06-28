# TeslaBLEDemo — SwiftUI Example App Design

**Date:** 2026-04-13
**Status:** Approved for implementation planning
**Target:** `Examples/TeslaBLEDemo/` (new directory in this repo)

## Goal

A minimal SwiftUI example app that demonstrates how to integrate the
`TeslaBLE` package against a real Tesla vehicle. The app covers:

1. **First-time BLE pairing** — generate a P-256 keypair, connect in
   pairing mode, send the unsigned `addKey` request.
2. **Read-only drive state** — gear, speed, power, and odometer via
   `TeslaVehicleClient.fetchDrive()`, with an optional 2-second live-poll
   loop.
3. **Two signed commands** — `security.unlock` and `actions.honk`, to prove
   the full VCSEC + Infotainment session path works end-to-end.

The app is a developer sample, not a product. UI uses stock SwiftUI
components (no custom design system). It is also the target audience's
first read of "how do I wire this package into an app," so clarity of
integration beats feature breadth.

## Scope

### In scope

- Single-vehicle pairing and daily-use flow.
- Manual VIN entry on a pairing screen; VIN persisted to `UserDefaults`.
- P-256 keypair persisted via `KeychainTeslaKeyStore`.
- Dashboard with connection status, drive-state card, two command buttons,
  and a "Forget this vehicle" affordance.
- Manual refresh plus an opt-in 2-second live-poll toggle.
- One global error alert driven by the controller's `lastError`.

### Out of scope

- Multi-vehicle management, vehicle list, or switching.
- Full snapshot display (`fetch(.all)` — battery %, climate, etc.).
- Additional commands beyond unlock and honk.
- Background BLE, state restoration across launches, push notifications.
- Localization — English strings only.
- Unit or UI tests for the example app (the package has 141 tests).
- macOS support — iOS 17+ only, matching the package.

## Architecture

### Project layout

```
Examples/TeslaBLEDemo/
├── TeslaBLEDemo.xcodeproj/        # committed; automatic signing; team unset
├── TeslaBLEDemo/
│   ├── TeslaBLEDemoApp.swift      # @main; owns VehicleController via @State
│   ├── VehicleController.swift    # @Observable integration layer
│   ├── PairedVehicleStore.swift   # UserDefaults-backed VIN persistence
│   ├── Views/
│   │   ├── RootView.swift         # routes PairingView or DashboardView
│   │   ├── PairingView.swift      # VIN entry + instructions + Start button
│   │   ├── DashboardView.swift    # status row, drive card, commands
│   │   ├── ConnectionStatusRow.swift
│   │   └── DriveStateCard.swift
│   ├── Assets.xcassets
│   └── Info.plist                 # NSBluetoothAlwaysUsageDescription
└── README.md                      # run instructions, signing note
```

### Project settings

- **Type:** iOS application (`.xcodeproj`, committed).
- **Bundle ID:** `com.example.TeslaBLEDemo`.
- **Display name:** `Tesla BLE Demo`.
- **Deployment target:** iOS 17.0 (matches the `TeslaBLE` package).
- **Swift version:** 6.2 (matches the package toolchain).
- **Signing:** automatic; development team left unset. The demo's README
  tells the user to pick their own team in Signing & Capabilities before
  running on device.
- **Package dependency:** local path `../..` → `TeslaBLE` product. Declared
  in the `.xcodeproj`'s package references; does not affect
  `swift build` / `swift test` at the repo root.
- **Info.plist:** `NSBluetoothAlwaysUsageDescription` =
  `"This demo connects to your paired Tesla vehicle over Bluetooth."` No
  background modes.

## Components

### `VehicleController` (the integration layer)

A single `@Observable @MainActor` class that owns the full client
lifecycle. This is the file the reader of the demo should study to
understand how to integrate `TeslaBLE` in a real app.

```swift
@Observable
@MainActor
final class VehicleController {
    // Pairing state
    var pairedVIN: String?
    var isPairing: Bool = false

    // Session state
    var connectionState: ConnectionState = .disconnected
    var drive: DriveState?
    var isLive: Bool = false
    var lastError: String?

    private let keyStore: KeychainTeslaKeyStore
    private let store: PairedVehicleStore
    private var client: TeslaVehicleClient?
    private var stateObserverTask: Task<Void, Never>?
    private var livePollTask: Task<Void, Never>?

    init(keyStore: KeychainTeslaKeyStore, store: PairedVehicleStore)

    // Pairing
    func startPairing(vin: String) async
    func clearPairing()

    // Daily use
    func connect() async
    func disconnect() async
    func refreshDrive() async
    func setLive(_ on: Bool)
    func unlock() async
    func honk() async
}
```

**`init`:** reads `store.pairedVIN` and assigns it to `pairedVIN`. Does
not touch BLE.

**`startPairing(vin:)`:**

1. `keyStore.loadPrivateKey(forVIN: vin)` or
   `KeyPairFactory.generateKeyPair()` + `keyStore.savePrivateKey(_,
forVIN: vin)`.
2. Create an ephemeral `TeslaVehicleClient(vin: vin, keyStore: keyStore)`.
3. `try await client.connect(mode: .pairing)`.
4. `try await client.send(.security(.addKey(publicKey:, role: .owner,
formFactor: .iosDevice)))`.
5. `await client.disconnect()` in a `defer`, whatever the outcome.
6. On success: `store.setPairedVIN(vin)`; `self.pairedVIN = vin`. Root
   view re-routes to the dashboard.
7. On throw: assign `lastError`; leave `pairedVIN` nil so the user can
   retry.

**`connect()`:**

- Idempotent. If `client != nil`, returns early.
- Builds a new `TeslaVehicleClient(vin: pairedVIN!, keyStore: keyStore)`.
- Spawns `stateObserverTask` that loops over `client.stateStream` and
  writes to `self.connectionState`.
- `try await client.connect(mode: .normal)` — handshakes both VCSEC and
  Infotainment.
- On throw: assign `lastError`, run `disconnect()` to clean up.

**`disconnect()`:**

- Cancels `livePollTask` and `stateObserverTask`.
- `await client?.disconnect()`.
- Sets `client = nil`, `isLive = false`, and leaves `connectionState` to
  reach `.disconnected` via the stream (or forces it if the stream is
  already torn down).

**`refreshDrive()`:**

- One-shot `try await client!.fetchDrive()`; writes result to `drive`.
- Errors caught → `lastError`.

**`setLive(_:)`:**

- `true`: cancels any existing `livePollTask`, starts a new one running
  `while !Task.isCancelled { await refreshDrive(); try? await
Task.sleep(for: .seconds(2)) }`. The loop short-circuits (skip the
  fetch, keep sleeping) when `connectionState != .connected`.
- `false`: cancels `livePollTask` and nils it.
- Errors thrown inside the loop's `refreshDrive()` are logged via
  `os.Logger` and **not** assigned to `lastError` — a transient miss
  should not spam alerts.

**`unlock()` / `honk()`:**

- `try await client!.send(.security(.unlock))` / `.actions(.honk)`.
- Errors caught → `lastError`.
- Callers (the buttons) are expected to gate on `connectionState ==
.connected` and to manage their own per-button "in-flight" state.

**`clearPairing()`:**

- Requires `client == nil` (call `disconnect()` first in the UI).
- Removes the keypair via `keyStore.deletePrivateKey(forVIN:)` (or
  equivalent — see "Open questions" below if the method name differs).
- Clears `store.pairedVIN`.
- Sets `pairedVIN = nil`, `drive = nil`, `isLive = false`.

### `PairedVehicleStore`

A tiny wrapper around `UserDefaults.standard` with one key,
`"com.example.TeslaBLEDemo.pairedVIN"`. Methods: `pairedVIN: String?
{ get }`, `setPairedVIN(_ vin: String)`, `clearPairedVIN()`. No reactive
publishing — the controller is the single source of truth for the UI.

### Screens

All views use only stock SwiftUI components (`Form`, `Section`, `List`,
`Label`, `GroupBox`, `TextField`, `Toggle`, `Button`, `ProgressView`,
`NavigationStack`, `.alert`, `.confirmationDialog`, `.refreshable`).

#### `RootView`

```swift
NavigationStack {
    Group {
        if controller.pairedVIN != nil {
            DashboardView()
        } else {
            PairingView()
        }
    }
    .navigationTitle("Tesla BLE Demo")
}
.alert("Error", isPresented: errorBinding,
       actions: { Button("OK") {} },
       message: { Text(controller.lastError ?? "") })
```

The `errorBinding` is a computed `Binding<Bool>` on
`controller.lastError != nil`. One alert for the whole app.

#### `PairingView`

A `Form` with:

- `Section("Vehicle")` — `TextField("VIN (17 characters)", text: $vin)`
  with `.textInputAutocapitalization(.characters)`,
  `.autocorrectionDisabled()`, `.monospaced()`. The primary button is
  disabled until `vin.count == 17`.
- `Section("How pairing works")` — a `Text` block explaining the
  three-step flow: (1) walk up to the vehicle, (2) tap **Start pairing**,
  (3) when prompted, tap your existing owner key card on the center
  console.
- Primary button `Button("Start pairing") { Task { await
controller.startPairing(vin: vin) } }`, with a trailing `ProgressView`
  while `controller.isPairing`.

#### `DashboardView`

A `List` with three sections:

- **`ConnectionStatusRow`** — a `Label` whose title follows
  `connectionState` ("Connecting…", "Connected", "Disconnected", "Failed:
  …") and whose `systemImage` changes by state (`"wifi"`, `"wifi.slash"`,
  `"exclamationmark.triangle"`). A trailing `ProgressView` shows while
  `.connecting`.
- **`DriveStateCard`** — a `GroupBox("Drive state")` with rows for gear,
  speed, power, and odometer, each reading from `controller.drive` with a
  `—` fallback when nil. Below the rows: `Button("Refresh") { Task {
await controller.refreshDrive() } }` and `Toggle("Live (2s)", isOn:
Binding(get: { controller.isLive }, set: { controller.setLive($0) }))`.
  The enclosing `List` also gets `.refreshable { await
controller.refreshDrive() }`.
- **Commands** — a `Section("Commands")` with two buttons, **Unlock** and
  **Honk**, each kicking off a `Task` that calls `controller.unlock()` /
  `.honk()`. Each button has local `@State var isSending` that disables
  it while its task is running. Both buttons are also
  `.disabled(controller.connectionState != .connected)`.
- **Forget this vehicle** — a destructive `Button` at the bottom of the
  `List` with a `.confirmationDialog` that calls `disconnect()` then
  `clearPairing()`.

**Dashboard lifecycle:**

```swift
.task { await controller.connect() }
.onDisappear { Task { await controller.disconnect() } }
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .background: Task { await controller.disconnect() }
    case .active:     Task { await controller.connect() }
    default: break
    }
}
```

## Data flow

- **SwiftUI → controller:** views call controller methods directly
  (`startPairing`, `connect`, `refreshDrive`, `setLive`, `unlock`,
  `honk`, `clearPairing`). No bindings pass raw state into methods.
- **Controller → SwiftUI:** views read observable properties
  (`pairedVIN`, `connectionState`, `drive`, `isPairing`, `isLive`,
  `lastError`). Because the controller is `@Observable @MainActor`,
  mutations trigger SwiftUI updates on the main thread automatically.
- **Controller → `TeslaBLE`:** all calls funnel through
  `self.client` (a `TeslaVehicleClient` actor). Await-points are
  natural; no manual threading. The `stateObserverTask` is the only
  long-lived subscription into the client; the `livePollTask` only uses
  one-shot `fetchDrive()` calls.
- **Persistence boundaries:** keypair → Keychain via
  `KeychainTeslaKeyStore(service: "com.example.TeslaBLEDemo")`. VIN →
  `UserDefaults` via `PairedVehicleStore`. Nothing else is persisted —
  `connectionState`, `drive`, and `isLive` are all ephemeral.

## Error handling

Single path: every throwing method on `VehicleController` catches errors
at its boundary, assigns `lastError = String(describing: error)`, and
logs via `os.Logger(subsystem: "com.example.TeslaBLEDemo", category:
"demo")`. `RootView` binds one `.alert` to `lastError`. No per-button
alerts.

### Specific cases

- **Bluetooth off / unauthorized.** `client.connect()` throws; the alert
  shows; `connectionState` settles at `.disconnected`. No automatic
  retry — user backs out and re-enters, or toggles scene phase.
- **Vehicle out of range / scan timeout.** Same as above.
- **Pairing throw.** The ephemeral pairing client is disconnected in a
  `defer` regardless of outcome. `pairedVIN` is only written on the
  success path; a failed attempt leaves the user on the pairing screen
  with the alert showing.
- **Pairing succeeds, NFC tap never happens.** `addKey` returns as soon
  as the car accepts the request; it does not wait for NFC authorization.
  The dashboard includes a helper `Text` — "If you haven't already, tap
  your owner key card on the center console, then reconnect." The first
  `connect(mode: .normal)` will fail until the NFC authorization lands,
  and that failure rides the normal alert path.
- **Live-poll-loop errors.** Logged, not alerted. Transient misses are
  expected and must not spam the UI.
- **Command buttons while disconnected.** Buttons are
  `.disabled(connectionState != .connected)`.
- **Rapid button taps.** Each command button owns a local
  `@State var isSending` that disables it while its task is running.
- **Scene goes background mid-request.** `disconnect()` cancels the
  tasks it owns; in-flight `fetchDrive`/`send` calls throw
  `CancellationError`, which the loop and methods swallow. No alert for
  cancellations.

## Testing

The example app has no unit or UI test target of its own. The
`TeslaBLE` package carries 141 deterministic tests against fixtures
from the Go reference implementation; the demo exists to validate the
real hardware path that those tests cannot cover. Adding a mocked test
target to the demo would duplicate package-level coverage while
contributing no hardware validation.

The implementation is validated by:

1. `swift build` at the repo root still succeeds (the `Examples/`
   directory is not a SwiftPM target, so this is a sanity check).
2. Opening `Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj` in Xcode and
   building for an iOS 17 simulator succeeds.
3. Running the app against a real paired vehicle and confirming: (a)
   pairing flow places the car in "tap NFC card to authorize" mode, (b)
   after authorization, the dashboard reaches `.connected`, (c)
   `fetchDrive()` returns non-nil fields, (d) unlock and honk execute
   against the car. This step is the user's responsibility and is the
   whole reason the demo exists.

## Open questions / verification during implementation

- **Keystore delete API.** The design assumes `KeychainTeslaKeyStore`
  exposes a delete-by-VIN method. The implementation plan must verify
  the actual method name (or add one if missing) before wiring
  `clearPairing()`.
- **`ConnectionState` cases.** The status-row copy above assumes cases
  like `.disconnected`, `.connecting`, `.connected`, and a failure
  variant. The implementation plan must read
  `Sources/TeslaBLE/Client/ConnectionState.swift` and map the actual
  cases to status strings.
- **`stateStream` termination semantics.** The design assumes the stream
  completes when the client disconnects; the implementation plan must
  confirm and decide whether `stateObserverTask` needs an explicit
  cancel or can rely on natural completion.
- **Local SwiftPM path.** Committing `.xcodeproj` with a local-path
  package reference is intentional. The implementation plan must
  generate the project with a relative path (`../..`) so the example
  works for any checkout location.

## Next step

Hand off to `writing-plans` to produce a step-by-step implementation
plan covering project creation, controller implementation, each view,
Info.plist wiring, and the README.
