# Building & Deploying TeslaWalkUp (CLI)

**TL;DR — just run the script** (it does everything below, signing gotcha included):

```bash
./deploy.sh            # build -> install -> launch on the connected iPhone
./deploy.sh <UDID>     # target a specific device
```

This app builds, installs, and launches onto a physical iPhone entirely from the
command line — no clicking around in Xcode. Two prerequisites:

- **Full Xcode** is installed (not just the Command Line Tools).
- Your **Apple ID / signing team is set in the project** (open
  `TeslaWalkUp.xcodeproj` once → Signing & Capabilities → select your team,
  automatic signing). After that it persists and the CLI can sign.

## The one command (build → install → launch)

```bash
cd TeslaWalkUp
# Use FULL Xcode, not the Command Line Tools (CLT has no signing accounts):
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Your connected device's UDID (3rd column of the device list):
DEV=$(xcrun devicectl list devices | awk '/iPhone/{print $3; exit}')

xcodebuild -project TeslaWalkUp.xcodeproj -scheme TeslaWalkUp \
  -configuration Debug -destination "platform=iOS,id=$DEV" \
  -allowProvisioningUpdates -derivedDataPath build build

APP=build/Build/Products/Debug-iphoneos/TeslaWalkUp.app
xcrun devicectl device install app --device "$DEV" "$APP"
xcrun devicectl device process launch --device "$DEV" com.knight.teslawalkup
```

## ⚠️ The gotcha (this is the one that burns time)

**Do NOT pass `DEVELOPMENT_TEAM=…` or `CODE_SIGN_STYLE=Automatic` on the
`xcodebuild` command line.** Those overrides clobber the project's
Xcode-managed automatic signing and produce:

```
error: No Account for Team "XXXXXXXXXX". Add a new account in Accounts settings…
error: No profiles for 'com.knight.teslawalkup' were found…
```

The working recipe passes **nothing** signing-related except
`-allowProvisioningUpdates`, and lets the team configured in the project (tied
to your logged-in Apple ID) drive. Two ways this same "No Account" error shows
up:

1. You added `DEVELOPMENT_TEAM=` / `CODE_SIGN_STYLE=` overrides — remove them.
2. `DEVELOPER_DIR` resolved to `/Library/Developer/CommandLineTools` instead of
   `Xcode.app` — the CLT has no signing accounts. Export `DEVELOPER_DIR` as
   above (or `sudo xcode-select -s /Applications/Xcode.app`).

A successful build logs `Signing Identity: "Apple Development: <you> (TEAMID)"`
followed by `** BUILD SUCCEEDED **`.

## Compile-check only (no device, no signing)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project TeslaWalkUp.xcodeproj -scheme TeslaWalkUp \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Don't run `xcodegen generate` unless you changed `project.yml`

It rewrites `TeslaWalkUp.xcodeproj` from `project.yml`. The committed
`project.yml` leaves `DEVELOPMENT_TEAM` blank (commented out) for public
release, so regenerating **wipes the team you set in Xcode** and you're back to
the "No Account" error until you re-pick the team (or temporarily bake your
team ID into `project.yml`). The generated `.xcodeproj` is gitignored.

## First-time device prerequisites (one-time, phone-side)

- iPhone → Settings → Privacy & Security → **Developer Mode → ON** (it restarts).
- Trust the Mac when prompted.
- First launch of a new signing identity: iPhone → Settings → General →
  VPN & Device Management → trust your developer profile.
