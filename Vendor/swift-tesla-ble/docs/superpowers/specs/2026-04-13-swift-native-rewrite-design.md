# Swift Native Rewrite — Design

**Date:** 2026-04-13
**Status:** Approved for implementation planning
**Branch (execution):** `native-swift`

## 1. Goals, Non-Goals, Scope

### Goals

- Eliminate the `TeslaCommand.xcframework` binary target, `GoPatches/mobile.go`, `scripts/bootstrap.sh`, `scripts/build-xcframework.sh`, and the entire `gomobile` build chain. After this work `swift build` requires no Go toolchain.
- Reimplement the complete BLE-side vehicle command surface of `pkg/vehicle` in pure Swift — the full "C" scope: state fetch, charge, climate, VCSEC, security, infotainment, actions, media, parental controls, schedules, tire pressure, software update. Roughly 40+ commands.
- Keep the library iOS-only. `Package.swift` no longer declares macOS as a supported platform.
- Public API is allowed to break. The client exposes a unified `send(_: Command)` entry plus `fetch(_: StateQuery)` / `fetchDrive()`. No legacy wrappers are preserved.

### Non-Goals

- Tesla Fleet HTTP API (OAuth, JWT, Schnorr over secp256r1). BLE only.
- Porting `pkg/account`, `pkg/cache`, `pkg/cli`, `pkg/connector`, `pkg/proxy`, `pkg/sign`, `cmd/`, `examples/`, or anything else outside the BLE command path.
- Runtime support for macOS. Compile-time conditionals for macOS are removed too.
- Publishing a prebuilt binary artifact (no xcframework, no `.binaryTarget(url:)`). Pure-source SwiftPM dependency.

### In-Scope Go Code (to port)

- `internal/authentication/` — all of it except `jwt.go` and `schnorr/*`. That is: `crypto.go`, `ecdh.go`, `peer.go`, `signer.go`, `verifier.go`, `metadata.go`, `window.go`, `session.go`, `dispatcher.go`, `error.go`.
- `internal/dispatcher/` — `dispatcher.go`, `receiver.go`, `session.go`.
- `pkg/protocol/` — `domains.go`, `key.go`, `receiver.go`, `error.go` (the helpers actually imported by the command path).
- `pkg/vehicle/` — all of it except `doc.go`.

### Size Estimate

Go source in scope is ~4.2k lines (tests excluded). Swift reimplementation projected at ~3.5k–4.5k LOC plus ~3k LOC of tests.

## 2. Architecture and Module Layout

Swift-idiomatic decomposition (chosen over a line-by-line mirror of Go — correctness is enforced by the test layers in §6, not by file-level parity).

```
Sources/TeslaBLE/
  Crypto/
    P256ECDH.swift
    SessionKey.swift
    MessageAuthenticator.swift
    CounterWindow.swift
    HMACTag.swift
  Session/
    VehicleSession.swift
    SessionNegotiator.swift
    OutboundSigner.swift
    InboundVerifier.swift
  Dispatcher/
    Dispatcher.swift
    RequestTable.swift
    InboundRouter.swift
  Commands/
    Command.swift
    CommandEncoder.swift
    ResponseDecoder.swift
    Subcommands/
      Security.swift
      Charge.swift
      Climate.swift
      Drive.swift
      Media.swift
      Infotainment.swift
      State.swift
  Client/
    TeslaVehicleClient.swift
    ConnectionState.swift
  Transport/
    BLETransport.swift       (retained)
    MessageFramer.swift      (retained)
  Keys/                      (retained)
  Model/                     (retained)
  Support/                   (retained)
  Generated/                 (retained, proto source now comes from the submodule)
```

### Concurrency Model

- `BLETransport` keeps its Core Bluetooth implementation. It exposes `AsyncStream<Data>` for inbound bytes and `func write(_: Data)` for outbound.
- `Dispatcher` is an actor. It owns an internal inbound `Task` (`for await chunk in transport.inbound`) that frames, decodes, and routes `RoutableMessage` values to either the pending `RequestTable` entry or the session handshake path.
- `VehicleSession` is an actor per domain. `Dispatcher` holds `vcsecSession` and `infotainmentSession` separately.
- `TeslaVehicleClient` is the outermost actor; it owns lifecycle, `ConnectionState` broadcasting, and the `Dispatcher`.
- No raw `Thread` or `DispatchQueue` — every background worker is a `Task` owned by an actor and cancelled on `disconnect()` or `deinit`.

