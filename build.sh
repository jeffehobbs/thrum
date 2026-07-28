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
#                         → dist/Thrum-<ver>.zip → docs/appcast.xml
#   ./build.sh appcast    Regenerate docs/appcast.xml from the existing zip
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
#
# Shipping an update needs one more secret than notarizing does: the Ed25519
# private key Sparkle signs archives with, held in the login keychain and created
# once by Sparkle's generate_keys. Its public half is SUPublicEDKey in
# project.yml. Installed copies refuse any archive not signed by that key, which
# is the point — and also means losing it strands every copy in the field on
# whatever version it has. Export a backup with:
#   build/sparkle-tools/<ver>/generate_keys -x thrum-sparkle-key.txt
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

# Sign an app bundle and everything nested inside it, innermost first.
#
# This exists because Thrum gained an embedded framework (Sparkle) and the old
# one-line `codesign "$APP"` silently stopped being sufficient. codesign seals
# each bundle's contents into its own signature, so signing the outer app first
# and a nested helper afterwards invalidates the outer seal — the order has to
# run inside-out, and every nested Mach-O or bundle needs its own call. Get it
# wrong and it builds, installs and runs perfectly on this machine, then
# notarization rejects the submission. `--deep` appears to solve this and is
# discouraged by Apple; doing it explicitly is the supported route.
#
# Sparkle's XPC services are only used by sandboxed apps, and Sparkle documents
# deleting them for apps like Thrum that aren't. They are kept and signed anyway:
# the saving is about a megabyte, and a mistake here breaks updates for every
# copy in the field with no way to push a fix.
sign_inside_out() {
  local app="$1"
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"
  local target
  # Innermost first. Order within this list matters.
  for target in \
    "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
    "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/Updater.app" \
    "$sparkle/Versions/B/Autoupdate" \
    "$sparkle" \
    "$app"
  do
    [[ -e "$target" ]] || continue
    codesign --force --timestamp --options runtime --sign "$DEV_ID" "$target"
  done
}

# Sparkle's command-line tools ship in the release tarball, not in the Swift
# package — the SPM product is only the XCFramework. Cached under build/ so it
# is fetched once and never committed.
SPARKLE_VERSION="2.9.4"

# Write docs/appcast.xml — the file every installed copy of Thrum polls to find
# out whether a newer one exists.
#
# Built from a staging directory holding *only* this release rather than from
# dist/ directly, and that is deliberate. generate_appcast signs every archive it
# finds and stamps them all with one --download-url-prefix, so pointing it at a
# dist/ that has accumulated older builds would emit entries claiming v1.2 lives
# under the v1.4.0 release tag. Those are 404s that only reveal themselves when
# someone on an old version tries to update. The cost is giving up delta patches,
# which need the older archives present — not worth it for a zip this size.
#
# Release notes are picked up automatically from notes/<version>.html if you
# write one; without it Sparkle shows the version numbers and nothing else.
make_appcast() {
  local ver="$1" zip="$2"
  local tools; tools=$(resolve_sparkle_tools) || return 1
  local stage; stage=$(mktemp -d)

  cp "$zip" "$stage/"
  [[ -f "notes/$ver.html" ]] && cp "notes/$ver.html" "$stage/Thrum-$ver.html"

  mkdir -p docs
  echo "▸ Generating appcast for $ver…"
  # The private key comes from the login keychain; macOS may prompt to allow it.
  "$tools/generate_appcast" \
    --download-url-prefix "https://github.com/jeffehobbs/thrum/releases/download/v$ver/" \
    --link "https://github.com/jeffehobbs/thrum" \
    -o docs/appcast.xml \
    "$stage"

  rm -rf "$stage"

  # A feed that parses but carries no signature would be accepted by nothing —
  # installed copies reject unsigned archives — so fail loudly here rather than
  # shipping a feed that silently never updates anyone.
  if ! grep -q 'sparkle:edSignature' docs/appcast.xml; then
    echo "✗ appcast has no EdDSA signature. Is the private key in the keychain?" >&2
    return 1
  fi
  echo "▸ Wrote docs/appcast.xml"
}

resolve_sparkle_tools() {
  local dir="build/sparkle-tools/$SPARKLE_VERSION"
  if [[ ! -x "$dir/generate_appcast" ]]; then
    echo "▸ Fetching Sparkle $SPARKLE_VERSION tools…" >&2
    mkdir -p "$dir"
    local tarball="$dir/sparkle.tar.xz"
    curl -sSfL -o "$tarball" \
      "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
      || { echo "✗ Could not download Sparkle $SPARKLE_VERSION." >&2; return 1; }
    tar -xJf "$tarball" -C "$dir" bin
    mv "$dir/bin/"* "$dir/" && rmdir "$dir/bin"
    rm -f "$tarball"
  fi
  echo "$dir"
}

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
  sign_inside_out "$APP"
  # --deep on the *verify* side is fine and wanted; it is only --deep signing
  # that Apple discourages. This is the check that would have caught the
  # framework being left ad-hoc, which notarization rejects.
  codesign --verify --strict --deep --verbose=2 "$APP"

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

  make_appcast "$VER" "$DIST_ZIP"
fi

if [[ "$MODE" == "appcast" ]]; then
  VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  [[ -f "dist/Thrum-$VER.zip" ]] || { echo "✗ dist/Thrum-$VER.zip not found — run ./build.sh notarize first." >&2; exit 1; }
  make_appcast "$VER" "dist/Thrum-$VER.zip"
fi
