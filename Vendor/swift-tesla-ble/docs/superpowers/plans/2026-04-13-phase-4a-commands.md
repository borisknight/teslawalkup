# Swift Native Rewrite — Phase 4a: Commands Layer Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay down the `Commands/` layer skeleton plus a meaningful subset of encoders covering the most-used vehicle commands. Establish the nested `Command` enum shape, the `CommandEncoder` top-level dispatcher, per-domain encoder files, a `ResponseDecoder` for CarServer + VCSEC response types, and a `StateQuery` / state-fetch encoder. Phase 4b will fill in the remaining ~70 commands following the same pattern.

**Architecture:** This plan is Phase 4a of the rewrite described in `docs/superpowers/specs/2026-04-13-swift-native-rewrite-design.md`. Prior phases delivered `Crypto/`, `Session/`, and `Dispatcher/` (59 tests green). Phase 4a adds `Commands/` — pure functions on top of existing layers, no concurrency, no state. Every encoder is one protobuf assembly function. Every decoder is one `init(serializedBytes:)` + a field read.

**Tech Stack:** Swift 6, SwiftProtobuf (already wired). No new SwiftPM dependencies.

**Surface covered in Phase 4a (~20 commands):**

- **Security (VCSEC domain, RKEAction)**: `lock`, `unlock`, `wakeVehicle`, `remoteDrive`, `autoSecure`
- **Security (VCSEC domain, ClosureMoveRequest)**: `openTrunk`, `closeTrunk`, `openFrunk`
- **Charge (Infotainment domain, CarServer_VehicleAction)**: `chargeStart`, `chargeStop`, `chargeMaxRange`, `chargeStandardRange`, `setChargeLimit(percent)`, `setChargingAmps(amps)`, `openChargePort`, `closeChargePort`
- **Climate (Infotainment domain)**: `climateOn`, `climateOff`, `setTemperature(driver, passenger)`
- **Actions (Infotainment domain)**: `honk`, `flashLights`
- **State** (`StateQuery` separate API, not a `Command` case): `fetchAll`, `fetchDrive`, `fetch(categories:)`

Phase 4b will add: full charge schedules + scheduled departure, seat heaters/coolers, climate keeper, sentry mode, trunk/frunk/tonneau variants, media control, volume, software updates, valet mode, speed limit, homelink trigger, low-power mode, etc. ~70 additional commands.

**Wire-critical invariants:**

1. **VCSEC domain** uses `VCSEC_UnsignedMessage` as the plaintext body, serialized via SwiftProtobuf. Sub-messages include `rkeAction`, `closureMoveRequest`, `whitelistOperation`, `informationRequest`.
2. **Infotainment domain** uses `CarServer_Action` as the plaintext body, wrapping `CarServer_VehicleAction` with exactly one `vehicleActionMsg` oneof case set. The outer `CarServer_Action.actionMsg` is always `.vehicleAction(...)`.
3. **State fetches** use a `CarServer_VehicleAction` with `vehicleActionMsg = .getVehicleData(...)` set, plus a category field inside `CarServer_GetVehicleData`. This is handled by a dedicated encoder, not through the `Command` enum.
4. **Responses for Infotainment** come back as `CarServer_Response` — contains `actionStatus: CarServer_ActionStatus` (success/failure) plus a oneof of domain-specific results (charge, climate, drive, vehicle data).
5. **Responses for VCSEC** come back as `VCSEC_FromVCSECMessage` — contains `commandStatus` with operation status codes. Most VCSEC commands only need success/failure, not structured data.
6. **`Signatures_SignatureType` and `UniversalMessage_Domain` raw values are already captured in Phase 2+3 plans. Don't re-check.**

**Generated Swift protobuf types used here** (all in `Sources/TeslaBLE/Generated/`):

- `VCSEC_UnsignedMessage` — top of VCSEC plaintext. Has `subMessage: OneOf_SubMessage?` with cases `.rkeAction`, `.closureMoveRequest`, `.whitelistOperation`, `.informationRequest`.
- `VCSEC_RKEAction_E` — enum with raw values: `.rkeActionUnlock=0`, `.rkeActionLock=1`, `.rkeActionRemoteDrive=20`, `.rkeActionAutoSecureVehicle=29`, `.rkeActionWakeVehicle=30`. Note: HONK and FLASH are NOT in this enum — they go through the Infotainment domain via `CarServer_VehicleControlHonkHornAction` / `CarServer_VehicleControlFlashLightsAction`.
- `VCSEC_ClosureMoveRequest` — has fields `rearTrunk`, `frontTrunk`, `tonneau`, each of type `VCSEC_ClosureMoveType_E` (with cases like `.closureMoveTypeOpen`, `.closureMoveTypeClose`).
- `CarServer_Action` — has `actionMsg: OneOf_ActionMsg?` with only case `.vehicleAction`.
- `CarServer_VehicleAction` — has `vehicleActionMsg: OneOf_VehicleActionMsg?` with dozens of cases. Phase 4a uses: `.chargingSetLimitAction`, `.chargingStartStopAction`, `.setChargingAmpsAction`, `.chargePortDoorOpen`, `.chargePortDoorClose`, `.hvacAutoAction`, `.hvacTemperatureAdjustmentAction`, `.vehicleControlHonkHornAction`, `.vehicleControlFlashLightsAction`, `.getVehicleData`.
- `CarServer_ChargingSetLimitAction` — has `percent: Int32`.
- `CarServer_ChargingStartStopAction` — has `chargingAction: OneOf_ChargingAction?` with `.start(Void)`, `.stop(Void)`, `.startMaxRange(Void)`, `.startStandard(Void)`.
- `CarServer_SetChargingAmpsAction` — has `chargingAmps: Int32`.
- `CarServer_HvacAutoAction` — has `powerOn: Bool`.
- `CarServer_HvacTemperatureAdjustmentAction` — has `driverTempCelsius: Float` and `passengerTempCelsius: Float`.
- `CarServer_Response` — has `actionStatus: CarServer_ActionStatus` and a payload oneof.
- `CarServer_ActionStatus` — has `result` (enum: `success`/`failure`) and `resultReason`.
- `VCSEC_FromVCSECMessage` — response type from VCSEC domain.

