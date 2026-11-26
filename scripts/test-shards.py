#!/usr/bin/env python3
"""Run the full Swift test suite as class shards in parallel xctest processes.

WHY: .project-docs/decisions/2026-11-26-builder-test-shards.md
The builder's full-suite step. SwiftPM serialises two `swift test` runs in one
package and `--parallel` starts one process per test (slower), so the built
bundle runs as `xcrun xctest -XCTest <classes>` in N processes at once. Classes
are split deterministically (committed class times, greedy, ties by name; an
unknown class weighs the median) and the split is checked against
`swift test --list-tests` before anything runs, so a new class is never lost.
Every run (each shard, the serial fallback, each rerun) is judged by one
function, `account`: the named final XCTest summary ("All tests" or "Selected
tests", with or without a skipped count), every expected test identity with
exactly one terminal result, the summary consistent with those results and
the process exit consistent with the failures. Any problem of the sharding
itself (no list, no bundle, a shard that does not account for its tests)
falls back to the serial `swift test`, which must account for the whole
listed suite (or at least one test without a list). A failing test is rerun
alone; the rerun counts only when that exact test ran alone and passed.

Exit 0: every test passed the first time. 1: a test failed (also after its
rerun). 2: the suite could not run or did not account for itself (an exit
without a failing test, missing tests, no summary). 3: no real failure, but
`failed_then_passed_alone` is not empty: the builder decides by the workflow
rule (an isolated pass waives a failure only when the test file and the code
under test are unchanged); the runner never waives it. The summary JSON is the
last line. Only Python's standard library is required.
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
FINAL_SUITE = re.compile(r"Test Suite '(All tests|Selected tests)' (passed|failed) at ")
SUMMARY = re.compile(r"^\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?"
                     r"(\d+) failures? \((\d+) unexpected\)")
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
    """What an XCTest log says: each test's terminal results, the named final summary
    (the last "All tests"/"Selected tests" suite, never a class or bundle total) and
    the tests skipped for protected data."""
    text = Path(log).read_text(errors="replace")
    results, protected, final = {}, set(), None
    lines = text.splitlines()
    for index, line in enumerate(lines):
        case = CASE.search(line)
        if case:
            results.setdefault(f"{case[1]}.{case[2]}/{case[3]}", []).append(case[4])
        if PROTECTED in line:
            match = re.search(r"-\[(\w+)\.(\w+) (\w+)\]", line)
            if match:
                protected.add(f"{match[1]}.{match[2]}/{match[3]}")
        suite = FINAL_SUITE.search(line)
        if suite:
            summary = next((SUMMARY.match(after) for after in lines[index + 1:index + 3]
                            if SUMMARY.match(after)), None)
            final = None if summary is None else {
                "outcome": suite[2], "executed": int(summary[1]),
                "skipped": int(summary[2] or 0), "failures": int(summary[3])}
    return {"results": results, "final": final, "protected_skipped": sorted(protected)}


# What `xcrun xctest` and `swift test` exit with: 0 when every test passed, 1 when a
# test failed. A signal (negative status) or any other status is an error of the
# run itself, never an assertion failure, even beside a failed test.
FAILURE_EXIT = 1


def account(log, code, expected=None):
    """The one judgement of a run. `expected`: the exact test identities it must
    run, or None (unknown: at least one test). Returns executed, failed, skipped,
    protected_skipped and `problems` (empty when the run accounts for itself)."""
    parsed = parse(log)
    results, final, problems = parsed["results"], parsed["final"], []
    if final is None:
        problems.append("no final XCTest summary")
    twice = sorted(t for t, r in results.items() if len(r) != 1)
    if twice:
        problems.append("tests with more than one result: " + ", ".join(twice[:5]))
    terminal = {t: r[-1] for t, r in results.items()}
    failed = sorted(t for t, r in terminal.items() if r == "failed")
    skipped = sorted(t for t, r in terminal.items() if r == "skipped")
    if expected is not None:
        missing, extra = sorted(set(expected) - set(terminal)), sorted(set(terminal) - set(expected))
        if missing:
            problems.append(f"{len(missing)} expected tests have no result: "
                            + ", ".join(missing[:5]))
        if extra:
            problems.append(f"{len(extra)} unexpected tests ran: " + ", ".join(extra[:5]))
    if not terminal:
        problems.append("no test ran")
    if final is not None:
        if final["executed"] != len(terminal):
            problems.append(f"the summary says {final['executed']} tests, the log shows "
                            f"{len(terminal)}")
        if final["failures"] != len(failed) and not (final["failures"] > len(failed) > 0):
            # Several failures of one test count once per assertion: only a summary
            # with failures and no failed test, or the reverse, is inconsistent.
            problems.append(f"the summary says {final['failures']} failures, the log shows "
                            f"{len(failed)} failed tests")
        if (final["outcome"] == "failed") != bool(failed or final["failures"]):
            problems.append(f"the final suite {final['outcome']} with {final['failures']} "
                            f"failures and {len(failed)} failed tests")
        if final["skipped"] != len(skipped):
            problems.append(f"the summary says {final['skipped']} skipped, the log shows "
                            f"{len(skipped)}")
    if code not in (0, FAILURE_EXIT):
        problems.append(f"the process ended with status {code}"
                        + (f" (signal {-code})" if code < 0 else "") + ", not a test result")
    elif code == FAILURE_EXIT and not failed:
        problems.append(f"the process exited {code} without a failed test")
    elif code == 0 and failed:
        problems.append("the process exited 0 with failed tests")
    return {"executed": len(terminal), "failed": failed, "skipped": len(skipped),
            "protected_skipped": parsed["protected_skipped"], "problems": problems}


def run_shard(index, classes, bundle, work, expected):
    log = work / f"shard-{index + 1}.log"
    log.write_text("")
    started = time.monotonic()
    code = run(["xcrun", "xctest", "-XCTest", ",".join(classes), str(bundle)], log)
    return {"shard": index + 1, "classes": len(classes), "exit": code,
            "seconds": round(time.monotonic() - started, 1), "log": str(log),
            **account(log, code, expected)}


def rerun(test, work):
    """A failed test alone, serially: True only when exactly that test ran alone and
    passed (a filter matching nothing also exits 0)."""
    module_class, name = test.split("/")
    log = work / ("rerun-" + re.sub(r"[^\w.-]", "_", test) + ".log")
    log.write_text("")
    code = run(["swift", "test", "--skip-build", "--filter",
                f"^{re.escape(module_class)}/{re.escape(name)}$"], log)
    result = account(log, code, [test])
    return not result["problems"] and not result["failed"] and result["skipped"] == 0


def serial(work, reason, classes=None):
    """The whole suite in one `swift test`: it must account for every listed test,
    or (without a list) for a nonempty run."""
    log = work / "serial.log"
    log.write_text("")
    started = time.monotonic()
    code = run(["swift", "test", "--skip-build"], log)
    expected = None if classes is None else [
        f"{module_class}/{test}" for module_class, tests in classes.items() for test in tests]
    result = account(log, code, expected)
    return {"mode": "serial", "fallback_reason": reason, "exit": code,
            "seconds": round(time.monotonic() - started, 1), "log": str(log), **result}


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
        # The known inventory always binds the serial run; only a failed discovery
        # leaves the nonempty rule.
        return finish(work, serial(work, reason, classes))
    plan, weights = split(classes, args.shards, load_times(args.times))
    problem = check_split(classes, plan)
    total = sum(len(t) for t in classes.values())
    if args.plan:
        print(json.dumps({"tests": total, "classes": len(classes), "problem": problem,
                          "weights": weights, "shards": plan}))
        return 0 if not problem else 2
    bundle = bundle_path()
    if problem or bundle is None:
        return finish(work, serial(work, problem or "no single .xctest bundle", classes))
    with ThreadPoolExecutor(max_workers=args.shards) as pool:
        shards = list(pool.map(lambda i: run_shard(i, plan[i], bundle, work, [
            f"{c}/{t}" for c in plan[i] for t in classes[c]]), range(args.shards)))
    broken = [f"shard {s['shard']}: " + "; ".join(s["problems"]) for s in shards if s["problems"]]
    if broken:
        # A shard that does not account for its tests is not a verdict on the PR: the
        # serial suite runs, and must account for every listed test itself.
        return finish(work, serial(work, " | ".join(broken), classes))
    summary = {"mode": f"{args.shards} shards", "tests": total, "shards": shards,
               "executed": sum(s["executed"] for s in shards),
               "seconds": max(s["seconds"] for s in shards), "problems": [],
               "failed": sorted({t for s in shards for t in s["failed"]}),
               "protected_skipped": sorted({t for s in shards for t in s["protected_skipped"]})}
    return finish(work, summary)


def finish(work, summary):
    """Rerun each failure alone, then the verdict and the exit code (see the module
    docstring). A run that did not account for itself never passes."""
    first = summary.get("failed", [])
    # A run that did not account for itself is an error of the run: no rerun can
    # turn it into a pass, so none is attempted.
    real = first if summary.get("problems") else [t for t in first if not rerun(t, work)]
    summary["failed_then_passed_alone"] = [t for t in first if t not in real]
    summary["failed"] = real
    summary["passed"] = not summary.get("problems") and not real
    # Never waived here: the builder applies the workflow rule (exit 3).
    summary["waiver_needed"] = bool(summary["passed"] and summary["failed_then_passed_alone"])
    (work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    if summary.get("problems"):
        return 2
    if real:
        return 1
    return 3 if summary["failed_then_passed_alone"] else 0


if __name__ == "__main__":
    sys.exit(main())
