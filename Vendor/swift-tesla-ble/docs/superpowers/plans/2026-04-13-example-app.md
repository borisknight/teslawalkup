# TeslaBLEDemo Example App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal SwiftUI example app (`Examples/TeslaBLEDemo/`) that exercises the `TeslaBLE` package's pairing flow, drive-state reads, and two signed commands (unlock, honk) on a real vehicle.

**Architecture:** One `@Observable @MainActor VehicleController` owns the `TeslaVehicleClient` actor and mediates all state. SwiftUI views (`PairingView`, `DashboardView` and small subviews) read observable properties and call controller methods. Keypair persists in Keychain via `KeychainTeslaKeyStore`; VIN persists in `UserDefaults`.

**Tech Stack:** Swift 6.2, SwiftUI, iOS 17, CoreBluetooth (indirectly via `TeslaBLE`), local-path SwiftPM dependency, XcodeGen (one-time, for generating the committed `.xcodeproj`).

---

## Notes for the engineer

- **You do not have Xcode UI access.** The `.xcodeproj` is generated via `xcodegen` from a committed `project.yml`, then the resulting `.xcodeproj` bundle is committed. After generation the app is self-contained — future users do not need xcodegen installed to open or run it.
- **No test target for this app.** The parent package has 141 tests; this demo's validation is "builds with `xcodebuild` and runs on a real paired vehicle." Each task ends with a build check, not a unit test.
- **Repo layout.** Everything lives under `Examples/TeslaBLEDemo/`. The parent repo root is the working directory — absolute paths below start at `/Users/jiaxinshou/Developer/swift-tesla-ble`.
- **API facts verified before writing this plan.** Don't second-guess these:
  - `ConnectionState` has exactly 5 cases: `.disconnected`, `.scanning`, `.connecting`, `.handshaking`, `.connected`. No error case — errors are thrown, not pushed onto `stateStream`.
  - `TeslaVehicleClient.stateStream` is `nonisolated` and "never finishes for the lifetime of the client." The observer task **must** be explicitly cancelled on teardown; it will not complete on its own.
  - `KeychainTeslaKeyStore` exposes `loadPrivateKey(forVIN:)`, `savePrivateKey(_:forVIN:)`, and `deletePrivateKey(forVIN:)` — all throwing.
  - `Command.Security` has `.lock` and `.unlock` (lines 33, 35 of `Command.swift`). `Command.Actions` has `.honk` and `.flashLights` (lines 430, 432).
  - `Command.Security.addKey(publicKey: Data, role: KeyRole, formFactor: KeyFormFactor)` — `KeyRole.owner` and `KeyFormFactor.iosDevice`.
  - `TeslaVehicleClient` is `public actor` gated on `@available(macOS 13.0, iOS 16.0, *)`. The app targets iOS 17, so no availability annotations are needed on the caller side.
  - `TeslaVehicleClient.connect(mode:timeout:)` → throws. `.send(_:timeout:)` → throws. `.fetchDrive(timeout:)` → throws, returns `DriveState`. `.disconnect()` → async, non-throwing.
- **No error-case on `ConnectionState`.** The dashboard status row's "Failed: …" copy from the spec does **not** come from `connectionState`; it comes from the controller's `lastError` as a separate line below the status row. Keep the status row honest to the 5-case enum.

---

## File map

```
Examples/TeslaBLEDemo/
├── project.yml                        # xcodegen input — committed
├── TeslaBLEDemo.xcodeproj/             # xcodegen output — committed
└── TeslaBLEDemo/
    ├── TeslaBLEDemoApp.swift           # @main
    ├── VehicleController.swift         # integration layer
    ├── PairedVehicleStore.swift        # UserDefaults wrapper
    ├── Info.plist
    ├── Assets.xcassets/
    │   ├── Contents.json
    │   ├── AccentColor.colorset/Contents.json
    │   └── AppIcon.appiconset/Contents.json
    └── Views/
        ├── RootView.swift
        ├── PairingView.swift
        ├── DashboardView.swift
        ├── ConnectionStatusRow.swift
        └── DriveStateCard.swift
Examples/TeslaBLEDemo/README.md         # run instructions
```

