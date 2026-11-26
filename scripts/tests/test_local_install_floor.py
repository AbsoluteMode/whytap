"""Every display version build-dmg.sh accepts, against every kind of installed version
(review item 4 on ticket 635): only a move forward replaces the working app."""
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "local-install-floor.py"
spec = importlib.util.spec_from_file_location("floor", SCRIPT)
floor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(floor)


class LocalInstallFloorTests(unittest.TestCase):
    def check(self, installed_version, installed_build, version, build):
        return floor.refusal({"CFBundleShortVersionString": installed_version,
                              "CFBundleVersion": str(installed_build)}, version, build)

    def test_display_versions_follow_semantic_versioning_precedence(self):
        allowed = [("2.2.27", "2.2.27"), ("2.2.27", "2.2.28"), ("2.2.27", "2.3.0"),
                   ("2.2.27", "10.0.0"), ("2.2.27-beta.1", "2.2.27"),
                   ("2.2.27-beta.1", "2.2.27-beta.2"), ("2.2.27-beta.2", "2.2.27-beta.10"),
                   ("2.2.27-1", "2.2.27-alpha"), ("2.2.27-beta", "2.2.27-beta.1"),
                   ("2.2.27-alpha", "2.2.27-beta"), ("2.2.26", "2.2.27-beta.1")]
        refused = [("2.2.27", "2.2.27-beta.1"), ("2.2.27", "2.2.26"), ("2.2.27", "1.9.99"),
                   ("2.2.27-beta.2", "2.2.27-beta.1"), ("2.2.27-beta.10", "2.2.27-beta.2"),
                   ("2.2.27-beta.1", "2.2.27-beta"), ("2.2.27-alpha", "2.2.27-1"),
                   ("2.2.27", "2.2"), ("2.2.27", "2.2.27-"), ("2.2.27", "2.2.27-beta..1"),
                   ("unknown", "2.2.28"), ("", "2.2.28")]
        for installed, candidate in allowed:
            with self.subTest(installed=installed, candidate=candidate):
                self.assertIsNone(self.check(installed, 1770, candidate, 1771))
        for installed, candidate in refused:
            with self.subTest(installed=installed, candidate=candidate):
                self.assertIsNotNone(self.check(installed, 1770, candidate, 1771))

    def test_the_build_number_must_be_higher(self):
        self.assertIn("not higher", self.check("2.2.27", 1770, "2.2.28", 1770))
        self.assertIn("not higher", self.check("2.2.27", 1770, "2.2.28", 1))
        self.assertIsNotNone(self.check("2.2.27", "x", "2.2.28", 1771))

    def test_the_command_line_refuses_with_its_reason(self):
        with tempfile.TemporaryDirectory() as folder:
            plist = Path(folder) / "Info.plist"
            plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "2.2.27",
                                              "CFBundleVersion": "1770"}))
            run = lambda *args: subprocess.run([sys.executable, str(SCRIPT), *args],
                                               capture_output=True, text=True)
            self.assertEqual(run(str(plist), "2.2.27", "1771").returncode, 0)
            refused = run(str(plist), "2.2.27-beta.1", "1771")
            self.assertEqual(refused.returncode, 1)
            self.assertIn("lower than the installed 2.2.27", refused.stderr)
            self.assertEqual(run(str(Path(folder) / "missing.plist"), "2.2.28",
                                 "1771").returncode, 1)
            self.assertEqual(run(str(plist)).returncode, 2)


if __name__ == "__main__":
    unittest.main()
