import json
import os
import plistlib
import tempfile
import subprocess
import shutil
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class LayeredAppIconTests(unittest.TestCase):
    def test_26_compatibility_keeps_native_geometry_without_27_annotations(self):
        with tempfile.TemporaryDirectory(prefix="emblem 26 icon ") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            wrapper = root / "bin/xcrun"
            wrapper.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
if sys.argv[1:] == ["--sdk", "macosx", "--show-sdk-version"]:
    print("26.6")
    sys.exit(0)
if len(sys.argv)>2 and sys.argv[1]=="actool":
    source=Path(sys.argv[2])
    definition=json.loads((source/"icon.json").read_text())
    assert "refractivity" not in definition.get("features", [])
    assert len(definition["groups"])==4
    assert all("refractivity" not in g for g in definition["groups"])
    assert definition["groups"][0]["layers"][0]["image-name"]=="Head.svg"
    Path(os.environ["ICON_COMPAT_CAPTURE"]).write_text(json.dumps({p.name:p.read_text() for p in (source/"Assets").iterdir()},sort_keys=True))
os.execv("/usr/bin/xcrun", ["xcrun"]+sys.argv[1:])
''')
            wrapper.chmod(0o700)
            app = root / "Emblem.app"
            (app / "Contents/Resources").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "55"}))
            capture = root / "captured.json"
            environment = dict(os.environ, PATH=str(root / "bin")+os.pathsep+os.environ["PATH"], ICON_COMPAT_CAPTURE=str(capture))
            result = subprocess.run(["bash", str(ROOT / "Scripts/build-icon.sh"), str(app)], capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("COMPILER_GENERATION=26", result.stdout)
            self.assertEqual(json.loads(capture.read_text()), {p.name:p.read_text() for p in (ROOT / "Resources/AppIcon.icon/Assets").iterdir()})
            self.assertTrue((app / "Contents/Resources/Assets.car").is_file())

    def test_approved_portrait_layering_and_quiet_gray_lens(self):
        icon = ROOT / "Resources/AppIcon.icon"
        definition = json.loads((icon / "icon.json").read_text())
        self.assertIn("refractivity", definition["features"])
        self.assertEqual(definition["fill"]["automatic-gradient"], "extended-srgb:0.79000,0.80500,0.73000,1.00000")
        groups = definition["groups"]
        self.assertEqual([g["layers"][0]["image-name"] for g in groups], ["Head.svg", "Lens.svg", "Body.svg", "Well.svg"])
        self.assertTrue(all(len(g["layers"]) == 1 for g in groups))
        self.assertEqual({p.name for p in (icon / "Assets").iterdir()}, {"Head.svg", "Lens.svg", "Body.svg", "Well.svg"})
        lens = groups[1]
        self.assertEqual(lens["blend-mode"], "multiply")
        self.assertIs(lens["specular"], False)
        self.assertEqual(lens["refractivity"], {"enabled": True, "strength": 0.86, "depth": 0.26})
        self.assertEqual(lens["layers"][0]["opacity"], 0.8)
        for index, asset in [(0, "Head.svg"), (2, "Body.svg")]:
            self.assertIs(groups[index]["layers"][0]["glass"], False)
            svg = ET.parse(icon / "Assets" / asset).getroot()
            self.assertEqual(svg.attrib["viewBox"], "0 0 1024 1024")
            self.assertEqual(len(list(svg)), 1)
            self.assertTrue(list(svg)[0].tag.endswith("path"))
            self.assertEqual(list(svg)[0].attrib["fill"], "#fff")
            self.assertFalse(any(e.tag.endswith(("circle", "rect", "image", "clipPath")) for e in svg.iter()))
        body = list(ET.parse(icon / "Assets/Body.svg").getroot())[0].attrib["d"]
        self.assertIn("A280 280 0 0 1 292 685.2050807569Z", body)
        # The shoulder endpoints and the lower silhouette share the glass circle.
        import math
        self.assertAlmostEqual(math.hypot(292-512, 685.2050807569-512), 280, places=8)
        for asset in ["Lens.svg", "Well.svg"]:
            circle = ET.parse(icon / "Assets" / asset).getroot().find("{http://www.w3.org/2000/svg}circle")
            self.assertEqual((circle.attrib["cx"], circle.attrib["cy"], circle.attrib["r"]), ("512", "512", "280"))
        self.assertIn('stop-color="#B9B8A8"', (icon / "Assets/Lens.svg").read_text())
        self.assertIn('stop-color="#FFFFFA"', (icon / "Assets/Lens.svg").read_text())

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
            self.assertEqual(sum(e.get("AssetType") == "IconGroup" for e in entries), 12)
            self.assertEqual(sum(e.get("AssetType") == "Vector" for e in entries), 4)
            stacks = [e for e in entries if e.get("AssetType") == "IconImageStack"]
            self.assertEqual(len(stacks), 3)
            self.assertTrue(all(e["LayerCount"] == 5 for e in stacks))
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True)
            if int(sdk.split(".")[0]) >= 27:
                layers = stacks[0]["Layers"]
                lenses = [layer for layer in layers if layer.get("LayerBlendMode") == "Multiply"]
                self.assertEqual(len(lenses), 3)
                for lens in lenses:
                    self.assertAlmostEqual(lens["LayerRefractionHeight"], 0.26, places=6)
                    self.assertAlmostEqual(lens["LayerRefractionStrength"], 0.86, places=6)
                    self.assertFalse(lens.get("LayerHasSpecular", False))


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