One file per responsibility. `VehicleController.swift` is the largest file and is intentionally kept in one piece — it is the "study this to learn the package" entry point the spec calls out.

---

## Task 0: Prerequisite check — xcodegen

**Files:** none yet (tool check only).

- [ ] **Step 1: Check whether `xcodegen` is already installed**

Run:

```bash
which xcodegen || echo "NOT INSTALLED"
```

Expected output: a path like `/opt/homebrew/bin/xcodegen` **or** `NOT INSTALLED`.

- [ ] **Step 2: If not installed, install via Homebrew**

Run (only if the previous step printed `NOT INSTALLED`):

```bash
brew install xcodegen
```

Expected: successful install; re-run `which xcodegen` and confirm it now prints a path.

- [ ] **Step 3: Verify version ≥ 2.38**

Run:

```bash
xcodegen --version
```

Expected: a version line like `Version: 2.4x.x`. Any 2.x release is fine for the project spec we will feed it.

**Do not commit anything in this task.** It only verifies the generator tool.

---

## Task 1: Create `project.yml`

**Files:**

- Create: `/Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/project.yml`

- [ ] **Step 1: Make sure the `Examples/TeslaBLEDemo/` directory exists**

Run:

```bash
mkdir -p /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo/Views
mkdir -p /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo/Assets.xcassets/AppIcon.appiconset
mkdir -p /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo/Assets.xcassets/AccentColor.colorset
ls /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo
```

Expected: the directory tree is created; the final `ls` prints `TeslaBLEDemo`.

- [ ] **Step 2: Write `project.yml`**

Create `Examples/TeslaBLEDemo/project.yml` with this exact content:

```yaml
name: TeslaBLEDemo
options:
  bundleIdPrefix: com.example
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
  xcodeVersion: "16.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    DEVELOPMENT_TEAM: ""
    CODE_SIGN_STYLE: Automatic
packages:
  TeslaBLE:
    path: ../..
targets:
  TeslaBLEDemo:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: TeslaBLEDemo
    resources:
      - path: TeslaBLEDemo/Assets.xcassets
    info:
      path: TeslaBLEDemo/Info.plist
      properties:
        CFBundleDisplayName: Tesla BLE Demo
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        NSBluetoothAlwaysUsageDescription: This demo connects to your paired Tesla vehicle over Bluetooth.
        UILaunchScreen:
          UIColorName: ""
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
        UIRequiredDeviceCapabilities:
          - armv7
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.TeslaBLEDemo
        TARGETED_DEVICE_FAMILY: "1,2"
        ENABLE_PREVIEWS: YES
        GENERATE_INFOPLIST_FILE: NO
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    dependencies:
      - package: TeslaBLE
        product: TeslaBLE
```

- [ ] **Step 3: Commit**

Run:

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/project.yml
git -c commit.gpgsign=false commit -m "feat(example): add xcodegen project.yml"
```

Expected: one commit created; no hook failures.

---

## Task 2: Generate the Xcode project and the Info.plist

**Files:**

- Create: `/Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo/Info.plist`
- Create (via xcodegen): `/Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj/`

xcodegen will not generate the app itself without at least one Swift source file, so we stub a main file first, let xcodegen generate, then move on. We also write the `Info.plist` by hand — xcodegen's `info.properties` writes it at generation time, but some xcodegen versions elide fields when the file already exists, so we control it explicitly.

- [ ] **Step 1: Write a throwaway stub `TeslaBLEDemoApp.swift`**

Create `Examples/TeslaBLEDemo/TeslaBLEDemo/TeslaBLEDemoApp.swift` with this exact content (it will be overwritten in Task 5):

```swift
import SwiftUI

