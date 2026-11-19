#!/usr/bin/env python3
"""Start one on-demand builder session while the build queue has open work.

WHY: .project-docs/decisions/2026-11-19-on-demand-build-queue-builder.md
A launchd agent runs `run` every minute and when the queue file changes. No
model is involved while the queue is idle. This script never merges, builds,
signs, installs or quits anything itself: it only decides whether a builder
session is needed, keeps it single, logs it and cleans up its own lease.
Only Python's standard library is required.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import time


ACTOR = "whytap-on-demand-builder"
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
DEFAULTS = {
    "engine": "codex",             # "codex", "claude" or "custom" (uses "command")
    "model": "",                   # empty: the engine's own configured default
    "worktree": "",                # empty: ~/.whytap-builder/integration
    "retry_install_seconds": 300,  # how often a deferred install rechecks the meeting gate
    "max_session_seconds": 6 * 3600,
    "poll_seconds": 2,             # how often the session's process tree is recorded
    "notify": True,
}
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
    """Read-only view of what could need a builder. Never modifies the queue."""
    path = root / QUEUE
    work = {"queued": [], "in_progress": [], "retry_install": [], "waiting_install": []}
    if not path.is_file():
        return {**work, "fingerprint": ""}
    def read():
        db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
        try:
            retry = "retry" if "retry" in {c[1] for c in db.execute(
                "PRAGMA table_info(tickets)")} else "''"
            return db.execute(
                "SELECT id, status, updated_at, " + retry + " FROM tickets WHERE status IN "
                "('queued', 'in_progress', 'pending_install') ORDER BY queued_at, id"
            ).fetchall()
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
    for ticket, status, updated, retry in rows:
        if status == "pending_install":
            status = "retry_install" if retry == "meeting" else "waiting_install"
        work[status].append(ticket)
        if status != "waiting_install":
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


def decide(work, state, config, now, gate):
    """Return (start, reason). `state` is updated when the meeting gate was consulted."""
    if work["queued"] or work["in_progress"]:
        failures = state.get("no_progress", 0)
        if failures and state.get("fingerprint") == work["fingerprint"]:
            wait = BACKOFF_SECONDS[min(failures, len(BACKOFF_SECONDS)) - 1]
            if now - state.get("last_exit", 0) < wait:
                return False, f"backoff: {failures} session(s) changed nothing, next try in " \
                              f"{int(wait - (now - state.get('last_exit', 0)))}s"
        return True, "recover_in_progress" if work["in_progress"] else "queued"
    if work["retry_install"]:
        wait = config["retry_install_seconds"]
        failures = state.get("no_progress", 0)
        if failures and state.get("fingerprint") == work["fingerprint"]:
            # The gate was clear but the install still did not happen: slow down too.
            wait = max(wait, BACKOFF_SECONDS[min(failures, len(BACKOFF_SECONDS)) - 1])
        if now - state.get("last_install_attempt", 0) < wait:
            return False, "deferred install: next meeting check not due"
        state["last_install_attempt"] = now
        if not gate(config):
            return False, "deferred install: meeting gate is not clear"
        return True, "retry_install"
    return False, "idle"


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
    }
    prompt_path = root / INSTALLED_PROMPT
    if not prompt_path.is_file():
        prompt_path = SOURCES / "build-queue-builder-prompt.md"
    prompt = prompt_path.read_text() + "\n\n## This run (written by the watcher)\n\n```json\n" \
        + json.dumps(context, indent=2) + "\n```\n"
    environment = {**os.environ, "WHYTAP_BUILD_QUEUE_ACTOR": ACTOR,
                   "WHYTAP_BUILDER_LEASE_PID": str(os.getpid()),
                   "WHYTAP_BUILD_QUEUE_GIT_DIR": str(root)}
    log(f"starting {config['engine']} builder session ({reason}); log {session_log.name}")
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
            while True:
                try:
                    code = process.wait(timeout=config["poll_seconds"])
                    break
                except subprocess.TimeoutExpired:
                    before = dict(known)
                    remember_tree(known, pgid)
                    if known != before:
                        record()
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
    config = load_config(root)
    if not reap_orphan(root, read_json(root / STATE, {})):
        return 0
    while True:
        state = read_json(root / STATE, {})
        work = open_work(root)
        before = json.dumps(state, sort_keys=True)
        start, reason = decide(work, state, config, time.time(), meeting_gate_clear)
        if not start:
            if state.get("last_reason") != reason and reason != "idle":
                log(reason)
            state["last_reason"] = reason
            if json.dumps(state, sort_keys=True) != before:
                write_json(root / STATE, state)
            return 0
        state.update(last_reason=reason, last_start=time.time())
        write_json(root / STATE, state)
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
    start, reason = decide(work, dict(state), config, time.time(), lambda _config: True)
    return {"session_running": probe is None, "would_start": start, "reason": reason,
            "open": {k: v for k, v in work.items() if k != "fingerprint"},
            "engine": config["engine"], "worktree": str(worktree_path(config)),
            "state": state, "logs": str(root / LOGS)}


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


def activate(root, arguments):
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
    activate = commands.add_parser("activate", help="Install and load the LaunchAgent")
    activate.add_argument("--engine", choices=("claude", "codex"))
    activate.add_argument("--model")
    commands.add_parser("deactivate", help="Unload the LaunchAgent, restore the builder")
    arguments = parser.parse_args()
    try:
        root = git_dir(arguments.git_dir)
        if arguments.command == "run":
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
