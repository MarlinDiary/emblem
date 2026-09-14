# Native layered app icon

`Resources/AppIcon.icon` is the approved editable Icon Composer document for
build55, with a warm ivory/gray/sage background and four original vector assets.
There are no colored page tabs, rasterized highlights or baked glass effects.
Front to back: **Head.svg → Lens.svg → Body.svg → Well.svg**.

The head is above the circular glass; the body is below it. Head and body each
contain just one white path, with no portrait background disk. The body's lower
arc and the lens share center(512,512), radius280, so the bottom silhouette meets
the lens edge. The separate recess is behind the body, not part of its artwork.
The gray gradient lens uses Multiply, opacity0.8, refractivity strength0.86 and
depth0.26. Specular is disabled on this group: no bright white upper circular rim.
This is independently drawn artwork, not extracted Contacts app imagery.

`Scripts/build-app.sh` calls `Scripts/build-icon.sh` before signing. Apple's
`actool` emits native `Assets.car` (four vector resources, four material groups
per appearance, five-layer stacks including background) and compatible
`AppIcon.icns`. Only generated icon metadata is merged into Info.plist. Existing
root catalogs are rejected and compile errors stop packaging without altering
existing resources.

The deployment target remains macOS14. Xcode27 compiles the complete source.
Xcode26 uses a temporary document stripped only of 27-specific refractivity
annotations: all four vectors, ordering, standard materials and geometry remain
unchanged. No flattening or editable-source modification is involved. Older OS
appearance behavior still has a separate runtime check.

Native Icon Composer exports reviewed include Default, Dark and Mono at1024px,
Default at64px, and design generations26 and27. The generation27 upper lens arc
regression used12420 identical pixels: the rejected white-lid draft had3031
near-white pixels; the approved gray lens has0. This bounded test is about the
upper circular rim, not all highlights on the outer app enclosure.

```sh
XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
ICTOOL="$XCODE_APP/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" "$PWD/Resources/AppIcon.icon" --export-image \
  --output-file "$PWD/icon-default.png" --platform macOS --rendition Default \
  --width 1024 --height 1024 --scale 1 --design-generation 27
python3 -m unittest discover -s Tests/Operations -p test_app_icon.py -v
```

Repeat with Dark or Mono for their previews. Website SVG reuses these same four
vectors as a flat brand rendition; native glass remains system-rendered.

RC5 is a preview, not stable promotion. Preserve signed build54 and its complete
observation cohort before installation. Build55 observations are separate; icon
previews, fixture checks and older mail latency samples do not establish its
natural72-hour acceptance or complete Google review/clean-Mac onboarding.

References: [Icon Composer](https://developer.apple.com/icon-composer/) and
[Creating your app icon](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