If any of the above field/type names differ slightly in the generated Swift, use the Read tool on `Sources/TeslaBLE/Generated/car_server.pb.swift` or `vcsec.pb.swift` to confirm — don't guess. The generator uses lowerCamelCase.

**What NOT to do in this plan:**

- Do NOT implement every pkg/vehicle command. Phase 4b follows up with the rest.
- Do NOT touch `Client/`, `Dispatcher/`, `Session/`, or `Crypto/`.
- Do NOT modify `Package.swift`.
- Do NOT add `ResponseDecoder` support for commands we haven't encoded yet — keep the decoder's scope aligned with the encoder's.

---

## File Structure

### Files to create

**Source:**

- `Sources/TeslaBLE/Commands/Command.swift` — the nested `Command` enum, `~80 lines`.
- `Sources/TeslaBLE/Commands/CommandEncoder.swift` — top-level `encode(_:)` that dispatches to the appropriate sub-encoder, `~60 lines`.
- `Sources/TeslaBLE/Commands/ResponseDecoder.swift` — `decodeInfotainment(_:) -> CommandResult` and `decodeVCSEC(_:) -> CommandResult`, `~100 lines`.
- `Sources/TeslaBLE/Commands/StateQuery.swift` — `StateQuery` enum + `encodeStateQuery(_:) -> Data`, `~80 lines`.
- `Sources/TeslaBLE/Commands/Subcommands/SecurityEncoder.swift` — VCSEC RKE + closure encoders, `~110 lines`.
- `Sources/TeslaBLE/Commands/Subcommands/ChargeEncoder.swift` — infotainment charge encoders, `~130 lines`.
- `Sources/TeslaBLE/Commands/Subcommands/ClimateEncoder.swift` — infotainment climate encoders, `~80 lines`.
- `Sources/TeslaBLE/Commands/Subcommands/ActionsEncoder.swift` — infotainment misc actions (honk, flash), `~60 lines`.

**Test:**

- `Tests/TeslaBLETests/CommandEncoderTests.swift` — encode-and-parse-back tests per command case, `~450 lines`.

### Files to modify

None. Scaffold-new-directory pattern.

### Branching and commit cadence

Continue on `dev`. One commit per task.

---

## Task 1: Scaffold Commands/ and Subcommands/

- [ ] **Step 1:**

```bash
cd /Users/jiaxinshou/Developer/swift-tesla-ble
mkdir -p Sources/TeslaBLE/Commands/Subcommands
touch Sources/TeslaBLE/Commands/.gitkeep
touch Sources/TeslaBLE/Commands/Subcommands/.gitkeep
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 2:**

```bash
git add Sources/TeslaBLE/Commands/.gitkeep Sources/TeslaBLE/Commands/Subcommands/.gitkeep
git commit -m "chore: scaffold Commands/ and Commands/Subcommands/ directories"
```

---

## Task 2: Implement `Command` enum

**File:** `Sources/TeslaBLE/Commands/Command.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// Public command surface — nested enum grouped by BLE domain. Every command
/// is a pure value type with no side effects. Construction produces a
/// deterministic case that `CommandEncoder.encode(_:)` turns into a
/// `(domain, body)` tuple ready to hand to `Dispatcher.send`.
///
/// This file is Phase 4a. It covers the most-used subset of `pkg/vehicle`
/// commands (~20 cases). Phase 4b will extend each inner enum with the
/// remaining cases without breaking the shape.
public enum Command: Sendable, Equatable {

    case security(Security)
    case charge(Charge)
    case climate(Climate)
    case actions(Actions)

    // MARK: - Security (VCSEC domain)

    /// VCSEC-domain commands. Mostly RKE actions plus closure movements.
    public enum Security: Sendable, Equatable {
        case lock
        case unlock
        case wakeVehicle
        case remoteDrive
        case autoSecure

        case openTrunk
        case closeTrunk
        case openFrunk
    }

    // MARK: - Charge (Infotainment domain)

    public enum Charge: Sendable, Equatable {
        case start
        case stop
        case startMaxRange
        case startStandardRange
        case setLimit(percent: Int32)
        case setAmps(Int32)
        case openPort
        case closePort
    }

    // MARK: - Climate (Infotainment domain)

