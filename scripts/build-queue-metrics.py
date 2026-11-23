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


# Only a meeting gate that said "not clear" starts a meeting wait. The plain "next meeting
# check not due" line continues one that is open (older watchers logged it between checks)
# but never starts one: after a clear gate and a failed install it is an ordinary backoff.
# A wait ends at the next other decision the watcher logs, idle included.
WAIT_KINDS = (("waiting: screen locked", "screen locked"), ("waiting: load", "load"),
              ("deferred install: meeting gate", "meeting gate"))
CONTINUES_MEETING = "deferred install: next meeting check not due"


def environment_waits(log_path, since, until):
    """Minutes of each wait the watcher logged, clipped to the period. A wait starts at
    its `waiting: …` (or deferred-install) line and lasts until the watcher logs a
    different decision or starts a session; watchdog lines do not end it. A wait still
    open at the end of the log or the period counts up to `until`, and one that started
    before `since` counts from `since`."""
    waits = defaultdict(float)
    if not log_path.is_file():
        return {}
    current = None  # (kind, start)

    def close(at):
        start = max(current[1], since)
        end = min(at, until)
        if end > start:
            waits[current[0]] += minutes(start, end)

    for line in log_path.read_text(errors="replace").splitlines():
        match = re.match(r"(\S+) (.*)", line)
        if not match:
            continue
        try:
            at = parse(match.group(1))
        except ValueError:
            continue
        text = match.group(2)
        if text.startswith("watchdog"):
            continue
        kind = next((name for prefix, name in WAIT_KINDS if text.startswith(prefix)), None)
        if text.startswith(CONTINUES_MEETING) and current and current[0] == "meeting gate":
            continue
        if current and kind == current[0]:
            continue  # the same wait logged again
        if current:
            close(at)
        current = (kind, at) if kind else None
    if current:
        close(until)
    return {kind: round(value) for kind, value in sorted(waits.items())}


def measure(root, since, until):
    """Counts and durations from events inside [since, until) only. Tickets are those
    with any event in the period (submission included); their status is the last one
    recorded before `until`. Durations that began before `since` (carry-in) count when
    they end in the period."""
    db = sqlite3.connect((root / QUEUE).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    db.row_factory = sqlite3.Row
    try:
        tickets = {r["id"]: dict(r) for r in db.execute("SELECT * FROM tickets")}
        events = defaultdict(list)
        for r in db.execute("SELECT * FROM events ORDER BY id"):
            if r["ticket"] in tickets and parse(r["created_at"]) < until:
                events[r["ticket"]].append(dict(r))
    finally:
        db.close()
    inside = lambda e: since <= parse(e["created_at"]) < until
    queued = {i: t for i, t in tickets.items() if any(inside(e) for e in events[i])}
    chains = defaultdict(list)
    for ticket in sorted(tickets.values(), key=lambda t: t["id"]):
        chains[ticket["pr"]].append(ticket)

    # Times come from the event history only: `tickets.queued_at` is reset by every
    # requeue, so it would make earlier waits negative. A queue wait runs from a
    # `queued` event (submission or requeue) to the claim that follows it.
    def submitted(ticket):
        first = next((e for e in events[ticket["id"]] if e["status"] == "queued"), None)
        return parse(first["created_at"] if first else ticket["queued_at"])

    waits, work, open_attempts = [], [], 0
    for ticket_id, ticket in tickets.items():
        started, waiting_since = None, submitted(ticket)
        for e in events[ticket_id]:
            at = parse(e["created_at"])
            if e["status"] == "queued":
                waiting_since = waiting_since or at
            elif e["status"] == "in_progress":
                if waiting_since and inside(e):
                    waits.append(minutes(waiting_since, at))
                waiting_since, started = None, at
            if started and e["status"] in ENDS:
                if inside(e):
                    work.append(minutes(started, at))
                started = None
        if started:
            open_attempts += 1  # still in progress at the cutoff
    returns = Counter()
    with_returns, without_returns = [], []
    for pr, chain in chains.items():
        chain_events = [e for t in chain for e in events[t["id"]]]
        returns[pr] = sum(1 for e in chain_events if e["status"] == "blocked" and inside(e))
        done = [parse(e["created_at"]) for e in chain_events if e["status"] == "done"
                and inside(e)]
        if done:
            before = sum(1 for e in chain_events if e["status"] == "blocked"
                         and parse(e["created_at"]) <= max(done))
            (with_returns if before else without_returns).append(
                minutes(min(submitted(t) for t in chain), max(done)))
    deferred = Counter()
    for ticket_id in tickets:
        for e in events[ticket_id]:
            if e["status"] == "pending_install" and inside(e):
                note = e["note"].lower()
                deferred["meeting or microphone" if re.search(r"microphone|meeting", note)
                         else "screen locked" if "lock" in note else "other"] += 1
    unacknowledged = Counter(
        tickets[t]["source"] for t in tickets for e in events[t]
        if inside(e) and (e["acknowledged_at"] is None or parse(e["acknowledged_at"]) >= until))
    status_at_cutoff = Counter(
        (events[i][-1]["status"] if events[i] else "queued") for i in queued)
    return {
        "period": {"since": since.isoformat(), "until": until.isoformat()},
        "tickets": len(queued), "prs": len({t["pr"] for t in queued.values()}),
        "status_at_cutoff": dict(status_at_cutoff),
        "returns": {"total": sum(returns.values()),
                    "prs_returned": sum(1 for v in returns.values() if v),
                    "per_pr": {str(k): v for k, v in sorted(Counter(
                        returns[pr] for pr in {t["pr"] for t in queued.values()}).items())},
                    "most": [{"pr": pr.rsplit("/", 1)[-1], "returns": n}
                             for pr, n in returns.most_common(5) if n]},
        "queue_wait_minutes": spread(waits),
        "builder_minutes_per_attempt": spread(work),
        "attempts_open_at_cutoff": open_attempts,
        "pr_to_done_minutes": {"without_returns": spread(without_returns),
                               "with_returns": spread(with_returns)},
        "deferred_installs": dict(deferred),
        "environment_wait_minutes": environment_waits(root / WATCHER_LOG, since, until),
        "unacknowledged_events_by_source": dict(unacknowledged),
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
