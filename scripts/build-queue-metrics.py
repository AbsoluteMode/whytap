#!/usr/bin/env python3
"""Measure the build queue over a period, read-only: returns, waits, builder time,
deferred installs, environment waits and authors the builder could not reach.

WHY: .project-docs/decisions/2026-11-23-builder-queue-watchdog.md
The baseline taken before a queue change is compared with the same command after
it. Opens the queue with SQLite `mode=ro` and only reads the watcher log; never
writes anything. Only Python's standard library is required.

    python3 scripts/build-queue-metrics.py --since 2026-11-23 [--until 2026-11-24]
"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sqlite3
import statistics
import subprocess

QUEUE = "exodia-build-queue.sqlite3"
WATCHER_LOG = Path("whytap-build-queue-logs") / "watcher.log"
ENDS = ("done", "blocked", "pending_install", "superseded", "cancelled", "queued")


def parse(stamp):
    value = datetime.fromisoformat(stamp)
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def spread(values):
    values = sorted(values)
    if not values:
        return {"n": 0}
    pick = lambda share: round(values[min(len(values) - 1, int(len(values) * share))], 1)
    return {"n": len(values), "median": round(statistics.median(values), 1),
            "p75": pick(0.75), "p90": pick(0.9), "max": round(values[-1], 1)}


def minutes(start, end):
    return (end - start).total_seconds() / 60


def environment_waits(log_path, since, until):
    """Episodes the watcher logged as `waiting: …` (screen, load) or a deferred install,
    each lasting until the watcher logged anything else."""
    waits = defaultdict(float)
    if not log_path.is_file():
        return {}
    current = None
    for line in log_path.read_text(errors="replace").splitlines():
        match = re.match(r"(\S+) (.*)", line)
        if not match:
            continue
        try:
            at = parse(match.group(1))
        except ValueError:
            continue
        text = match.group(2)
        if current and since <= current[1] < until:
            waits[current[0]] += minutes(current[1], min(at, until))
        current = None
        if text.startswith("waiting: screen locked"):
            current = ("screen locked", at)
        elif text.startswith("waiting: load"):
            current = ("load", at)
        elif text.startswith("deferred install: meeting gate"):
            current = ("meeting gate", at)
    return {kind: round(value) for kind, value in waits.items()}


def measure(root, since, until):
    db = sqlite3.connect((root / QUEUE).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    db.row_factory = sqlite3.Row
    try:
        tickets = {r["id"]: dict(r) for r in db.execute(
            "SELECT * FROM tickets WHERE queued_at >= ? AND queued_at < ?",
            (since.isoformat(), until.isoformat()))}
        events = defaultdict(list)
        for r in db.execute("SELECT * FROM events ORDER BY id"):
            if r["ticket"] in tickets:
                events[r["ticket"]].append(dict(r))
    finally:
        db.close()
    by_pr = defaultdict(list)
    for ticket in sorted(tickets.values(), key=lambda t: t["id"]):
        by_pr[ticket["pr"]].append(ticket)

    waits, work = [], []
    for ticket_id, ticket in tickets.items():
        queued = parse(ticket["queued_at"])
        started = None
        first_start = True
        for e in events[ticket_id]:
            at = parse(e["created_at"])
            if e["status"] == "in_progress":
                if first_start:
                    waits.append(minutes(queued, at))
                    first_start = False
                started = at
            elif started and e["status"] in ENDS:
                work.append(minutes(started, at))
                started = None
    returns = Counter()
    with_returns, without_returns = [], []
    for pr, chain in by_pr.items():
        chain_events = [e for t in chain for e in events[t["id"]]]
        returns[pr] = sum(1 for e in chain_events if e["status"] == "blocked")
        done = [parse(e["created_at"]) for e in chain_events if e["status"] == "done"]
        if done:
            (with_returns if returns[pr] else without_returns).append(
                minutes(parse(chain[0]["queued_at"]), max(done)))
    deferred = Counter()
    for ticket_id in tickets:
        for e in events[ticket_id]:
            if e["status"] == "pending_install":
                note = e["note"].lower()
                deferred["meeting or microphone" if re.search(r"microphone|meeting", note)
                         else "screen locked" if "lock" in note else "other"] += 1
    unreachable = Counter(tickets[t]["source"] for t in tickets for e in events[t]
                          if e["acknowledged_at"] is None)
    return {
        "period": {"since": since.isoformat(), "until": until.isoformat()},
        "tickets": len(tickets), "prs": len(by_pr),
        "final_status": dict(Counter(t["status"] for t in tickets.values())),
        "returns": {"total": sum(returns.values()),
                    "prs_returned": sum(1 for v in returns.values() if v),
                    "per_pr": {str(k): v for k, v in sorted(Counter(returns.values()).items())},
                    "most": [{"pr": pr.rsplit("/", 1)[-1], "returns": n}
                             for pr, n in returns.most_common(5) if n]},
        "queue_wait_minutes": spread(waits),
        "builder_minutes_per_attempt": spread(work),
        "pr_to_done_minutes": {"without_returns": spread(without_returns),
                               "with_returns": spread(with_returns)},
        "deferred_installs": dict(deferred),
        "environment_wait_minutes": environment_waits(root / WATCHER_LOG, since, until),
        "unacknowledged_events_by_source": dict(unreachable),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--git-dir", help="Shared Git common directory (default: detected)")
    parser.add_argument("--since", required=True, help="UTC date or ISO time")
    parser.add_argument("--until", help="UTC date or ISO time (default: now)")
    arguments = parser.parse_args()
    root = Path(arguments.git_dir or subprocess.check_output(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip())
    until = parse(arguments.until) if arguments.until else datetime.now(timezone.utc)
    print(json.dumps(measure(root, parse(arguments.since), until), indent=2))


if __name__ == "__main__":
    main()
