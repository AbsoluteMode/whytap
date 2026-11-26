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
PROMPT_SOURCE = "scripts/build-queue-builder-prompt.md"
OUTBOX_LIMIT = 500  # alert lines kept per unwritable target
ACTIVATED_SOURCES = ("build-queue.py", "build-queue-watcher.py", "build-queue-builder-prompt.md",
                     "build-queue-preview-prompt.md", "build-queue-watcher.plist.template")
# WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
# The preview lane: a second LaunchAgent runs `run-preview`, which starts preview
# sessions (build + safety checks + install for the owner's check, no review) beside a
# running validation session. Each lane has its own session lock, state and worktree;
# both replace the app only under APP_LOCK.
APP_LOCK = "whytap-app.lock"
LEASE_LOCKS = (INTEGRATION_LOCK, APP_LOCK)  # locks a dead session of this lane may leave
LANE = "builder"
PREVIEW_LABEL = "ai.whytap.build-queue-preview"
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
    "validate_while_locked": True,  # review, tests and merge go on behind a locked screen;
                                    # packaging and installs still wait for the unlock
    "stale_dependency_minutes": 120,  # return a ticket whose dependency stays blocked
    "preview_lane": False,         # set by `activate --preview-lane`
    "preview_worktree": "",        # empty: ~/.whytap-builder/preview
    "release_after_approved": 0,   # start a release batch at this many approved features
                                   # (0: only when the orchestrator says `release`)
    "notes_max_bytes": 32768,      # builder notes above this keep only their tail
}
NOTES = "whytap-builder-notes"
NOTES_KEPT_LINES = 120
PREVIEW_SESSION_LOCK = "whytap-build-queue-preview.lock"
PREVIEW_STATE = "whytap-build-queue-preview-state.json"
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
    if LANE == "preview":
        return Path(config["preview_worktree"]).expanduser() if config.get(
            "preview_worktree") else Path.home() / ".whytap-builder" / "preview"
    return Path(config["worktree"]).expanduser() if config["worktree"] else (
        Path.home() / ".whytap-builder" / "integration")


def use_preview_lane():
    """Switch this process to the preview lane: its own lock, state, logs label,
    worktree and prompt. The validation lane's files are never touched by it."""
    global LANE, STATE, SESSION_LOCK, PROMPT_SOURCE, INSTALLED_PROMPT, LEASE_LOCKS
    LANE = "preview"
    STATE = PREVIEW_STATE
    SESSION_LOCK = PREVIEW_SESSION_LOCK
    PROMPT_SOURCE = "scripts/build-queue-preview-prompt.md"
    INSTALLED_PROMPT = "whytap-build-queue-preview-prompt.md"
    LEASE_LOCKS = (APP_LOCK,)


