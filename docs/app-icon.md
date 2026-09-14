# Native layered app icon

`Resources/AppIcon.icon` is an editable Apple Icon Composer document, not a
flattened glass-effect image. It keeps Emblem's blue background with **one
foreground layer**: the portrait and circular ring combined in `Assets/Emblem.svg`.
There is no glass disk behind the portrait. The circular interior is a genuine
cutout that reveals the system-rendered blue background.

The single compound vector path joins the shoulders into the ring without
stacked edges or duplicate shadows. Its head, cutout and outer circle share one
material group and one image layer. Blur is disabled so the silhouette remains
crisp. The artwork has no baked shadows, highlights, enclosure mask, raster
scaling or gradients; Icon Composer and the system supply those effects.

`Scripts/build-app.sh` calls `Scripts/build-icon.sh` before code signing. Apple's
`actool` emits `Assets.car`, a compatible `AppIcon.icns`, and icon metadata. The
helper merges only the generated `CFBundleIconName` and `CFBundleIconFile` keys
and removes its temporary compiler output. Existing root catalogs are rejected
instead of overwritten. An icon compile failure fails the build; it never
silently switches back to the old flat icon.

The deployment target stays macOS 14. Older systems use the compiler-generated
fallback; supported systems render the layered appearance. The refractivity
annotations were authored with Icon Composer 27 and verified with Xcode 27.
Xcode 26 builds the same vector foreground and standard native glass material
using a temporary document with only the 27-specific refractivity annotations
removed. It does not rasterize the icon or modify its editable source. Older OS
appearance behavior remains a runtime check. The Icon Composer
companion `ictool` was used to export and visually review Default, Dark and Mono
at 1024px with design generations 26 and 27. These are native material renders,
not image-editor approximations; the installed app was not replaced for review.

Use Icon Composer's companion tool (not the different developer `ictool` shim):

```sh
XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
ICTOOL="$XCODE_APP/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" "$PWD/Resources/AppIcon.icon" --export-image \
  --output-file "$PWD/icon-default.png" --platform macOS --rendition Default \
  --width 1024 --height 1024 --scale 1 --design-generation 26
```

Repeat with `Dark` or `Mono` for their previews. Generation 27 can also be
exported with this toolchain; rendering on an older macOS remains a runtime gate.

Run the resource and real compiler regressions with:

```sh
python3 -m unittest discover -s Tests/Operations -p test_app_icon.py -v
```

This resource change is build 54. The initial resource-only previews left the
installed build 53 unchanged. Signed distribution and installation have their
own verification record: preserve the previous bundle and its observation
cohort before replacement, and keep the new build's observations separate.
Neither icon previews nor bounded runtime checks establish 72-hour acceptance
or permit promoting a stable update feed while other release gates remain open.

References: [Icon Composer](https://developer.apple.com/icon-composer/) and
[Creating your app icon](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
