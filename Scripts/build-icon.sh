#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: build-icon.sh /absolute/path/Emblem.app}"
APP="$(cd "$APP" && pwd)"
INFO="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"
[[ -f "$INFO" && -d "$RESOURCES" ]] || { echo 'App bundle is incomplete.' >&2; exit 2; }
# This app has no other root asset catalog. Never destroy an unrelated catalog
# when this helper is invoked on a different bundle or invoked twice.
[[ ! -e "$RESOURCES/Assets.car" ]] || { echo 'Assets.car already exists; leaving the bundle unchanged.' >&2; exit 2; }
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# Absolute paths avoid the shared asset-tool daemon resolving paths against a
# previous invocation's working directory. The native compiler owns all glass
# rendering and automatically supplies the pre-Liquid-Glass .icns fallback.
xcrun actool "$ROOT/Resources/AppIcon.icon" \
  --compile "$SCRATCH" --output-format human-readable-text \
  --notices --warnings --errors \
  --output-partial-info-plist "$SCRATCH/partial-info.plist" \
  --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en \
  --target-device mac --minimum-deployment-target 14.0 --platform macosx
python3 - "$SCRATCH" "$INFO" <<'PY'
import plistlib, sys
from pathlib import Path
scratch, info = map(Path, sys.argv[1:])
assert (scratch / 'Assets.car').stat().st_size > 1000
assert (scratch / 'AppIcon.icns').read_bytes()[:4] == b'icns'
generated = plistlib.loads((scratch / 'partial-info.plist').read_bytes())
assert generated['CFBundleIconName'] == 'AppIcon'
assert generated['CFBundleIconFile'] == 'AppIcon'
original = plistlib.loads(info.read_bytes())
original.update({key: generated[key] for key in ('CFBundleIconName', 'CFBundleIconFile')})
(scratch / 'Info.plist').write_bytes(plistlib.dumps(original, sort_keys=False))
PY
cp "$SCRATCH/Assets.car" "$RESOURCES/Assets.car"
cp "$SCRATCH/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$SCRATCH/Info.plist" "$INFO"
echo 'APP_ICON=NATIVE_LAYERED GLASS=SYSTEM_RENDERED LEGACY_ICNS=GENERATED MINIMUM_OS=14.0'