## 3. Component Responsibilities

### 3.1 `Crypto/`

- **`P256ECDH`**: CryptoKit `P256.KeyAgreement` wrapper. Generates ephemeral keypairs, derives shared secrets. Private keys from `TeslaKeyStore` are reconstituted via `P256.KeyAgreement.PrivateKey(rawRepresentation:)`.
- **`SessionKey`**: Derives the 16-byte AES-GCM-128 key from the ECDH shared secret. The vehicle uses **SHA-1 of the 32-byte big-endian shared X coordinate, first 16 bytes** — not HKDF. This is for vehicle compatibility, not a choice (see `internal/authentication/native.go` `NativeECDHKey.Exchange`). SHA-1 is safe here because the input is already a pseudo-random curve point; collision resistance is not required.
- **`MessageAuthenticator`**: `seal(plaintext, aad) -> (ciphertext, tag, nonce)` and `open(...)`. The AAD layout follows `metadata.go`'s TLV format — tag order, length encoding, field presence semantics — and is the first fixture-tested invariant (§6.1).
- **`CounterWindow`**: Value-semantics struct mirroring `window.go`. 64-bit sliding replay window with `accept(counter) -> Bool`.
- **`HMACTag`**: HMAC-SHA256 used during the handshake for SessionInfo challenge computation. Uses the exact "SESSION INFO" string constant from `peer.go`.

### 3.2 `Session/`

- **`VehicleSession`** (actor): One instance per BLE domain. Holds `{ epoch: Data, counterOut: UInt32, window: CounterWindow, sessionKey: SymmetricKey, publicInfo: SessionInfo, clockOffset: TimeInterval }`.
  - `sign(_ request: RoutableMessage) throws -> RoutableMessage` — injects a signed envelope (AES-GCM with metadata AAD) or, for the addKey path, an HMAC envelope used before a session is established.
  - `verify(_ response: RoutableMessage) throws -> RoutableMessage` — verifies tag, opens ciphertext, runs the counter window, rejects on replay or tag mismatch.
- **`SessionNegotiator`**: Stateless helper. Given a domain, constructs a `SessionInfoRequest`. Given a `SessionInfo` response, constructs the initial `VehicleSession` state. The handshake itself is an ordinary request/response pair that flows through `Dispatcher.send`.

### 3.3 `Dispatcher/`

- **`Dispatcher`** (actor): The only component that talks directly to `BLETransport`.
  - Owns: `transport`, `vcsecSession`, `infotainmentSession`, `requestTable`, `inboundTask`.
  - `start()` launches the inbound task which routes inbound messages.
  - `send(_ message: RoutableMessage, domain: Domain, timeout: Duration) async throws -> RoutableMessage`:
    1. Generates a request UUID, registers a `CheckedContinuation` in `RequestTable`.
    2. Calls `session.sign(message)` for the target domain.
    3. Serializes, frames, and writes through `BLETransport`.
    4. Awaits the continuation. A sibling task runs `Task.sleep(for: timeout)` and throws `.commandTimeout` on expiry; whichever returns first wins and the other is cancelled.
  - `negotiate(domain:)` runs the handshake for one domain and installs the resulting `VehicleSession` into `self`.
- **`RequestTable`**: An internal `[UUID: CheckedContinuation<RoutableMessage, Error>]`. `register`, `complete`, `cancel(tag:)`, `cancelAll(error:)`. Cancellation paths are wired through `withTaskCancellationHandler` so that external `Task.cancel()` resolves the continuation with `CancellationError`.
- **`InboundRouter`**: Consumes `BLETransport.inbound` (bytes), drives `MessageFramer` for frame assembly, decodes to `RoutableMessage`, and yields into an internal `AsyncStream` that `Dispatcher` consumes. Single-threaded inside the dispatcher actor.

### 3.4 `Commands/`

`Command` is a nested enum grouped by BLE domain. One outer case per domain family, inner enums for individual operations:

```swift
public enum Command: Sendable {
    case security(Security)
    case charge(Charge)
    case climate(Climate)
    case drive(Drive)
    case media(Media)

    public enum Security: Sendable {
        case lock
        case unlock
        case openTrunk(Trunk)
        case addKey(publicKey: Data, role: KeyRole, formFactor: KeyFormFactor)
        // ... other VCSEC ops
    }

    public enum Charge: Sendable {
        case start
        case stop
        case setLimit(percent: Int)
        case setAmps(Int)
        case openPort
        case closePort
        case setSchedule(ChargeSchedule)
    }

    public enum Climate: Sendable {
        case on
        case off
        case setTemperature(driver: Double, passenger: Double)
        case setSeatHeater(Seat, SeatHeaterLevel)
        case setKeeperMode(ClimateKeeperMode)
        case setPreconditioning(PreconditioningSchedule)
    }

    public enum Drive: Sendable {
        case honk
        case flashLights
        case remoteStart(password: String)
        case actuateTrunk(Trunk)
    }

    public enum Media: Sendable {
        case togglePlayback
        case next
        case previous
        case setVolume(Int)
    }
}
```

Benefits:

- Encoder dispatch is a one-level switch — `case .security(let s): return SecurityEncoder.encode(s)` — with every inner encoder in its own file under `Subcommands/`, each under ~200 lines.
- Outer case → BLE domain mapping is trivial: `.security` → VCSEC, everything else → INFOTAINMENT. `Dispatcher` does not need a leaf-level lookup table.
- Adding a new operation stays local to one inner enum and one encoder file.
- Logging and metric labels fall out naturally as `"\(outer).\(inner)"`.

State fetching is **not** a `Command` case. It has a heterogeneous return type and a fundamentally different semantics, so it lives on its own client-level API (see §4).

- **`CommandEncoder`**: `func encode(_ command: Command) -> (domain: Domain, body: Data)`. One-level outer dispatch that delegates to the per-domain encoder file.
- **`ResponseDecoder`**: Turns a `RoutableMessage` payload into `CommandResult` (`.ok` / `.ok(payload)` / `.vehicleError(code, reason)`).

### 3.5 `Client/`

`TeslaVehicleClient` composes `BLETransport`, `Dispatcher`, and key-store lookup, manages lifecycle, and publishes `ConnectionState`. Public API in §4.

## 4. Data Flow and Public API

### 4.1 Outbound Path (example: `lock`)

```
TeslaVehicleClient.send(.security(.lock))
  ├─ Require state == .connected (otherwise throw .notConnected).
  └─ Dispatcher.send(command: .security(.lock), timeout: 10s)
       ├─ domain = .vcsec  (outer enum case determines this)
       ├─ body   = SecurityEncoder.encode(.lock)
       ├─ uuid   = UUID() — written into RoutableMessage.uuid, used as request tag
       ├─ Register continuation in RequestTable under uuid.
       ├─ signed = vcsecSession.sign(routable, body: body)  // AES-GCM + metadata AAD
       ├─ framed = MessageFramer.encode(signed.serializedData())
       ├─ transport.write(framed)
       └─ await continuation (or timeout task wins and throws .commandTimeout)
  └─ ResponseDecoder maps payload to CommandResult:
       ├─ .ok                   → return
       ├─ .ok(bytes)             → return (only for fetch-ish commands)
       └─ .vehicleError(code)    → throw TeslaBLEError.commandRejected(code, reason)
```

### 4.2 Inbound Path

```
BLETransport.inbound (AsyncStream<Data>)
  └─ InboundRouter task (owned by Dispatcher)
       ├─ MessageFramer.feed(chunk) → 0..n complete frames
       ├─ each frame → RoutableMessage(serializedBytes:)
       ├─ match message.requestUuid:
       │    ├─ hit  → session.verify(message) → RequestTable.complete(uuid, result)
       │    └─ miss → SessionNegotiator.handle(...) for unsolicited SessionInfo broadcasts
       └─ bad frames: warn log + drop (single corrupt frame must not kill the connection)
```

### 4.3 Timeouts and Cancellation

- `Dispatcher.send` uses `withThrowingTaskGroup`: one child awaits the continuation, one child runs `Task.sleep(for: timeout)` and throws `.commandTimeout`. First to finish wins; the other is cancelled.
- External `Task.cancel()` is wired through `withTaskCancellationHandler`. The cancellation handler calls `RequestTable.cancel(uuid)`, which resolves the continuation with `CancellationError`.
- `disconnect()` walks `RequestTable` and resolves every outstanding continuation with `TeslaBLEError.notConnected`, then shuts down the inbound task and closes `BLETransport`. No caller is ever left suspended.
- `CancellationError` is **not** wrapped into `TeslaBLEError`; it propagates as-is so standard `catch is CancellationError` works.