def open_preview_work(root):
    """Read-only view of the preview lane: queued preview tickets whose dependencies are
    merged or in the train, a preview being built, or a train to rebuild after the owner
    sent a preview back. Shaped like `open_work` so `decide` applies unchanged."""
    work = {"queued": [], "in_progress": [], "retry_install": [], "waiting_install": [],
            "waiting_dependency": [], "install_first": [], "held_for_install": []}
    path = root / QUEUE
    if not path.is_file():
        return {**work, "fingerprint": ""}
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    try:
        if "lane" not in {c[1] for c in db.execute("PRAGMA table_info(tickets)")}:
            return {**work, "fingerprint": ""}
        latest = dict(db.execute("SELECT pr, status FROM tickets WHERE id IN "
                                 "(SELECT MAX(id) FROM tickets GROUP BY pr)").fetchall())
        rows = db.execute("SELECT id, status, updated_at, queued_at, depends_on FROM tickets "
                          "WHERE (status='queued' AND lane='preview') OR status='previewing' "
                          "ORDER BY queued_at, id").fetchall()
        installs = db.execute("SELECT COUNT(*) FROM tickets WHERE "
                              "status='pending_install'").fetchone()[0]
    finally:
        db.close()
    if installs:
        # A preview installs current main: merged work waiting for its own install goes
        # first (the helper refuses to claim a preview meanwhile).
        return {**work, "fingerprint": ""}
    seen = []
    for ticket, status, updated, queued, needs in rows:
        if status == "previewing":
            work["in_progress"].append(ticket)
            seen.append([ticket, status, updated])
        elif any(latest.get(pr) not in ("done", "pending_install", "awaiting_approval")
                 for pr in json.loads(needs or "[]")):
            work["waiting_dependency"].append(ticket)
        else:
            work["queued"].append(ticket)
            seen.append([ticket, status, queued])
    if not work["queued"] and not work["in_progress"]:
        try:
            status = helper(root, ACTOR, "status", "--open", check=False) or {}
        except (OSError, ValueError):
            status = {}
        if status.get("preview_rebuild"):
            work["queued"].append("rebuild")
            seen.append(["rebuild", status.get("installed_preview")])
    work["fingerprint"] = hashlib.sha256(json.dumps(seen).encode()).hexdigest() if seen else ""
    return work


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
            # Preview-lane tickets belong to the preview watcher, never to a builder session.
            lane = "AND lane != 'preview' " if "lane" in columns else ""
            # The latest ticket of each PR: a dependency is met once it is merged.
            merged = {pr for pr, status in db.execute(
                "SELECT pr, status FROM tickets WHERE id IN (SELECT MAX(id) FROM tickets "
                "GROUP BY pr)") if status in ("done", "pending_install")}
            rows = db.execute(
                "SELECT id, status, updated_at, queued_at, " + retry + ", " + depends + ", " +
                runtime + " FROM tickets WHERE status IN "
                "('queued', 'in_progress', 'pending_install', 'releasing') " + lane +
                "ORDER BY queued_at, id").fetchall()
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
        if status == "releasing":
            status = "in_progress"  # a release batch a session must finish or recover
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
    # WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
    # Only the two protected-data tests, signing and the install need an unlocked
    # screen: validation work may run behind a lock when nothing else stops it.
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
        if not check["clear"] and not (
                LANE == "builder" and config.get("validate_while_locked", True)
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
    process group ended has no live owner and no protected operation. The same holds
    for the app lock this lane's sessions take around an install."""
    for name in LEASE_LOCKS:
        lock = root / name
        owner = read_json(lock / "owner.json", {})
        if lock.is_dir() and owner.get("pid") == lease_pid and owner.get("session") == ACTOR:
            shutil.rmtree(lock)
            log(f"released the {name} lock left by the ended session")


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
            "SELECT t.id, t.pr, t.title, t.status, t.updated_at, t.source, " + retry + " AS retry, "
            "(SELECT MAX(created_at) FROM events e WHERE e.ticket = t.id) AS last_event "
            "FROM tickets t WHERE t.status IN ('queued', 'in_progress', 'pending_install', "
            "'awaiting_approval')")]
        undelivered = [dict(r) for r in db.execute(
            "SELECT e.id, e.ticket, e.created_at, t.pr, t.source FROM events e "
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


def findings(root, config, context, previous, now):
    """Conditions worth a person's attention, keyed so one episode raises once and
    clears only when its condition is resolved."""
    tickets, undelivered = ticket_rows(root, previous["undelivered_since"])
    found = {}
    open_work = any(t["status"] in ("queued", "in_progress") or t["retry"] == "meeting"
                    for t in tickets if t["status"] != "awaiting_approval")
    for t in tickets:
        name = f"#{t['id']} (PR {t['pr'].rsplit('/', 1)[-1]})"
        if t["status"] == "awaiting_approval":
            # WHY: .project-docs/decisions/2026-11-26-release-batches.md
            found[f"ready_to_check:{t['id']}"] = {
                "ticket": t["id"], "pr": t["pr"],
                "detail": f"{name} preview installed, ready for the owner's check: {t['title']}"}
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
    for e in undelivered:
        late = age_minutes(e["created_at"], now)
        if late > config["undelivered_minutes"]:
            key = f"undelivered:{e['ticket']}"
            entry = found.setdefault(key, {
                "ticket": e["ticket"], "pr": e["pr"], "events": [],
                "detail": f"#{e['ticket']} ({e['source']}) author not told: "
                          + ("no Harness Link address, inbox only" if e["source"] == "other"
                             else "event not acknowledged")})
            entry["events"].append(e["id"])
            entry["minutes"] = max(entry.get("minutes", 0), round(late))
    return found


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
    if LANE != "builder":
        return  # one watchdog: the validation lane's already sees every ticket
    try:
        now = time.time()
        path = root / WATCHDOG
        previous = read_json(path, {})
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        previous.setdefault("undelivered_since", datetime.fromtimestamp(
            now, timezone.utc).isoformat(timespec="microseconds"))
        found = findings(root, config, context, previous, now) if (root / QUEUE).is_file() \
            else {}
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
    for pattern in ("session-*.log", "preview-*.log"):
        sessions = sorted(directory.glob(pattern))
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
    session_log = logs / (f"session-{stamp}-{config['engine']}.log" if LANE == "builder"
                          else f"preview-{stamp}-{config['engine']}.log")
    context = {
        "reason": reason, "lane": LANE, "actor": ACTOR, "lease_pid": os.getpid(),
        "git_dir": str(root), "app_lock": str(root / APP_LOCK),
        "queue_helper": str(root / HELPER), "worktree": str(worktree),
        "open_tickets": {k: work[k] for k in ("queued", "in_progress", "retry_install")},
        "session_log": str(session_log),
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
        if open_work(root)["waiting_dependency"] or open_preview_work_dependencies(root):
            returned_stale_dependencies(root, config)
        if LANE == "builder":
            auto_release(root, config)
        work = current_work(root)
        before = json.dumps(state, sort_keys=True)
        start, reason = decide(work, state, config, time.time(), meeting_gate_clear, environment)
        if start and LANE == "builder" and reason.startswith("queued") \
                and returned_moved_heads(root):
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
        trim_notes(root, config)
        code = run_session(root, config, reason, work)
        after = current_work(root)
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


def open_preview_work_dependencies(root):
    """Queued preview tickets waiting for a dependency (read-only, no helper)."""
    path = root / QUEUE
    if not path.is_file():
        return False
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    try:
        if "lane" not in {c[1] for c in db.execute("PRAGMA table_info(tickets)")}:
            return False
        return db.execute("SELECT 1 FROM tickets WHERE status='queued' AND lane='preview' "
                          "AND depends_on != '[]'").fetchone() is not None
    finally:
        db.close()


def auto_release(root, config):
    """The optional count trigger: at `release_after_approved` approved features (and no
    open batch) the watcher starts a release batch as the builder. Failures only log."""
    limit = config.get("release_after_approved") or 0
    if not isinstance(limit, int) or limit <= 0 or not (root / QUEUE).is_file():
        return None
    db = sqlite3.connect((root / QUEUE).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    try:
        if "batch" not in {c[1] for c in db.execute("PRAGMA table_info(tickets)")}:
            return None
        approved = db.execute("SELECT COUNT(*) FROM tickets WHERE status='approved'").fetchone()[0]
        open_batch = db.execute("SELECT 1 FROM tickets WHERE status='releasing' OR "
                                "(status='queued' AND lane='release')").fetchone()
    finally:
        db.close()
    if approved < limit or open_batch:
        return None
    try:
        result = helper(root, ACTOR, "release", "--auto", "--by",
                        f"auto: {approved} approved features (release_after_approved)",
                        check=False) or {}
    except (OSError, ValueError) as error:
        log(f"release trigger failed: {error}")
        return None
    if result.get("batch"):
        log(f"release batch {result['batch']} started: "
            + ", ".join(f"#{t}" for t in result["tickets"]))
    return result


def trim_notes(root, config):
    """Builder notes are read at every session start: above `notes_max_bytes` the file
    keeps its last lines and the older part moves to a single .old file."""
    path = root / NOTES
    try:
        limit = int(config.get("notes_max_bytes") or 0)
        if limit <= 0 or not path.is_file() or path.stat().st_size <= limit:
            return False
        lines = path.read_text(errors="replace").splitlines(keepends=True)
        (root / (NOTES + ".old")).write_text("".join(lines[:-NOTES_KEPT_LINES]))
        temporary = path.with_name(NOTES + ".tmp")
        temporary.write_text("".join(lines[-NOTES_KEPT_LINES:]))
        temporary.replace(path)
        log(f"builder notes trimmed to their last {NOTES_KEPT_LINES} lines")
        return True
    except (OSError, ValueError) as error:
        log(f"builder notes could not be trimmed: {error}")
        return False


def current_work(root):
    return open_preview_work(root) if LANE == "preview" else open_work(root)


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


def agent_plist(label=LABEL):
    directory = Path(os.environ.get("WHYTAP_WATCHER_LAUNCH_AGENTS")
                     or Path.home() / "Library" / "LaunchAgents")
    return directory / (label + ".plist")


def both_lanes_idle(root, verb):
    """Hold both lanes' session locks (a live session of either refuses) and refuse while
    the app lock or a preview session record remains: activation and deactivation
    replace agents only between builds of both lanes."""
    probe = acquire(root)
    if probe is None:
        raise ValueError(f"A builder session is running; {verb} after it finishes")
    fd = os.open(root / PREVIEW_SESSION_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        os.close(probe)
        raise ValueError(f"A preview session is running; {verb} after it finishes")
    if (root / APP_LOCK).exists() or read_json(root / PREVIEW_STATE, {}).get("session"):
        os.close(fd)
        os.close(probe)
        raise ValueError(f"An app install or an interrupted preview is not finished; {verb} "
                         "after it is recovered")
    return probe, fd


def command_activate(root, arguments):
    probe, preview = both_lanes_idle(root, "activate")
    try:
        # Holding the session locks keeps a freshly loaded agent from starting a
        # session before the builder configuration is transferred.
        return activate(root, arguments)
    finally:
        os.close(preview)
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
    shutil.copyfile(Path(__file__).resolve(), root / INSTALLED_WATCHER)
    shutil.copyfile(SOURCES / "build-queue-builder-prompt.md", root / INSTALLED_PROMPT)
    if (SOURCES / "build-queue-preview-prompt.md").is_file():
        shutil.copyfile(SOURCES / "build-queue-preview-prompt.md",
                        root / "whytap-build-queue-preview-prompt.md")
    if arguments.preview_lane is not None:
        config["preview_lane"] = arguments.preview_lane
    write_json(root / CONFIG, config)
    if not config.get("preview_lane") and previous == ACTOR:
        helper(root, ACTOR, "preview-lane-off", check=False)  # nothing stays stranded
    if arguments.orchestrator:
        if not arguments.orchestrator_token_file:
            raise ValueError("--orchestrator needs --orchestrator-token-file")
        helper(root, previous, "configure-orchestrator", "--orchestrator",
               arguments.orchestrator, "--token-file", arguments.orchestrator_token_file)
    (root / LOGS).mkdir(mode=0o700, exist_ok=True)
    values = {"LABEL": LABEL, "PYTHON": sys.executable,
              "WATCHER": str(root / INSTALLED_WATCHER), "GIT_DIR": str(root),
              "QUEUE": str(root / QUEUE), "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
              "HOME": str(Path.home()), "LOG": str(root / LOGS / "watcher.log")}
    for key, value in values.items():
        template = template.replace("@" + key + "@", value.replace("&", "&amp;")
                                    .replace("<", "&lt;").replace(">", "&gt;"))
    domain = f"gui/{os.getuid()}"
    agents = [(LABEL, template)]
    if config.get("preview_lane"):
        # The same agent shape with its own label and command: it runs beside a
        # validation session, so a preview never waits behind a full suite.
        agents.append((PREVIEW_LABEL, template.replace(
            "<string>" + LABEL + "</string>", "<string>" + PREVIEW_LABEL + "</string>").replace(
            "<string>run</string>", "<string>run-preview</string>")))
    else:
        launchctl("bootout", f"{domain}/{PREVIEW_LABEL}", check=False)
        agent_plist(PREVIEW_LABEL).unlink(missing_ok=True)
    for label, text in agents:
        plist = agent_plist(label)
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_text(text)
        launchctl("bootout", f"{domain}/{label}", check=False)
        deadline = time.monotonic() + 120  # an earlier agent may still be unloading
        while launchctl("print", f"{domain}/{label}", check=False).returncode == 0:
            if time.monotonic() > deadline:
                raise ValueError("The previous LaunchAgent is still unloading; try again")
            time.sleep(1)
        launchctl("bootstrap", domain, str(plist))
    plist = agent_plist()
    # Only now: a failed load must not leave the queue pointing at a builder nobody runs.
    state = read_json(root / STATE, {})
    if previous != ACTOR:
        state["previous_builder"] = previous
        write_json(root / STATE, state)
        helper(root, previous, "configure", "--builder-thread", ACTOR)
    return {"activated": True, "builder": ACTOR, "previous_builder": state.get("previous_builder"),
            "engine": config["engine"], "launch_agent": str(plist),
            "preview_lane": bool(config.get("preview_lane")),
            "next": "Keep the old builder chat's automation paused; it must not claim work."}


def command_deactivate(root):
    probe, preview = both_lanes_idle(root, "deactivate")
    try:
        for label in (LABEL, PREVIEW_LABEL):
            launchctl("bootout", f"gui/{os.getuid()}/{label}", check=False)
            agent_plist(label).unlink(missing_ok=True)
        state = read_json(root / STATE, {})
        status = helper(root, "", "status")
        if status["builder"].get("builder_thread") == ACTOR:
            # Queued previews would wait forever for a lane that no longer runs.
            helper(root, ACTOR, "preview-lane-off", check=False)
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
        os.close(preview)
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
        help="suite: a locked screen does not stop the full suite (protected-data tests "
             "skip and run again before the install); install: it does")
    commands.add_parser("run-preview", help="What the preview LaunchAgent calls")
    activate = commands.add_parser("activate", help="Install and load the LaunchAgent")
    activate.add_argument("--allow-local", action="store_true",
                          help="Install this checkout's scripts even if they differ from main")
    activate.add_argument("--engine", choices=("claude", "codex"))
    activate.add_argument("--model")
    activate.add_argument("--preview-lane", dest="preview_lane", action="store_true",
                          default=None, help="also load the preview LaunchAgent")
    activate.add_argument("--no-preview-lane", dest="preview_lane", action="store_false",
                          help="unload the preview LaunchAgent")
    activate.add_argument("--orchestrator", help="the one actor that relays the owner's "
                                                 "decisions (approve, reject, release)")
    activate.add_argument("--orchestrator-token-file",
                          help="a private file with that orchestrator's secret token")
    commands.add_parser("deactivate", help="Unload the LaunchAgent, restore the builder")
    arguments = parser.parse_args()
    try:
        root = git_dir(arguments.git_dir)
        if arguments.command == "run":
            return command_run(root)
        if arguments.command == "environment":
            result = environment(load_config(root))
            if arguments.purpose == "suite":
                # The suite may run behind a locked screen: the protected-data tests
                # skip and run again before the install.
                result["clear"] = result["clear_for_validation"]
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result["clear"] else 3
        if arguments.command == "run-preview":
            use_preview_lane()
            if not load_config(root).get("preview_lane"):
                return 0  # not enabled: `activate --preview-lane`
            return command_run(root)
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
