#!/bin/zsh
# Build Thrum.app.
#
# Release is the default on purpose. The drone engine is ~40× slower under
# -Onone — a Debug build misses the render deadline with a handful of voices
# and cannot keep up at all with a full grid, which sounds like crackle and
# ticks rather than like anything being wrong with the code. Only build Debug
# when you actually need the symbols, and don't listen to the result.
#
#   ./build.sh            Release build
#   ./build.sh run        Release, install to ~/Applications, launch
#   ./build.sh debug      Debug build — for the debugger, not for the ears
#   ./build.sh notarize   Release → Developer ID sign → notarize → staple
#                         → dist/Thrum-<ver>.zip
#
# Notarizing needs a one-time stored credential profile (Apple ID method):
#   xcrun notarytool store-credentials thrum-notary \
#     --apple-id "you@example.com" --team-id YKF353373Y \
#     --password "<app-specific-password>"
# The credential is per Apple ID rather than per app, so any profile already
# stored for another app works too; the script picks the first one that
# authenticates. Set NOTARY_PROFILE=... to force a particular one.
#
# Thrum is signed with the hardened runtime and *no* entitlements. It needs
# none: it only opens CoreMIDI endpoints and an audio output unit, neither of
# which is a restricted resource, and its one piece of persisted state is a
# UserDefaults dictionary. It is deliberately not sandboxed — the sandbox buys
# nothing for Developer ID distribution here and gets in the way of talking to
# a class-compliant USB controller.
set -e
cd "$(dirname "$0")"

MODE="${1:-release}"
DEV_ID="${DEV_ID:-Developer ID Application}"   # codesign matches this as a substring

# First stored notary credential that authenticates wins.
resolve_notary_profile() {
  local candidates=(thrum-notary mutiny-notary)
  [[ -n "$NOTARY_PROFILE" ]] && candidates=("$NOTARY_PROFILE")
  local p
  for p in $candidates; do
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  echo "✗ No usable notarytool credential profile (tried: $candidates)." >&2
  echo "  Create one with: xcrun notarytool store-credentials thrum-notary \\" >&2
  echo "    --apple-id \"you@example.com\" --team-id YKF353373Y --password \"<app-specific-password>\"" >&2
  return 1
}

CONFIG=Release
[[ "$MODE" == "debug" ]] && CONFIG=Debug

xcodegen generate --quiet

# Sign ad-hoc during the build; the notarize path re-signs with the real
# identity afterwards. This keeps xcodebuild from needing a provisioning
# profile for an app that is distributed outside the App Store.
# ARCHS/ONLY_ACTIVE_ARCH are explicit because they have to be: xcodebuild
# defaults to ONLY_ACTIVE_ARCH=YES for a local build, which quietly produces a
# host-only binary. Thrum shipped arm64-only from 1.0 to 1.3.1 while the README
# claimed Apple silicon *or* Intel, and nothing in the pipeline noticed — hence
# the lipo check further down.
xcodebuild -project Thrum.xcodeproj -scheme Thrum -configuration "$CONFIG" \
  -derivedDataPath build -quiet \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build

APP="build/Build/Products/$CONFIG/Thrum.app"

# Universal or it doesn't ship. This is a one-line guard against the exact way
# the claim and the artifact drifted apart before.
ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/Thrum" | tr ' ' '\n' | sort | tr '\n' ' ')
if [[ "$ARCHS_BUILT" != "arm64 x86_64 " ]]; then
  echo "✗ expected a universal binary, got: $ARCHS_BUILT" >&2
  exit 1
fi

echo "Built: $APP  ($CONFIG, universal: $ARCHS_BUILT)"
[[ "$CONFIG" == "Debug" ]] && echo "  ⚠︎  Debug build — the engine will glitch. Use ./build.sh for Release."

if [[ "$MODE" == "run" ]]; then
  osascript -e 'quit app "Thrum"' 2>/dev/null || true
  sleep 1
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$HOME/Applications/Thrum.app"
  echo "Installed: ~/Applications/Thrum.app"
  open "$HOME/Applications/Thrum.app"
fi

if [[ "$MODE" == "notarize" ]]; then
  VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  PROFILE=$(resolve_notary_profile)
  mkdir -p dist

  echo "▸ Signing with Developer ID (hardened runtime + secure timestamp)…"
  codesign --force --timestamp --options runtime --sign "$DEV_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  echo "▸ Submitting to Apple notary service as '$PROFILE' (this can take a few minutes)…"
  SUBMIT_ZIP="dist/Thrum-$VER-submit.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"
  xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vvv --type execute "$APP" || true

  DIST_ZIP="dist/Thrum-$VER.zip"
  rm -f "$SUBMIT_ZIP" "$DIST_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_ZIP"
  echo "▸ Notarized & stapled: $DIST_ZIP"
fi