### 4.4 Public API

```swift
public actor TeslaVehicleClient {
    public init(vin: String, keyStore: any TeslaKeyStore, logger: (any TeslaBLELogger)?)

    public var state: ConnectionState { get }
    public nonisolated var stateStream: AsyncStream<ConnectionState> { get }

    public enum ConnectMode: Sendable {
        case normal    // scan + BLE connect + handshake both VCSEC and INFOTAINMENT
        case pairing   // scan + BLE connect + dispatcher only, no handshake — first-time addKey
    }

    public func connect(mode: ConnectMode = .normal, timeout: Duration = .seconds(30)) async throws
    public func disconnect() async

    public func send(_ command: Command) async throws
    public func fetch(_ query: StateQuery) async throws -> TeslaVehicleSnapshot
    public func fetchDrive() async throws -> DriveStateDTO
}

public enum StateQuery: Sendable {
    case all
    case driveOnly
    case categories(Set<StateCategory>)
}
```

Usage:

```swift
// First-time pairing
let client = TeslaVehicleClient(vin: vin, keyStore: keyStore, logger: logger)
try await client.connect(mode: .pairing)
try await client.send(.security(.addKey(publicKey: pub, role: .owner, formFactor: .cloudKey)))
await client.disconnect()
// User taps key card on center console...

// Normal use
try await client.connect()
try await client.send(.security(.unlock))
let snapshot = try await client.fetch(.all)
let drive    = try await client.fetchDrive()
await client.disconnect()
```

### 4.5 Client Behavior Contracts

- `connect(mode: .normal)` connects BLE, runs `SessionNegotiator` for VCSEC and INFOTAINMENT, transitions to `.connected` only after both sessions establish.
- `connect(mode: .pairing)` connects BLE and starts the dispatcher without running any handshake. `vcsecSession` and `infotainmentSession` remain `nil`. State becomes `.connected` but only `addKey` is legal.
- `send(command)`: if the command's target domain has no session and the command is not `.security(.addKey)`, throw `TeslaBLEError.notConnected`. `addKey` uses a special path — an unsigned VCSEC whitelist request, which is the legitimate pre-pairing flow used by the car.
- `fetch(_:)` and `fetchDrive()` require an established INFOTAINMENT session (only available under `.normal`), otherwise throw `.notConnected`.

## 5. Error Handling

```swift
public enum TeslaBLEError: Error, Sendable {
    // Transport / BLE
    case bluetoothUnavailable
    case scanTimeout
    case connectionFailed(underlying: String)
    case notConnected
    case serviceNotFound
    case characteristicsNotFound
    case messageTooLarge

    // Session / handshake
    case handshakeFailed(domain: Domain, reason: String)
    case sessionExpired(domain: Domain)
    case counterReplay(domain: Domain)
    case tagMismatch(domain: Domain)

    // Command
    case commandRejected(code: Int, reason: String?)
    case commandTimeout
    case unsupportedCommand(String)

    // Keys / keychain
    case keyNotFound(vin: String)
    case keychainFailure(status: OSStatus)

    // Internal invariants
    case decodingFailed(String)
}
```

### 5.1 Layering and Translation Points

- `BLETransport` throws internal `BLEError`. `TeslaVehicleClient` is the single translation point to `TeslaBLEError.connection*` / `.bluetoothUnavailable` / `.scanTimeout` / etc. No scattered re-wrapping.
- `Crypto/` throws an internal `CryptoError` (`.tagMismatch`, `.invalidKeyLength`, …). `VehicleSession.sign` and `.verify` catch these and re-throw as `.tagMismatch(domain:)` or `.handshakeFailed(domain:)`.
- `Dispatcher` throws `.commandTimeout`, `.notConnected`, or `.decodingFailed`. Vehicle-level errors (`MessageFault_E`) are translated by `ResponseDecoder` to `.commandRejected(code:reason:)` using a static table derived from Go's `errors.go`.
- `TeslaVehicleClient` does not translate further — it just passes errors up.

### 5.2 Never Silently Swallow

- Bad inbound frames, unknown request UUIDs, obsolete messages: warn-log and drop. A single corrupt frame must not poison the connection.
- Counter window rejection, HMAC failure, epoch mismatch: **security-critical** — always raised to the caller. Never silently dropped.

### 5.3 Logging Discipline