    public enum Climate: Sendable, Equatable {
        case on
        case off
        case setTemperature(driver: Float, passenger: Float)
    }

    // MARK: - Actions (Infotainment domain)

    public enum Actions: Sendable, Equatable {
        case honk
        case flashLights
    }
}
```

- [ ] **Step 2:** Build check:

```bash
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 3:** Commit:

```bash
git rm Sources/TeslaBLE/Commands/.gitkeep
git add Sources/TeslaBLE/Commands/Command.swift
git commit -m "feat: add Command nested enum (Phase 4a subset)"
```

---

## Task 3: Implement `SecurityEncoder` (VCSEC domain)

**File:** `Sources/TeslaBLE/Commands/Subcommands/SecurityEncoder.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// Encodes `Command.Security` cases into VCSEC-domain plaintext bytes.
///
/// All security commands use `VCSEC_UnsignedMessage` as the top-level
/// protobuf, with one of several sub-messages:
///
/// - `rkeAction` — lock/unlock/wake/remoteDrive/autoSecure
/// - `closureMoveRequest` — open/close trunk, frunk, tonneau
///
/// Returns the serialized `VCSEC_UnsignedMessage` bytes. The caller
/// (`CommandEncoder`) pairs this with `UniversalMessage_Domain.vehicleSecurity`.
///
/// Port of `pkg/vehicle/vcsec.go` `executeRKEAction` and
/// `executeClosureAction`.
enum SecurityEncoder {

    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
    }

    static func encode(_ command: Command.Security) throws -> Data {
        var unsigned = VCSEC_UnsignedMessage()

        switch command {
        case .lock:
            unsigned.subMessage = .rkeaction(.rkeActionLock)
        case .unlock:
            unsigned.subMessage = .rkeaction(.rkeActionUnlock)
        case .wakeVehicle:
            unsigned.subMessage = .rkeaction(.rkeActionWakeVehicle)
        case .remoteDrive:
            unsigned.subMessage = .rkeaction(.rkeActionRemoteDrive)
        case .autoSecure:
            unsigned.subMessage = .rkeaction(.rkeActionAutoSecureVehicle)

        case .openTrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.rearTrunk = .closureMoveTypeOpen
            unsigned.subMessage = .closureMoveRequest(req)
        case .closeTrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.rearTrunk = .closureMoveTypeClose
            unsigned.subMessage = .closureMoveRequest(req)
        case .openFrunk:
            var req = VCSEC_ClosureMoveRequest()
            req.frontTrunk = .closureMoveTypeOpen
            unsigned.subMessage = .closureMoveRequest(req)
        }

        do {
            return try unsigned.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
```

**Note:** The exact oneof case names (`.rkeAction`, `.closureMoveRequest`) and enum case names (`.closureMoveTypeOpen`) may differ slightly in the generated Swift. If `swift build` fails, use the Read tool on `Sources/TeslaBLE/Generated/vcsec.pb.swift` to confirm and adapt. Likely candidates:

- `VCSEC_UnsignedMessage.OneOf_SubMessage` cases
- `VCSEC_ClosureMoveType_E` enum case names (look around line ~200 of vcsec.pb.swift)

- [ ] **Step 2:** Build check:

```bash
swift build 2>&1 | tail -5
```

- [ ] **Step 3:** Commit:

```bash
git add Sources/TeslaBLE/Commands/Subcommands/SecurityEncoder.swift
git commit -m "feat: implement SecurityEncoder (VCSEC RKE + closure commands)"
```

---

## Task 4: Implement `ChargeEncoder` (Infotainment domain)

**File:** `Sources/TeslaBLE/Commands/Subcommands/ChargeEncoder.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// Encodes `Command.Charge` cases into Infotainment-domain plaintext bytes.
///
/// All infotainment commands wrap a `CarServer_VehicleAction` inside a
/// `CarServer_Action` with `actionMsg = .vehicleAction(...)`. The specific
/// charge sub-action is set on `vehicleAction.vehicleActionMsg`.
///
/// Port of `pkg/vehicle/charge.go`.
enum ChargeEncoder {

    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
        case invalidParameter(String)
    }

    static func encode(_ command: Command.Charge) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .start:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .start(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .stop:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .stop(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .startMaxRange:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .startMaxRange(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .startStandardRange:
            var sub = CarServer_ChargingStartStopAction()
            sub.chargingAction = .startStandard(CarServer_Void())
            vehicleAction.vehicleActionMsg = .chargingStartStopAction(sub)

        case .setLimit(let percent):
            guard (0...100).contains(percent) else {
                throw Error.invalidParameter("charge limit percent out of range: \(percent)")
            }
            var sub = CarServer_ChargingSetLimitAction()
            sub.percent = percent
            vehicleAction.vehicleActionMsg = .chargingSetLimitAction(sub)

        case .setAmps(let amps):
            guard amps > 0 && amps <= 80 else {
                throw Error.invalidParameter("charging amps out of range: \(amps)")
            }
            var sub = CarServer_SetChargingAmpsAction()
            sub.chargingAmps = amps
            vehicleAction.vehicleActionMsg = .setChargingAmpsAction(sub)

        case .openPort:
            vehicleAction.vehicleActionMsg = .chargePortDoorOpen(CarServer_ChargePortDoorOpen())

        case .closePort:
            vehicleAction.vehicleActionMsg = .chargePortDoorClose(CarServer_ChargePortDoorClose())
        }

        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
```

