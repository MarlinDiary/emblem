import json
import plistlib
import tempfile
import subprocess
import shutil
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class LayeredAppIconTests(unittest.TestCase):
    def test_portrait_and_ring_share_one_unbacked_foreground(self):
        icon = ROOT / "Resources/AppIcon.icon"
        definition = json.loads((icon / "icon.json").read_text())
        self.assertIn("refractivity", definition["features"])
        groups = definition["groups"]
        self.assertEqual(len(groups), 1)
        self.assertEqual(len(groups[0]["layers"]), 1)
        self.assertEqual(groups[0]["layers"][0]["image-name"], "Emblem.svg")
        self.assertEqual(groups[0]["blur-material"], 0)
        self.assertTrue(groups[0]["refractivity"]["enabled"])
        self.assertGreater(groups[0]["refractivity"]["depth"], 0)
        self.assertLessEqual(groups[0]["shadow"]["opacity"], 0.3)
        self.assertEqual({p.name for p in (icon / "Assets").iterdir()}, {"Emblem.svg"})
        svg = ET.parse(icon / "Assets/Emblem.svg").getroot()
        self.assertEqual(svg.attrib["viewBox"], "0 0 1024 1024")
        # A single compound outline joins the shoulders into the ring. The
        # interior is an actual cutout, not an opaque/translucent disk layer.
        self.assertEqual(len(list(svg)), 1)
        path = list(svg)[0]
        self.assertTrue(path.tag.endswith("path"))
        self.assertEqual(path.attrib["fill-rule"], "evenodd")
        self.assertEqual(path.attrib["d"].count("M"), 3)
        self.assertFalse(any(e.tag.endswith(("image", "clipPath")) for e in svg.iter()))

    def test_packaging_compiles_the_icon_instead_of_baking_a_png(self):
        script = (ROOT / "Scripts/build-app.sh").read_text()
        self.assertIn('bash "$ROOT/Scripts/build-icon.sh" "$APP"', script)
        self.assertNotIn('swift "$ROOT/Scripts/make-icon.swift"', script)

    def test_real_compiler_emits_native_and_legacy_resources(self):
        with tempfile.TemporaryDirectory(prefix="emblem icon ") as directory:
            app = Path(directory) / "Emblem.app"
            (app / "Contents/Resources").mkdir(parents=True)
            info = app / "Contents/Info.plist"
            baseline = {"CFBundleIdentifier": "org.mailportrait.icon-fixture", "CFBundleVersion": "1"}
            info.write_bytes(plistlib.dumps(baseline))
            result = subprocess.run(["bash", str(ROOT / "Scripts/build-icon.sh"), str(app)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            modified = plistlib.loads(info.read_bytes())
            self.assertEqual(modified["CFBundleIdentifier"], baseline["CFBundleIdentifier"])
            self.assertEqual(modified["CFBundleVersion"], "1")
            self.assertEqual(modified["CFBundleIconName"], "AppIcon")
            self.assertEqual(modified["CFBundleIconFile"], "AppIcon")
            resources = app / "Contents/Resources"
            self.assertGreater((resources / "Assets.car").stat().st_size, 1000)
            self.assertEqual((resources / "AppIcon.icns").read_bytes()[:4], b"icns")
            catalog = subprocess.run(["xcrun", "assetutil", "--info", str(resources / "Assets.car")], capture_output=True, text=True)
            self.assertEqual(catalog.returncode, 0, catalog.stderr)
            entries = json.loads(catalog.stdout)
            self.assertEqual(sum(e.get("AssetType") == "IconGroup" for e in entries), 3)
            self.assertEqual(sum(e.get("AssetType") == "Vector" for e in entries), 1)
            stacks = [e for e in entries if e.get("AssetType") == "IconImageStack"]
            self.assertEqual(len(stacks), 3)
            self.assertTrue(all(e["LayerCount"] == 2 for e in stacks))


    def test_existing_catalog_is_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory(prefix="emblem icon failure ") as directory:
            app = Path(directory) / "Emblem.app"
            (app / "Contents/Resources").mkdir(parents=True)
            info = app / "Contents/Info.plist"
            original = plistlib.dumps({"CFBundleIdentifier": "org.mailportrait.icon-fixture"})
            info.write_bytes(original)
            car = app / "Contents/Resources/Assets.car"
            car.write_bytes(b"existing catalog must stay unchanged")
            result = subprocess.run(["bash", str(ROOT / "Scripts/build-icon.sh"), str(app)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(info.read_bytes(), original)
            self.assertEqual(car.read_bytes(), b"existing catalog must stay unchanged")

    def test_actual_compiler_failure_preserves_info_and_icon(self):
        with tempfile.TemporaryDirectory(prefix="emblem invalid icon ") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            (root / "Resources/AppIcon.icon/Assets").mkdir(parents=True)
            shutil.copy2(ROOT / "Scripts/build-icon.sh", root / "Scripts/build-icon.sh")
            (root / "Resources/AppIcon.icon/icon.json").write_text("{ invalid json")
            app = root / "Emblem.app"
            (app / "Contents/Resources").mkdir(parents=True)
            info = app / "Contents/Info.plist"
            original = plistlib.dumps({"CFBundleIdentifier": "org.mailportrait.icon-fixture"})
            info.write_bytes(original)
            icon = app / "Contents/Resources/AppIcon.icns"
            icon.write_bytes(b"original icon must stay unchanged")
            result = subprocess.run(["bash", str(root / "Scripts/build-icon.sh"), str(app)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("error", (result.stdout + result.stderr).lower())
            self.assertEqual(info.read_bytes(), original)
            self.assertEqual(icon.read_bytes(), b"original icon must stay unchanged")
            self.assertFalse((app / "Contents/Resources/Assets.car").exists())


if __name__ == "__main__":
    unittest.main()
