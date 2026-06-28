#!/usr/bin/env bash
#
# Build, install, and launch TeslaWalkUp on a connected iPhone — entirely from
# the CLI. This is the proven, signing-safe invocation (see BUILD.md for the RCA).
#
# Usage:
#   ./deploy.sh [DEVICE_UDID]
#       no arg  -> auto-detects the first connected iPhone
#       UDID    -> targets that device (xcrun devicectl list devices)
#
# ⚠️  DO NOT add DEVELOPMENT_TEAM=… or CODE_SIGN_STYLE=… to the xcodebuild line.
#     Those overrides clobber the project's Xcode-managed automatic signing and
#     throw `error: No Account for Team …`. Pass ONLY -allowProvisioningUpdates
#     and let the team configured in the project (your logged-in Apple ID) drive.
#     DEVELOPER_DIR must point at the full Xcode.app — the Command Line Tools have
#     no signing accounts and produce the same "No Account" error.
#
set -euo pipefail
cd "$(dirname "$0")"

# Full Xcode (NOT /Library/Developer/CommandLineTools).
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

PROJECT=TeslaWalkUp.xcodeproj
SCHEME=TeslaWalkUp
BUNDLE_ID=com.knight.teslawalkup

# Device: first CLI arg, else the first connected iPhone.
DEV="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/{print $3; exit}')}"
if [ -z "${DEV:-}" ]; then
  echo "❌ No connected iPhone found. Plug it in + unlock, or pass a UDID:" >&2
  echo "   ./deploy.sh <UDID>    (list: xcrun devicectl list devices)" >&2
  exit 1
fi
echo "▶︎ Device: $DEV"

echo "▶︎ Building + signing (automatic signing via the project)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "platform=iOS,id=$DEV" \
  -allowProvisioningUpdates -derivedDataPath build build

APP="build/Build/Products/Debug-iphoneos/${SCHEME}.app"
echo "▶︎ Installing ${APP}…"
xcrun devicectl device install app --device "$DEV" "$APP"

echo "▶︎ Launching ${BUNDLE_ID}…"
if xcrun devicectl device process launch --device "$DEV" "$BUNDLE_ID" 2>/dev/null; then
  echo "✅ Done — built, installed, and launched on the phone."
else
  echo "✅ Built + installed. ⚠︎  Couldn't auto-launch — the iPhone is almost certainly LOCKED"
  echo "   (devicectl can't launch on a locked device). Unlock it and tap TeslaWalkUp,"
  echo "   or re-run ./deploy.sh with the phone unlocked."
fi