@main
struct TeslaBLEDemoApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Stub — will be replaced.")
        }
    }
}
```

- [ ] **Step 2: Write `Info.plist`**

Create `Examples/TeslaBLEDemo/TeslaBLEDemo/Info.plist` with this exact content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key>
    <string>Tesla BLE Demo</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>This demo connects to your paired Tesla vehicle over Bluetooth.</string>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
    </dict>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>armv7</string>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: Write the three asset-catalog `Contents.json` files**

Create `Examples/TeslaBLEDemo/TeslaBLEDemo/Assets.xcassets/Contents.json`:

```json
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

Create `Examples/TeslaBLEDemo/TeslaBLEDemo/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors": [
    {
      "idiom": "universal"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

Create `Examples/TeslaBLEDemo/TeslaBLEDemo/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images": [
    {
      "idiom": "universal",
      "platform": "ios",
      "size": "1024x1024"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

- [ ] **Step 4: Run xcodegen**

Run:

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo
xcodegen generate
```

Expected: output ending with a line like `⚙️  Generated project to: ...` and exit code 0. A new `TeslaBLEDemo.xcodeproj` directory appears alongside `project.yml`.

- [ ] **Step 5: Smoke-build the stub for the iOS Simulator**

Run:

```bash
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -20
```

Expected: `** BUILD SUCCEEDED **` on the last line. If the command fails because no iOS Simulator SDK is available, fall back to `-destination 'platform=iOS,name=Any iOS Device'` with `CODE_SIGNING_ALLOWED=NO`. If `xcodebuild` is not available at all, the whole plan cannot be validated on this host — stop and report.

- [ ] **Step 6: Commit**

Run:

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj Examples/TeslaBLEDemo/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): generate Xcode project, Info.plist, asset catalog"
```

Expected: one commit including `project.pbxproj` and the stub `TeslaBLEDemoApp.swift`, `Info.plist`, and asset catalog.

---

## Task 3: `PairedVehicleStore`

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/PairedVehicleStore.swift`

- [ ] **Step 1: Write the file**

Exact content:

```swift
import Foundation

/// Tiny `UserDefaults` wrapper persisting a single paired VIN.
///
/// The demo intentionally supports one vehicle at a time; clearing resets the
/// app to the pairing screen.
struct PairedVehicleStore {
    private let defaults: UserDefaults
    private let key = "com.example.TeslaBLEDemo.pairedVIN"

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
```

- [ ] **Step 2: Regenerate the Xcode project so xcodegen picks up the new source**

Run:

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
```

Expected: `⚙️  Generated project to: ...`. (Any file added under `TeslaBLEDemo/` auto-pulls in via the `sources: [path: TeslaBLEDemo]` rule — but regenerate after every add to keep `project.pbxproj` in sync.)

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/TeslaBLEDemo/PairedVehicleStore.swift Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj
git -c commit.gpgsign=false commit -m "feat(example): add PairedVehicleStore"
```

---

## Task 4: `VehicleController` — state, init, and lifecycle helpers

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift`

This task lays down the `@Observable @MainActor` class with all observable properties and stubbed-out method signatures — enough to compile. The method bodies are fleshed out in Tasks 5–7. Splitting the class across tasks keeps each step small and lets each build check confirm the previous task didn't break compilation.

- [ ] **Step 1: Write the skeleton**

Exact content of `Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift`:

```swift
import Foundation
import OSLog
import SwiftUI
import TeslaBLE

/// Single source of truth wrapping `TeslaVehicleClient` for the demo UI.
///
/// All mutations happen on the main actor so SwiftUI bindings fire on the
/// main thread. Every throwing call to the client funnels through a catch
/// block that assigns `lastError` — the UI shows a single global alert.
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
    private let logger = Logger(subsystem: "com.example.TeslaBLEDemo", category: "controller")

    private var client: TeslaVehicleClient?
    private var stateObserverTask: Task<Void, Never>?
    private var livePollTask: Task<Void, Never>?

    init(
        keyStore: KeychainTeslaKeyStore = KeychainTeslaKeyStore(service: "com.example.TeslaBLEDemo"),
        store: PairedVehicleStore = PairedVehicleStore()
    ) {
        self.keyStore = keyStore
        self.store = store
        self.pairedVIN = store.pairedVIN
    }

    // MARK: - Pairing (Task 6)

    func startPairing(vin: String) async {
        // Implemented in Task 6.
    }

    func clearPairing() {
        // Implemented in Task 6.
    }

    // MARK: - Session (Task 5)

    func connect() async {
        // Implemented in Task 5.
    }

    func disconnect() async {
        // Implemented in Task 5.
    }

    // MARK: - Reads & commands (Task 7)

    func refreshDrive() async {
        // Implemented in Task 7.
    }

    func setLive(_ on: Bool) {
        // Implemented in Task 7.
    }

    func unlock() async {
        // Implemented in Task 7.
    }

    func honk() async {
        // Implemented in Task 7.
    }
}
```

Note: the four `case` names that appear later in the views (`.disconnected`, `.scanning`, `.connecting`, `.handshaking`, `.connected`) come from `TeslaBLE.ConnectionState`. They are implicitly imported via `import TeslaBLE`.

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): add VehicleController skeleton"
```

---

## Task 5: `VehicleController` — connect / disconnect

**Files:**

- Modify: `Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift`

- [ ] **Step 1: Replace the `connect()` stub**

Replace the body of `func connect() async { ... }` (the `// Implemented in Task 5.` stub) with:

```swift
    func connect() async {
        guard let vin = pairedVIN else {
            lastError = "No paired vehicle."
            return
        }
        guard client == nil else { return }

        let newClient = TeslaVehicleClient(vin: vin, keyStore: keyStore)
        self.client = newClient

        // Subscribe to state transitions. This stream never finishes for the
        // lifetime of the client, so we MUST cancel this task in disconnect().
        stateObserverTask = Task { [weak self] in
            for await state in newClient.stateStream {
                guard let self else { return }
                await MainActor.run { self.connectionState = state }
                if Task.isCancelled { return }
            }
        }

        do {
            try await newClient.connect(mode: .normal)
        } catch {
            logger.error("connect failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
            await disconnect()
        }
    }
```

- [ ] **Step 2: Replace the `disconnect()` stub**

Replace the body of `func disconnect() async { ... }` with:

```swift
    func disconnect() async {
        livePollTask?.cancel()
        livePollTask = nil
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
    }
```

- [ ] **Step 3: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift
git -c commit.gpgsign=false commit -m "feat(example): implement VehicleController connect/disconnect"
```

---

## Task 6: `VehicleController` — pairing flow

**Files:**

- Modify: `Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift`

- [ ] **Step 1: Replace the `startPairing` stub**

Replace the body of `func startPairing(vin: String) async { ... }` with:

```swift
    func startPairing(vin: String) async {
        guard vin.count == 17 else {
            lastError = "VIN must be exactly 17 characters."
            return
        }
        guard !isPairing else { return }
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
                    .security(.addKey(publicKey: publicKey, role: .owner, formFactor: .iosDevice))
                )
                await pairingClient.disconnect()
            } catch {
                await pairingClient.disconnect()
                throw error
            }

            store.setPairedVIN(vin)
            self.pairedVIN = vin
        } catch {
            logger.error("pairing failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }
```

- [ ] **Step 2: Add the `CryptoKit` import**

At the top of the file, alongside the existing imports, add:

```swift
import CryptoKit
```

This is required because `startPairing` names `P256.KeyAgreement.PrivateKey` explicitly in its type annotation.

- [ ] **Step 3: Replace the `clearPairing` stub**

Replace `func clearPairing() { ... }` with:

```swift
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
        connectionState = .disconnected
    }
```

- [ ] **Step 4: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`. If the compiler complains that `P256` isn't in scope, confirm the `import CryptoKit` was added in Step 2.

- [ ] **Step 5: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift
git -c commit.gpgsign=false commit -m "feat(example): implement VehicleController pairing flow"
```

---

## Task 7: `VehicleController` — drive reads, live poll, commands

**Files:**

- Modify: `Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift`

- [ ] **Step 1: Replace the `refreshDrive` stub**

```swift
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
```

- [ ] **Step 2: Replace the `setLive` stub**

```swift
    func setLive(_ on: Bool) {
        guard on != isLive else { return }
        isLive = on
        livePollTask?.cancel()
        livePollTask = nil
        guard on else { return }

        livePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await MainActor.run(body: { self.connectionState }) == .connected {
                    await self.pollOnce()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Live-loop variant of `refreshDrive` that never writes to `lastError`.
    /// Transient misses while Live is on must not spam the global alert.
    private func pollOnce() async {
        guard let client else { return }
        do {
            let drive = try await client.fetchDrive()
            self.drive = drive
        } catch {
            logger.debug("live poll miss: \(String(describing: error), privacy: .public)")
        }
    }
```

- [ ] **Step 3: Replace the `unlock` stub**

```swift
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
```

- [ ] **Step 4: Replace the `honk` stub**

```swift
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
```

- [ ] **Step 5: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/TeslaBLEDemo/VehicleController.swift
git -c commit.gpgsign=false commit -m "feat(example): implement VehicleController drive reads and commands"
```

---

## Task 8: `ConnectionStatusRow`

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/Views/ConnectionStatusRow.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import TeslaBLE

/// Single row summarizing `ConnectionState`. Driven entirely by the enum
/// — errors are shown via the global alert, not this row.
struct ConnectionStatusRow: View {
    let state: ConnectionState

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer()
            if isBusy {
                ProgressView()
            }
        }
    }

    private var title: String {
        switch state {
        case .disconnected: return "Disconnected"
        case .scanning:     return "Scanning…"
        case .connecting:   return "Connecting…"
        case .handshaking:  return "Handshaking…"
        case .connected:    return "Connected"
        }
    }

    private var systemImage: String {
        switch state {
        case .disconnected: return "wifi.slash"
        case .scanning, .connecting, .handshaking: return "antenna.radiowaves.left.and.right"
        case .connected:    return "wifi"
        }
    }

    private var isBusy: Bool {
        switch state {
        case .scanning, .connecting, .handshaking: return true
        default: return false
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): add ConnectionStatusRow view"
```

---

## Task 9: `DriveStateCard`

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/Views/DriveStateCard.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import TeslaBLE

/// GroupBox presenting gear/speed/power/odometer from `DriveState`, with
/// manual refresh and a live-poll toggle.
struct DriveStateCard: View {
    let drive: DriveState?
    let isLive: Bool
    let onRefresh: () -> Void
    let onToggleLive: (Bool) -> Void

    var body: some View {
        GroupBox("Drive state") {
            VStack(alignment: .leading, spacing: 8) {
                row("Gear", value: gearString)
                row("Speed", value: speedString)
                row("Power", value: powerString)
                row("Odometer", value: odometerString)

                Divider()

                HStack {
                    Button("Refresh", action: onRefresh)
                        .buttonStyle(.bordered)
                    Spacer()
                    Toggle(
                        "Live (2s)",
                        isOn: Binding(get: { isLive }, set: { onToggleLive($0) })
                    )
                    .labelsHidden()
                    Text("Live")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var gearString: String {
        switch drive?.shiftState {
        case .park:    return "P"
        case .reverse: return "R"
        case .neutral: return "N"
        case .drive:   return "D"
        case .none:    return "—"
        }
    }

    private var speedString: String {
        guard let mph = drive?.speedMph else { return "—" }
        return String(format: "%.0f mph", mph)
    }

    private var powerString: String {
        guard let kw = drive?.powerKW else { return "—" }
        return "\(kw) kW"
    }

    private var odometerString: String {
        guard let hundredths = drive?.odometerHundredthsMile else { return "—" }
        return String(format: "%.2f mi", Double(hundredths) / 100)
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): add DriveStateCard view"
```

---

## Task 10: `PairingView`

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/Views/PairingView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct PairingView: View {
    @Environment(VehicleController.self) private var controller
    @State private var vin: String = ""

    var body: some View {
        Form {
            Section("Vehicle") {
                TextField("VIN (17 characters)", text: $vin)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .monospaced()
            }

            Section("How pairing works") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Walk up to your vehicle with this phone.")
                    Text("2. Tap **Start pairing** below.")
                    Text("3. When prompted, tap your existing owner key card on the center console to authorize this device.")
                }
                .font(.footnote)
            }

            Section {
                Button {
                    Task { await controller.startPairing(vin: vin) }
                } label: {
                    HStack {
                        Text("Start pairing")
                        if controller.isPairing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(vin.count != 17 || controller.isPairing)
            }
        }
        .navigationTitle("Pair vehicle")
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): add PairingView"
```

---

## Task 11: `DashboardView`

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/Views/DashboardView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct DashboardView: View {
    @Environment(VehicleController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

    @State private var isUnlocking = false
    @State private var isHonking = false
    @State private var showForgetConfirm = false

    var body: some View {
        List {
            Section("Status") {
                ConnectionStatusRow(state: controller.connectionState)
                if let vin = controller.pairedVIN {
                    HStack {
                        Text("VIN")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(vin).monospaced().font(.footnote)
                    }
                }
            }

            Section {
                DriveStateCard(
                    drive: controller.drive,
                    isLive: controller.isLive,
                    onRefresh: { Task { await controller.refreshDrive() } },
                    onToggleLive: { controller.setLive($0) }
                )
            }

            Section("Commands") {
                Button {
                    Task {
                        isUnlocking = true
                        await controller.unlock()
                        isUnlocking = false
                    }
                } label: {
                    HStack {
                        Text("Unlock")
                        if isUnlocking { Spacer(); ProgressView() }
                    }
                }
                .disabled(controller.connectionState != .connected || isUnlocking)

                Button {
                    Task {
                        isHonking = true
                        await controller.honk()
                        isHonking = false
                    }
                } label: {
                    HStack {
                        Text("Honk")
                        if isHonking { Spacer(); ProgressView() }
                    }
                }
                .disabled(controller.connectionState != .connected || isHonking)
            }

            Section {
                Button("Forget this vehicle", role: .destructive) {
                    showForgetConfirm = true
                }
            } footer: {
                Text("Removes the stored key and VIN. You will need to pair again.")
            }
        }
        .refreshable { await controller.refreshDrive() }
        .navigationTitle("Dashboard")
        .confirmationDialog(
            "Forget this vehicle?",
            isPresented: $showForgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                Task {
                    await controller.disconnect()
                    controller.clearPairing()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await controller.connect() }
        .onDisappear { Task { await controller.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await controller.disconnect() }
            case .active:     Task { await controller.connect() }
            default: break
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): add DashboardView"
```

---

## Task 12: `RootView` and global alert wiring

**Files:**

- Create: `Examples/TeslaBLEDemo/TeslaBLEDemo/Views/RootView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct RootView: View {
    @Environment(VehicleController.self) private var controller

    var body: some View {
        @Bindable var bindable = controller
        NavigationStack {
            Group {
                if controller.pairedVIN != nil {
                    DashboardView()
                } else {
                    PairingView()
                }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { controller.lastError != nil },
                set: { if !$0 { bindable.lastError = nil } }
            ),
            actions: { Button("OK") {} },
            message: { Text(controller.lastError ?? "") }
        )
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo
git -c commit.gpgsign=false commit -m "feat(example): add RootView with global error alert"
```

---

## Task 13: Replace the stub `TeslaBLEDemoApp.swift`

**Files:**

- Modify: `Examples/TeslaBLEDemo/TeslaBLEDemo/TeslaBLEDemoApp.swift`

- [ ] **Step 1: Overwrite the stub**

Replace the entire file contents with:

```swift
import SwiftUI

@main
struct TeslaBLEDemoApp: App {
    @State private var controller = VehicleController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo && xcodegen generate
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/TeslaBLEDemo/TeslaBLEDemoApp.swift Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj
git -c commit.gpgsign=false commit -m "feat(example): wire TeslaBLEDemoApp entry point"
```

---

## Task 14: `Examples/TeslaBLEDemo/README.md`

**Files:**

- Create: `Examples/TeslaBLEDemo/README.md`

- [ ] **Step 1: Write the README**

Exact content:

````markdown
# TeslaBLEDemo

A minimal SwiftUI example app exercising the `TeslaBLE` package against a real Tesla vehicle. The app covers:

- First-time BLE pairing (`connect(mode: .pairing)` + unsigned `addKey`).
- Reading drive state (`fetchDrive()`) with manual refresh and an opt-in 2-second live-poll toggle.
- Two signed commands: `security.unlock` and `actions.honk`.

## Running

1. Open `Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj` in Xcode 16 or later.
2. Select the `TeslaBLEDemo` scheme.
3. In **Signing & Capabilities**, set a development team — automatic signing is on; no team is baked into the committed project.
4. Build and run on a real iOS 17+ device. CoreBluetooth does not work in the simulator.
5. Enter your vehicle's 17-character VIN, tap **Start pairing**, and follow the prompt on the car's center console (tap your existing owner key card).
6. After authorization completes, the dashboard auto-connects. Use **Refresh** or flip **Live** to pull drive state; use **Unlock** and **Honk** to prove the signed command path.

## Regenerating the Xcode project

The `.xcodeproj` is committed and does not require any tooling to open. If you modify `project.yml` (e.g. to add files or settings), regenerate with:

```bash
brew install xcodegen   # once
cd Examples/TeslaBLEDemo
xcodegen generate
```

## Caveats

- The keypair is stored in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It is not included in iCloud or device backups; restoring to a new device requires re-pairing.
- The demo runs foreground-only. Background BLE is out of scope.
- The demo is single-vehicle. Use **Forget this vehicle** to clear the stored key + VIN and re-pair a different car.
````

- [ ] **Step 2: Commit**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git add Examples/TeslaBLEDemo/README.md
git -c commit.gpgsign=false commit -m "docs(example): add README"
```

---

## Task 15: Final verification

**Files:** none.

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -project /Users/jiaxinshou/Developer/swift-tesla-ble/Examples/TeslaBLEDemo/TeslaBLEDemo.xcodeproj \
  -scheme TeslaBLEDemo -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  clean build | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Confirm the parent package still builds and tests pass**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
swift build 2>&1 | tail -5
swift test 2>&1 | tail -10
```

Expected: `Build complete!` and all 141 tests pass.

- [ ] **Step 3: Confirm the committed `.xcodeproj` has no uncommitted churn**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
git status
```

Expected: working tree clean. If anything is dirty after a plain regenerate, investigate before claiming completion — xcodegen output should be stable across identical inputs.

- [ ] **Step 4: Stop and report**

Hand back to the user. Hardware validation (pair against an actual vehicle, confirm Unlock and Honk work) is their responsibility — the demo exists to enable that step, not replace it.

---

## Self-review notes (not an executable task)

- Spec coverage: every component, screen, persistence boundary, and error path from `2026-04-13-example-app-design.md` has at least one task. The four "Open questions" from the spec are answered inline in the "Notes for the engineer" section.
- Type consistency: `ConnectionState` cases match the source file; `Command.Security.unlock`, `Command.Actions.honk`, and `Command.Security.addKey(publicKey:role:formFactor:)` match `Command.swift`; `KeychainTeslaKeyStore.deletePrivateKey(forVIN:)` matches the source.
- The spec's "Failed: …" status-row copy is intentionally dropped because `ConnectionState` has no error case. Errors surface via the global alert, per the spec's error-handling section.