- `TeslaBLELogger` protocol is retained.
- `.debug` — each outbound command's `(domain, command tag, request UUID)`.
- `.info` — state transitions and successful handshakes.
- `.warning` — dropped bad frames.
- `.error` — handshake failures, tag mismatches, counter replays, timeouts.
- **Never logged**: session keys, private key bytes, protobuf bodies. Only lengths for sensitive data.

## 6. Test Strategy

Approach 3 (Swift-idiomatic rewrite) keeps no line-by-line parity with Go, so correctness is enforced entirely by the test layers below. All four layers are required. Layers A–C must be green before layer D (real-car smoke) is attempted.

### 6.1 Layer A — Crypto Unit Tests (Deterministic Vectors)

**Scope:** `P256ECDH`, `SessionKey`, `MessageAuthenticator`, `CounterWindow`, `HMACTag`.

**Approach:** Before the rip, extract test vectors from Go. A local (not-upstreamed) patch inside `Vendor/tesla-vehicle-command/internal/authentication/*_test.go` adds a `TestDumpVectors` function that serializes inputs and expected outputs for `crypto_test.go`, `metadata_test.go`, `window_test.go`, and `peer_test.go` into `Tests/TeslaBLETests/Fixtures/crypto/*.json`. JSON schema per file is a flat array: `[{ "name": "...", "inputs": { ... hex bytes ... }, "expected": { ... hex bytes ... } }]`. Raw bytes are hex-encoded. The patch is saved as `GoPatches/fixture-dump.patch` for future regeneration runs.

**Mandatory coverage:**

- Session key derivation — SHA-1 of shared X → 16-byte AES key — at least 4 vectors.
- AES-GCM AAD construction — ~20 vectors covering every combination of `metadata.go` TLV fields (epoch, counter, request_hash, auth_method, expires_at, flags) present and absent.
- `CounterWindow` accept / reject boundaries — ~15 vectors including reorder, replay, and cross-window-size cases.
- HMAC SessionInfo challenge — ~6 vectors.

**Failure mode:** any byte-level mismatch blocks progression to layer B.

### 6.2 Layer B — Session / Dispatcher Replay Tests

**Scope:** `VehicleSession.sign` and `.verify`, `SessionNegotiator`, `Dispatcher` routing and request-id matching.

**Approach:** Run the Go stack against a real vehicle and dump every inbound and outbound `RoutableMessage` (timestamp, direction, bytes, parsed summary) to `Tests/TeslaBLETests/Fixtures/sessions/{vcsec,infotainment}/session_N.json`. Each fixture includes:

- Setup parameters: vehicle public key bytes, test-only private key bytes (not a production key).
- Timeline: `[{ direction, bytes, parsed_summary }]`.

Swift tests drive `FakeTransport` (a test double conforming to the same async read / write shape as `BLETransport`) by feeding inbound bytes from the fixture and asserting outbound bytes match.

**Mandatory coverage:**

- Full VCSEC handshake (`SessionInfoRequest` → `SessionInfo` → Idle).
- Full Infotainment handshake.
- One `lock` command round-trip including signed envelope and verified response.
- One drive-state fetch.
- `addKey` whitelist flow under the unsigned pre-pairing path.
- Retry and timeout scenarios (test drives a fake clock).

**Failure mode:** any byte mismatch against the fixture indicates a bug in sign / verify / framing.

### 6.3 Layer C — Command Encoding Unit Tests

**Scope:** `CommandEncoder` and `ResponseDecoder`. Pure functions — no network or session state.

**Approach:** For each `Command` case construct a minimal instance, encode, and compare against an expected byte sequence captured from the Go side. For each response type, decode a known byte sequence and assert the resulting Swift value. Complex commands (e.g. `setSchedule`, `setPreconditioning`) get additional parameter-boundary positive cases plus an invalid-input negative case.

**Coverage target:** ≥1 positive test per command case (~40), with 2–3 extras for each command that takes structured parameters.

**Failure mode:** any missing protobuf field assignment or wrong tag is caught here before reaching the session layer.

### 6.4 Layer D — End-to-End Smoke (Real Car)

**Smoke CLI:** `Sources/TeslaBLESmoke/main.swift` (new `.executableTarget`). Takes a VIN argument and runs:

```
connect → fetch(.all) → send(.security(.unlock)) → send(.security(.lock))
  → send(.charge(.start)) → send(.charge(.stop)) → disconnect
```

