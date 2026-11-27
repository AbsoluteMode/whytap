#!/usr/bin/env python3
"""Start one on-demand builder session while the build queue has open work.

WHY: .project-docs/decisions/2026-11-19-on-demand-build-queue-builder.md
A launchd agent runs `run` every minute and when the queue file changes. No
model is involved while the queue is idle. This script never merges, builds,
signs, installs or quits anything itself: it only decides whether a builder
session is needed, keeps it single, logs it and cleans up its own lease.
It also waits while the screen is locked or the Mac is overloaded, and a
model-free watchdog records stalls and waits in an alerts file for the
maintainer's orchestrator (WHY: .project-docs/decisions/2026-11-23-builder-queue-watchdog.md).
It also tells each ticket's author what became of it through the Whycode inbox
(WHY: .project-docs/decisions/2026-11-27-build-queue-whycode-inbox.md).
Only Python's standard library is required.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time


ACTOR = "whytap-on-demand-builder"
GROUP_LIMIT = 4  # merged runtime PRs one install may carry (as in the helper)
LABEL = "ai.whytap.build-queue-watcher"
QUEUE = "exodia-build-queue.sqlite3"
HELPER = "exodia-build-queue.py"
INSTALLED_WATCHER = "whytap-build-queue-watcher.py"
INSTALLED_PROMPT = "whytap-build-queue-builder-prompt.md"
CONFIG = "whytap-build-queue-builder.json"
STATE = "whytap-build-queue-watcher-state.json"
SESSION_LOCK = "whytap-build-queue-watcher.lock"
LOGS = "whytap-build-queue-logs"
INTEGRATION_LOCK = "exodia-integration.lock"
ALERTS = "whytap-build-queue-alerts.jsonl"
WATCHDOG = "whytap-build-queue-watchdog.json"
INBOX_STATE = "whytap-build-queue-inbox.json"
INBOX_SOURCE = "whytap-build-queue"
# A notice of its own for these; queued/in_progress events ride along with the next one.
NOTICE_STATUSES = ("blocked", "pending_install", "done", "superseded", "cancelled")
FINAL_STATUSES = ("blocked", "done", "superseded", "cancelled")
INBOX_TEXT_LIMIT = 20000      # Whycode's limit for `text`, in UTF-16 units
INBOX_FILE_LIMIT = 128 * 1024  # Whycode's limit for the whole file, in bytes
RECEIPT_STATUSES = ("queued", "delivered", "rejected")
RECORD_STATUSES = ("sent", "queued", "delivered", "rejected")
INBOX_KEPT_MESSAGES = 1000    # delivered records kept in the inbox state
PROMPT_SOURCE = "scripts/build-queue-builder-prompt.md"
OUTBOX_LIMIT = 500  # alert lines kept per unwritable target
ACTIVATED_SOURCES = ("build-queue.py", "build-queue-watcher.py", "build-queue-builder-prompt.md",
                     "build-queue-watcher.plist.template")
DEFAULTS = {
    "engine": "codex",             # "codex", "claude" or "custom" (uses "command")
    "model": "",                   # empty: the engine's own configured default
    "worktree": "",                # empty: ~/.whytap-builder/integration
    "retry_install_seconds": 300,  # how often a deferred install rechecks the meeting gate
    "max_session_seconds": 6 * 3600,
    "poll_seconds": 2,             # how often the session's process tree is recorded
    "notify": True,
    "prompt_from_origin": True,    # each session reads the builder prompt from origin/main
    "load_limit_per_cpu": 2.0,     # 5-minute load average above this x CPUs: wait
    "environment_command": None,   # tests: a probe printing the environment JSON
    "watchdog_seconds": 60,        # how often a running session is checked for stalls
    "stall_minutes": 60,           # an in_progress ticket without a new event this long
    "environment_alert_minutes": 60,  # open work waiting for the screen or the load
    "install_alert_minutes": 120,  # a deferred install still waiting
    "undelivered_minutes": 20,     # an author event still unacknowledged
    "alerts_mirror": "",           # optional second JSONL path, e.g. the orchestrator's folder
    # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
    "validate_while_locked": True,  # review, tests and merge go on behind a locked screen;
                                    # protected-data tests, packaging and installs wait
    "stale_dependency_minutes": 120,  # return a ticket whose dependency stays blocked
    "notes_max_bytes": 32768,      # builder notes above this keep only their tail
    # WHY: .project-docs/decisions/2026-11-27-build-queue-whycode-inbox.md
    "whycode_inbox": "~/Library/Application Support/Whycode/inbox",  # "" turns notices off
    "whycode_project": "",         # empty: the main checkout beside the Git common directory
    "inbox_settle_seconds": 90,    # an open ticket's newest event waits this long for more
    "inbox_retry_minutes": 30,     # a rejected notice is sent again under a new id after this
    "inbox_max_attempts": 6,       # then only the undelivered alert remains
}
NOTES = "whytap-builder-notes"
NOTES_KEPT_LINES = 120
NOTES_ARCHIVE_MAX_BYTES = 1 << 20  # the .old archive keeps its newest megabyte
BACKOFF_SECONDS = (300, 900, 3600)
KEPT_LOGS = 40
SOURCES = Path(__file__).resolve().parent


def log(message):
    print(datetime.now(timezone.utc).isoformat(timespec="seconds") + " " + message, flush=True)


def git_dir(explicit):
    if explicit:
        return Path(explicit).resolve()
    if (SOURCES / "HEAD").is_file() and (SOURCES / "objects").is_dir():
        return SOURCES  # the installed copy lives in the Git common directory
    return Path(subprocess.check_output(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip())


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return dict(default)


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def load_config(root):
    return {**DEFAULTS, **read_json(root / CONFIG, {})}


def worktree_path(config):
    return Path(config["worktree"]).expanduser() if config["worktree"] else (
        Path.home() / ".whytap-builder" / "integration")


def open_work(root):
    """Read-only view of what could need a builder. Never modifies the queue. A queued
    ticket waiting for a `--depends-on` PR that is not merged yet needs none."""
    path = root / QUEUE
    work = {"queued": [], "in_progress": [], "retry_install": [], "waiting_install": [],
            "waiting_dependency": [], "install_first": [], "held_for_install": []}
    if not path.is_file():
        return {**work, "fingerprint": ""}
    def read():
        db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
        try:
            columns = {c[1] for c in db.execute("PRAGMA table_info(tickets)")}
            retry = "retry" if "retry" in columns else "''"
            depends = "depends_on" if "depends_on" in columns else "'[]'"
            runtime = "runtime" if "runtime" in columns else "1"
            # The latest ticket of each PR: a dependency is met once it is merged.
            merged = {pr for pr, status in db.execute(
                "SELECT pr, status FROM tickets WHERE id IN (SELECT MAX(id) FROM tickets "
                "GROUP BY pr)") if status in ("done", "pending_install")}
            rows = db.execute(
                "SELECT id, status, updated_at, queued_at, " + retry + ", " + depends + ", " +
                runtime + " FROM tickets WHERE status IN "
                "('queued', 'in_progress', 'pending_install') ORDER BY queued_at, id").fetchall()
            return [(ticket, status, updated, queued, retry_value,
                     any(pr not in merged for pr in json.loads(needs or "[]")), changes_app)
                    for ticket, status, updated, queued, retry_value, needs, changes_app
                    in rows]
        finally:
            db.close()

    try:
        rows = read()
    except sqlite3.OperationalError:
        # A writer killed mid-transaction leaves a journal that a read-only
        # connection cannot roll back. An ordinary open recovers it; no data changes.
        db = sqlite3.connect(path, timeout=30)
        try:
            db.execute("SELECT COUNT(*) FROM tickets").fetchone()
        finally:
            db.close()
        rows = read()
    seen = []
    # The install boundary (as in the helper): an install marked first or held for a
    # person, or a full group, comes before any other runtime work.
    # WHY: .project-docs/decisions/2026-11-23-builder-queue-group-install.md
    waiting_installs = [(ticket, retry) for ticket, status, _u, _q, retry, _w, _r in rows
                        if status == "pending_install"]
    automatic = [ticket for ticket, retry in waiting_installs if retry in ("meeting", "first")]
    full = len(automatic) >= GROUP_LIMIT
    boundary = full or any(retry in ("first", "hold") for _t, retry in waiting_installs)
    # One candidate installs the whole group: a person holding any of it holds all.
    held = any(retry == "hold" for _t, retry in waiting_installs)
    for ticket, status, updated, queued, retry, waiting, changes_app in rows:
        if status == "pending_install":
            status = ("retry_install" if retry in ("meeting", "first") and not held
                      else "waiting_install")
            if status == "retry_install" and (full or retry == "first"):
                work["install_first"].append(ticket)
        if status == "queued" and waiting:
            status = "waiting_dependency"  # no session until its dependency is merged
        elif status == "queued" and boundary and changes_app:
            status = "held_for_install"  # keeps its place until the install is done
        work[status].append(ticket)
        if status == "queued":
            # A ticket returned without a block keeps its queued_at: the same queued
            # work again is no progress. A retry after a block gets a new queued_at
            # and resets the backoff.
            seen.append([ticket, status, queued])
        elif status not in ("waiting_install", "waiting_dependency", "held_for_install"):
            seen.append([ticket, status, updated])
    work["fingerprint"] = hashlib.sha256(json.dumps(seen).encode()).hexdigest() if seen else ""
    return work


def meeting_gate_clear(config):
    """Cheap pre-filter only; the builder repeats the gate right before Quit."""
    command = config.get("meeting_gate_command") or [
        sys.executable, str(worktree_path(config) / "scripts" / "build-queue-meeting-gate.py")]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        return result.returncode == 0 and json.loads(result.stdout).get("status") == "clear"
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def console_locked():
    """True when this user's console is locked or not in front (logged out, another
    user's session); None when unknown. Reads `ioreg`, like the login window does."""
    try:
        result = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True,
                                timeout=10)
        users = plistlib.loads(result.stdout).get("IOConsoleUsers", [])
    except (OSError, ValueError, subprocess.TimeoutExpired, plistlib.InvalidFileException,
            AttributeError):
        return None
    for user in users:
        if user.get("kCGSSessionUserIDKey") == os.getuid() and user.get("kCGSSessionOnConsoleKey"):
            return bool(user.get("CGSSessionScreenIsLocked", False))
    return True


