#!/usr/bin/env python3
"""Run the full Swift test suite as class shards in parallel xctest processes.

WHY: .project-docs/decisions/2026-11-26-builder-test-shards.md
The builder's full-suite step. SwiftPM serialises two `swift test` runs in one
package and `--parallel` starts one process per test (slower), so the built
bundle runs as `xcrun xctest -XCTest <classes>` in N processes at once. Classes
are split deterministically (committed class times, greedy, ties by name; an
unknown class weighs the median) and the split is checked against
`swift test --list-tests` before anything runs, so a new class is never lost.
A failing test is rerun alone, serially, before it counts. Any problem of the
sharding itself (no list, no bundle, a crashed shard, a count mismatch) falls
back to the serial `swift test`. Exit 0: all passed; 1: a test failed (also
after its rerun); 2: the suite could not run. The summary JSON is the last line.
Only Python's standard library is required.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

TIMES = Path(__file__).resolve().with_name("test-shard-times.json")
LISTED = re.compile(r"^(\w+)\.(\w+)/(\w+)$")
CASE = re.compile(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed|skipped)")
EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")
PROTECTED = "Protected data is unavailable"


def run(command, log, timeout=None):
    with open(log, "a") as output:
        output.write("$ " + " ".join(command) + "\n")
        output.flush()
        return subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                              timeout=timeout).returncode


def listed_tests(work):
    """{"Module.Class": [test, ...]} from `swift test --list-tests`, or None."""
    log = work / "list.log"
    result = subprocess.run(["swift", "test", "--skip-build", "--list-tests"],
                            capture_output=True, text=True)
    log.write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        return None
    classes = {}
    for line in result.stdout.splitlines():
        match = LISTED.match(line.strip())
        if match:
            classes.setdefault(f"{match[1]}.{match[2]}", []).append(match[3])
    return classes or None


def bundle_path():
    result = subprocess.run(["swift", "build", "--show-bin-path"], capture_output=True,
                            text=True)
    if result.returncode != 0:
        return None
    bundles = sorted(Path(result.stdout.strip()).glob("*.xctest"))
    return bundles[0] if len(bundles) == 1 else None


def load_times(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return {k: float(v) for k, v in value.items()
            if isinstance(k, str) and isinstance(v, (int, float)) and v >= 0} \
        if isinstance(value, dict) else {}


def split(classes, shards, times):
    """Deterministic greedy split: heaviest class first (ties by name) to the lightest
    shard (ties by index). Returns lists of class names."""
    known = [times[c] for c in classes if c in times]
    default = statistics.median(known) if known else 1.0
    weight = {c: times.get(c, default) for c in classes}
    bins = [[0.0, i, []] for i in range(shards)]
    for name in sorted(classes, key=lambda c: (-weight[c], c)):
        target = min(bins, key=lambda b: (b[0], b[1]))
        target[0] += weight[name]
        target[2].append(name)
    return [sorted(b[2]) for b in bins], [round(b[0], 1) for b in bins]


def check_split(classes, plan):
    """Every listed class in exactly one shard and the shards' test count equal to the
    listed count; otherwise the reason."""
    seen = [c for shard in plan for c in shard]
    if len(seen) != len(set(seen)):
        return "a class is in two shards"
    if set(seen) != set(classes):
        return "the shards do not cover the listed classes"
    if sum(len(classes[c]) for c in seen) != sum(len(t) for t in classes.values()):
        return "the shards' test count differs from swift test --list-tests"
    return None


def parse(log):
    text = Path(log).read_text(errors="replace")
    failed, protected = set(), set()
    for match in CASE.finditer(text):
        if match[4] == "failed":
            failed.add(f"{match[1]}.{match[2]}/{match[3]}")
    for line in text.splitlines():
        if PROTECTED in line:
            match = re.search(r"-\[(\w+)\.(\w+) (\w+)\]", line)
            if match:
                protected.add(f"{match[1]}.{match[2]}/{match[3]}")
    executed = [int(m[1]) for m in EXECUTED.finditer(text)]
    # The last summary line is the whole run's ("All tests" / "Selected tests").
    return {"executed": executed[-1] if executed else None, "failed": sorted(failed),
            "protected_skipped": sorted(protected)}


def run_shard(index, classes, bundle, work):
    log = work / f"shard-{index + 1}.log"
    log.write_text("")
    started = time.monotonic()
    code = run(["xcrun", "xctest", "-XCTest", ",".join(classes), str(bundle)], log)
    return {"shard": index + 1, "classes": len(classes), "exit": code,
            "seconds": round(time.monotonic() - started, 1), "log": str(log), **parse(log)}


def rerun(test, work):
    """A failed test alone, serially: True when it passes."""
    log = work / "reruns.log"
    module_class, name = test.split("/")
    return run(["swift", "test", "--skip-build", "--filter",
                f"^{re.escape(module_class)}/{re.escape(name)}$"], log) == 0


def serial(work, reason):
    log = work / "serial.log"
    log.write_text("")
    started = time.monotonic()
    code = run(["swift", "test", "--skip-build"], log)
    result = parse(log)
    return {"mode": "serial", "fallback_reason": reason, "exit": code,
            "seconds": round(time.monotonic() - started, 1), "log": str(log), **result,
            "passed": code == 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shards", type=int, default=2)
    parser.add_argument("--out", default="build/test-shards", help="logs and summary")
    parser.add_argument("--times", default=str(TIMES), help="class times (JSON)")
    parser.add_argument("--plan", action="store_true", help="print the split, run nothing")
    parser.add_argument("--no-build", action="store_true", help="the tests are built already")
    parser.add_argument("--write-times", metavar="LOG",
                        help="write class times from a full XCTest log to --times and exit")
    args = parser.parse_args()
    work = Path(args.out).resolve()
    work.mkdir(parents=True, exist_ok=True)

    if args.write_times:
        times = {}
        for match in re.finditer(r"Test Case '-\[(\w+)\.(\w+) \w+\]' \w+ \((\d+\.\d+) seconds\)",
                                 Path(args.write_times).read_text(errors="replace")):
            key = f"{match[1]}.{match[2]}"
            times[key] = round(times.get(key, 0.0) + float(match[3]), 3)
        Path(args.times).write_text(json.dumps(dict(sorted(times.items())), indent=1) + "\n")
        print(json.dumps({"classes": len(times), "times": args.times}))
        return 0

    if not args.no_build and not args.plan:
        if run(["swift", "build", "--build-tests"], work / "build.log") != 0:
            print(json.dumps({"mode": "none", "passed": False, "error": "the tests do not build",
                              "log": str(work / "build.log")}))
            return 2
    classes = listed_tests(work)
    if args.shards < 2 or classes is None:
        reason = "one shard requested" if args.shards < 2 else "swift test --list-tests failed"
        if args.plan:
            print(json.dumps({"plan": None, "reason": reason}))
            return 2
        summary = serial(work, reason)
        return finish(work, summary)
    plan, weights = split(classes, args.shards, load_times(args.times))
    problem = check_split(classes, plan)
    total = sum(len(t) for t in classes.values())
    if args.plan:
        print(json.dumps({"tests": total, "classes": len(classes), "problem": problem,
                          "weights": weights, "shards": plan}))
        return 0 if not problem else 2
    bundle = bundle_path()
    if problem or bundle is None:
        return finish(work, serial(work, problem or "no single .xctest bundle"))
    with ThreadPoolExecutor(max_workers=args.shards) as pool:
        shards = list(pool.map(lambda i: run_shard(i, plan[i], bundle, work),
                               range(args.shards)))
    executed = [s["executed"] for s in shards]
    if any(e is None for e in executed) or sum(executed) != total:
        # A crashed or incomplete shard is not a verdict on the PR: run it serially.
        return finish(work, serial(work, f"shards executed {executed} of {total} listed tests"))
    failed = sorted({t for s in shards for t in s["failed"]})
    real = [t for t in failed if not rerun(t, work)]
    summary = {"mode": f"{args.shards} shards", "tests": total, "shards": shards,
               "seconds": max(s["seconds"] for s in shards),
               "failed_then_passed_alone": [t for t in failed if t not in real],
               "failed": real, "protected_skipped": sorted(
                   {t for s in shards for t in s["protected_skipped"]}),
               "passed": not real}
    return finish(work, summary)


def finish(work, summary):
    if summary.get("mode") == "serial" and summary.get("failed"):
        # The serial run already is the baseline; still rerun each failure alone.
        real = [t for t in summary["failed"] if not rerun(t, work)]
        summary["failed_then_passed_alone"] = [t for t in summary["failed"] if t not in real]
        summary["failed"] = real
        summary["passed"] = not real and summary["executed"] is not None
    elif summary.get("mode") == "serial" and summary["exit"] != 0:
        summary["passed"] = False  # a crash or a build failure without a test name
    (work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    if summary.get("passed"):
        return 0
    return 1 if summary.get("failed") else 2


if __name__ == "__main__":
    sys.exit(main())