Each step prints result and elapsed time. A human watches the car react.

**Release gate:** the smoke script must pass against a real vehicle before any release tag. The `v0.1.0` README explicitly notes no hardware validation has ever been performed against the extracted codebase — this rewrite fixes that gap.

**Mock vehicle (deferred — see §9):** A `MockVehicle` test target that lets layers A–C run end-to-end in CI without hardware is planned for future work but not in scope for the rewrite.

### 6.5 CI Matrix

- **PR gate:** layers A + B + C must be green under `swift test` on macOS. The test target temporarily allows macOS builds even though the library ships iOS-only — layers A–C are pure logic and do not touch `CoreBluetooth`.
- **Release gate:** layer D real-car smoke + layers A–C green + tag.
- Layer A fixture JSONs live in `Tests/TeslaBLETests/Fixtures/crypto/`. Layer B session fixtures live in `Tests/TeslaBLETests/Fixtures/sessions/`. Depending on final size they are either committed directly or stored via Git LFS.

## 7. Migration Execution Order

Work happens on a dedicated `native-swift` branch, with CI-meaningful checkpoints at each phase.

### Phase 0 — Fixture Extraction (on `main`, no Go removal)

- Apply a local patch to `Vendor/tesla-vehicle-command/internal/authentication/*_test.go`, `metadata_test.go`, `window_test.go`, `peer_test.go`, and `dispatcher_test.go` adding `TestDumpVectors*` functions.
- Run `go test ./... -run TestDump` to produce `Tests/TeslaBLETests/Fixtures/crypto/*.json` and `Fixtures/sessions/*.json`.
- Commit the fixture files to `main` in a single commit. Do **not** commit the Go patch — save it as `GoPatches/fixture-dump.patch` for future regeneration runs.
- Phase 0 only adds files. `main` still builds on xcframework.

### Phase 1 — Branch and Skeleton

- `git checkout -b native-swift`.
- Create empty directories `Sources/TeslaBLE/Crypto/`, `Session/`, `Dispatcher/`, `Commands/` with skeleton files (types and stub methods only).
- `Package.swift` is not yet modified — xcframework still present, new code is all `internal` and unused by `TeslaVehicleClient`.
- `swift build` must pass.

### Phase 2 — Crypto Layer + Layer A Tests

- Implement `Crypto/*.swift`.
- Write `CryptoVectorTests.swift` consuming the Phase 0 fixtures; all tests must go green.
- `swift test` runs layer A on macOS by end of phase.

### Phase 3 — Session + Dispatcher Layer + Layer B Tests

- Implement `Session/*.swift`, `Dispatcher/*.swift`, `InboundRouter`, and the test-only `FakeTransport`.
- Write `SessionReplayTests.swift` consuming session fixtures; all tests must go green.
- `TeslaVehicleClient` and xcframework are still untouched.

### Phase 4 — Commands Layer + Layer C Tests

- Implement `Commands/Command.swift`, `CommandEncoder`, `ResponseDecoder`, and every file under `Subcommands/`.
- Write `CommandEncoderTests.swift` with full coverage per §6.3.

### Phase 5 — Client Switchover

- Rewrite `TeslaVehicleClient` to use the new `Dispatcher` and `Commands`. New public API per §4.
- Delete:
  - `Sources/TeslaBLE/Internal/MobileSessionAdapter.swift`
  - `Sources/TeslaBLE/Transport/BLETransportBridge.swift`
  - Every `#if canImport(TeslaCommand)` conditional.
  - `build/TeslaCommand.xcframework` (if checked in).
  - `scripts/bootstrap.sh`, `scripts/build-xcframework.sh`.
  - `GoPatches/mobile.go`.
- `Package.swift` changes:
  - Remove `.binaryTarget(name: "TeslaCommand", ...)`.
  - Remove the `TeslaBLE` → `TeslaCommand` target dependency.
  - Drop `.macOS(.v11)` from `platforms`.
- Retain `Vendor/tesla-vehicle-command` submodule per §1 — it is no longer used at build time but remains the source of truth for `.proto` files and for regenerating fixtures later.
- Update `README.md`: remove every Go / `gomobile` / bootstrap / build-xcframework section. New install flow is `clone → swift test`.
- End of Phase 5: `swift build` no longer requires a Go toolchain.

### Phase 6 — Real-Car Smoke (Layer D)

