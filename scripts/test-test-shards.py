#!/usr/bin/env python3
"""Exercise scripts/test-shards.py with fake `swift` and `xcrun` in disposable folders."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().with_name("test-shards.py")

FAKE_SWIFT = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
control = Path(os.environ["FAKE_CONTROL"])
tests = json.loads((control / "tests.json").read_text())
args = sys.argv[1:]
with open(control / "calls.log", "a") as log:
    log.write(" ".join(args) + "\n")
if args[:2] == ["build", "--build-tests"]:
    sys.exit(0)
if args[:2] == ["build", "--show-bin-path"]:
    print(control / "bin")
    sys.exit(0)
if "--list-tests" in args:
    if (control / "list-fails").exists():
        sys.exit(1)
    for name in tests:
        print(name)
    sys.exit(0)
if "--filter" in args:
    pattern = args[args.index("--filter") + 1]
    name = re.sub(r"\\(.)", r"\1", pattern.strip("^$"))
    still = (control / "fail-always.txt")
    failing = still.read_text().split() if still.exists() else []
    sys.exit(1 if name in failing else 0)
# serial `swift test --skip-build`
failing = (control / "fail-always.txt").read_text().split() \
    if (control / "fail-always.txt").exists() else []
for name in tests:
    module_class, test = name.split("/")
    state = "failed" if name in failing else "passed"
    print(f"Test Case '-[{module_class} {test}]' {state} (0.010 seconds).")
print(f"\t Executed {len(tests)} tests, with {len(failing)} failures (0 unexpected) in 1.0 (1.0) seconds")
sys.exit(1 if failing else 0)
'''

FAKE_XCRUN = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
control = Path(os.environ["FAKE_CONTROL"])
tests = json.loads((control / "tests.json").read_text())
args = sys.argv[1:]
assert args[0] == "xctest" and args[1] == "-XCTest", args
classes = set(args[2].split(","))
with open(control / "shards.log", "a") as log:
    log.write(args[2] + "\n")
if (control / "crash").exists() and "Mod.Big" in classes:
    print("Test Case '-[Mod.Big test_a]' started.")
    sys.exit(134)
failing = []
for name in ("fail-once.txt", "fail-always.txt"):
    if (control / name).exists():
        failing += (control / name).read_text().split()
ran = [t for t in tests if t.split("/")[0] in classes]
for name in ran:
    module_class, test = name.split("/")
    if name in failing:
        print(f"Test Case '-[{module_class} {test}]' failed (0.010 seconds).")
    elif (control / "protected").exists() and test == "test_protected":
        print(f"/x.swift:1: -[{module_class} {test}] : Test skipped - Protected data is unavailable: the screen is locked")
        print(f"Test Case '-[{module_class} {test}]' skipped (0.001 seconds).")
    else:
        print(f"Test Case '-[{module_class} {test}]' passed (0.010 seconds).")
bad = [t for t in ran if t in failing]
print(f"\t Executed {len(ran)} tests, with {len(bad)} failures (0 unexpected) in 1.0 (1.0) seconds")
sys.exit(1 if bad else 0)
'''

TESTS = ["Mod.Big/test_a", "Mod.Big/test_b", "Mod.Small/test_c", "Mod.Other/test_d",
         "Mod.Other/test_protected", "Kit.Tool/test_e"]


class ShardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.control = base / "control"
        (self.control / "bin" / "WhytapPackageTests.xctest").mkdir(parents=True)
        tools = base / "tools"
        tools.mkdir()
        for name, body in (("swift", FAKE_SWIFT), ("xcrun", FAKE_XCRUN)):
            (tools / name).write_text(body)
            (tools / name).chmod(0o755)
        self.times = base / "times.json"
        self.times.write_text(json.dumps({"Mod.Big": 30, "Mod.Small": 1, "Mod.Other": 10,
                                          "Kit.Tool": 5}))
        self.set_tests(TESTS)
        self.out = base / "out"
        self.env = {**os.environ, "FAKE_CONTROL": str(self.control),
                    "PATH": f"{tools}:{os.environ['PATH']}"}

    def set_tests(self, tests):
        (self.control / "tests.json").write_text(json.dumps(tests))

    def shards(self, *extra, code=0):
        result = subprocess.run([sys.executable, str(SCRIPT), "--out", str(self.out),
                                 "--times", str(self.times), *extra], env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def calls(self):
        path = self.control / "calls.log"
        return path.read_text().splitlines() if path.exists() else []

    def test_two_shards_cover_every_listed_test_and_pass(self):
        summary = self.shards()
        self.assertEqual((summary["mode"], summary["tests"], summary["passed"]),
                         ("2 shards", 6, True))
        self.assertEqual(sum(s["executed"] for s in summary["shards"]), 6)
        ran = (self.control / "shards.log").read_text().split()
        self.assertEqual(sorted(c for line in ran for c in line.split(",")),
                         ["Kit.Tool", "Mod.Big", "Mod.Other", "Mod.Small"])
        self.assertTrue((self.out / "summary.json").exists())

    def test_the_split_is_deterministic_and_a_new_class_is_not_lost(self):
        first = self.shards("--plan")
        self.assertEqual(first, self.shards("--plan"))
        self.assertEqual(first["shards"], [["Mod.Big"], ["Kit.Tool", "Mod.Other", "Mod.Small"]])
        self.set_tests(TESTS + ["New.Feature/test_new"])  # no time recorded yet
        plan = self.shards("--plan")
        self.assertIn("New.Feature", [c for shard in plan["shards"] for c in shard])
        self.assertEqual((plan["tests"], plan["problem"]), (7, None))

    def test_a_failure_that_passes_alone_is_a_flake_not_a_finding(self):
        (self.control / "fail-once.txt").write_text("Mod.Small/test_c")
        summary = self.shards()
        self.assertEqual((summary["passed"], summary["failed"],
                          summary["failed_then_passed_alone"]),
                         (True, [], ["Mod.Small/test_c"]))
        self.assertIn("test --skip-build --filter ^Mod\\.Small/test_c$", self.calls())

    def test_a_failure_that_fails_alone_again_is_a_finding(self):
        (self.control / "fail-always.txt").write_text("Kit.Tool/test_e")
        summary = self.shards(code=1)
        self.assertEqual((summary["passed"], summary["failed"]), (False, ["Kit.Tool/test_e"]))

    def test_a_crashed_shard_falls_back_to_the_serial_suite(self):
        (self.control / "crash").touch()
        summary = self.shards()
        self.assertEqual(summary["mode"], "serial")
        self.assertIn("executed", summary["fallback_reason"])
        self.assertIn("test --skip-build", self.calls())

    def test_no_test_list_falls_back_to_the_serial_suite(self):
        (self.control / "list-fails").touch()
        summary = self.shards()
        self.assertEqual((summary["mode"], summary["passed"]), ("serial", True))
        self.assertEqual(summary["fallback_reason"], "swift test --list-tests failed")

    def test_protected_data_skips_are_reported_for_the_run_after_unlock(self):
        (self.control / "protected").touch()
        summary = self.shards()
        self.assertEqual(summary["protected_skipped"], ["Mod.Other/test_protected"])

    def test_a_serial_fallback_failure_is_rerun_alone_too(self):
        (self.control / "list-fails").touch()
        (self.control / "fail-always.txt").write_text("Mod.Big/test_b")
        summary = self.shards(code=1)
        self.assertEqual((summary["mode"], summary["failed"]), ("serial", ["Mod.Big/test_b"]))


if __name__ == "__main__":
    unittest.main()
