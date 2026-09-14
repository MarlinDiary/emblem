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
ICON_SOURCE="$ROOT/Resources/AppIcon.icon"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
[[ "$SDK_MAJOR" -ge 26 ]] || { echo 'Icon compilation requires Xcode 26 or later.' >&2; exit 2; }
if [[ "$SDK_MAJOR" == "26" ]]; then
  # Xcode 26 accepts native Icon Composer documents, but not the 27-only
  # refractivity feature. Keep the exact vector geometry and standard glass
  # material in a temporary document; never flatten or alter the source icon.
  python3 - "$ICON_SOURCE" "$SCRATCH/Source/AppIcon.icon" <<'PY'
import json, shutil, sys
from pathlib import Path
source, compatible = map(Path, sys.argv[1:])
shutil.copytree(source, compatible)
path = compatible / 'icon.json'
definition = json.loads(path.read_text())
features = [f for f in definition.get('features', []) if f != 'refractivity']
if features: definition['features'] = features
else: definition.pop('features', None)
for group in definition['groups']:
    group.pop('refractivity', None)
path.write_text(json.dumps(definition))
PY
  ICON_SOURCE="$SCRATCH/Source/AppIcon.icon"
  echo 'ICON_MATERIAL=SYSTEM_GLASS COMPILER_GENERATION=26 REFRACTIVITY_27=OMITTED'
fi
# Absolute paths avoid the shared asset-tool daemon resolving paths against a
# previous invocation's working directory. The native compiler owns all glass
# rendering and automatically supplies the pre-Liquid-Glass .icns fallback.
xcrun actool "$ICON_SOURCE" \
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