**Note:** `CarServer_Void` is a zero-field message used as a "no payload" marker in oneof cases. If the generated Swift name differs (e.g., `CarServer_Void_` or just `Void`), use Read on `car_server.pb.swift` around the `Void` definition to confirm.

- [ ] **Step 2:** Build check:

```bash
swift build 2>&1 | tail -5
```

- [ ] **Step 3:** Commit:

```bash
git add Sources/TeslaBLE/Commands/Subcommands/ChargeEncoder.swift
git commit -m "feat: implement ChargeEncoder (infotainment charge commands)"
```

---

## Task 5: Implement `ClimateEncoder` + `ActionsEncoder`

Two small files in one task.

**Files:**

- `Sources/TeslaBLE/Commands/Subcommands/ClimateEncoder.swift`
- `Sources/TeslaBLE/Commands/Subcommands/ActionsEncoder.swift`

- [ ] **Step 1: ClimateEncoder:**

```swift
import Foundation

/// Encodes `Command.Climate` cases into Infotainment-domain plaintext bytes.
///
/// Port of `pkg/vehicle/climate.go`.
enum ClimateEncoder {

    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
        case invalidParameter(String)
    }

    static func encode(_ command: Command.Climate) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .on:
            var sub = CarServer_HvacAutoAction()
            sub.powerOn = true
            vehicleAction.vehicleActionMsg = .hvacAutoAction(sub)

        case .off:
            var sub = CarServer_HvacAutoAction()
            sub.powerOn = false
            vehicleAction.vehicleActionMsg = .hvacAutoAction(sub)

        case .setTemperature(let driver, let passenger):
            guard driver.isFinite, passenger.isFinite else {
                throw Error.invalidParameter("temperature must be a finite float")
            }
            var sub = CarServer_HvacTemperatureAdjustmentAction()
            sub.driverTempCelsius = driver
            sub.passengerTempCelsius = passenger
            vehicleAction.vehicleActionMsg = .hvacTemperatureAdjustmentAction(sub)
        }

        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 2: ActionsEncoder:**

```swift
import Foundation