def number(value, low=0.0, high=1e6):
    """A finite real number within [low, high], or None: bools, strings, integers too
    large for a float and absurd magnitudes are unknown, never an exception."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        value = float(value)
    except OverflowError:
        return None
    return value if value == value and low <= value <= high else None


def environment(config):
    """Whether the Mac can run a build now: screen unlocked and load below the limit.
    Unknown values never block (a failed, malformed or odd-shaped probe is unknown);
    the builder checks again before the full suite."""
    probe = {}
    if config.get("environment_command"):
        try:
            result = subprocess.run(config["environment_command"], capture_output=True,
                                    text=True, timeout=30)
            if result.returncode == 0:
                probe = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            probe = {}
    else:
        try:
            load_average = os.getloadavg()[1]
        except OSError:
            load_average = None
        probe = {"screen_locked": console_locked(), "load": load_average,
                 "cpus": os.cpu_count()}
    if not isinstance(probe, dict):
        probe = {}
    locked = probe.get("screen_locked") if isinstance(probe.get("screen_locked"), bool) else None
    load = number(probe.get("load"))
    cpus = probe.get("cpus")
    if isinstance(cpus, bool) or not isinstance(cpus, int) or not 1 <= cpus <= 4096:
        cpus = os.cpu_count() or 1
    per_cpu = number(config.get("load_limit_per_cpu"), high=1000)
    if per_cpu is None or per_cpu <= 0:
        per_cpu = DEFAULTS["load_limit_per_cpu"]
    limit = per_cpu * cpus
    reason = ""
    overloaded = load is not None and load > limit
    if locked:
        reason = "screen locked"
    elif overloaded:
        reason = f"load {load:.0f} on {cpus} CPUs (limit {limit:.0f})"
    # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
    # Only the protected-data tests, signing and the install need an unlocked screen:
    # review, the suite and the merge may run behind a lock when the load allows.
    return {"clear": not reason, "reason": reason, "screen_locked": locked,
            "load": load, "cpus": cpus, "load_limit": limit,
            "clear_for_validation": not overloaded}


def waiting_kind(reason):
    """One log line per wait: a changing load figure is the same wait, and a blocked
    meeting gate between its checks is one wait until it clears or the queue changes."""
    for prefix in ("waiting: load", "deferred install: meeting gate"):
        if reason.startswith(prefix):
            return prefix
    return reason


def is_wait(reason):
    return reason.startswith(("waiting:", "deferred install"))


def decide(work, state, config, now, gate, ready=lambda _config: {"clear": True}):
    """Return (start, reason). `state` is updated when the meeting gate was consulted.
    A locked screen or an overloaded Mac only waits: no backoff, no blame."""
    if not work["retry_install"]:
        state.pop("meeting_blocked", None)
    # An install that must come first goes before queued work (only work that does not
    # change the app is still queued then); while it waits, that work may run.
    if work.get("install_first") and not work["in_progress"]:
        start, reason = install(work, state, config, now, gate, ready)
        if start or not work["queued"]:
            return start, reason
    if work["queued"] or work["in_progress"]:
        failures = state.get("no_progress", 0)
        if failures and state.get("fingerprint") == work["fingerprint"]:
            wait = BACKOFF_SECONDS[min(failures, len(BACKOFF_SECONDS)) - 1]
            if now - state.get("last_exit", 0) < wait:
                return False, f"backoff: {failures} session(s) changed nothing, next try in " \
                              f"{int(wait - (now - state.get('last_exit', 0)))}s"
        check = ready(config)
        if not check["clear"] and not (config.get("validate_while_locked", True)
                                       and check.get("clear_for_validation")):
            return False, "waiting: " + check["reason"]
        reason = "recover_in_progress" if work["in_progress"] else "queued"
        if not check["clear"]:
            reason += " (screen locked: validation and merge only, installs wait)"
        return True, reason
    if work["retry_install"]:
        return install(work, state, config, now, gate, ready)
    return False, "idle"


def install(work, state, config, now, gate, ready):
    """The deferred-install branch of `decide`: retry interval, environment, gate."""
    wait = config["retry_install_seconds"]
    failures = state.get("no_progress", 0)
    if failures and state.get("fingerprint") == work["fingerprint"]:
        # The gate was clear but the install still did not happen: slow down too.
        wait = max(wait, BACKOFF_SECONDS[min(failures, len(BACKOFF_SECONDS)) - 1])
    if now - state.get("last_install_attempt", 0) < wait:
        # Only a gate that said "not clear" is a meeting wait; a retry after a
        # clear gate and a failed install is a backoff under its own text.
        return False, ("deferred install: meeting gate is not clear; next check not due"
                       if state.get("meeting_blocked")
                       else "deferred install: next meeting check not due")
    check = ready(config)
    if not check["clear"]:
        return False, "waiting: " + check["reason"]
    state["last_install_attempt"] = now
    state["meeting_blocked"] = not gate(config)
    if state["meeting_blocked"]:
        return False, "deferred install: meeting gate is not clear"
    return True, "retry_install"


def engine_command(config, worktree):
    engine = config["engine"]
    if engine == "custom":
        return list(config["command"])
    model = config["model"]
    if engine == "claude":
        command = ["claude", "-p", "--dangerously-skip-permissions",
                   "--output-format", "stream-json", "--verbose"]
        return command + (["--model", model] if model else [])
    if engine == "codex":
        command = ["codex", "exec", "--dangerously-bypass-approvals-and-sandbox",
                   "--json", "-C", str(worktree)]
        return command + (["-m", model] if model else []) + ["-"]
    raise ValueError("Unknown engine: " + str(engine))


def ensure_worktree(root, config):
    path = worktree_path(config)
    if (path / ".git").exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    base = "origin/main"
    if subprocess.run(["git", "--git-dir", str(root), "rev-parse", "--verify", "--quiet",
                       base + "^{commit}"], capture_output=True).returncode != 0:
        base = "HEAD"
    subprocess.run(["git", "--git-dir", str(root), "worktree", "add", "--detach", "--quiet",
                    str(path), base], check=True, capture_output=True)
    return path


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def process_table():
    """{pid: (ppid, start)} with a locale- and zone-independent start time."""
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,lstart="], capture_output=True,
                            text=True, env={"PATH": "/bin:/usr/bin", "LC_ALL": "C", "TZ": "UTC"})
    table = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2].strip())
    return table


def started_at(pid):
    return process_table().get(pid, (0, ""))[1]


def remember_tree(known, leader):
    """Tool commands of an agent CLI often run in their own process groups, and
    are reparented when the CLI dies. Record every descendant seen while it lives."""
    table = process_table()
    for pid in [p for p, start in known.items() if table.get(p, (0, ""))[1] != start]:
        del known[pid]
    children = {}
    for pid, (parent, _start) in table.items():
        children.setdefault(parent, []).append(pid)
    pending = [leader]
    while pending:
        for child in children.get(pending.pop(), ()):
            if child not in known:
                known[child] = table[child][1]
                pending.append(child)


def survivors(known):
    table = process_table()
    return [pid for pid, start in known.items() if table.get(pid, (0, ""))[1] == start]


def stop_group(pgid, grace, reap=lambda: None, known=None):
    """End what is left of our own session: its process group and the recorded
    descendants that left the group. Other processes are never signalled.
    `reap` collects our own exited child, which otherwise still counts as alive.
    Returns True when nothing of the session is left."""
    def left():
        reap()
        return (pgid is not None and group_alive(pgid), survivors(known) if known else [])

    for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 10)):
        group, others = left()
        if not group and not others:
            return True
        try:
            if group:
                os.killpg(pgid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            group = False  # only zombies awaiting their parent are left in the group
        for pid in others:
            try:
                os.kill(pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            now_group, others = left()
            if not (group and now_group) and not others:
                return True
            time.sleep(0.1)
    return False


def release_integration_lock(root, lease_pid):
    """A lock naming an ended watcher's PID after that watcher's session and its
    process group ended has no live owner and no protected operation."""
    lock = root / INTEGRATION_LOCK
    owner = read_json(lock / "owner.json", {})
    if lock.is_dir() and owner.get("pid") == lease_pid and owner.get("session") == ACTOR:
        shutil.rmtree(lock)
        log("released the integration lock left by the ended session")


def reap_orphan(root, state):
    """A watcher that was killed outright leaves its session without a live lease.
    End that session before anything else; the next one recovers the ticket.
    Returns False while something of that session could not be ended."""
    session = state.get("session")
    if not session:
        return True
    pgid = session["pgid"]
    known = {int(pid): start for pid, start in session.get("tree", {}).items()}
    leader = started_at(pgid)
    ours = leader in ("", session["started"])  # otherwise the PID belongs to someone else
    gone = True
    if (ours and group_alive(pgid)) or survivors(known):
        log("ending a builder session whose watcher is gone")
        gone = stop_group(pgid if ours else None, 60, known=known)
    if not gone:
        log("that session did not end; nothing new is started")
        return False
    release_integration_lock(root, session["lease_pid"])
    del state["session"]
    write_json(root / STATE, state)
    return True


def git_in(root, *arguments, timeout=60):
    return subprocess.run(["git", "--git-dir", str(root), *arguments], capture_output=True,
                          timeout=timeout)


def fetched_main(root):
    """The commit of origin/main right after a successful fetch, or None. A cached
    origin/main after a failed fetch is not current and is never used as such."""
    try:
        if git_in(root, "fetch", "--quiet", "origin", "main").returncode != 0:
            return None
        commit = git_in(root, "rev-parse", "--verify", "--quiet", "origin/main^{commit}")
        sha = commit.stdout.decode().strip()
        return sha if commit.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", sha) else None
    except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError):
        return None


def show(root, commit, path):
    """A file at one immutable commit (bytes), or None."""
    try:
        shown = git_in(root, "show", f"{commit}:{path}")
    except (OSError, subprocess.TimeoutExpired):
        return None
    return shown.stdout if shown.returncode == 0 else None


def builder_prompt(root, config):
    """The builder's rules as merged: origin/main's prompt, so a rule change reaches the
    next session without reinstalling. Only after a successful fetch, read and labelled
    from the same commit; otherwise the installed copy, labelled as such."""
    if config.get("prompt_from_origin", True):
        commit = fetched_main(root)
        text = show(root, commit, PROMPT_SOURCE) if commit else None
        try:
            if text and text.strip():
                return text.decode(), "origin/main " + commit
        except UnicodeDecodeError:
            pass
    prompt_path = root / INSTALLED_PROMPT
    if not prompt_path.is_file():
        prompt_path = SOURCES / "build-queue-builder-prompt.md"
    return prompt_path.read_text(), str(prompt_path)


def ticket_rows(root, undelivered_since):
    """Read-only snapshot for the watchdog: open tickets with each one's latest event,
    and author events still unacknowledged that were created since the watchdog began
    (older backlog is out of scope; nothing in scope expires while unacknowledged)."""
    db = sqlite3.connect((root / QUEUE).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    db.row_factory = sqlite3.Row
    try:
        columns = {c[1] for c in db.execute("PRAGMA table_info(tickets)")}
        retry = "t.retry" if "retry" in columns else "''"
        tickets = [dict(r) for r in db.execute(
            "SELECT t.id, t.pr, t.status, t.updated_at, t.source, " + retry + " AS retry, "
            "(SELECT MAX(created_at) FROM events e WHERE e.ticket = t.id) AS last_event "
            "FROM tickets t WHERE t.status IN ('queued', 'in_progress', 'pending_install')")]
        undelivered = [dict(r) for r in db.execute(
            "SELECT e.id, e.ticket, e.status, e.created_at, t.pr, t.source, "
            "t.status AS ticket_status, (SELECT MAX(id) FROM events x WHERE x.ticket = e.ticket) "
            "AS newest_id FROM events e "
            "JOIN tickets t ON t.id = e.ticket WHERE e.acknowledged_at IS NULL "
            "AND e.created_at >= ? ORDER BY e.id", (undelivered_since,))]
    finally:
        db.close()
    return tickets, undelivered


def age_minutes(stamp, now):
    try:
        value = datetime.fromisoformat(stamp)
        value = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return (now - value.timestamp()) / 60
    except (TypeError, ValueError):
        return 0


def findings(root, config, context, previous, now, inbox=None):
    """Conditions worth a person's attention, keyed so one episode raises once and
    clears only when its condition is resolved."""
    inbox = inbox if isinstance(inbox, dict) else {}
    tickets, undelivered = ticket_rows(root, previous["undelivered_since"])
    found = {}
    open_work = any(t["status"] in ("queued", "in_progress") or t["retry"] == "meeting"
                    for t in tickets)
    for t in tickets:
        name = f"#{t['id']} (PR {t['pr'].rsplit('/', 1)[-1]})"
        if t["status"] == "in_progress" and context.get("session"):
            quiet = age_minutes(t["last_event"], now)
            if quiet > config["stall_minutes"]:
                found[f"ticket_stalled:{t['id']}"] = {
                    "ticket": t["id"], "pr": t["pr"], "minutes": round(quiet),
                    "detail": f"{name} in progress for {round(quiet)} min without a queue event"}
        if t["status"] == "pending_install" and t["retry"] == "meeting":
            waited = age_minutes(t["updated_at"], now)
            if waited > config["install_alert_minutes"]:
                found[f"install_waiting:{t['id']}"] = {
                    "ticket": t["id"], "pr": t["pr"], "minutes": round(waited),
                    "detail": f"{name} merged, install deferred for {round(waited)} min"}
    reason = context.get("reason", "")
    if open_work and reason.startswith("waiting:"):
        since = previous.get("waiting_since") or now
        if (now - since) / 60 > config["environment_alert_minutes"]:
            found["environment_wait"] = {
                "minutes": round((now - since) / 60),
                "detail": f"queue waits: {reason[len('waiting: '):]}"}
    # Sessions (queued work or a deferred install) that keep ending without changing the
    # queue, whatever the decision text of the current tick says.
    if open_work and context.get("no_progress", 0) >= 2:
        found["no_progress"] = {"sessions": context["no_progress"],
                                "detail": f"{context['no_progress']} builder sessions in a row "
                                          "ended without changing the queue"}
    # The backstop of the Whycode inbox notices: an author still not told. Only the
    # ticket's newest event as a state change (or anything of a closed ticket) counts:
    # a receipt, start or requeue of an open ticket, and anything a newer event replaced,
    # rides along with its next notice. A rejected notice counts at once.
    # WHY: .project-docs/decisions/2026-11-27-build-queue-whycode-inbox.md
    messages = valid_records(inbox.get("messages"))  # the same checks as delivery
    in_flight = {event_id: record for record in messages.values()
                 if record.get("status") in ("sent", "queued")
                 for event_id in record.get("events", [])}
    rejected = {}  # a later attempt in flight supersedes an earlier rejection
    for message_id, record in messages.items():
        if record.get("status") == "rejected":
            for event_id in record.get("events", []):
                if event_id not in in_flight:
                    rejected[event_id] = f"Whycode inbox rejected {message_id}: " \
                                         f"{record.get('reason', '')}"
    for e in undelivered:
        late = age_minutes(e["created_at"], now)
        rides_along = e["ticket_status"] not in FINAL_STATUSES and (
            e["status"] not in NOTICE_STATUSES or e["id"] != e["newest_id"])
        if e["id"] not in rejected and (rides_along or late <= config["undelivered_minutes"]):
            continue
        if e["id"] in rejected:
            why = rejected[e["id"]]
        elif inbox.get("unavailable"):
            why = "Whycode inbox unavailable: " + inbox["unavailable"]
        elif e["id"] in in_flight:
            receipt = in_flight[e["id"]].get("receipt") or {}
            why = ("Whycode has not answered the notice yet (Whycode closed?)" if not receipt
                   else "Whycode holds the notice: " + str(receipt.get("waiting")
                                                           or receipt.get("status")))
        else:
            why = "no notice sent (before the inbox scope, or not settled)"
        key = f"undelivered:{e['ticket']}"
        entry = found.setdefault(key, {
            "ticket": e["ticket"], "pr": e["pr"], "events": [],
            "detail": f"#{e['ticket']} ({e['source']}) author not told: {why}"})
        entry["events"].append(e["id"])
        entry["minutes"] = max(entry.get("minutes", 0), round(late))
    return found

# --- Whycode inbox: tell each ticket's author what became of it ---------------------
# WHY: .project-docs/decisions/2026-11-27-build-queue-whycode-inbox.md
# Harness Link `link_send` only stored messages no Whycode session ever read, and the
# builder acknowledged them anyway. The watcher now writes one file per ticket batch into
# Whycode's inbox (spec: whycode docs/session-inbox.md); Whycode continues the author's
# session or hands the notice to the project's orchestrator and answers with a receipt.
# An event is acknowledged only when its receipt says `delivered`.


def inbox_sender(root):
    """Ids are unique per queue: another clone's queue numbers its events from 1 too."""
    return INBOX_SOURCE + ":" + hashlib.sha256(str(root).encode()).hexdigest()[:8]


