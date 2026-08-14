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
#   ./build.sh testflight ThrumFlow (iOS/iPadOS) → archive → App Store IPA
#                         → dist/ios/, and uploads if ASC_* are set.
#                         CarPlay is included; CARPLAY=0 leaves it out.
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

# ./build.sh flightlog — pull ThrumFlow's flight recorder off the phone.
#
# The interesting audio failures happen on a walk, with the screen off and the
# phone in a pocket, which is precisely when nothing can be observed live. The app
# writes one heartbeat line every thirty seconds plus a line per route change,
# interruption and transport change; this fetches it.
#
# `--domain-type appDataContainer` needs the app to be a development build, which
# a device install from here always is.
if [[ "$MODE" == "flightlog" ]]; then
  DEVICE="${DEVICE:-DDF950A8-6E31-5DAD-8F99-79FF51CFB271}"
  OUT="${2:-dist/flight.log}"
  mkdir -p "$(dirname "$OUT")"
  rm -f "$OUT"
  # A wedged CoreDevice tunnel reports the phone as unavailable even when it is
  # sitting unlocked on the desk; restarting the daemons clears it.
  xcrun devicectl list devices 2>/dev/null | grep -i iphone | grep -q unavailable \
    && { echo "▸ Device unavailable — restarting CoreDevice…"; killall -9 remotepairingd remotepaireddevice CoreDeviceService coredeviced 2>/dev/null || true; sleep 6; }
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier com.jeffhobbs.thrumflow \
    --source "Library/Application Support/Thrum/flight.log" \
    --destination "$OUT"
  echo
  echo "▸ $OUT"
  echo
  tail -40 "$OUT"
  exit 0
fi
# Only `testflight` reads this: an explicit build number, overriding project.yml.
BUILD_ARG="${2:-}"
DEV_ID="${DEV_ID:-Developer ID Application}"   # codesign matches this as a substring

# Find an app-specific password without it having to be in the environment.
#
# These cannot be recovered from Apple: appleid.apple.com shows the password once,
# at creation, and never again — "I'll look it up later" ends in generating a new
# one. So the moment you have it, put it in the keychain:
#
#   xcrun altool --store-password-in-keychain-item --item thrum-asc \
#     -u you@example.com -p abcd-efgh-ijkl-mnop
#
# The `--item` is required and altool's own usage line omits it — without it the
# command fails with "Expected item argument is missing, --item", which reads like
# the flag is wrong rather than incomplete.
#
# and it is never needed again. `altool` reads it back through the `@keychain:`
# prefix, so nothing secret passes through this script, the environment, or shell
# history. Other apps' stored items are probed too, because an app-specific
# password is per Apple ID rather than per app — one made for another project
# works here unchanged.
resolve_asc_password() {
  if [[ -n "$ASC_APP_PASSWORD" ]]; then
    echo "$ASC_APP_PASSWORD"
    return 0
  fi
  local candidates=(thrum-asc thrumflow-asc phonotropic-asc mutiny-asc)
  for item in "${candidates[@]}"; do
    if security find-generic-password -l "$item" >/dev/null 2>&1 \
       || security find-generic-password -s "$item" >/dev/null 2>&1; then
      echo "@keychain:$item"
      return 0
    fi
  done
  return 1
}

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

