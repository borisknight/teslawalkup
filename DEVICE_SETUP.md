# TeslaWalkUp — get it on your iPhone (one page)

## 1. Install Xcode  ✅ (downloading now)
Mac App Store → Xcode → Install (~15 GB).

## 2. Open the project
```sh
cd TeslaWalkUp && xcodegen generate && open TeslaWalkUp.xcodeproj
```

## 3. Signing (~30 sec)
- Click the blue **TeslaWalkUp** at the top of the left sidebar.
- **Signing & Capabilities** tab → check **Automatically manage signing**.
- **Team** → pick your Apple ID (or "Add an Account…"). A free Apple ID is fine.

## 4. Run on your iPhone
- Plug in iPhone (cable), unlock, tap **Trust** if asked.
- Top of Xcode: pick your iPhone from the device dropdown.
- Press **▶** (Play).
- First time the phone blocks it → **Settings → General → VPN & Device Management → [your profile] → Trust**, then press ▶ again.

## 5. Pair (sit in the car)
- App opens → enter your 17-char **VIN** → **Pair**.
- Car screen prompts → **tap your Tesla NFC key card** on the center console.
- App says "armed." Lock the car, walk ~20 m away, walk back to the door.

---

## If something snags

| What you see | Fix |
|---|---|
| "Untrusted Developer" on iPhone | Settings → General → VPN & Device Management → trust your profile, re-run. |
| Xcode signing error about bundle id | Change `com.knight.teslawalkup` to something unique like `com.<you>.teslawalkup` (Signing tab → Bundle Identifier), re-run. |
| App asks for Bluetooth | Tap **Allow** — it can't see the car otherwise. |
| Pair fails / HMAC error | Be IN the car, car awake, Bluetooth on; the VIN must be exactly right. Tap the NFC card when prompted. |
| Door won't unlatch but pairing worked | Test the manual path first; some firmware blocks door actuation. If the Tesla app's own "Unlatch Door" works but this doesn't, tell me. |
| Fires too early / too late on walk-up | Tune `rssiNear` / `rssiFar` in `App/PairingStore.swift` (closer to 0 = must be nearer), re-run. |

Stuck on any line → tell me the exact screen/error and I'll fix it.