/// Encodes `Command.Actions` cases into Infotainment-domain plaintext bytes.
/// These are miscellaneous VehicleAction commands that don't belong in the
/// Charge or Climate buckets.
///
/// Honk and Flash are intentionally routed through the Infotainment domain
/// (not VCSEC RKE), matching `pkg/vehicle/actions.go` HonkHorn and FlashLights.
enum ActionsEncoder {

    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
    }

    static func encode(_ command: Command.Actions) throws -> Data {
        var vehicleAction = CarServer_VehicleAction()

        switch command {
        case .honk:
            vehicleAction.vehicleActionMsg = .vehicleControlHonkHornAction(CarServer_VehicleControlHonkHornAction())
        case .flashLights:
            vehicleAction.vehicleActionMsg = .vehicleControlFlashLightsAction(CarServer_VehicleControlFlashLightsAction())
        }

        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 3:** Build check:

```bash
swift build 2>&1 | tail -5
```

- [ ] **Step 4:** Commit:

```bash
git add Sources/TeslaBLE/Commands/Subcommands/ClimateEncoder.swift Sources/TeslaBLE/Commands/Subcommands/ActionsEncoder.swift
git commit -m "feat: implement ClimateEncoder and ActionsEncoder"
```

---

## Task 6: Implement `CommandEncoder` top-level dispatcher

**File:** `Sources/TeslaBLE/Commands/CommandEncoder.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// Top-level dispatcher that turns a `Command` into a `(domain, body)` pair
/// ready for `Dispatcher.send`. One-level switch on the outer case → delegate
/// to per-domain encoder.
///
/// Design rule: every VCSEC-domain command returns `.vehicleSecurity` and a
/// serialized `VCSEC_UnsignedMessage`. Every Infotainment-domain command
/// returns `.infotainment` and a serialized `CarServer_Action`.
///
/// Remove `.gitkeep`:
enum CommandEncoder {

    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
    }

    static func encode(_ command: Command) throws -> (domain: UniversalMessage_Domain, body: Data) {
        switch command {
        case .security(let s):
            let body = try SecurityEncoder.encode(s)
            return (.vehicleSecurity, body)
        case .charge(let c):
            let body = try ChargeEncoder.encode(c)
            return (.infotainment, body)
        case .climate(let cl):
            let body = try ClimateEncoder.encode(cl)
            return (.infotainment, body)
        case .actions(let a):
            let body = try ActionsEncoder.encode(a)
            return (.infotainment, body)
        }
    }
}
```

- [ ] **Step 2:** Remove the Subcommands `.gitkeep` and build:

```bash
git rm Sources/TeslaBLE/Commands/Subcommands/.gitkeep
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 3:** Commit:

```bash
git add Sources/TeslaBLE/Commands/CommandEncoder.swift
git commit -m "feat: implement CommandEncoder top-level dispatcher"
```

---

## Task 7: Implement `ResponseDecoder`

**File:** `Sources/TeslaBLE/Commands/ResponseDecoder.swift`

- [ ] **Step 1:** Before writing, inspect the response types:

```bash
grep -n "public struct CarServer_Response\|public struct CarServer_ActionStatus\|public enum CarServer_OperationStatus_E\|public struct VCSEC_FromVCSECMessage" Sources/TeslaBLE/Generated/car_server.pb.swift Sources/TeslaBLE/Generated/vcsec.pb.swift
```

Expected: you'll see the struct definitions. Pay attention to:

- `CarServer_Response.actionStatus` field
- `CarServer_ActionStatus.result` (an enum, likely `CarServer_OperationStatus_E` with `.operationstatusOk` etc.)
- `CarServer_ActionStatus.resultReason` — probably a oneof or a struct with a `.plainText` case

Use the Read tool to confirm the exact field names. If you find field/type names different from the ones used in the code below, adapt them (don't guess).

- [ ] **Step 2:** Create the file:

```swift
import Foundation

/// Decodes command response bytes into typed `CommandResult` values.
///
/// Phase 4a covers only the outcome path (success/failure + reason string).
/// Phase 4b will extend with structured payload extraction (e.g., charge
/// state, drive state) for `fetch(_:)` responses.
enum ResponseDecoder {

    /// The decoded outcome of a command.
    enum CommandResult: Sendable, Equatable {
        case ok
        case okWithPayload(Data)
        case vehicleError(code: Int, reason: String?)
    }

    enum Error: Swift.Error, Equatable {
        case decodingFailed(String)
        case unexpectedMessageType(String)
    }

    /// Decode an Infotainment-domain response. Returns `.ok` if
    /// `actionStatus.result` indicates success, `.vehicleError` otherwise.
    static func decodeInfotainment(_ bytes: Data) throws -> CommandResult {
        let response: CarServer_Response
        do {
            response = try CarServer_Response(serializedBytes: bytes)
        } catch {
            throw Error.decodingFailed("CarServer_Response: \(error)")
        }

        let status = response.actionStatus
        switch status.result {
        case .operationstatusOk:
            return .ok
        case .rror:
            // Codegen quirk: the "error" case was generated as `.rror` after
            // protoc stripped the leading E from ERROR. CarServer only has
            // ok and error — there's no wait case on this enum (unlike VCSEC).
            let reason = Self.reasonString(from: status)
            return .vehicleError(code: status.result.rawValue, reason: reason)
        case .UNRECOGNIZED:
            return .vehicleError(code: status.result.rawValue, reason: "unrecognized status")
        }
    }

    /// Decode a VCSEC-domain response. Returns `.ok` if the `commandStatus`
    /// indicates operation success, `.vehicleError` otherwise.
    static func decodeVCSEC(_ bytes: Data) throws -> CommandResult {
        let response: VCSEC_FromVCSECMessage
        do {
            response = try VCSEC_FromVCSECMessage(serializedBytes: bytes)
        } catch {
            throw Error.decodingFailed("VCSEC_FromVCSECMessage: \(error)")
        }

        // Some VCSEC responses have no commandStatus at all — they're
        // informational broadcasts. Treat "no commandStatus" as OK since
        // every action that generates a command status is bypassed only by
        // "just acknowledged" messages.
        if !response.hasCommandStatus {
            return .ok
        }
        let status = response.commandStatus
        switch status.operationStatus {
        case .operationstatusOk:
            return .ok
        case .operationstatusWait:
            return .vehicleError(code: status.operationStatus.rawValue, reason: "busy (wait)")
        case .rror:
            // VCSEC codegen quirk: `.rror` is the "error" case.
            return .vehicleError(code: status.operationStatus.rawValue, reason: "error")
        case .UNRECOGNIZED:
            return .vehicleError(code: status.operationStatus.rawValue, reason: "unrecognized status")
        }
    }

    private static func reasonString(from status: CarServer_ActionStatus) -> String? {
        // `resultReason` is a oneof (plainText / minimalError / etc.) depending
        // on proto version. Cover the common case.
        if status.hasResultReason, !status.resultReason.plainText.isEmpty {
            return status.resultReason.plainText
        }
        return nil
    }
}
```

- [ ] **Step 3:** Build check:

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!`. If the generated `CarServer_OperationStatus_E` has different case names (e.g., `.rror` from the codegen quirk we saw in Phase 3a), use Read to confirm the actual case names and adapt the switch statement.

The `VCSEC_OperationStatus_E` enum may also have different case names. Expected values from Go:

- `OPERATIONSTATUS_OK = 0`
- `OPERATIONSTATUS_WAIT = 1`
- `OPERATIONSTATUS_ERROR = 2`

If the Swift enum cases are `.rrorOk`, `.rrorWait`, `.rrorError` (another codegen quirk), adapt.

- [ ] **Step 4:** Commit:

```bash
git add Sources/TeslaBLE/Commands/ResponseDecoder.swift
git commit -m "feat: implement ResponseDecoder (CarServer + VCSEC outcome)"
```

---

## Task 8: Implement `StateQuery` + fetch encoder

**File:** `Sources/TeslaBLE/Commands/StateQuery.swift`

- [ ] **Step 1:** Inspect the state-fetch protobuf shape:

```bash
grep -n "public struct CarServer_GetVehicleData\|case getVehicleData\|getChargeState\|getDriveState\|getClimateState" Sources/TeslaBLE/Generated/car_server.pb.swift | head -15
```

Expected: `CarServer_GetVehicleData` is a struct with multiple optional sub-requests (`getChargeState`, `getClimateState`, `getDriveState`, `getLocationState`, `getClosuresState`, `getChargeScheduleState`, `getPreconditioningScheduleState`, `getTirePressureState`, `getMediaState`, `getMediaDetailState`, `getSoftwareUpdateState`, `getParentalControlsState`). Each is a small empty struct (just marks "please include this category").

Use Read if you need to confirm the exact names.

- [ ] **Step 2:** Create the file:

```swift
import Foundation

/// Categories of vehicle state that `fetch(_:)` can request.
public enum StateCategory: String, Sendable, CaseIterable {
    case charge
    case climate
    case drive
    case location
    case closures
    case chargeSchedule
    case preconditioningSchedule
    case tirePressure
    case media
    case mediaDetail
    case softwareUpdate
    case parentalControls
}

/// High-level state query shapes accepted by `Client.fetch(_:)`.
public enum StateQuery: Sendable, Equatable {
    case all
    case driveOnly
    case categories(Set<StateCategory>)
}

/// Encoder for the `getVehicleData` infotainment action used by
/// `TeslaVehicleClient.fetch(_:)`. Returns serialized `CarServer_Action`
/// bytes targeting `UniversalMessage_Domain.infotainment`.
enum StateQueryEncoder {

    enum Error: Swift.Error, Equatable {
        case encodingFailed(String)
    }

    static func encode(_ query: StateQuery) throws -> Data {
        let categories: Set<StateCategory>
        switch query {
        case .all:
            categories = Set(StateCategory.allCases)
        case .driveOnly:
            categories = [.drive]
        case .categories(let cats):
            categories = cats
        }

        var get = CarServer_GetVehicleData()
        for category in categories {
            switch category {
            case .charge:
                get.getChargeState = CarServer_GetChargeState()
            case .climate:
                get.getClimateState = CarServer_GetClimateState()
            case .drive:
                get.getDriveState = CarServer_GetDriveState()
            case .location:
                get.getLocationState = CarServer_GetLocationState()
            case .closures:
                get.getClosuresState = CarServer_GetClosuresState()
            case .chargeSchedule:
                get.getChargeScheduleState = CarServer_GetChargeScheduleState()
            case .preconditioningSchedule:
                get.getPreconditioningScheduleState = CarServer_GetPreconditioningScheduleState()
            case .tirePressure:
                get.getTirePressureState = CarServer_GetTirePressureState()
            case .media:
                get.getMediaState = CarServer_GetMediaState()
            case .mediaDetail:
                get.getMediaDetailState = CarServer_GetMediaDetailState()
            case .softwareUpdate:
                get.getSoftwareUpdateState = CarServer_GetSoftwareUpdateState()
            case .parentalControls:
                get.getParentalControlsState = CarServer_GetParentalControlsState()
            }
        }

        var vehicleAction = CarServer_VehicleAction()
        vehicleAction.getVehicleData = get
        var action = CarServer_Action()
        action.vehicleAction = vehicleAction

        do {
            return try action.serializedData()
        } catch {
            throw Error.encodingFailed(String(describing: error))
        }
    }
}
```

**If the generated field names don't match:** Some of the `getChargeScheduleState` / `getPreconditioningScheduleState` / `getParentalControlsState` fields may not exist in the current proto snapshot. If `swift build` errors on a missing field, **remove that category case entirely** (drop it from the enum and the switch) — Phase 4b will add it back when the proto is refreshed. Don't fabricate fields.

- [ ] **Step 3:** Build check:

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 4:** Commit:

```bash
git add Sources/TeslaBLE/Commands/StateQuery.swift
git commit -m "feat: add StateQuery + StateQueryEncoder for getVehicleData"
```

---

## Task 9: Write `CommandEncoderTests`

**File:** `Tests/TeslaBLETests/CommandEncoderTests.swift`

Tests follow a simple pattern: encode → parse back the same protobuf → assert the expected field was set. No fixtures — protobuf encoding is deterministic per field set.

- [ ] **Step 1:** Create the file:

```swift
import Foundation
import XCTest
@testable import TeslaBLE

final class CommandEncoderTests: XCTestCase {

    // MARK: - Security

    func testSecurityLockEncodesRKELock() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.lock))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case .rkeaction(let action)? = unsigned.subMessage else {
            XCTFail("expected rkeAction"); return
        }
        XCTAssertEqual(action, .rkeActionLock)
    }

    func testSecurityUnlockEncodesRKEUnlock() throws {
        let (_, body) = try CommandEncoder.encode(.security(.unlock))
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case .rkeaction(let a)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(a, .rkeActionUnlock)
    }

    func testSecurityWakeAutoSecureRemoteDrive() throws {
        for (cmd, expected) in [
            (Command.Security.wakeVehicle, VCSEC_RKEAction_E.rkeActionWakeVehicle),
            (.remoteDrive, .rkeActionRemoteDrive),
            (.autoSecure, .rkeActionAutoSecureVehicle),
        ] {
            let (_, body) = try CommandEncoder.encode(.security(cmd))
            let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
            guard case .rkeaction(let a)? = unsigned.subMessage else {
                XCTFail("\(cmd): not an rkeaction"); continue
            }
            XCTAssertEqual(a, expected, "\(cmd)")
        }
    }

    func testSecurityOpenTrunkEncodesClosureRequest() throws {
        let (domain, body) = try CommandEncoder.encode(.security(.openTrunk))
        XCTAssertEqual(domain, .vehicleSecurity)
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case .closureMoveRequest(let req)? = unsigned.subMessage else {
            XCTFail("expected closureMoveRequest"); return
        }
        XCTAssertEqual(req.rearTrunk, .closureMoveTypeOpen)
    }

    func testSecurityCloseTrunkEncodesRearTrunkClose() throws {
        let (_, body) = try CommandEncoder.encode(.security(.closeTrunk))
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case .closureMoveRequest(let req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.rearTrunk, .closureMoveTypeClose)
    }

    func testSecurityOpenFrunkEncodesFrontTrunkOpen() throws {
        let (_, body) = try CommandEncoder.encode(.security(.openFrunk))
        let unsigned = try VCSEC_UnsignedMessage(serializedBytes: body)
        guard case .closureMoveRequest(let req)? = unsigned.subMessage else { XCTFail(); return }
        XCTAssertEqual(req.frontTrunk, .closureMoveTypeOpen)
    }

    // MARK: - Charge

    func testChargeStartStop() throws {
        let (startDomain, startBody) = try CommandEncoder.encode(.charge(.start))
        XCTAssertEqual(startDomain, .infotainment)
        let startAction = try CarServer_Action(serializedBytes: startBody)
        guard case .chargingStartStopAction(let startSub) = startAction.vehicleAction.vehicleActionMsg else {
            XCTFail("expected chargingStartStopAction"); return
        }
        if case .start = startSub.chargingAction {} else { XCTFail("expected .start") }

        let (_, stopBody) = try CommandEncoder.encode(.charge(.stop))
        let stopAction = try CarServer_Action(serializedBytes: stopBody)
        guard case .chargingStartStopAction(let stopSub) = stopAction.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        if case .stop = stopSub.chargingAction {} else { XCTFail("expected .stop") }
    }

    func testChargeSetLimit() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.setLimit(percent: 80)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case .chargingSetLimitAction(let sub) = action.vehicleAction.vehicleActionMsg else {
            XCTFail(); return
        }
        XCTAssertEqual(sub.percent, 80)
    }

    func testChargeSetLimitOutOfRangeThrows() {
        XCTAssertThrowsError(try CommandEncoder.encode(.charge(.setLimit(percent: 150)))) { error in
            guard case ChargeEncoder.Error.invalidParameter = error else {
                XCTFail("expected invalidParameter, got \(error)"); return
            }
        }
    }

    func testChargeSetAmps() throws {
        let (_, body) = try CommandEncoder.encode(.charge(.setAmps(32)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case .setChargingAmpsAction(let sub) = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.chargingAmps, 32)
    }

    func testChargePortOpenClose() throws {
        let (_, openBody) = try CommandEncoder.encode(.charge(.openPort))
        let openAction = try CarServer_Action(serializedBytes: openBody)
        if case .chargePortDoorOpen = openAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected chargePortDoorOpen")
        }
        let (_, closeBody) = try CommandEncoder.encode(.charge(.closePort))
        let closeAction = try CarServer_Action(serializedBytes: closeBody)
        if case .chargePortDoorClose = closeAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected chargePortDoorClose")
        }
    }

    // MARK: - Climate

    func testClimateOnOff() throws {
        let (_, onBody) = try CommandEncoder.encode(.climate(.on))
        let onAction = try CarServer_Action(serializedBytes: onBody)
        guard case .hvacAutoAction(let onSub) = onAction.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(onSub.powerOn)

        let (_, offBody) = try CommandEncoder.encode(.climate(.off))
        let offAction = try CarServer_Action(serializedBytes: offBody)
        guard case .hvacAutoAction(let offSub) = offAction.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertFalse(offSub.powerOn)
    }

    func testClimateSetTemperature() throws {
        let (_, body) = try CommandEncoder.encode(.climate(.setTemperature(driver: 22.5, passenger: 21.0)))
        let action = try CarServer_Action(serializedBytes: body)
        guard case .hvacTemperatureAdjustmentAction(let sub) = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertEqual(sub.driverTempCelsius, 22.5)
        XCTAssertEqual(sub.passengerTempCelsius, 21.0)
    }

    // MARK: - Actions

    func testActionsHonkFlash() throws {
        let (_, honkBody) = try CommandEncoder.encode(.actions(.honk))
        let honkAction = try CarServer_Action(serializedBytes: honkBody)
        if case .vehicleControlHonkHornAction = honkAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlHonkHornAction")
        }
        let (_, flashBody) = try CommandEncoder.encode(.actions(.flashLights))
        let flashAction = try CarServer_Action(serializedBytes: flashBody)
        if case .vehicleControlFlashLightsAction = flashAction.vehicleAction.vehicleActionMsg {} else {
            XCTFail("expected vehicleControlFlashLightsAction")
        }
    }

    // MARK: - StateQuery

    func testStateQueryDriveOnly() throws {
        let body = try StateQueryEncoder.encode(.driveOnly)
        let action = try CarServer_Action(serializedBytes: body)
        guard case .getVehicleData(let get) = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(get.hasGetDriveState)
        XCTAssertFalse(get.hasGetChargeState)
    }

    func testStateQueryAllIncludesCharge() throws {
        let body = try StateQueryEncoder.encode(.all)
        let action = try CarServer_Action(serializedBytes: body)
        guard case .getVehicleData(let get) = action.vehicleAction.vehicleActionMsg else { XCTFail(); return }
        XCTAssertTrue(get.hasGetDriveState)
        XCTAssertTrue(get.hasGetChargeState)
        XCTAssertTrue(get.hasGetClimateState)
    }

    // MARK: - ResponseDecoder

    func testResponseDecoderInfotainmentOk() throws {
        var status = CarServer_ActionStatus()
        status.result = .operationstatusOk
        var response = CarServer_Response()
        response.actionStatus = status
        let bytes = try response.serializedData()

        let result = try ResponseDecoder.decodeInfotainment(bytes)
        XCTAssertEqual(result, .ok)
    }

    func testResponseDecoderInfotainmentError() throws {
        var status = CarServer_ActionStatus()
        status.result = .rror
        var response = CarServer_Response()
        response.actionStatus = status
        let bytes = try response.serializedData()

        let result = try ResponseDecoder.decodeInfotainment(bytes)
        guard case .vehicleError = result else {
            XCTFail("expected vehicleError, got \(result)"); return
        }
    }

    func testResponseDecoderVCSECOk() throws {
        var response = VCSEC_FromVCSECMessage()
        var status = VCSEC_CommandStatus()
        status.operationStatus = .operationstatusOk
        response.commandStatus = status
        let bytes = try response.serializedData()

        let result = try ResponseDecoder.decodeVCSEC(bytes)
        XCTAssertEqual(result, .ok)
    }
}
```

**Note on `hasGetDriveState` / `hasGetChargeState`**: Generated SwiftProtobuf structs expose `has<FieldName>: Bool` for message-typed fields. If the specific accessor name differs, use Read on `car_server.pb.swift` to confirm.

**Note on `.operationstatusOk`**: If the generated Swift uses `.rror`/`.rrorOk` due to the codegen quirk we saw in Phase 3a, adapt the test. Run `grep -n "case rror\|operationStatus" Sources/TeslaBLE/Generated/car_server.pb.swift` to check.

- [ ] **Step 2:** Run the test

```bash
swift test --filter CommandEncoderTests 2>&1 | tail -30
```

Expected: all tests green. If some cases fail on enum/field name lookups, that's a Phase 4a quirk where the generated code didn't match our guess — fix the specific test and encoder and rerun. Do NOT skip failing tests.

- [ ] **Step 3:** Run the full suite:

```bash
swift test 2>&1 | tail -10
```

Expected: 59 prior + new CommandEncoder tests (~18 methods), 0 failures.

- [ ] **Step 4:** Commit:

```bash
git add Tests/TeslaBLETests/CommandEncoderTests.swift
git commit -m "test: cover Phase 4a command encoders and response decoder"
```

---

## Task 10: Final regression check

- [ ] **Step 1:** Full suite + branch status:

```bash
swift test 2>&1 | grep -E "Executed.*(tests|failures)" | tail -3
swift build 2>&1 | tail -3
git log --oneline af702f4..HEAD | cat
git diff --stat af702f4..HEAD
```

Expected:

- `Executed <N> tests, with 0 failures` (N = 59 prior + CommandEncoderTests method count)
- `Build complete!`
- ~9 commits on top of the Phase 3b head (`af702f4 test: cover Dispatcher handshake SessionInfoRequest/Response flow`)
- New files: `Sources/TeslaBLE/Commands/*.swift` (4 files) + `Subcommands/*.swift` (4 files) + `Tests/TeslaBLETests/CommandEncoderTests.swift`

- [ ] **Step 2:** No commit. Verification only.

---

## Appendix A — Phase 4b follow-ups

Commands to add in Phase 4b:

- **Actions**: sunroof, windows (close/vent), tonneau (open/close/stop), trunk actuate
- **Charge**: schedules (add/remove/batch), scheduled departure, scheduled charging, low-power mode, keep accessory power
- **Climate**: seat heaters (per-seat map), seat coolers, steering wheel heater, preconditioning max, bioweapon defense, cabin overheat protection, climate keeper mode, auto-seat-and-climate
- **Infotainment**: volume (up/down/set), media (next/prev/toggle/favorite), software update (schedule/cancel), nearby charging, set vehicle name
- **Security** (PIN-protected): valet mode, sentry mode, guest mode, PIN-to-drive, speed limit (activate/deactivate/set/clear), erase user data, homelink trigger, reset valet PIN, reset PIN
- **Response decoder extensions**: extract structured payloads for state fetches (charge / drive / climate DTOs)

Each follows the pattern established in Phase 4a. No new architectural work.