def inbox_project(root, config):
    if config.get("whycode_project"):
        return str(Path(config["whycode_project"]).expanduser())
    return str(root.parent if root.name == ".git" else root)


def inbox_folder(config):
    """The inbox folder, or (None, why not). Whycode makes it; a sender may make it 0700
    once Whycode's own folder exists. A symlinked folder is never used."""
    if not config.get("whycode_inbox"):
        return None, "notices are turned off (whycode_inbox is empty)"
    inbox = Path(config["whycode_inbox"]).expanduser()
    if inbox.is_symlink() or (inbox / "receipts").is_symlink():
        return None, f"{inbox} is a symlink"
    if not inbox.is_dir():
        if not inbox.parent.is_dir():
            return None, f"Whycode is not installed here ({inbox.parent} is missing)"
        inbox.mkdir(mode=0o700, exist_ok=True)
    return inbox, ""


def ensure_inbox_scope(root, now=None):
    """Events from the first run of this version on are delivered; older ones stay with
    the undelivered alert (sending days-old results would wake sessions for stale news)."""
    path = root / INBOX_STATE
    state = read_json(path, {})
    if not isinstance(state, dict):
        state = {}  # unreadable: a new scope; earlier events stay with the alert
    if not state.get("since"):
        state["since"] = datetime.fromtimestamp(
            now or time.time(), timezone.utc).isoformat(timespec="microseconds")
        state.setdefault("messages", {})
        write_json(path, state)
    return state


