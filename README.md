# TeslaWalkUp

**Walk up to your locked Tesla with nothing but your iPhone in your pocket — the driver door unlatches as you arrive. No key fob, no card, no beacon, nothing added to the car, and you never touch the phone.**

Your iPhone *is* the key: it speaks Tesla's signed BLE protocol as a paired key and gates on how close you are to the car. Confirmed working **backgrounded, screen-locked, on a Model Y running iOS 26.**

> _Demo:_ <!-- drop a 20–30s GIF/clip here: lock car → walk away → walk back → door pops -->

---

## Why this is hard (and why it didn't exist)

Every obvious approach is a dead end, which is most of the fun:

- **No official API for it.** Tesla's Fleet API has `door_unlock` but **no "open/unlatch the door."** The only way to fire it is the local, end-to-end-signed **VCSEC BLE protocol** — so the phone has to pair as a real key.
- **You can't put a beacon in the car.** iOS randomizes its BLE MAC, so a chip in the car can't reliably see your phone; and the car doesn't advertise its GATT service UUID, so background scanning for it fails. So the **phone** has to be the smart side.
- **iOS murders background BLE.** A backgrounded app's timers are suspended after ~30s even with a live BLE connection — Core Bluetooth only wakes you for discrete *events*, not for "keep measuring distance." (And on iOS 26, state-restoration *relaunch* is now restricted to AccessorySetupKit apps.)
- **The Model Y latch is momentary.** A single unlatch releases then **re-latches** ("the second click"). There's no BLE "hold." And there's no door motor (that's S/X).

## How it actually works

```
iPhone (key + proximity sensor)                     Tesla (nothing installed)
┌───────────────────────────────────────┐
│ swift-tesla-ble (forked) = paired key  │   signed VCSEC session over BLE
│ CoreBluetooth: standing connect to car ├────────────►  car in range, connection holds
│ readRSSI() poll → "how close am I?"     │
│ low-power background LOCATION session   │   ← keeps the app alive so the poll
│   keeps the process alive in-pocket     │     keeps running while backgrounded
│ gate: RSSI ≥ threshold + was-away +     │
│   cooldown                              │
│        │ pass                           │
│        ▼  pulse every ~2s through the   │
│  ClosureMoveRequest(frontDriverDoor,    ├────────────►  latch releases each pulse;
│    OPEN), stop when door reads ajar      │              you pull the edge → open
└───────────────────────────────────────┘
```

The pieces that took real work:

1. **Forked [`swift-tesla-ble`](https://github.com/shoujiaxin/swift-tesla-ble) (MIT)** to add the driver-door unlatch the upstream lib (and Tesla's own Go SDK) doesn't expose: `Command.Security.openDriverDoor` → `ClosureMoveRequest(frontDriverDoor = .open)`.
2. **Background-survivable transport.** A `BackgroundBLETransport` + `TeslaVehicleClient.connect(using:)` that runs the signed session over an *already-connected* peripheral, because you can't scan in the background.
3. **The keep-alive.** A low-power `CoreLocation` session (`location` background mode) so the RSSI poll keeps running with the app suspended in your pocket — the one reliable way to beat iOS's background suspension. (Verified via on-device logging: RSSI samples flow in real time while backgrounded.)
4. **Locked-phone keychain.** The signing key is stored `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so it's readable while the phone is locked — otherwise the session fails with keychain `-25308`.
5. **The latch cycle.** Because a single unlatch re-latches, the app **pulses** the unlatch every ~2 s across a tunable window, giving you repeated clean moments to pull the door open by its edge — then **stops the instant the door reads open/ajar** (polls VCSEC closure state).

---

## Setup (you build + sideload it — it's not on the App Store)

You need a Mac with Xcode, or [AltStore](https://altstore.io) to sideload with your own free Apple ID.

```sh
brew install xcodegen
cd TeslaWalkUp
xcodegen generate
open TeslaWalkUp.xcodeproj   # set your Signing Team, pick your iPhone, Run
```

Then, **in the car:** enter your 17-char VIN → **Pair** → tap your Tesla key card on the console when the screen prompts. Grant **Location: Always** (that's the background keep-alive). Lock the car, walk away, walk back — pull the door as you arrive. Tune **"Open at"** (RSSI) and the **unlatch window** with the in-app sliders while watching the live signal.

A full step-by-step (including the no-Mac AltStore path) is in [`DEVICE_SETUP.md`](DEVICE_SETUP.md).

---

## Honest limits

- **Driver door only**, and it **unlatches** — the Model Y has no motor to swing the door (S/X only). You grab the edge and pull; no handle press. Whether it pops far enough vs. re-catches is partly your car's **latch striker** (a known, service-adjustable thing).
- **Don't force-quit the app** (don't swipe it away). On iOS 26 a force-quit app won't relaunch for Bluetooth without AccessorySetupKit. Backgrounded/suspended works.
- **Battery:** the location keep-alive costs some battery. That's the price of hands-free.
- **You own the outcome.** It only fires when the car is locked + you just arrived, but a door that auto-unlatches is your responsibility — tune conservatively.

## Disclaimer

For use on **your own vehicle**, for educational purposes, **at your own risk**. No warranty. Not affiliated with, endorsed by, or connected to Tesla, Inc. You are responsible for anything the door does. Reverse-engineering / local control of your own car is the gray area you're choosing to operate in.

## Credits / license

Built on [`shoujiaxin/swift-tesla-ble`](https://github.com/shoujiaxin/swift-tesla-ble) (MIT) and the protocol from [`teslamotors/vehicle-command`](https://github.com/teslamotors/vehicle-command). This project and the fork retain **MIT**.
