"""Exercise real HFS+ metadata and compressed remounts, without Finder/app launch."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("dmg_layout", ROOT / "scripts/dmg-layout.py")
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


@unittest.skipUnless(sys.platform == "darwin", "HFS+ images require macOS")
class DMGLayoutTests(unittest.TestCase):
    @classmethod
    def command(cls, *args):
        return subprocess.run(args, check=True, capture_output=True, text=True).stdout

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="whytap-layout-test-")
        cls.work = Path(cls.temp.name)
        cls.volume = cls.work / "writable"
        cls.volume.mkdir()
        cls.image = cls.work / "layout-rw.dmg"
        cls.source = ROOT / "Resources/dmg-background.png"
        staging = cls.work / "staging"
        (staging / ".background").mkdir(parents=True)
        (staging / "Whytap.app").mkdir()
        (staging / "Applications").symlink_to("/Applications")
        shutil.copyfile(cls.source, staging / layout.BACKGROUND)
        cls.command("hdiutil", "create", "-srcfolder", str(staging), "-volname",
                    "Whytap Layout Test", "-fs", "HFS+", "-format", "UDRW", str(cls.image))
        cls.attach()

    @classmethod
    def attach(cls):
        cls.command("hdiutil", "attach", "-nobrowse", "-noautoopen", "-mountpoint",
                    str(cls.volume), str(cls.image))

    @classmethod
    def tearDownClass(cls):
        try:
            cls.command("hdiutil", "detach", str(cls.volume))
        finally:
            cls.temp.cleanup()

    def setUp(self):
        shutil.copyfile(self.source, self.volume / layout.BACKGROUND)
        layout.write_layout(self.volume, "Whytap.app", self.source)

    def test_compressed_remount_at_another_path(self):
        # Real conversion/remount proves the alias uses this HFS+ file's ID,
        # not an inaccessible path in the builder's temporary directory.
        self.command("hdiutil", "detach", str(self.volume))
        try:
            final = self.work / "layout-final.dmg"
            self.command("hdiutil", "convert", str(self.image), "-format", "UDZO",
                         "-o", str(final))
            other_mount = self.work / "another-mac-mount"
            other_mount.mkdir()
            self.command("hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen",
                         "-mountpoint", str(other_mount), str(final))
            try:
                layout.verify_layout(other_mount, "Whytap.app", self.source)
            finally:
                self.command("hdiutil", "detach", str(other_mount))
        finally:
            self.attach()

    def test_beta_bundle_name(self):
        (self.volume / "Whytap-Beta.app").mkdir(exist_ok=True)
        layout.write_layout(self.volume, "Whytap-Beta.app", self.source)
        layout.verify_layout(self.volume, "Whytap-Beta.app", self.source)

    def test_missing_store_rejected(self):
        (self.volume / ".DS_Store").unlink()
        with self.assertRaisesRegex(ValueError, "layout.*missing"):
            layout.verify_layout(self.volume, "Whytap.app", self.source)

    def test_corrupt_store_rejected_by_cli(self):
        (self.volume / ".DS_Store").write_bytes(b"broken")
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts/dmg-layout.py"), "verify",
            "--volume", str(self.volume), "--app-name", "Whytap.app",
            "--background-source", str(self.source),
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: DMG layout", result.stderr)

    def test_missing_and_altered_background_rejected(self):
        background = self.volume / layout.BACKGROUND
        background.write_bytes(b"different image")
        with self.assertRaisesRegex(ValueError, "differs"):
            layout.verify_layout(self.volume, "Whytap.app", self.source)
        background.unlink()
        with self.assertRaisesRegex(ValueError, "background is missing"):
            layout.verify_layout(self.volume, "Whytap.app", self.source)

    def test_default_view_and_icon_positions_rejected_if_changed(self):
        for name, key, value in [
            (".", "icvl", ("type", b"Nlsv")),
            ("Whytap.app", "Iloc", (10, 10)),
            ("Applications", "Iloc", (20, 20)),
        ]:
            with self.subTest(key=key, name=name):
                layout.write_layout(self.volume, "Whytap.app", self.source)
                with layout.DSStore.open(str(self.volume / ".DS_Store"), "r+") as store:
                    store[name][key] = value
                with self.assertRaises(ValueError):
                    layout.verify_layout(self.volume, "Whytap.app", self.source)

    def test_window_and_background_reference_rejected_if_changed(self):
        for key, change in [
            ("bwsp", {"WindowBounds": "{{0, 0}, {1800, 900}}"}),
            ("icvp", {"backgroundType": 0}),
            ("icvp", {"backgroundImageAlias": b"broken alias"}),
        ]:
            with self.subTest(change=change):
                layout.write_layout(self.volume, "Whytap.app", self.source)
                with layout.DSStore.open(str(self.volume / ".DS_Store"), "r+") as store:
                    value = store["."][key]
                    value.update(change)
                    store["."][key] = value
                with self.assertRaises(Exception):
                    layout.verify_layout(self.volume, "Whytap.app", self.source)

    def test_alias_to_another_file_rejected(self):
        other = self.volume / "other.png"
        shutil.copyfile(self.source, other)
        with layout.DSStore.open(str(self.volume / ".DS_Store"), "r+") as store:
            icons = store["."]["icvp"]
            icons["backgroundImageAlias"] = layout.Alias.for_file(str(other.resolve())).to_bytes()
            store["."]["icvp"] = icons
        with self.assertRaisesRegex(ValueError, "alias"):
            layout.verify_layout(self.volume, "Whytap.app", self.source)


if __name__ == "__main__":
    unittest.main()