- Add `Sources/TeslaBLESmoke/main.swift`.
- Run the smoke flow per §6.4 against a real vehicle.
- Every bug surfaced by real hardware must be matched by a new regression test at the appropriate layer (A, B, or C) so it cannot silently regress.

### Phase 7 — Merge to `main`

- `git merge --no-ff native-swift` into `main`.
- Tag `v0.2.0`.
- README updated with `hardware-verified on <model> <date>` marker.

### Rollback Strategy

- Phases 0–4 are additive and leave the old code path intact, so rollback is a `git checkout main`.
- Phase 5 onward commits to the rewrite. The correctness guarantee at this point rests on layers A–C being complete and green. Bugs discovered in Phase 6 should surface at the right test layer first; issues that only appear in Phase 6 are a signal that A–C has a coverage gap and must be extended.

## 8. Dependency and Build Changes (Summary Diff)

### Removed

- `GoPatches/mobile.go`
- `scripts/bootstrap.sh`
- `scripts/build-xcframework.sh`
- `Sources/TeslaBLE/Internal/MobileSessionAdapter.swift`
- `Sources/TeslaBLE/Transport/BLETransportBridge.swift`
- `Package.swift`: `.binaryTarget(name: "TeslaCommand", ...)`, the conditional dependency on `TeslaCommand`, and `.macOS(.v11)` from `platforms`.
- `build/TeslaCommand.xcframework` (generated artifact; was gitignored).

### Added

- `Sources/TeslaBLE/Crypto/` — 5 files.
- `Sources/TeslaBLE/Session/` — 4 files.
- `Sources/TeslaBLE/Dispatcher/` — 3 files.
- `Sources/TeslaBLE/Commands/` — `Command.swift`, `CommandEncoder.swift`, `ResponseDecoder.swift`, plus 6–8 files under `Subcommands/`.
- `Sources/TeslaBLESmoke/main.swift` — executable target for real-car smoke.
- `Tests/TeslaBLETests/Fixtures/crypto/*.json`
- `Tests/TeslaBLETests/Fixtures/sessions/*.json`
- `Tests/TeslaBLETests/CryptoVectorTests.swift`
- `Tests/TeslaBLETests/SessionReplayTests.swift`
- `Tests/TeslaBLETests/CommandEncoderTests.swift`
- `Tests/TeslaBLETests/FakeTransport.swift`
- `GoPatches/fixture-dump.patch` — the Phase 0 Go patch, preserved for future fixture regeneration against upstream updates.

### Retained Unchanged

- `Sources/TeslaBLE/Transport/BLETransport.swift` and `MessageFramer.swift`
- `Sources/TeslaBLE/Generated/*.pb.swift` (regenerated from the submodule's `.proto` files when Tesla updates them)
- `Sources/TeslaBLE/Keys/`, `Model/`, `Support/`
- `Sources/TeslaBLE/Client/ConnectionState.swift`
- Existing non-xcframework tests
- `Vendor/tesla-vehicle-command` submodule — retained for `.proto` sources and future fixture extraction, but no longer built

### Final `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-tesla-ble",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TeslaBLE", targets: ["TeslaBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "TeslaBLE",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")],
        ),
        .executableTarget(
            name: "TeslaBLESmoke",
            dependencies: ["TeslaBLE"]
        ),
        .testTarget(
            name: "TeslaBLETests",
            dependencies: ["TeslaBLE"],
            resources: [.copy("Fixtures")]
        ),
    ],
)
```

### Runtime Dependencies After Rewrite

- `CryptoKit` (system)
- `CoreBluetooth` (system)
- `Foundation` (system)
- `SwiftProtobuf` (existing SwiftPM dep)

No Go toolchain. No `gomobile`. No binary artifacts.

## 9. Deferred / Future Work

- **`MockVehicle` test target.** A CI-friendly end-to-end integration harness that simulates the vehicle side of the session handshake and command path in-process, removing the need for real-car smoke in CI. Complexity is moderate because it must replicate vehicle-side signing and verification. Tracked as a follow-up after the rewrite ships.
- **Prebuilt xcframework distribution.** The v0.1.0 README listed this as future work, but the pure-Swift rewrite makes it unnecessary — consumers can depend on the package by source alone. This item can be closed after the rewrite lands.
- **Upstreaming `mobile.go` into a tesla-vehicle-command fork.** Also listed in v0.1.0 README. The rewrite deletes `mobile.go` entirely, so this item closes.
