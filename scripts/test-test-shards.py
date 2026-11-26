#!/usr/bin/env python3
"""Exercise scripts/test-shards.py with fake `swift` and `xcrun` in disposable folders."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().with_name("test-shards.py")

LOG = r'''
def xctest_log(top, ran, failing, protected, extra_failures=0):
    lines = [f"Test Suite '{top}' started at 2026-11-26 10:00:00.000."]
    by_class = {}
    for name in ran:
        by_class.setdefault(name.split("/")[0], []).append(name)
    skipped_total = 0
    for module_class, names in by_class.items():
        lines.append(f"Test Suite '{module_class}' started at 2026-11-26 10:00:00.000.")
        bad = skipped = 0
        for name in names:
            test = name.split("/")[1]
            lines.append(f"Test Case '-[{module_class} {test}]' started.")
            if name in failing:
                lines.append(f"/x.swift:1: error: -[{module_class} {test}] : XCTAssertTrue failed")
                lines.append(f"Test Case '-[{module_class} {test}]' failed (0.010 seconds).")
                bad += 1
            elif protected and test == "test_protected":
                lines.append(f"/x.swift:1: -[{module_class} {test}] : Test skipped - Protected data is unavailable: the screen is locked")
                lines.append(f"Test Case '-[{module_class} {test}]' skipped (0.001 seconds).")
                skipped += 1
            else:
                lines.append(f"Test Case '-[{module_class} {test}]' passed (0.010 seconds).")
        skipped_total += skipped
        state = "failed" if bad else "passed"
        lines.append(f"Test Suite '{module_class}' {state} at 2026-11-26 10:00:01.000.")
        lines.append(summary(len(names), skipped, bad))
    bad_total = sum(1 for n in ran if n in failing) + extra_failures
    state = "failed" if bad_total else "passed"
    lines.append(f"Test Suite '{top}' {state} at 2026-11-26 10:00:02.000.")
    lines.append(summary(len(ran), skipped_total, bad_total))
    return "\n".join(lines)

def summary(executed, skipped, failures):
    tests = "test" if executed == 1 else "tests"
    skip = "" if not skipped else f"{skipped} {'test' if skipped == 1 else 'tests'} skipped and "
    fail = "failure" if failures == 1 else "failures"
    return (f"\t Executed {executed} {tests}, with {skip}{failures} {fail} ({failures} unexpected) "
            f"in 1.000 (1.001) seconds")
'''

FAKE_SWIFT = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
''' + LOG + r'''
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
failing = (control / "fail-always.txt").read_text().split() \
    if (control / "fail-always.txt").exists() else []
if "--filter" in args:
    pattern = args[args.index("--filter") + 1]
    name = re.sub(r"\\(.)", r"\1", pattern.strip("^$"))
    if (control / "rerun-matches-nothing").exists():
        print("warning: No matching test cases were run")
        sys.exit(0)
    print(xctest_log("Selected tests", [name], failing, False))
    sys.exit(1 if name in failing else 0)
# serial `swift test --skip-build`
if (control / "serial-empty").exists():
    print(xctest_log("All tests", [], [], False))
    sys.exit(0)
if (control / "serial-class-total-only").exists():
    print(xctest_log("Mod.Big", [t for t in tests if t.startswith("Mod.Big/")], [], False))
    sys.exit(0)
if (control / "serial-fail-once.txt").exists():
    failing += (control / "serial-fail-once.txt").read_text().split()
print(xctest_log("All tests", tests, failing, (control / "protected").exists()))
sys.exit(1 if failing or (control / "guard-fails").exists() else 0)
'''

FAKE_XCRUN = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
''' + LOG + r'''
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
print(xctest_log("Selected tests", ran, failing, (control / "protected").exists()))
bad = [t for t in ran if t in failing]
sys.exit(1 if bad or (control / "guard-fails").exists() else 0)
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

    def test_a_failure_that_passes_alone_is_left_to_the_builder(self):
        (self.control / "fail-once.txt").write_text("Mod.Small/test_c")
        summary = self.shards(code=3)  # never exit 0: the workflow rule decides
        self.assertEqual((summary["passed"], summary["failed"],
                          summary["failed_then_passed_alone"], summary["waiver_needed"]),
                         (True, [], ["Mod.Small/test_c"], True))
        self.assertIn("test --skip-build --filter ^Mod\\.Small/test_c$", self.calls())

    def test_a_failure_that_fails_alone_again_is_a_finding(self):
        (self.control / "fail-always.txt").write_text("Kit.Tool/test_e")
        summary = self.shards(code=1)
        self.assertEqual((summary["passed"], summary["failed"]), (False, ["Kit.Tool/test_e"]))

    def test_a_crashed_shard_falls_back_to_the_serial_suite(self):
        (self.control / "crash").touch()
        summary = self.shards()
        self.assertEqual((summary["mode"], summary["passed"]), ("serial", True))
        self.assertIn("no final XCTest summary", summary["fallback_reason"])
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

    # Ticket 634: every run is judged by one function, `account`.

    def test_the_final_summary_is_read_in_every_form_xctest_prints(self):
        spec = importlib.util.spec_from_file_location("shards", SCRIPT)
        shards = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(shards)
        names = [f"Mod.C{n // 100}/test_{n}" for n in range(250)]
        log = Path(self.temp.name) / "x.log"
        cases = [  # (top suite, failing, protected, expected executed, skipped, failed)
            ("All tests", [], False, 250, 0, 0),
            ("Selected tests", [], False, 250, 0, 0),
            ("All tests", names[:1], False, 250, 0, 1),
            ("All tests", names[:3], False, 250, 0, 3),
        ]
        for top, failing, protected, executed, skipped, failed in cases:
            with self.subTest(top=top, failing=len(failing)):
                log.write_text(self.log(top, names, failing, protected))
                result = shards.account(log, 1 if failing else 0, names)
                self.assertEqual((result["executed"], result["skipped"], len(result["failed"]),
                                  result["problems"]), (executed, skipped, failed, []))
        # Skipped counts, singular and plural: the case recorded on ticket 634
        # (many class totals, then "with 59 tests skipped").
        for skipped in (1, 59):
            protected = [f"Mod.P{n}/test_protected" for n in range(skipped)]
            with self.subTest(skipped=skipped):
                log.write_text(self.log("All tests", names + protected, [], True))
                result = shards.account(log, 0, names + protected)
                self.assertEqual((result["executed"], result["skipped"], result["problems"],
                                  len(result["protected_skipped"])),
                                 (250 + skipped, skipped, [], skipped))
        # A class total is never the suite total; nothing is not a green run.
        for broken, code in ((self.log("Mod.C0", names[:100], [], False), 0),
                             (self.log("All tests", [], [], False), 0),
                             ("", 0), ("", 1),
                             (self.log("All tests", names[:-1], [], False), 0),
                             (self.log("All tests", names, [], False), 1),
                             (self.log("All tests", names, [], False, extra_failures=1), 1),
                             (self.log("All tests", names, names[:1], False), 0)):
            with self.subTest(broken=broken[-80:], code=code):
                log.write_text(broken)
                self.assertTrue(shards.account(log, code, names)["problems"])

    def log(self, *args, **kwargs):
        namespace = {}
        exec(LOG, namespace)
        return namespace["xctest_log"](*args, **kwargs)

    def test_an_exit_without_a_failed_test_never_passes(self):
        (self.control / "guard-fails").touch()  # an after-suite guard failure
        summary = self.shards(code=2)
        self.assertEqual((summary["mode"], summary["passed"]), ("serial", False))
        self.assertIn("exited 1 without a failed test", summary["fallback_reason"])
        self.assertIn("exited 1 without a failed test", " ".join(summary["problems"]))
        (self.control / "list-fails").touch()  # the serial path alone
        self.assertFalse(self.shards(code=2)["passed"])
        # A serial failure that passes alone is never waived by the runner either.
        (self.control / "guard-fails").unlink()
        (self.control / "serial-fail-once.txt").write_text("Mod.Small/test_c")
        summary = self.shards(code=3)
        self.assertEqual((summary["mode"], summary["failed_then_passed_alone"],
                          summary["waiver_needed"]), ("serial", ["Mod.Small/test_c"], True))

    def test_a_serial_run_must_account_for_the_suite(self):
        for flag in ("serial-empty", "serial-class-total-only"):
            for listed in (True, False):
                with self.subTest(flag=flag, listed=listed):
                    for name in ("serial-empty", "serial-class-total-only", "list-fails"):
                        (self.control / name).unlink(missing_ok=True)
                    (self.control / flag).touch()
                    if not listed:
                        (self.control / "list-fails").touch()
                    (self.control / "crash").touch()  # force the serial path
                    summary = self.shards(code=2)
                    self.assertEqual((summary["mode"], summary["passed"]), ("serial", False))

    def test_a_rerun_counts_only_when_that_test_ran_alone_and_passed(self):
        (self.control / "fail-once.txt").write_text("Mod.Small/test_c")
        (self.control / "rerun-matches-nothing").touch()  # SwiftPM exits 0 on no match
        summary = self.shards(code=1)
        self.assertEqual((summary["passed"], summary["failed"],
                          summary["failed_then_passed_alone"]),
                         (False, ["Mod.Small/test_c"], []))


if __name__ == "__main__":
    unittest.main()