def inbox_events(root, since):
    """Unacknowledged events in scope, each with its ticket and the ticket's newest event
    (acknowledged or not): the newest one is the ticket's actual state."""
    db = sqlite3.connect((root / QUEUE).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    db.row_factory = sqlite3.Row
    try:
        columns = {c[1] for c in db.execute("PRAGMA table_info(tickets)")}
        returned = "t.auto_returned" if "auto_returned" in columns else "0"
        depends = "t.depends_on" if "depends_on" in columns else "'[]'"
        return [dict(r) for r in db.execute(
            "SELECT e.id, e.ticket, e.status, e.note, e.created_at, t.pr, t.head, t.title, "
            "t.source, t.session, t.acceptance, t.status AS ticket_status, "
            + returned + " AS auto_returned, " + depends + " AS depends_on, "
            "n.id AS newest_id, n.acknowledged_at AS newest_acknowledged FROM events e "
            "JOIN tickets t ON t.id = e.ticket "
            "JOIN events n ON n.id = (SELECT MAX(id) FROM events x WHERE x.ticket = e.ticket) "
            "WHERE e.acknowledged_at IS NULL AND e.created_at >= ? ORDER BY e.id", (since,))]
    finally:
        db.close()


def ticket_of_event(root, event_id):
    db = sqlite3.connect((root / QUEUE).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    try:
        row = db.execute("SELECT ticket FROM events WHERE id = ?", (event_id,)).fetchone()
        return row[0] if row else None
    finally:
        db.close()


def utf16_units(text):
    """Whycode checks lengths in JavaScript, which counts UTF-16 code units."""
    return len(str(text).encode("utf-16-le")) // 2


def clip(text, limit, tail=" [...]"):
    """At most `limit` UTF-16 units, never splitting a character."""
    text = str(text or "")
    if utf16_units(text) <= limit:
        return text
    budget, used, kept = max(limit - utf16_units(tail), 0), 0, []
    for character in text:
        size = 2 if ord(character) > 0xFFFF else 1
        if used + size > budget:
            break
        kept.append(character)
        used += size
    return "".join(kept).rstrip() + tail


def pr_label(pr):
    return "PR #" + str(pr).rstrip("/").rsplit("/", 1)[-1]


def return_kind(ticket, status):
    """`finding`, or the structured kind of a return made without review."""
    if status != "blocked" or not ticket.get("auto_returned"):
        return "finding"
    try:
        dependencies = json.loads(ticket.get("depends_on") or "[]")
    except ValueError:
        dependencies = []
    return "dependency" if dependencies and "dependency" in (ticket.get("note") or "") \
        else "moved_head"


def notice_guidance(status, kind, helper_path, pr):
    enqueue = (f'python3 "{helper_path}" enqueue --pr {pr} --head <new reviewed head> '
               "--title ... --checks ... --dependencies ... --acceptance ...")
    if kind == "dependency":
        return ("Returned without review: nothing in your change was judged, so do not change "
                "code for it. Wait until the dependency named in the note is merged through "
                "the queue, then resubmit the same head (`enqueue` with the same --head keeps "
                "the place), or drop --depends-on if it is no longer needed.")
    if kind == "moved_head":
        return ("Returned without review: the PR head moved after you submitted it, and "
                "nothing in your change was judged. Review the newer commit named in the note "
                "and enqueue that head; no other change is asked for.")
    if status == "blocked":
        return (
            "Your PR went back to you. Start on it now; the owner does not need to forward "
            "this.\n"
            "1. Fix every finding by class: find and fix the same kind of defect across the "
            "whole change, not only the cited line, and add a check that would have caught it.\n"
            "2. Update the branch onto current origin/main (fetch first) and resolve conflicts.\n"
            "3. Validate as the runbook requires: the relevant build, tests and other "
            "non-launching checks. Never launch or install the app.\n"
            "4. Push, then resubmit the new reviewed head of the same PR:\n   " + enqueue + "\n"
            "   A resubmission keeps the PR's place twice at most.\n"
            "If a finding needs a product decision by the owner, or you disagree with it, do "
            "not guess: report it to your orchestrator with the evidence.")
    if status == "pending_install":
        return ("Merged into main; the installation into the working app is still pending "
                "(see the note). Nothing to do unless the note asks you; another notice "
                "follows when it is running. A merge alone does not update the running app.")
    if status == "done":
        return ("Done: merged, and installed when it changes the app (the note says what "
                "actually runs). Now follow the runbook's Feature session steps 7-8: check "
                "that the remote feature branch was deleted and remove your worktree's build "
                "output. Then report to your orchestrator what runs and the acceptance steps "
                "below.")
    if status == "superseded":
        return ("Superseded: this ticket will not be built (see the note). If a newer "
                "ticket of yours replaces it, nothing to do; otherwise tell your orchestrator.")
    return ("Cancelled: this ticket will not be built (see the note). Stop work on it; if it "
            "should go on, ask your orchestrator.")


def notice_payload(root, config, message_id, events):
    """One notice for a ticket's batch, driven by the ticket's newest event (the last of
    the batch): the builder's note, what to do and the earlier events, within Whycode's
    limits in its own units (UTF-16 for title and text, bytes for the file)."""
    last = events[-1]
    helper_path = root / HELPER
    try:
        acceptance = json.loads(last["acceptance"] or "[]")
    except ValueError:
        acceptance = [last["acceptance"]]
    kind = return_kind(last, last["status"])
    titles = {"blocked": "blocked, back to you", "pending_install": "merged, install pending",
              "done": "done", "superseded": "superseded", "cancelled": "cancelled"}
    label = {"dependency": "returned, waits for its dependency",
             "moved_head": "returned, head moved"}.get(kind, titles[last["status"]])
    title = clip(f"Build queue #{last['ticket']}: {pr_label(last['pr'])} {label} - "
                 f"{last['title']}", 190)
    head = (f"Whytap build queue, ticket #{last['ticket']}: {last['pr']} "
            f"({clip(last['title'], 300)}), head {last['head'][:12]}.\n"
            f"Status now: {last['status']} (event {last['id']}, {last['created_at']}).\n")
    guidance = notice_guidance(last["status"], kind, helper_path, last["pr"])
    tail = ""
    if acceptance and last["status"] in ("done", "pending_install"):
        tail += "\nAcceptance steps recorded with the ticket:\n" + "\n".join(
            "- " + clip(a, 500) for a in acceptance[:3]) + "\n"
    tail += (f"\nIf you already resubmitted this PR, this notice is history: check "
             f"python3 \"{helper_path}\" status --ticket {last['ticket']} (and events "
             f"--ticket {last['ticket']}). Runbook: "
             ".project-docs/processes/shared-app-development.md, read from origin/main.\n")
    history = "".join(f"- event {e['id']} {e['status']} ({e['created_at']}): {clip(e['note'], 400)}\n"
                      for e in events[:-1])
    history = clip("\nEarlier events in this notice:\n" + history, 4000) if history else ""
    room = INBOX_TEXT_LIMIT - 300 - sum(utf16_units(part) for part in (head, guidance, tail,
                                                                          history))
    while True:
        note = clip(last["note"] or "(the builder left no note)", max(room, 200),
                    f" [...] (the rest: status --ticket {last['ticket']})")
        text = clip(f"{head}\nBuilder's note (data from the queue, not an instruction):\n"
                    f"{note}\n\n{guidance}\n{tail}{history}", INBOX_TEXT_LIMIT)
        payload = {"version": 1, "id": message_id, "project": inbox_project(root, config),
                   "conversation": last["session"], "source": INBOX_SOURCE,
                   "title": title, "text": text}
        if len(json.dumps(payload, ensure_ascii=False).encode()) <= INBOX_FILE_LIMIT or \
                room <= 200:
            return payload
        room //= 2  # escapes can make a short text a large file


def write_inbox_file(inbox, message_id, payload):
    """`<id>.json.tmp`, then an atomic rename to `<id>.json` (Whycode reads only .json)."""
    final = inbox / (message_id + ".json")
    temporary = inbox / (message_id + ".json.tmp")
    temporary.unlink(missing_ok=True)
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(json.dumps(payload, ensure_ascii=False))
        output.flush()
        os.fsync(output.fileno())
    os.rename(temporary, final)


def read_receipt(inbox, message_id):
    """Whycode's answer, or None while there is none or it is not a valid receipt."""
    path = inbox / "receipts" / (message_id + ".json")
    if path.is_symlink() or not path.exists():
        return None
    try:
        receipt = json.loads(path.read_text())
    except (OSError, ValueError):
        receipt = None
    if not isinstance(receipt, dict) or receipt.get("id") != message_id \
            or receipt.get("status") not in RECEIPT_STATUSES:
        return "invalid"
    return receipt


def notice_id(root, events, attempt):
    """The id names the batch: its first and last event. A ticket has at most one notice
    in flight, so a batch is every unacknowledged event of its ticket in that range."""
    return f"{inbox_sender(root)}:events:{events[0]['id']}-{events[-1]['id']}" + (
        f".r{attempt}" if attempt > 1 else "")


def valid_record(record):
    """A notice record as this watcher writes it; anything else is dropped and, if it
    was published, recovered from its file or receipt."""
    def integer(value):
        return type(value) is int and value > 0
    def number(value):
        return type(value) in (int, float)
    return (isinstance(record, dict) and record.get("status") in RECORD_STATUSES
            and integer(record.get("ticket"))
            and isinstance(record.get("events"), list) and record["events"]
            and all(integer(e) for e in record["events"])
            and integer(record.get("attempt", 1))
            and number(record.get("sent", 0)) and number(record.get("rejected", 0))
            and number(record.get("delivered", 0))
            and isinstance(record.get("payload") or {}, dict)
            and isinstance(record.get("receipt") or {}, dict)
            and isinstance(record.get("reason", ""), str))


def valid_records(messages):
    return {k: v for k, v in messages.items() if isinstance(k, str) and valid_record(v)} \
        if isinstance(messages, dict) else {}


def recover_published(root, inbox, messages, unacknowledged):
    """A notice can be published while recording it fails (a crash, a full disk), and an
    invalid record is dropped. The notice's file or receipt is the durable evidence, and
    its id names the exact batch whatever the records on disk still say. Recovered, it is
    never sent again under another id."""
    prefix = inbox_sender(root) + ":events:"
    names = {path.name[:-len(".json")] for folder in (inbox, inbox / "receipts")
             for path in folder.glob(prefix + "*.json")}
    for message_id in sorted(names - set(messages)):
        try:
            match = re.fullmatch(r"(\d+)-(\d+)(?:\.r(\d+))?", message_id[len(prefix):])
            if not match:
                continue
            first, last = int(match.group(1)), int(match.group(2))
            ticket = ticket_of_event(root, last)
            events = [e["id"] for e in unacknowledged
                      if e["ticket"] == ticket and first <= e["id"] <= last]
            if not events:
                continue  # already acknowledged: nothing left to cover
            payload = read_json(inbox / (message_id + ".json"), {})
            valid = isinstance(payload, dict) and payload.get("id") == message_id
            messages[message_id] = {"ticket": ticket, "events": events, "status": "sent",
                                    "sent": time.time(), "attempt": int(match.group(3) or 1),
                                    "payload": payload if valid else None, "recovered": True}
            log(f"inbox: recovered notice {message_id} for #{ticket} (events "
                f"{', '.join(map(str, events))})")
        except Exception as error:  # this notice only
            log(f"inbox: {message_id} not recovered: {type(error).__name__}: {error}")


def settle_receipt(root, inbox, message_id, record, now):
    receipt = read_receipt(inbox, message_id)
    if receipt == "invalid":
        if not record.get("invalid_receipt"):
            log(f"inbox: ignoring an invalid receipt for {message_id}")  # once per notice
        record["invalid_receipt"] = True
        receipt = None
    if receipt is None:
        # Whycode is closed, or has not looked yet. A file gone without a receipt is
        # written again under the same id: Whycode's ledger keeps it single.
        if record.get("payload") and not (inbox / (message_id + ".json")).exists() and \
                now - record.get("sent", now) > 600:
            write_inbox_file(inbox, message_id, record["payload"])
            record["sent"] = now
        return
    status = receipt["status"]
    record["receipt"] = {k: receipt.get(k) for k in ("status", "at", "waiting", "reason",
                                                     "target")}
    if status == "delivered":
        acknowledged = [e for e in record["events"] if acknowledge(root, e, "delivered")]
        if len(acknowledged) == len(record["events"]):
            record.update(status="delivered", delivered=now)
            target = receipt.get("target") if isinstance(receipt.get("target"), dict) else {}
            log(f"inbox: #{record['ticket']} delivered to {target.get('kind', '?')} "
                f"(events {', '.join(map(str, record['events']))})")
    elif status == "rejected":
        record.update(status="rejected", rejected=now,
                      reason=str(receipt.get("reason", ""))[:300])
        log(f"inbox: #{record['ticket']} rejected: {record['reason']}")
    else:
        record["status"] = "queued"


def acknowledge(root, event_id, why):
    try:
        helper(root, ACTOR, "ack", "--event", str(event_id))
        return True
    except (OSError, ValueError) as error:
        log(f"inbox: event {event_id} ({why}) not acknowledged: {error}")
        return False


def deliver_notices(root, config, now=None):
    """Model-free, one pass: settle receipts (acknowledge on `delivered`), then send one
    notice per ticket whose newest event is an unacknowledged state change. Returns the
    inbox state the watchdog reads; never raises into the caller, and one notice's
    failure never stops another's."""
    now = now or time.time()
    path = root / INBOX_STATE
    try:
        state = ensure_inbox_scope(root, now)
        if not isinstance(state.get("messages"), dict):
            state["messages"] = {}
        inbox, unavailable = inbox_folder(config)
        state["unavailable"] = unavailable
        if inbox is None:
            write_json(path, state)
            return state
        messages = state["messages"] = valid_records(state["messages"])
        unacknowledged = inbox_events(root, state["since"])
        recover_published(root, inbox, messages, unacknowledged)
        for message_id, record in list(messages.items()):
            if record.get("status") in ("sent", "queued"):
                try:
                    settle_receipt(root, inbox, message_id, record, now)
                except Exception as error:  # this notice only
                    log(f"inbox: {message_id} not settled: {type(error).__name__}: {error}")
        unacknowledged = inbox_events(root, state["since"])  # after the acknowledgements
        # A notice holds its events while it is on its way or waits for a retry, and a
        # notice rejected for the last time keeps them with the alert. A new batch is every
        # unacknowledged event of its ticket newer than all of those, so it is a contiguous
        # range of the ticket's events, which its id names.
        held, flight, attempts = {}, set(), {}
        for record in messages.values():
            status, attempt = record["status"], record.get("attempt", 1)
            for event_id in record["events"]:
                attempts[event_id] = max(attempts.get(event_id, 0), attempt)
            if status in ("sent", "queued"):
                flight.update(record["events"])
            if status in ("sent", "queued") or status == "rejected" and (
                    attempt >= config["inbox_max_attempts"]
                    or now - record.get("rejected", now) < config["inbox_retry_minutes"] * 60):
                held[record["ticket"]] = max([held.get(record["ticket"], 0), *record["events"]])
        tickets = {}
        for event in unacknowledged:
            tickets.setdefault(event["ticket"], []).append(event)
        stamp = datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds")
        for ticket_id, pending in tickets.items():
            try:
                if pending[-1]["newest_acknowledged"]:
                    # The ticket's latest state already reached the author: a delivered
                    # notice, or the author's own command (a resubmission, a new head)
                    # whose response said so. Older events not on their way are history,
                    # not work to wake the author for.
                    for event in pending:
                        if event["id"] not in flight:
                            acknowledge(root, event["id"], "history: a newer state was told")
                    continue
                events = [e for e in pending if e["id"] > held.get(ticket_id, 0)]
                if not events:
                    continue  # the newest is on its way; older ones wait for it
                newest = events[-1]
                if newest["status"] not in NOTICE_STATUSES:
                    continue  # a receipt, start or requeue rides along with the next result
                youngest = min(age_minutes(e["created_at"], now) for e in events)
                if newest["ticket_status"] not in FINAL_STATUSES and \
                        youngest * 60 < config["inbox_settle_seconds"]:
                    continue
                attempt = max(attempts.get(e["id"], 0) for e in events) + 1
                message_id = notice_id(root, events, attempt)
                payload = notice_payload(root, config, message_id, events)
                write_inbox_file(inbox, message_id, payload)
                messages[message_id] = {"ticket": ticket_id, "events": [e["id"] for e in events],
                                        "status": "sent", "sent": now, "sent_at": stamp,
                                        "attempt": attempt, "payload": payload}
                log(f"inbox: #{ticket_id} notice {message_id} written "
                    f"(events {', '.join(str(e['id']) for e in events)})")
                write_json(path, state)  # each published notice is recorded at once
            except Exception as error:  # this ticket only
                log(f"inbox: no notice for #{ticket_id}: {type(error).__name__}: {error}")
        done = [k for k, v in messages.items() if v["status"] == "delivered"]
        for message_id in done[:-INBOX_KEPT_MESSAGES]:
            messages.pop(message_id)
        for record in messages.values():
            if record.get("status") == "delivered":
                record.pop("payload", None)  # the text lives in the queue; keep the file small
        write_json(path, state)
        return state
    except Exception as error:  # delivery must never stop a build or the watchdog
        log(f"inbox delivery failed: {type(error).__name__}: {error}")
        return read_json(path, {})


def alert_targets(root, config):
    targets = [str(root / ALERTS)]
    if config.get("alerts_mirror"):
        targets.append(str(Path(config["alerts_mirror"]).expanduser()))
    return targets


def flush(outbox):
    """Append each target's pending lines; a target that fails keeps them for the next
    check, so a destination restored later still receives every record in order."""
    remaining = {}
    for target, lines in outbox.items():
        if not lines:
            continue
        try:
            Path(target).parent.mkdir(parents=True, exist_ok=True)
            with open(target, "a") as output:
                output.write("".join(lines))
        except OSError as error:
            log(f"watchdog could not write {target}: {error}")
            remaining[target] = lines[-OUTBOX_LIMIT:]
    return remaining


def watchdog(root, config, context):
    """Model-free: compare the current findings with the last check, queue raised and
    cleared episodes for the alerts file(s) and keep a heartbeat. Delivery is the file
    only; it never notifies, changes the queue, the lock or the session, and never
    raises into the caller."""
    try:
        now = time.time()
        path = root / WATCHDOG
        previous = read_json(path, {})
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        previous.setdefault("undelivered_since", datetime.fromtimestamp(
            now, timezone.utc).isoformat(timespec="microseconds"))
        inbox = deliver_notices(root, config, now) if (root / QUEUE).is_file() else {}
        found = findings(root, config, context, previous, now, inbox) \
            if (root / QUEUE).is_file() else {}
        active = previous.get("active", {})
        outbox = previous.get("outbox", {})
        targets = alert_targets(root, config)
        records = []
        for key, detail in found.items():
            if key not in active:
                records.append({"at": stamp, "state": "raised", "condition": key, **detail})
                log("watchdog: " + detail["detail"])
        for key, detail in active.items():
            if key not in found:
                records.append({"at": stamp, "state": "cleared", "condition": key,
                                "detail": detail.get("detail", "")})
        for record in records:
            line = json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n"
            for target in targets:
                outbox.setdefault(target, []).append(line)
        outbox = flush(outbox)
        waiting = context.get("reason", "").startswith("waiting:")
        write_json(path, {"checked_at": stamp, "watcher_pid": os.getpid(),
                          "reason": context.get("reason", ""),
                          "session": bool(context.get("session")),
                          "undelivered_since": previous["undelivered_since"],
                          "waiting_since": (previous.get("waiting_since") or now) if waiting
                          else None,
                          "outbox": outbox,
                          "active": {k: {"detail": v["detail"], "since": active.get(k, {}).get(
                              "since", stamp)} for k, v in found.items()}})
    except Exception as error:  # the watchdog must never stop a build
        log(f"watchdog failed: {type(error).__name__}: {error}")


def prune_logs(directory):
    sessions = sorted(directory.glob("session-*.log"))
    for old in sessions[:-KEPT_LOGS]:
        old.unlink(missing_ok=True)


def run_session(root, config, reason, work):
    try:
        worktree = ensure_worktree(root, config)
    except (OSError, subprocess.CalledProcessError) as error:
        log(f"the integration worktree is not usable: {error}")
        return 127
    logs = root / LOGS
    logs.mkdir(mode=0o700, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    session_log = logs / f"session-{stamp}-{config['engine']}.log"
    context = {
        "reason": reason, "actor": ACTOR, "lease_pid": os.getpid(), "git_dir": str(root),
        "queue_helper": str(root / HELPER), "worktree": str(worktree),
        "open_tickets": {k: work[k] for k in ("queued", "in_progress", "retry_install")},
        "session_log": str(session_log),
        # The builder prompt keys on this: this watcher tells authors itself.
        # WHY: .project-docs/decisions/2026-11-27-build-queue-whycode-inbox.md
        "author_notices": "whycode_inbox",
    }
    rules, rules_source = builder_prompt(root, config)
    context["builder_prompt"] = rules_source
    prompt = rules + "\n\n## This run (written by the watcher)\n\n```json\n" \
        + json.dumps(context, indent=2) + "\n```\n"
    environment = {**os.environ, "WHYTAP_BUILD_QUEUE_ACTOR": ACTOR,
                   "WHYTAP_BUILDER_LEASE_PID": str(os.getpid()),
                   "WHYTAP_BUILD_QUEUE_GIT_DIR": str(root)}
    log(f"starting {config['engine']} builder session ({reason}); log {session_log.name}; "
        f"rules from {rules_source}")
    stops = {signal.SIGTERM, signal.SIGINT}
    known = {}
    with open(session_log, "ab") as output:
        os.chmod(session_log, 0o600)
        # No stop signal may land between the start and its record: a session
        # nobody remembers would get a second one beside it.
        signal.pthread_sigmask(signal.SIG_BLOCK, stops)
        try:
            process = subprocess.Popen(
                engine_command(config, worktree), stdin=subprocess.PIPE, stdout=output,
                stderr=subprocess.STDOUT, cwd=worktree, env=environment,
                start_new_session=True,
                preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, stops))
        except OSError as error:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, stops)
            output.close()
            session_log.unlink(missing_ok=True)
            log(f"the builder session could not start: {error}")
            return 127
        pgid = process.pid

        def record():
            state = read_json(root / STATE, {})
            state["session"] = {"pgid": pgid, "started": started, "lease_pid": os.getpid(),
                                "log": str(session_log), "tree": known}
            write_json(root / STATE, state)

        def finish(gone):
            state = read_json(root / STATE, {})
            if gone:
                release_integration_lock(root, os.getpid())
                state.pop("session", None)
            else:
                # Keep the lock and the record: the next run deals with what is left.
                log("part of the session is still running; its lock is kept")
            write_json(root / STATE, state)

        def forward(signum, _frame):
            log("watcher is stopping; ending the builder session")
            finish(stop_group(pgid, 60, process.poll, known))
            sys.exit(128 + signum)

        started = started_at(pgid)
        record()
        previous = {s: signal.signal(s, forward) for s in stops}
        signal.pthread_sigmask(signal.SIG_UNBLOCK, stops)
        try:
            try:
                process.stdin.write(prompt.encode())
                process.stdin.close()
            except BrokenPipeError:
                pass
            deadline = time.monotonic() + config["max_session_seconds"]
            next_check = time.monotonic() + config["watchdog_seconds"]
            while True:
                try:
                    code = process.wait(timeout=config["poll_seconds"])
                    break
                except subprocess.TimeoutExpired:
                    before = dict(known)
                    remember_tree(known, pgid)
                    if known != before:
                        record()
                if time.monotonic() > next_check:
                    next_check = time.monotonic() + config["watchdog_seconds"]
                    watchdog(root, config, {"reason": "session " + reason, "session": True,
                                            "no_progress": read_json(root / STATE, {}).get(
                                                "no_progress", 0)})
                if time.monotonic() > deadline:
                    log("session exceeded max_session_seconds; stopping it")
                    stop_group(pgid, 60, process.poll, known)
                    code = process.wait()
                    break
            gone = stop_group(pgid, 15, known=known)  # leftovers of a finished session
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
    finish(gone)
    prune_logs(logs)
    log(f"builder session exited with {code}")
    return code


def notify(config, text):
    if not config["notify"]:
        return
    try:
        subprocess.run(["osascript", "-e", "display notification " + json.dumps(text)
                        + ' with title "Whytap build queue"'], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def acquire(root, blocking=False):
    fd = os.open(root / SESSION_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def command_run(root):
    lock_fd = acquire(root)
    if lock_fd is None:
        return 0  # a watcher or its builder session is alive; arrivals simply wait in FIFO
    try:
        return watch(root)
    finally:
        os.close(lock_fd)


def ensure_watchdog_scope(root, now=None):
    """Fix the watchdog's lower bound for author events once, before any session this
    watcher starts: events from then on are in scope; history from before the watcher
    was enabled is not."""
    path = root / WATCHDOG
    state = read_json(path, {})
    if not state.get("undelivered_since"):
        # Full precision, like the queue's event stamps: rounding down would bring in
        # events from earlier in the same second.
        state["undelivered_since"] = datetime.fromtimestamp(
            now or time.time(), timezone.utc).isoformat(timespec="microseconds")
        write_json(path, state)


def watch(root):
    config = load_config(root)
    try:
        ensure_watchdog_scope(root)
    except OSError as error:
        log(f"watchdog scope could not be recorded: {error}")
    while True:
        # Before every start, also after our own session: while anything of an
        # earlier session is left, its record and lock stay and nothing new starts.
        if not reap_orphan(root, read_json(root / STATE, {})):
            return 0
        state = read_json(root / STATE, {})
        if open_work(root)["waiting_dependency"]:
            returned_stale_dependencies(root, config)
        work = open_work(root)
        before = json.dumps(state, sort_keys=True)
        start, reason = decide(work, state, config, time.time(), meeting_gate_clear, environment)
        if start and reason.startswith("queued") and returned_moved_heads(root):
            work = open_work(root)  # a returned ticket needs no builder
            start, reason = decide(work, state, config, time.time(), meeting_gate_clear,
                                   environment)
        if not start:
            watchdog(root, config, {"reason": reason, "no_progress": state.get("no_progress", 0)})
            last = str(state.get("last_reason", ""))
            if waiting_kind(last) != waiting_kind(reason) and (
                    reason != "idle" or is_wait(last)):
                log(reason)  # a wait is logged when it starts, changes kind and ends
            state["last_reason"] = reason
            if json.dumps(state, sort_keys=True) != before:
                write_json(root / STATE, state)
            return 0
        state.update(last_reason=reason, last_start=time.time())
        write_json(root / STATE, state)
        trim_notes(root, config)  # under the session lock: no session writes them now
        code = run_session(root, config, reason, work)
        after = open_work(root)
        state = read_json(root / STATE, {})
        unchanged = after["fingerprint"] == work["fingerprint"]
        if reason == "retry_install":
            state["last_install_attempt"] = time.time()
        state["no_progress"] = state.get("no_progress", 0) + 1 if unchanged else 0
        if unchanged and state["no_progress"] == len(BACKOFF_SECONDS):
            notify(config, "The builder session keeps exiting without progress. "
                           "Run the watcher's status command.")
        state.update(last_exit=time.time(), last_exit_code=code,
                     fingerprint=after["fingerprint"])
        write_json(root / STATE, state)


def summary(root):
    config = load_config(root)
    state = read_json(root / STATE, {})
    work = open_work(root)
    probe = acquire(root)
    if probe is not None:
        os.close(probe)
    start, reason = decide(work, dict(state), config, time.time(), lambda _config: True,
                           environment)
    return {"session_running": probe is None, "would_start": start, "reason": reason,
            "watchdog": read_json(root / WATCHDOG, {}),
            "open": {k: v for k, v in work.items() if k != "fingerprint"},
            "engine": config["engine"], "worktree": str(worktree_path(config)),
            "state": state, "logs": str(root / LOGS)}


def returned_moved_heads(root):
    """Model-free: before a session starts for queued work, the helper returns tickets
    whose PR head moved after submission to their authors. Failures only log."""
    # WHY: .project-docs/decisions/2026-11-23-builder-queue-cheap-fixes.md
    try:
        result = helper(root, ACTOR, "check-heads", check=False) or {}
    except (OSError, ValueError) as error:
        log(f"head check failed: {error}")
        return []
    returned = result.get("returned_moved_heads", [])
    if returned:
        log("returned to their authors, PR head moved: "
            + ", ".join(f"#{ticket}" for ticket in returned))
    return returned


def returned_stale_dependencies(root, config):
    """Model-free: queued tickets whose dependency has stayed blocked go back to their
    authors (as the builder, like check-heads). Failures only log."""
    try:
        result = helper(root, ACTOR, "return-stale-dependencies", "--minutes",
                        str(int(config.get("stale_dependency_minutes", 120))), check=False) or {}
    except (OSError, ValueError) as error:
        log(f"stale dependency check failed: {error}")
        return []
    returned = result.get("returned", [])
    if returned:
        log("returned to their authors, dependency still blocked: "
            + ", ".join(f"#{ticket}" for ticket in returned))
    return returned


def utf8_tail(data, limit):
    """At most `limit` newest bytes of `data`, starting at a character boundary:
    a cut never splits a multi-byte UTF-8 character."""
    if len(data) <= limit:
        return data
    tail = data[len(data) - limit:] if limit > 0 else b""
    start = 0
    while start < len(tail) and tail[start] & 0xC0 == 0x80:
        start += 1
    return tail[start:]


def tail_lines(data, limit):
    """The newest complete lines of `data` (bytes) within `limit` bytes; when even
    the newest line is longer, its newest characters. Every byte bound of the notes
    and their archive goes through here."""
    if len(data) <= limit:
        return data
    tail = data[len(data) - limit:] if limit > 0 else b""
    start = tail.find(b"\n") + 1
    return tail[start:] if 0 < start < len(tail) else utf8_tail(data, limit)


TRUNCATED = b"[...] "  # the line continues from the archive


def replace_bytes(path, data):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def trim_notes(root, config):
    """Builder notes are read at every session start: above `notes_max_bytes` (UTF-8
    bytes on disk) the file keeps its newest lines (at most NOTES_KEPT_LINES and half
    the limit) and the older lines are appended to `.old`, which keeps its newest
    NOTES_ARCHIVE_MAX_BYTES. The archive is written first, so an interruption
    duplicates lines instead of losing them. Runs only under the session lock, so no
    builder session writes the notes meanwhile."""
    path = root / NOTES
    try:
        limit = int(config.get("notes_max_bytes") or 0)
        if limit <= 0 or not path.is_file() or path.stat().st_size <= limit:
            return False
        lines = path.read_bytes().splitlines(keepends=True)
        budget = limit // 2
        kept, size = [], 0
        for line in reversed(lines):
            if kept and (len(kept) >= NOTES_KEPT_LINES or size + len(line) > budget):
                break
            kept.insert(0, line)
            size += len(line)
        moved = lines[:len(lines) - len(kept)]
        if size > budget:
            # Only the newest line is left and it alone is over the budget: the whole
            # line goes to the archive and the notes keep its newest characters.
            moved.append(kept[0])
            marker = TRUNCATED if budget > len(TRUNCATED) else b""
            kept = [marker + utf8_tail(kept[0], budget - len(marker))]
        if not moved:
            return False
        archive = root / (NOTES + ".old")
        older = archive.read_bytes() if archive.is_file() else b""
        if older and not older.endswith(b"\n"):
            older += b"\n"
        replace_bytes(archive, tail_lines(older + b"".join(moved), NOTES_ARCHIVE_MAX_BYTES))
        replace_bytes(path, b"".join(kept))
        log(f"builder notes trimmed to their last {len(kept)} lines")
        return True
    except (OSError, ValueError) as error:
        log(f"builder notes could not be trimmed: {error}")
        return False


def helper(root, actor, *arguments, check=True):
    source = SOURCES / "build-queue.py"
    script = source if source.is_file() else root / HELPER
    result = subprocess.run([sys.executable, str(script), "--actor", actor, *arguments],
                            cwd=root, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise ValueError(result.stderr.strip() or "queue helper failed")
    return json.loads(result.stdout) if result.returncode == 0 else None


def launchctl(*arguments, check=True):
    command = os.environ.get("WHYTAP_WATCHER_LAUNCHCTL", "launchctl")
    result = subprocess.run([command, *arguments], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise ValueError("launchctl " + " ".join(arguments) + ": " + result.stderr.strip())
    return result


def agent_plist():
    directory = Path(os.environ.get("WHYTAP_WATCHER_LAUNCH_AGENTS")
                     or Path.home() / "Library" / "LaunchAgents")
    return directory / (LABEL + ".plist")


def command_activate(root, arguments):
    probe = acquire(root)
    if probe is None:
        raise ValueError("A builder session is running; activate after it finishes")
    try:
        # Holding the session lock keeps a freshly loaded agent from starting a
        # session before the builder configuration is transferred.
        return activate(root, arguments)
    finally:
        os.close(probe)


def unmerged_sources(root):
    """Files that would be installed but differ from freshly fetched origin/main
    (activation installs what was reviewed and merged, not a stale or edited checkout)."""
    commit = fetched_main(root)
    if not commit:
        raise ValueError("Could not fetch origin main to compare the scripts with it; "
                         "retry online, or pass --allow-local to install this checkout anyway")
    return [name for name in ACTIVATED_SOURCES
            if show(root, commit, "scripts/" + name) != (SOURCES / name).read_bytes()]


def activate(root, arguments):
    if not arguments.allow_local:
        different = unmerged_sources(root)
        if different:
            raise ValueError("Run activate from a checkout of origin/main; these differ: "
                             + ", ".join(different) + " (--allow-local to install them anyway)")
    status = helper(root, "", "status")
    previous = status["builder"].get("builder_thread")
    if not previous:
        raise ValueError("Configure the queue builder once before activating the watcher")
    if any(t["status"] == "in_progress" for t in status["tickets"]):
        raise ValueError("A ticket is in progress; switch builders only between builds")
    if (root / INTEGRATION_LOCK).exists():
        raise ValueError("The integration lock is held; switch builders when it is free")
    config = load_config(root)
    if arguments.engine:
        config["engine"] = arguments.engine
    if arguments.model is not None:
        config["model"] = arguments.model
    if config["engine"] != "custom" and not shutil.which(config["engine"]):
        raise ValueError(config["engine"] + " is not on PATH")
    template = (SOURCES / "build-queue-watcher.plist.template").read_text()
    helper(root, "", "install")
    ensure_watchdog_scope(root)
    ensure_inbox_scope(root)
    shutil.copyfile(Path(__file__).resolve(), root / INSTALLED_WATCHER)
    shutil.copyfile(SOURCES / "build-queue-builder-prompt.md", root / INSTALLED_PROMPT)
    write_json(root / CONFIG, config)
    (root / LOGS).mkdir(mode=0o700, exist_ok=True)
    values = {"LABEL": LABEL, "PYTHON": sys.executable,
              "WATCHER": str(root / INSTALLED_WATCHER), "GIT_DIR": str(root),
              "QUEUE": str(root / QUEUE), "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
              "HOME": str(Path.home()), "LOG": str(root / LOGS / "watcher.log")}
    for key, value in values.items():
        template = template.replace("@" + key + "@", value.replace("&", "&amp;")
                                    .replace("<", "&lt;").replace(">", "&gt;"))
    plist = agent_plist()
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_text(template)
    domain = f"gui/{os.getuid()}"
    launchctl("bootout", f"{domain}/{LABEL}", check=False)
    deadline = time.monotonic() + 120  # an earlier agent may still be unloading
    while launchctl("print", f"{domain}/{LABEL}", check=False).returncode == 0:
        if time.monotonic() > deadline:
            raise ValueError("The previous LaunchAgent is still unloading; try again")
        time.sleep(1)
    launchctl("bootstrap", domain, str(plist))
    # Only now: a failed load must not leave the queue pointing at a builder nobody runs.
    state = read_json(root / STATE, {})
    if previous != ACTOR:
        state["previous_builder"] = previous
        write_json(root / STATE, state)
        helper(root, previous, "configure", "--builder-thread", ACTOR)
    return {"activated": True, "builder": ACTOR, "previous_builder": state.get("previous_builder"),
            "engine": config["engine"], "launch_agent": str(plist),
            "next": "Keep the old builder chat's automation paused; it must not claim work."}


def command_deactivate(root):
    probe = acquire(root)
    if probe is None:
        raise ValueError("A builder session is running; deactivate after it finishes")
    try:
        launchctl("bootout", f"gui/{os.getuid()}/{LABEL}", check=False)
        agent_plist().unlink(missing_ok=True)
        state = read_json(root / STATE, {})
        status = helper(root, "", "status")
        result = {"deactivated": True, "builder": status["builder"].get("builder_thread")}
        previous = state.get("previous_builder")
        if result["builder"] == ACTOR and previous:
            if any(t["status"] == "in_progress" for t in status["tickets"]):
                result["next"] = ("A ticket is still in progress under the on-demand builder; "
                                  "recover it before transferring the builder back")
            else:
                helper(root, ACTOR, "configure", "--builder-thread", previous)
                result["builder"] = previous
                result["next"] = ("Tell the previous builder chat it owns the queue again "
                                  "and resume its automation if wanted")
        return result
    finally:
        os.close(probe)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-dir", help="Shared Git common directory (default: detected)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("run", help="What launchd calls: start a session if work is open")
    commands.add_parser("status", help="Show the decision without starting anything")
    environment_command = commands.add_parser(
        "environment", help="Can a build run now (screen and load)? Exit 0 when clear, 3 when not")
    environment_command.add_argument(
        "--for", dest="purpose", choices=("install", "suite"), default="install",
        help="suite: a locked screen does not stop the review, the full suite or the merge "
             "(protected-data tests skip and run before the install); install: it does")
    activate = commands.add_parser("activate", help="Install and load the LaunchAgent")
    activate.add_argument("--allow-local", action="store_true",
                          help="Install this checkout's scripts even if they differ from main")
    activate.add_argument("--engine", choices=("claude", "codex"))
    activate.add_argument("--model")
    commands.add_parser("deactivate", help="Unload the LaunchAgent, restore the builder")
    arguments = parser.parse_args()
    try:
        root = git_dir(arguments.git_dir)
        if arguments.command == "run":
            return command_run(root)
        if arguments.command == "environment":
            settings = load_config(root)
            result = environment(settings)
            if arguments.purpose == "suite" and settings.get("validate_while_locked", True):
                result["clear"] = result["clear_for_validation"]
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result["clear"] else 3
        if arguments.command == "status":
            result = summary(root)
        elif arguments.command == "activate":
            result = command_activate(root, arguments)
        else:
            result = command_deactivate(root)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, OSError, sqlite3.Error, subprocess.CalledProcessError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
