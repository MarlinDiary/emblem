#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${EMBLEM_BUILD_DIR:-$ROOT/.build}"
DEST="${1:-$ROOT/build}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
cd "$ROOT"
for key in com.apple.security.personal-information.addressbook com.apple.security.automation.apple-events; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$ROOT/Resources/Emblem.entitlements")" == "true" ]] || { echo "Missing required entitlement: $key" >&2; exit 4; }
done
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 26 ]] || { echo 'Build with Xcode 26 or later for Liquid Glass.' >&2; exit 2; }
# SwiftPM's swiftbuild backend can stamp the deployment target as the linked SDK.
# Pass the actual SDK explicitly; otherwise AppKit may render compatibility UI.
BUILD_ARGS=(-c release --scratch-path "$SCRATCH" --sdk "$SDK"
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")
swift build "${BUILD_ARGS[@]}" --product Emblem
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
LINKED_SDK="$(xcrun vtool -show-build "$BIN/Emblem" | awk '$1 == "sdk" { print $2; exit }')"
[[ "$LINKED_SDK" == "$SDK_VERSION" ]] || { echo "Linked SDK mismatch: $LINKED_SDK (expected $SDK_VERSION)" >&2; exit 3; }
APP="$DEST/Emblem.app"
if [[ -e "$APP" ]]; then
  echo "Output already exists: $APP. Move it aside before rebuilding." >&2
  exit 2
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${EMBLEM_UNIVERSAL:-0}" == "1" ]]; then
  INTEL_ARGS=(-c release --scratch-path "${SCRATCH}-intel" --triple x86_64-apple-macosx14.0 --sdk "$SDK"
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")
  swift build "${INTEL_ARGS[@]}" --product Emblem
  INTEL_BIN="$(swift build "${INTEL_ARGS[@]}" --show-bin-path)"
  lipo -create "$BIN/Emblem" "$INTEL_BIN/Emblem" -output "$APP/Contents/MacOS/Emblem"
else
  cp "$BIN/Emblem" "$APP/Contents/MacOS/Emblem"
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Sources/PortraitCore/Resources/public_suffix_list.dat" "$APP/Contents/Resources/"
cp "$ROOT/Sources/PortraitCore/Resources/claude-icon.svg" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
[[ -z "$SOURCE_REVISION" ]] || plutil -insert EmblemSourceRevision -string "$SOURCE_REVISION" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ThirdPartyNotices.txt" "$APP/Contents/Resources/"
# Include dependency privacy manifests and package resources.
for RESOURCE in "$BIN"/*.bundle; do
  [[ -d "$RESOURCE" ]] && cp -R "$RESOURCE" "$APP/Contents/Resources/"
done
if [[ -n "${EMBLEM_GOOGLE_CLIENT_ID:-}" ]]; then
  [[ "$EMBLEM_GOOGLE_CLIENT_ID" == *.apps.googleusercontent.com ]] || exit 4
  plutil -insert EmblemGoogleClientID -string "$EMBLEM_GOOGLE_CLIENT_ID" "$APP/Contents/Info.plist"
fi
if [[ -n "${EMBLEM_GOOGLE_DESKTOP_CONFIG_FILE:-}" ]]; then
  python3 "$ROOT/Scripts/apply-native-oauth-config.py" "$EMBLEM_GOOGLE_DESKTOP_CONFIG_FILE" "$APP/Contents/Info.plist"
  export EMBLEM_GOOGLE_CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :EmblemGoogleClientID' "$APP/Contents/Info.plist")"
fi
# Push is an all-or-nothing build configuration; a partially configured app
# remains an ordinary Gmail client rather than advertising instant updates.
if [[ -n "${EMBLEM_GMAIL_PUSH_ENDPOINT:-}${EMBLEM_GMAIL_PUBSUB_TOPIC:-}${EMBLEM_GOOGLE_PROJECT_NUMBER:-}" ]]; then
  python3 "$ROOT/Scripts/validate-push-config.py"
  plutil -insert EmblemGmailPushEndpoint -string "$EMBLEM_GMAIL_PUSH_ENDPOINT" "$APP/Contents/Info.plist"
  plutil -insert EmblemGmailPubSubTopic -string "$EMBLEM_GMAIL_PUBSUB_TOPIC" "$APP/Contents/Info.plist"
  plutil -insert EmblemGoogleProjectNumber -string "$EMBLEM_GOOGLE_PROJECT_NUMBER" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/Resources/LaunchAgents/com.protoyard.emblem.sync.plist" "$APP/Contents/Library/LaunchAgents/"
# Kept for one release so Emblem can unregister the previous login item during upgrade.
cp "$ROOT/Resources/LaunchAgents/org.mailportrait.sync.plist" "$APP/Contents/Library/LaunchAgents/"
plutil -insert DTSDKName -string "macosx$SDK_VERSION" "$APP/Contents/Info.plist"
plutil -insert DTPlatformVersion -string "$SDK_VERSION" "$APP/Contents/Info.plist"
bash "$ROOT/Scripts/build-icon.sh" "$APP"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # A stable identity preserves the designated requirement across local builds.
  # Select only an unambiguous existing Developer ID; never invent a certificate.
  IDENTITIES="$(security find-identity -v -p codesigning | sed -n '/"Developer ID Application:/s/^[[:space:]]*[0-9]*) \([A-F0-9]*\).*/\1/p')"
  COUNT="$(printf '%s\n' "$IDENTITIES" | grep -c '^[A-F0-9]' || true)"
  if [[ "$COUNT" == "1" ]]; then SIGN_IDENTITY="$IDENTITIES"; else SIGN_IDENTITY="-"; fi
fi
# Unsigned/ad-hoc source builds have no Team ID; enable Hardened Runtime only
# for real Developer ID distributions so development can load its own framework.
SIGN_OPTIONS=(--timestamp=none)
[[ "$SIGN_IDENTITY" == "-" ]] || SIGN_OPTIONS=(--options runtime)
# Sign nested code inside-out. Preserve the upstream XPC entitlements rather
# than granting Contacts/Mail privileges to the updater's downloader/installer.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for NESTED in "$FRAMEWORK/XPCServices/Downloader.xpc" "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app"; do
  codesign --force "${SIGN_OPTIONS[@]}" --preserve-metadata=identifier,entitlements --sign "$SIGN_IDENTITY" "$NESTED"
done
codesign --force "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${SIGN_OPTIONS[@]}" --entitlements "$ROOT/Resources/Emblem.entitlements" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
echo "APP=$APP"
echo "LINKED_SDK=$LINKED_SDK MINIMUM_OS=14.0"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "SIGNING=ad-hoc NOTARIZED=no"
else
  echo "SIGNING=$SIGN_IDENTITY NOTARIZED=no"
fi