# ThrumFlow — the iOS/iPadOS build, to TestFlight.
#
# Handled before the macOS build below and exits, because none of that applies:
# no universal binary (iOS is arm64 only), no Developer ID, no notarization, no
# Sparkle. App Store builds are signed by Apple's own pipeline after upload, so
# what leaves here is an unnotarized IPA and that is correct.
#
# One build covers iPhone and iPad — TARGETED_DEVICE_FAMILY is "1,2", so there is
# no separate iPadOS target and no second upload.
#
# Uploading needs App Store Connect credentials, which are deliberately not stored
# here. Either kind works; set one pair and it uploads, leave both unset and it
# stops with the IPA on disk.
#
#   App-specific password (simplest, and what the other iOS apps on this machine
#   use). The password comes from appleid.apple.com → Sign-In and Security →
#   App-Specific Passwords, NOT from App Store Connect. It is per Apple ID rather
#   than per app, so one already made for another app works here unchanged:
#     ASC_APPLE_ID      your Apple ID email
#     ASC_APP_PASSWORD  abcd-efgh-ijkl-mnop
#
#   Or an API key, if you have one:
#     ASC_KEY_ID        the key's ID
#     ASC_ISSUER_ID     the issuer UUID from the Keys page
#   with the .p8 in ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#
# The build number can be overridden: `./build.sh testflight 42`. Without one it
# uses CURRENT_PROJECT_VERSION from project.yml, which has to be bumped by hand
# because App Store Connect rejects a build number it has already seen — and it
# rejects it *after* the upload and a processing wait, which is a slow way to find
# out. `./build.sh testflight $(date +%s)` sidesteps the question entirely.
if [[ "$MODE" == "testflight" ]]; then
  ARCHIVE="build-ios/ThrumFlow.xcarchive"
  EXPORT_DIR="dist/ios"
  mkdir -p "$EXPORT_DIR" build-ios

  # CarPlay is ON by default as of 2026-08-01, when Apple granted
  # `com.apple.developer.carplay-audio` (developer.apple.com/carplay, app type
  # Audio) and it was enabled on the App ID. Verified by signing a device build
  # that carries it in both the binary and the embedded profile.
  #
  # It was opt-in before that, and had to be: a provisioning profile cannot carry
  # the entitlement until the account has been granted it, so attaching it early
  # fails profile generation and would have broken every ordinary upload. That
  # reasoning is now spent, and an env var you have to remember is worse than no
  # var at all — forgetting it ships a TestFlight build with no CarPlay and
  # nothing that says so. Hence the default flipped rather than the flag kept.
  #
  # `CARPLAY=0 ./build.sh testflight` still turns it off, for one situation: if
  # profile generation ever starts failing on the entitlement again, that gets an
  # uploadable build out of the door while the account side is sorted out.
  #
  # The CarPlay *code* and the scene manifest ship either way — the scene simply
  # never activates without the entitlement — so there is no second code path to
  # keep working.
  #
  # Without the grant, this fails with exactly:
  #
  #   error: Entitlement com.apple.developer.carplay-audio not found and could
  #   not be included in profile. This likely is not a valid entitlement and
  #   should be removed from your entitlements file.
  #
  # Ignore the second sentence. The entitlement is valid and correctly spelled;
  # the account simply cannot sign it, and Xcode cannot tell the difference
  # between "not granted" and "not real". Deleting the entitlements file on that
  # advice throws away working CarPlay support. The thing to check is that the
  # capability is still enabled on the App ID and that the profile has been
  # regenerated — not the spelling.
  CARPLAY_ARGS=()
  if [[ "$CARPLAY" == "0" ]]; then
    echo "▸ CarPlay entitlement withheld (CARPLAY=0) — the car will not see this build."
  else
    echo "▸ CarPlay entitlement attached."
    CARPLAY_ARGS=(CODE_SIGN_ENTITLEMENTS=iOS/ThrumFlow.entitlements)
  fi

  # An explicit build number overrides project.yml for this archive only, so a
  # re-upload doesn't need an edit-and-commit cycle just to get past App Store
  # Connect's "you have used that number" rejection.
  BUILD_ARGS=()
  if [[ -n "$BUILD_ARG" ]]; then
    BUILD_ARGS=(CURRENT_PROJECT_VERSION="$BUILD_ARG")
    echo "▸ Build number overridden: $BUILD_ARG"
  fi

  echo "▸ Archiving ThrumFlow…"
  # -allowProvisioningUpdates creates or downloads the App Store distribution
  # profile. Signing turned out to be Cloud Managed, so Apple holds the
  # distribution certificate and no local certificate slot is spent.
  xcodebuild -project Thrum.xcodeproj -scheme ThrumFlow -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet \
    "${CARPLAY_ARGS[@]}" "${BUILD_ARGS[@]}" \
    archive

  # Read the version from the *archive*, not from iOS/Info.plist.
  #
  # XcodeGen writes `$(MARKETING_VERSION)` into that plist as a literal and Xcode
  # resolves it at build time, so reading it beforehand yields the token rather
  # than a number — the first version of this printed "Archiving ThrumFlow
  # $(MARKETING_VERSION)". Same lesson as the macOS side, where the zip is named
  # from the built bundle: the artifact is the only source of truth for what a
  # build actually calls itself.
  ARCHIVED_PLIST="$ARCHIVE/Products/Applications/ThrumFlow.app/Info.plist"
  VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ARCHIVED_PLIST")
  BUILD_NO=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ARCHIVED_PLIST")
  echo "▸ Archived $VER ($BUILD_NO)"

  # `app-store-connect` is the current name; it was `app-store` before Xcode
  # 15.3 and the old value now warns.
  cat > build-ios/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>YKF353373Y</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

  echo "▸ Exporting IPA…"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist build-ios/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" -allowProvisioningUpdates -quiet

  RAW_IPA=$(ls "$EXPORT_DIR"/ThrumFlow.ipa 2>/dev/null | head -1)
  [[ -n "$RAW_IPA" ]] || { echo "✗ No IPA produced." >&2; exit 1; }

  # Re-read the build number from the *exported* IPA, because the export changes
  # it. `manageAppVersionAndBuildNumber` is true in the options above, so Xcode
  # asks App Store Connect what it has already seen and silently bumps past it —
  # on 2026-08-10 an archive that said 2 came out of export as 3, and the archive
  # is the number this script had already printed and named the file with. So the
  # console said "Archived 1.0.0 (2)", the file said `-2`, and TestFlight said 3.
  #
  # Same lesson as reading the version from the archive rather than from
  # iOS/Info.plist, one stage further along: the artifact is the only source of
  # truth for what a build calls itself, and export produces a *new* artifact.
  #
  # It also means the closing advice about bumping CURRENT_PROJECT_VERSION is a
  # belt-and-braces measure rather than a requirement — Xcode will find the next
  # free number by itself. Bumping it by hand keeps the repo honest about what has
  # shipped, which is worth doing anyway.
  EXPORTED_BUILD_NO=$(unzip -p "$RAW_IPA" 'Payload/ThrumFlow.app/Info.plist' 2>/dev/null \
    | plutil -extract CFBundleVersion raw -o - - 2>/dev/null) || true
  if [[ -n "$EXPORTED_BUILD_NO" && "$EXPORTED_BUILD_NO" != "$BUILD_NO" ]]; then
    echo "▸ Export bumped the build number: $BUILD_NO → $EXPORTED_BUILD_NO (App Store Connect had already seen $BUILD_NO)."
    BUILD_NO="$EXPORTED_BUILD_NO"
  fi
  # Versioned filename, matching the macOS convention — an unversioned artifact
  # is how you upload yesterday's build.
  IPA="$EXPORT_DIR/ThrumFlow-$VER-$BUILD_NO.ipa"
  mv -f "$RAW_IPA" "$IPA"
  echo "▸ Exported: $IPA"

  # Two credential shapes, one upload. Validate first in both cases: it catches
  # the whole ITMS-9xxxx family — a missing privacy-manifest declaration, an icon
  # with an alpha channel, an entitlement the profile can't carry — in about a
  # minute, against finding out by email a quarter of an hour after uploading.
  AUTH=()
  ASC_PW="$(resolve_asc_password || true)"
  if [[ -n "$ASC_APPLE_ID" && -n "$ASC_PW" ]]; then
    AUTH=(-u "$ASC_APPLE_ID" -p "$ASC_PW")
    if [[ "$ASC_PW" == @keychain:* ]]; then
      echo "▸ Using the app-specific password in the keychain (${ASC_PW#@keychain:}) for $ASC_APPLE_ID."
    else
      echo "▸ Using the app-specific password from the environment for $ASC_APPLE_ID."
    fi
  elif [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]]; then
    AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
    echo "▸ Using the App Store Connect API key $ASC_KEY_ID."
  fi

  if (( ${#AUTH[@]} )); then
    echo "▸ Validating…"
    xcrun altool --validate-app -f "$IPA" -t ios "${AUTH[@]}"
    echo "▸ Uploading to App Store Connect…"
    xcrun altool --upload-app -f "$IPA" -t ios "${AUTH[@]}"
    echo "▸ Uploaded. Processing takes a few minutes before it appears in TestFlight;"
    echo "  Apple emails when it finishes. Testers are added there, not here."
  else
    echo "▸ Not uploading — no credentials found."
    if [[ -z "$ASC_APPLE_ID" ]]; then
      echo "  Missing ASC_APPLE_ID (your Apple ID email):  export ASC_APPLE_ID=\"you@example.com\""
    fi
    if [[ -z "$ASC_PW" ]]; then
      echo "  Missing the app-specific password. Make one at appleid.apple.com →"
      echo "  Sign-In and Security → App-Specific Passwords (it is shown once), then:"
      echo "    xcrun altool --store-password-in-keychain-item --item thrum-asc \\"
      echo "      -u \"\$ASC_APPLE_ID\" -p abcd-efgh-ijkl-mnop"
      echo "  after which this script finds it by itself, forever."
    fi
    echo "  An API key works too: export ASC_KEY_ID=<id> ASC_ISSUER_ID=<uuid>"
    echo "  Or upload the IPA on disk by hand:"
    echo "    xcrun altool --upload-app -f \"$IPA\" -t ios -u <apple-id> -p @keychain:thrum-asc"
  fi
  echo
  echo "  Next upload needs a build number App Store Connect has not seen: bump"
  echo "  CURRENT_PROJECT_VERSION in project.yml, or run"
  echo "    ./build.sh testflight \$(date +%s)"
  exit 0
fi

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
