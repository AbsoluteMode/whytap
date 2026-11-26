#!/usr/bin/env python3
"""Exercise the on-demand builder watcher with a disposable repository, queue,
fake builder session, fake meeting gate and fake launchctl. Nothing here reaches
a real model, the real queue, launchd or an application."""

import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent
QUEUE = SCRIPTS / "build-queue.py"
WATCHER = SCRIPTS / "build-queue-watcher.py"
ACTOR = "whytap-on-demand-builder"
WORKER = "0b0e6f3a-5d1c-4a8e-9f2b-7c3d1e2f4a5b"

FAKE_SESSION = r'''
import json, os, subprocess, sys, time
from pathlib import Path
control = Path(os.environ["FAKE_CONTROL"])
root = os.environ["WHYTAP_BUILD_QUEUE_GIT_DIR"]
lease = int(os.environ["WHYTAP_BUILDER_LEASE_PID"])
def queue(*arguments):
    result = subprocess.run([sys.executable, os.environ["FAKE_QUEUE"], *arguments], cwd=root,
                            capture_output=True, text=True)
    return json.loads(result.stdout)
prompt = sys.stdin.read()
with open(control / "sessions.log", "a") as output:
    output.write(json.dumps({"pid": os.getpid(), "lease": lease,
                             "prompt": "## This run" in prompt and "FIFO" in prompt,
                             "origin_rules": "ORIGIN MAIN RULES" in prompt,
                             "cwd": os.getcwd()}) + "\n")
if (control / "noop").exists():
    sys.exit(0)
if '"lane": "preview"' in prompt:
    with open(control / "previews.log", "a") as output:
        output.write(json.dumps({"cwd": os.getcwd(), "lease": lease}) + "\n")
    import plistlib
    app = Path(os.environ["WHYTAP_INSTALLED_APP"]) / "Contents" / "Info.plist"
    def install(members):
        """What a verified install leaves behind: the app names its composition."""
        build = 1800
        if app.exists():
            build = int(plistlib.loads(app.read_bytes())["CFBundleVersion"])
        app.parent.mkdir(parents=True, exist_ok=True)
        app.write_bytes(plistlib.dumps({"CFBundleVersion": str(build + 1),
                                        "ExodiaBuildComposition": json.dumps(
                                            {"base": "", "members": members})}))
    while True:
        claim = queue("preview-claim")
        ticket = claim.get("ticket") or claim.get("active")
        train = [{"ticket": t["ticket"], "head": t["head"]}
                 for t in queue("status")["preview_train"]]
        if ticket:
            install(train + [{"ticket": ticket["id"], "head": ticket["head"]}])
            queue("set", "--ticket", str(ticket["id"]), "--status", "awaiting_approval",
                  "--note", "fake preview installed")
        elif claim.get("rebuild"):
            install(train)
        else:
            break
    sys.exit(0)
for ticket in queue("status")["tickets"]:
    if ticket["status"] == "pending_install" and ticket["retry"] in ("meeting", "first"):
        queue("set", "--ticket", str(ticket["id"]), "--status", "done", "--note", "installed")
while True:
    claim = queue("claim")
    ticket = claim.get("ticket") or claim.get("active")
    if not ticket:
        break
    if (control / "detach").exists():
        # Like an agent CLI running a tool command in its own process group.
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"],
                                 start_new_session=True)
        (control / "detached.pid").write_text(str(child.pid))
        time.sleep(1)
    if (control / "crash").exists():
        (control / "crash").unlink()
        lock = Path(root) / "exodia-integration.lock"
        lock.mkdir()
        (lock / "owner.json").write_text(json.dumps({"session": os.environ[
            "WHYTAP_BUILD_QUEUE_ACTOR"], "pid": lease}))
        sys.exit(3)
    if (control / "hold").exists():
        (control / "hold").rename(control / "holding")
        while (control / "holding").exists():
            time.sleep(0.02)
    if (control / "requeue").exists():
        queue("set", "--ticket", str(ticket["id"]), "--status", "queued", "--note", "environment")
        break
    defer = (control / "defer").exists()
    queue("set", "--ticket", str(ticket["id"]), "--status",
          "pending_install" if defer else "done", "--note", "fake result",
          *(["--retry-install"] if defer else []))
    with open(control / "handled.log", "a") as output:
        output.write(str(ticket["id"]) + "\n")
'''

FAKE_GATE = r'''
import json, os, sys
from pathlib import Path
busy = (Path(os.environ["FAKE_CONTROL"]) / "meeting").exists()
print(json.dumps({"status": "busy" if busy else "clear"}))
sys.exit(1 if busy else 0)
'''

FAKE_ENVIRONMENT = r'''
import json, os
from pathlib import Path
path = Path(os.environ["FAKE_CONTROL"]) / "environment.json"
print(path.read_text() if path.exists() else json.dumps({"screen_locked": False, "load": 1,
                                                          "cpus": 8}))
'''

FAKE_LAUNCHCTL = r'''#!/bin/sh
[ "$1" = print ] && exit 113
echo "$@" >> "$FAKE_CONTROL/launchctl.log"
[ "$1" = bootstrap ] && [ -e "$FAKE_CONTROL/bootstrap-fails" ] && exit 5
exit 0
'''


class WatcherTests(unittest.TestCase):
    builder = ACTOR

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.repo = base / "repo"
        self.control = base / "control"
        self.repo.mkdir()
        self.control.mkdir()
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/example/app.git")
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.root = self.repo / ".git"
        for name, body in (("session.py", FAKE_SESSION), ("gate.py", FAKE_GATE),
                           ("environment.py", FAKE_ENVIRONMENT),
                           ("launchctl", FAKE_LAUNCHCTL)):
            (base / name).write_text(body)
        (base / "launchctl").chmod(0o755)
        self.base = base
        self.env = {**os.environ, "FAKE_CONTROL": str(self.control), "FAKE_QUEUE": str(QUEUE),
                    "WHYTAP_WATCHER_LAUNCHCTL": str(base / "launchctl"),
                    "WHYTAP_WATCHER_LAUNCH_AGENTS": str(base / "LaunchAgents"),
                    "WHYTAP_INSTALLED_APP": str(base / "Applications" / "Whytap.app")}
        self.env.pop("CODEX_THREAD_ID", None)
        self.env.pop("CLAUDE_CODE_SESSION_ID", None)
        self.pulls = base / "pulls.git"  # GitHub's refs/pull/<n>/head, locally
        subprocess.run(["git", "init", "-q", "--bare", str(self.pulls)], check=True)
        self.env["WHYTAP_BUILD_QUEUE_PULL_REMOTE"] = str(self.pulls)
        self.configure_watcher()
        self.queue("configure", "--builder-thread", self.builder)

    def configure_watcher(self, **overrides):
        (self.root / "whytap-build-queue-builder.json").write_text(json.dumps({
            "engine": "custom", "command": [sys.executable, str(self.base / "session.py")],
            "meeting_gate_command": [sys.executable, str(self.base / "gate.py")],
            "environment_command": [sys.executable, str(self.base / "environment.py")],
            "worktree": str(self.base / "integration"), "retry_install_seconds": 0,
            "poll_seconds": 0.1, "notify": False, "prompt_from_origin": False, **overrides}))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def make_origin(self, files):
        """A local bare `origin` whose main holds `files` (path -> bytes or str)."""
        origin = self.base / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
        source = self.base / "source"
        subprocess.run(["git", "clone", "-q", str(origin), str(source)], check=True,
                       capture_output=True)
        for name, body in files.items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body if isinstance(body, bytes) else body.encode())
        for args in (("add", "-A"), ("-c", "user.name=T", "-c", "user.email=t@example.invalid",
                                     "commit", "-qm", "main"), ("push", "-q", "origin",
                                                                "HEAD:main")):
            subprocess.run(["git", *args], cwd=source, check=True, capture_output=True)
        self.git("remote", "set-url", "origin", str(origin))
        return origin

    def queue(self, *args, actor=None, ok=True):
        result = subprocess.run([sys.executable, str(QUEUE), "--actor", actor or self.builder,
                                 *args], cwd=self.repo, env=self.env, capture_output=True,
                                text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def enqueue(self, pr, *extra):
        return self.queue("enqueue", "--pr", f"https://github.com/example/app/pull/{pr}",
                          "--head", self.head, "--title", "Fixture", "--checks", "Fixture",
                          "--acceptance", "Fixture", "--source", "claude",
                          "--session", WORKER, *extra)["ticket"]["id"]

    def move_pr_head(self, pr):
        """The author pushed after submitting: the PR's head is a newer commit."""
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit",
                 "--allow-empty", "-qm", f"push to {pr}")
        moved = self.git("rev-parse", "HEAD").strip()
        self.git("push", "-q", str(self.pulls), f"{moved}:refs/pull/{pr}/head")
        return moved

    def watcher(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(WATCHER), "--git-dir", str(self.root),
                                 *args], cwd=self.repo, env=self.env, capture_output=True,
                                text=True, timeout=120)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def start_watcher(self):
        process = subprocess.Popen([sys.executable, str(WATCHER), "--git-dir", str(self.root),
                                    "run"], cwd=self.repo, env=self.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def wait_for(self, condition, what):
        deadline = time.monotonic() + 30
        while not condition():
            self.assertLess(time.monotonic(), deadline, "Timed out waiting for " + what)
            time.sleep(0.02)

    def lines(self, name):
        path = self.control / name
        return path.read_text().splitlines() if path.exists() else []

    def sessions(self):
        return [json.loads(line) for line in self.lines("sessions.log")]

    def statuses(self):
        return {t["id"]: t["status"] for t in self.queue("status")["tickets"]}

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def test_empty_queue_starts_no_session(self):
        self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.assertFalse(json.loads(self.watcher("status").stdout)["would_start"])

    def test_closed_tickets_start_no_session(self):
        first, second = self.enqueue(1), self.enqueue(2)
        self.queue("set", "--ticket", str(first), "--status", "cancelled", "--note", "x")
        self.queue("claim")
        self.queue("set", "--ticket", str(second), "--status", "blocked", "--note", "x")
        self.watcher("run")
        self.assertEqual(self.sessions(), [])

    def test_open_ticket_starts_one_session_that_drains_fifo(self):
        first, second = self.enqueue(1), self.enqueue(2)
        self.watcher("run")
        sessions = self.sessions()
        self.assertEqual(len(sessions), 1)
        self.assertTrue(sessions[0]["prompt"])
        self.assertEqual(Path(sessions[0]["cwd"]), self.base / "integration")
        self.assertEqual(self.lines("handled.log"), [str(first), str(second)])
        self.assertEqual(set(self.statuses().values()), {"done"})

    def test_arrival_during_a_build_queues_behind_the_same_session(self):
        (self.control / "hold").touch()
        first = self.enqueue(1)
        running = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the session to hold its build")
        self.assertTrue(json.loads(self.watcher("status").stdout)["session_running"])
        second = self.enqueue(2)
        self.watcher("run")  # launchd fires again because the queue file changed
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(self.statuses(), {first: "in_progress", second: "queued"})
        (self.control / "holding").unlink()
        self.assertEqual(running.wait(timeout=30), 0)
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(self.lines("handled.log"), [str(first), str(second)])

    def test_crashed_session_is_replaced_and_recovers_the_active_ticket(self):
        (self.control / "crash").touch()
        ticket = self.enqueue(1)
        self.watcher("run")
        sessions = self.sessions()
        self.assertEqual(len(sessions), 2)
        self.assertEqual(self.statuses(), {ticket: "done"})
        # The crashed session's lease named the watcher; its lock does not outlive it.
        self.assertFalse((self.root / "exodia-integration.lock").exists())

    def test_foreign_integration_lock_is_never_removed(self):
        lock = self.root / "exodia-integration.lock"
        lock.mkdir()
        (lock / "owner.json").write_text(json.dumps({"session": "feature", "pid": 1}))
        self.enqueue(1)
        self.watcher("run")
        self.assertTrue((lock / "owner.json").exists())

    def test_sessions_without_progress_back_off_until_the_queue_changes(self):
        (self.control / "noop").touch()
        self.enqueue(1)
        self.watcher("run")
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 1)
        self.assertIn("backoff", json.loads(self.watcher("status").stdout)["reason"])
        self.enqueue(2)
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 2)

    def test_deferred_install_is_retried_once_the_meeting_ends(self):
        (self.control / "defer").touch()
        (self.control / "meeting").touch()
        ticket = self.enqueue(1)
        self.watcher("run")
        self.assertEqual(self.statuses(), {ticket: "pending_install"})
        (self.control / "defer").unlink()
        self.watcher("run")
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 1)  # no model while the meeting lasts
        (self.control / "meeting").unlink()
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(self.statuses(), {ticket: "done"})

    def test_meeting_gate_is_rechecked_no_sooner_than_the_retry_interval(self):
        self.configure_watcher(retry_install_seconds=3600)
        (self.control / "defer").touch()
        (self.control / "meeting").touch()
        self.enqueue(1)
        self.watcher("run")
        (self.control / "defer").unlink()
        (self.control / "meeting").unlink()
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 1)

    def test_install_waiting_for_a_person_is_not_retried(self):
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install",
                   "--note", "needs the maintainer")
        self.watcher("run")
        self.assertEqual(self.sessions(), [])

    def test_killed_watcher_leaves_no_session_without_a_lease(self):
        (self.control / "hold").touch()
        ticket = self.enqueue(1)
        first = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the session to hold its build")
        orphan = self.sessions()[0]["pid"]
        first.kill()
        first.wait()
        self.assertTrue(self.alive(orphan))
        self.watcher("run")
        self.assertFalse(self.alive(orphan))
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(self.statuses(), {ticket: "done"})
        state = json.loads((self.root / "whytap-build-queue-watcher-state.json").read_text())
        self.assertNotIn("session", state)

    def test_tool_processes_outside_the_session_group_do_not_outlive_it(self):
        (self.control / "detach").touch()
        (self.control / "crash").touch()
        ticket = self.enqueue(1)
        self.watcher("run")
        self.assertFalse(self.alive(int((self.control / "detached.pid").read_text())))
        self.assertFalse((self.root / "exodia-integration.lock").exists())
        self.assertEqual(self.statuses(), {ticket: "done"})

    def test_unfinished_cleanup_blocks_the_next_session_and_keeps_its_record(self):
        """Processes of the first session that cannot be ended must keep their
        record and stop every later start, also for a newly arrived ticket."""
        spec = importlib.util.spec_from_file_location("watcher_under_test", WATCHER)
        watcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(watcher)
        watcher.stop_group = lambda *_arguments, **_keywords: False
        watcher.log = lambda _message: None
        (self.control / "detach").touch()
        (self.control / "crash").touch()
        first = self.enqueue(1)
        saved = dict(os.environ)
        os.environ.update(self.env)
        try:
            self.assertEqual(watcher.command_run(self.root), 0)
            leftover = int((self.control / "detached.pid").read_text())
            self.addCleanup(lambda: self.alive(leftover) and os.kill(leftover, signal.SIGKILL))
            state_path = self.root / "whytap-build-queue-watcher-state.json"
            record = json.loads(state_path.read_text())["session"]
            self.assertIn(str(leftover), record["tree"])
            self.assertEqual(len(self.sessions()), 1)
            self.assertTrue((self.root / "exodia-integration.lock").exists())
            second = self.enqueue(2)  # the queue changes; still no second session
            self.assertEqual(watcher.command_run(self.root), 0)
            self.assertEqual(len(self.sessions()), 1)
            self.assertEqual(json.loads(state_path.read_text())["session"], record)
            self.assertEqual(self.statuses(), {first: "in_progress", second: "queued"})
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.watcher("run")  # a watcher that can end the leftovers recovers everything
        self.assertFalse(self.alive(leftover))
        self.assertFalse((self.root / "exodia-integration.lock").exists())
        self.assertEqual(self.statuses(), {first: "done", second: "done"})

    def test_engine_that_cannot_start_backs_off_without_piling_up_logs(self):
        self.configure_watcher(command=[str(self.base / "no-such-engine")])
        self.enqueue(1)
        for _ in range(3):
            self.watcher("run")
        self.assertEqual(list((self.root / "whytap-build-queue-logs").glob("session-*")), [])
        self.assertIn("backoff", json.loads(self.watcher("status").stdout)["reason"])

    def test_install_that_keeps_failing_with_a_clear_gate_backs_off(self):
        (self.control / "defer").touch()
        self.enqueue(1)
        self.watcher("run")  # builds, defers; the retry session then changes nothing
        (self.control / "noop").touch()
        before = len(self.sessions())
        self.watcher("run")
        self.watcher("run")
        self.assertLessEqual(len(self.sessions()) - before, 1)

    def test_stopping_the_watcher_stops_its_session(self):
        (self.control / "hold").touch()
        self.enqueue(1)
        running = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the session to hold its build")
        session = self.sessions()[0]["pid"]
        running.send_signal(signal.SIGTERM)
        self.assertEqual(running.wait(timeout=30), 128 + signal.SIGTERM)
        self.assertFalse(self.alive(session))


    # Environment gate and watchdog (.project-docs/decisions/2026-11-23-builder-queue-watchdog.md)

    def set_environment(self, **values):
        (self.control / "environment.json").write_text(json.dumps(
            {"screen_locked": False, "load": 1, "cpus": 8, **values}))

    def alerts(self, path=None):
        path = path or self.root / "whytap-build-queue-alerts.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] \
            if path.exists() else []

    def state(self):
        return json.loads((self.root / "whytap-build-queue-watcher-state.json").read_text())

    def test_locked_screen_still_runs_validation_but_not_installs(self):
        # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
        self.enqueue(1)
        self.set_environment(screen_locked=True)
        result = self.watcher("run")
        self.assertEqual(len(self.sessions()), 1)
        self.assertIn("screen locked: validation and merge only", result.stdout + result.stderr)
        self.assertEqual(self.statuses(), {1: "done"})
        self.assertEqual(self.watcher("environment", "--for", "suite").returncode, 0)
        self.assertEqual(self.watcher("environment", ok=False).returncode, 3)
        self.configure_watcher(validate_while_locked=False)
        self.assertEqual(self.watcher("environment", "--for", "suite", ok=False).returncode, 3)

    def test_locked_screen_waits_without_backoff_when_validation_must_wait_too(self):
        self.configure_watcher(validate_while_locked=False)
        self.enqueue(1)
        self.set_environment(screen_locked=True)
        self.watcher("run")
        self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.assertEqual(self.state()["last_reason"], "waiting: screen locked")
        self.assertEqual(self.state().get("no_progress", 0), 0)
        self.assertEqual(json.loads(self.watcher("status").stdout)["reason"],
                         "waiting: screen locked")
        self.set_environment(screen_locked=False)
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(self.statuses(), {1: "done"})

    def test_overloaded_mac_waits_for_the_load_to_fall(self):
        self.enqueue(1)
        self.set_environment(load=317, cpus=14)
        self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.assertTrue(self.state()["last_reason"].startswith("waiting: load 317 on 14 CPUs"))
        self.set_environment(load=20, cpus=14)  # below 2 x 14
        self.watcher("run")
        self.assertEqual(self.statuses(), {1: "done"})

    def test_deferred_install_waits_for_unlock_before_asking_the_meeting_gate(self):
        (self.control / "defer").touch()
        (self.control / "meeting").touch()
        self.enqueue(1)
        self.watcher("run")
        (self.control / "defer").unlink()
        (self.control / "meeting").unlink()
        attempts = self.state().get("last_install_attempt")
        self.set_environment(screen_locked=True)
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(self.state().get("last_install_attempt"), attempts)
        self.assertEqual(self.state()["last_reason"], "waiting: screen locked")
        self.set_environment(screen_locked=False)
        self.watcher("run")
        self.assertEqual(self.statuses(), {1: "done"})

    def test_environment_command_reports_the_gate(self):
        self.set_environment(screen_locked=True)
        result = self.watcher("environment", ok=False)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["reason"], "screen locked")

    def test_watchdog_raises_and_clears_a_long_environment_wait_once(self):
        mirror = self.base / "orchestrator" / "alerts.jsonl"
        self.configure_watcher(environment_alert_minutes=0, alerts_mirror=str(mirror))
        self.enqueue(1)
        self.set_environment(load=317, cpus=14)
        self.watcher("run")
        self.watcher("run")
        self.watcher("run")
        raised = [a for a in self.alerts() if a["state"] == "raised"]
        self.assertEqual([a["condition"] for a in raised], ["environment_wait"])
        self.assertIn("load 317", raised[0]["detail"])
        self.set_environment(load=1)
        self.watcher("run")
        self.assertEqual([(a["state"], a["condition"]) for a in self.alerts()],
                         [("raised", "environment_wait"), ("cleared", "environment_wait")])
        self.assertEqual(self.alerts(mirror), self.alerts())
        heartbeat = json.loads((self.root / "whytap-build-queue-watchdog.json").read_text())
        self.assertEqual(heartbeat["active"], {})

    def test_watchdog_reports_a_ticket_without_events_during_a_live_session(self):
        self.configure_watcher(stall_minutes=0, watchdog_seconds=0.05)
        (self.control / "hold").touch()
        self.enqueue(1)
        running = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the session to hold its build")
        self.wait_for(lambda: any(a["condition"] == "ticket_stalled:1" for a in self.alerts()),
                      "the stall alert")
        (self.control / "holding").unlink()
        self.assertEqual(running.wait(timeout=30), 0)
        self.assertEqual(self.statuses(), {1: "done"})

    def test_watchdog_reports_an_author_the_builder_cannot_reach(self):
        self.configure_watcher(undelivered_minutes=0)
        self.set_environment(screen_locked=True)
        self.watcher("run")  # the watchdog's scope starts with its first check
        time.sleep(0.01)
        self.queue("enqueue", "--pr", "https://github.com/example/app/pull/7", "--head",
                   self.head, "--title", "Fixture", "--checks", "Fixture", "--acceptance",
                   "Fixture", "--source", "other", "--session", "agent-app-control")
        self.set_environment(screen_locked=True)
        self.watcher("run")
        alert = next(a for a in self.alerts() if a["condition"] == "undelivered:1")
        self.assertIn("inbox only", alert["detail"])

    def test_a_broken_queue_file_never_stops_the_watcher(self):
        self.enqueue(1)
        self.configure_watcher(environment_command=["/nonexistent/probe"])
        self.watcher("run")  # unknown environment does not block
        self.assertEqual(self.statuses(), {1: "done"})

    def watchdog_state(self):
        return json.loads((self.root / "whytap-build-queue-watchdog.json").read_text())

    def test_unacknowledged_event_stays_raised_after_a_day(self):
        self.configure_watcher(undelivered_minutes=0)
        self.set_environment(screen_locked=True)
        self.watcher("run")
        state = self.watchdog_state()
        state["undelivered_since"] = "2000-01-01T00:00:00+00:00"
        (self.root / "whytap-build-queue-watchdog.json").write_text(json.dumps(state))
        self.enqueue(1)
        db = sqlite3.connect(self.root / "exodia-build-queue.sqlite3")
        db.execute("UPDATE events SET created_at = '2026-01-01T00:00:00+00:00'")
        db.commit()
        db.close()
        self.watcher("run")
        self.watcher("run")
        states = [(a["state"], a["condition"]) for a in self.alerts()]
        self.assertEqual(states, [("raised", "undelivered:1")])

    def test_an_unwritable_mirror_receives_the_episode_once_it_is_restored(self):
        blocker = self.base / "blocked-parent"
        blocker.write_text("not a directory")
        mirror = blocker / "alerts.jsonl"
        self.configure_watcher(environment_alert_minutes=0, alerts_mirror=str(mirror))
        self.enqueue(1)
        self.set_environment(load=317, cpus=14)
        self.watcher("run")
        self.watcher("run")
        self.assertEqual([a["state"] for a in self.alerts()], ["raised"])
        self.assertTrue(self.watchdog_state()["outbox"][str(mirror)])
        blocker.unlink()
        self.watcher("run")
        self.assertEqual(self.alerts(mirror), self.alerts())
        self.assertEqual(self.watchdog_state()["outbox"], {})

    def test_deferred_install_without_progress_is_reported(self):
        (self.control / "defer").touch()
        (self.control / "meeting").touch()
        self.enqueue(1)
        self.watcher("run")
        state = self.state()
        state.update(no_progress=2, last_exit=time.time(), last_install_attempt=time.time())
        (self.root / "whytap-build-queue-watcher-state.json").write_text(json.dumps(state))
        self.watcher("run")
        self.assertEqual(self.state()["last_reason"],  # the meeting is still on
                         "deferred install: meeting gate is not clear; next check not due")
        self.assertIn("no_progress", [a["condition"] for a in self.alerts()])

    def test_events_of_the_first_session_are_in_the_watchdog_scope(self):
        self.enqueue(1)
        self.watcher("run")  # a fresh watcher: its first tick starts a session at once
        self.assertEqual(self.statuses(), {1: "done"})
        self.configure_watcher(undelivered_minutes=-1)
        self.watcher("run")
        self.assertIn("undelivered:1", [a["condition"] for a in self.alerts()])

    def test_deferred_install_wait_ends_when_the_queue_moves_on(self):
        (self.control / "defer").touch()
        (self.control / "meeting").touch()
        ticket = self.enqueue(1)
        output = self.watcher("run").stdout  # the session defers the install
        output += self.watcher("run").stdout  # meeting gate not clear
        output += self.watcher("run").stdout  # next meeting check not due: the same wait
        db = sqlite3.connect(self.root / "exodia-build-queue.sqlite3")
        db.execute("UPDATE tickets SET status='superseded' WHERE id=?", (ticket,))
        db.commit()
        db.close()
        output += self.watcher("run").stdout
        decisions = [line.split(" ", 1)[1] for line in output.splitlines()
                     if not line.split(" ", 1)[1].startswith(("watchdog", "starting",
                                                              "builder session"))]
        self.assertEqual([d.split(":")[0] for d in decisions], ["deferred install", "idle"], output)

    def test_a_failed_install_after_a_clear_gate_is_no_meeting_wait(self):
        (self.control / "defer").touch()
        (self.control / "noop").touch()
        self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", "1", "--status", "pending_install", "--note", "mic",
                   "--retry-install")  # deferred by an earlier session
        output = self.watcher("run").stdout  # gate clear on its only call; no progress
        output += self.watcher("run").stdout  # retry backoff
        self.assertEqual(self.state()["last_reason"],
                         "deferred install: next meeting check not due")
        self.assertNotIn("meeting gate", output)
        logs = self.root / "whytap-build-queue-logs"
        logs.mkdir(exist_ok=True)
        (logs / "watcher.log").write_text(output)
        metrics = json.loads(subprocess.check_output(
            [sys.executable, str(SCRIPTS / "build-queue-metrics.py"), "--git-dir",
             str(self.root), "--since", "2000-01-01"], text=True))
        self.assertNotIn("meeting gate", metrics["environment_wait_minutes"])

    def test_the_scope_keeps_sub_second_precision(self):
        spec = importlib.util.spec_from_file_location("watcher_scope", WATCHER)
        watcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(watcher)
        watcher.ensure_watchdog_scope(self.root, now=1767225600.7)  # 2026-01-01 00:00:00.7
        self.assertEqual(self.watchdog_state()["undelivered_since"],
                         "2026-01-01T00:00:00.700000+00:00")
        self.configure_watcher(undelivered_minutes=-1)
        self.set_environment(load=317, cpus=14)
        before, after = self.enqueue(1), self.enqueue(2)
        db = sqlite3.connect(self.root / "exodia-build-queue.sqlite3")
        for ticket, stamp in ((before, "00:00:00.400000"), (after, "00:00:00.800000")):
            db.execute("UPDATE events SET created_at=? WHERE ticket=?",
                       (f"2026-01-01T{stamp}+00:00", ticket))
        db.commit()
        db.close()
        self.watcher("run")
        conditions = [a["condition"] for a in self.alerts()]
        self.assertIn(f"undelivered:{after}", conditions)
        self.assertNotIn(f"undelivered:{before}", conditions)

    # Preview lane (.project-docs/decisions/2026-11-26-preview-before-validation.md)

    def preview_ticket(self, pr, name="Sources/App/Window.swift"):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        self.git("checkout", "-q", "--detach", self.head)
        (self.repo / name).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / name).write_text("ui " + str(pr))
        self.git("add", "-A")
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-qm", "ui")
        head = self.git("rev-parse", "HEAD").strip()
        return self.queue("enqueue", "--pr", f"https://github.com/example/app/pull/{pr}",
                          "--head", head, "--title", "Preview", "--checks", "branch build",
                          "--acceptance", "No lag", "--source", "claude", "--session", WORKER,
                          "--preview")["ticket"]["id"]

    def test_validation_watcher_starts_no_session_for_preview_tickets(self):
        self.configure_watcher(preview_lane=True, preview_worktree=str(self.base / "preview"))
        (self.control / "noop").touch()
        self.preview_ticket(1)
        self.watcher("run")
        self.assertEqual(self.sessions(), [])

    def test_disabled_lane_does_not_strand_a_submission(self):
        ticket = self.preview_ticket(1)  # the lane is off: normal validation
        self.watcher("run")
        self.assertEqual(self.watcher("run-preview").returncode, 0)
        self.assertFalse((self.control / "previews.log").exists())
        self.assertEqual(self.statuses()[ticket], "done")

    def orchestrator(self):
        token = self.base / "orchestrator-token"
        token.write_text("t" * 40)
        self.queue("configure-orchestrator", "--orchestrator", "orchestrator",
                   "--token-file", str(token))
        return token

    def test_activation_does_not_interrupt_active_preview(self):
        import fcntl
        self.configure_watcher(preview_lane=True)
        with (self.root / "whytap-build-queue-preview.lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.watcher("activate", "--allow-local", "--no-preview-lane", ok=False)
            self.watcher("deactivate", ok=False)
        (self.root / "whytap-app.lock").mkdir()
        error = self.watcher("activate", "--allow-local", ok=False).stderr
        self.assertIn("app install", error)
        self.assertFalse((self.control / "launchctl.log").exists())

    def test_a_stacked_preview_goes_to_validation_and_then_back_to_its_author(self):
        self.configure_watcher(preview_lane=True, preview_worktree=str(self.base / "preview"))
        (self.control / "noop").touch()
        parent = self.enqueue(9)
        self.queue("claim")
        self.queue("set", "--ticket", str(parent), "--status", "blocked", "--note", "finding")
        child = self.preview_ticket(1)
        with sqlite3.connect(self.root / "exodia-build-queue.sqlite3") as db:
            db.execute("UPDATE tickets SET depends_on=? WHERE id=?",
                       (json.dumps(["https://github.com/example/app/pull/9"]), child))
        (self.control / "noop").unlink()
        self.watcher("run-preview")  # a stacked preview is never previewed
        ticket = self.queue("status", "--ticket", str(child))["tickets"][0]
        self.assertEqual((ticket["status"], ticket["lane"]), ("queued", ""))
        self.configure_watcher(stale_dependency_minutes=0)
        (self.control / "noop").touch()
        self.watcher("run")
        self.assertEqual(self.statuses()[child], "blocked")

    def test_a_ready_preview_alerts_the_orchestrator_and_notes_stay_small(self):
        mirror = self.base / "orchestrator" / "alerts.jsonl"
        self.configure_watcher(preview_lane=True, alerts_mirror=str(mirror),
                               preview_worktree=str(self.base / "preview"), notes_max_bytes=100)
        (self.root / "whytap-builder-notes").write_text("".join(f"line {n}\n" for n in range(500)))
        preview = self.preview_ticket(1)
        self.watcher("run-preview")
        # Only the validation lane trims the notes, under its own session lock.
        self.assertEqual(len((self.root / "whytap-builder-notes").read_text().splitlines()), 500)
        self.watcher("run")
        ready = [a for a in self.alerts(mirror) if a["condition"] == f"ready_to_check:{preview}"]
        self.assertEqual([a["state"] for a in ready], ["raised"])

    def test_the_count_trigger_starts_one_release_batch(self):
        self.configure_watcher(preview_lane=True, release_after_approved=1,
                               preview_worktree=str(self.base / "preview"))
        token = self.orchestrator()
        preview = self.preview_ticket(1)
        self.watcher("run-preview")
        (self.control / "noop").touch()
        head = self.queue("status", "--ticket", str(preview))["tickets"][0]["head"]
        self.queue("approve", "--ticket", str(preview), "--head", head, "--build", "1801",
                   "--by", "owner: OK", "--note", "x", "--token-file", str(token),
                   actor="orchestrator")
        self.configure_watcher(preview_lane=True, release_after_approved=0,
                               preview_worktree=str(self.base / "preview"))
        self.watcher("run")  # the trigger is off: nothing starts
        self.assertEqual(self.queue("status", "--ticket", str(preview))["tickets"][0]["batch"], 0)
        self.configure_watcher(preview_lane=True, release_after_approved=1,
                               preview_worktree=str(self.base / "preview"))
        self.watcher("run")
        ticket = self.queue("status", "--ticket", str(preview))["tickets"][0]
        self.assertEqual(ticket["batch"], 1)

    def test_a_preview_is_installed_while_a_validation_session_runs(self):
        self.configure_watcher(preview_lane=True,
                               preview_worktree=str(self.base / "preview"))
        (self.control / "hold").touch()
        self.enqueue(9)
        running = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the validation session to hold")
        preview = self.preview_ticket(1)
        self.watcher("run-preview")
        self.assertEqual(self.statuses()[preview], "awaiting_approval")
        sessions = self.lines("previews.log")
        self.assertEqual(json.loads(sessions[0])["cwd"], str(self.base / "preview"))
        self.assertTrue((self.root / "whytap-build-queue-preview-state.json").exists())
        (self.control / "holding").unlink()
        self.assertEqual(running.wait(timeout=30), 0)
        self.assertEqual(self.statuses(), {1: "done", preview: "awaiting_approval"})
        # The owner sends it back: the preview lane rebuilds the train without it.
        token = self.orchestrator()
        head = self.queue("status", "--ticket", str(preview))["tickets"][0]["head"]
        self.queue("reject", "--ticket", str(preview), "--note", "lags", "--head", head,
                   "--build", "1801", "--token-file", str(token), actor="orchestrator")
        self.assertTrue(self.queue("status")["preview_rebuild"])
        self.watcher("run-preview")
        self.assertEqual(len(self.lines("previews.log")), 2)
        status = self.queue("status")
        self.assertFalse(status["preview_rebuild"])
        self.assertEqual(status["installed_app"]["members"], [])

    def test_activation_loads_the_preview_agent_only_when_asked(self):
        token = self.base / "orchestrator-token"
        token.write_text("t" * 40)
        error = self.watcher("activate", "--allow-local", "--preview-lane", ok=False).stderr
        self.assertIn("needs an orchestrator", error)
        self.watcher("activate", "--allow-local", "--preview-lane", "--orchestrator", ACTOR,
                     "--orchestrator-token-file", str(token), ok=False)
        self.assertFalse((self.control / "launchctl.log").exists())  # refused before changes
        self.assertNotIn("orchestrator", self.queue("status")["builder"])
        self.watcher("activate", "--allow-local", "--preview-lane", "--orchestrator",
                     "orchestrator", "--orchestrator-token-file", str(token))
        agents = self.base / "LaunchAgents"
        preview = agents / "ai.whytap.build-queue-preview.plist"
        self.assertIn("<string>run-preview</string>", preview.read_text())
        self.assertIn("<string>run</string>", (agents / "ai.whytap.build-queue-watcher.plist")
                      .read_text())
        self.assertTrue(json.loads((self.root / "whytap-build-queue-builder.json").read_text())
                        ["preview_lane"])
        self.watcher("deactivate")
        self.assertEqual(list(agents.glob("*.plist")), [])
        self.assertFalse(json.loads((self.root / "whytap-build-queue-builder.json").read_text())
                         ["preview_lane"])
        # A later --preview submission has no watcher: it goes to normal validation.
        ticket = self.preview_ticket(1)
        self.assertEqual(self.queue("status", "--ticket", str(ticket))["tickets"][0]["lane"], "")

    def test_a_moved_pr_head_goes_back_to_its_author_without_a_session(self):
        ticket = self.enqueue(1)
        moved = self.move_pr_head(1)
        result = self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.assertEqual(self.statuses(), {ticket: "blocked"})
        self.assertIn(moved, self.queue("status", "--ticket", str(ticket))["tickets"][0]["note"])
        self.assertIn(f"PR head moved: #{ticket}", result.stdout)

    def test_a_moved_head_does_not_hold_up_the_next_ticket(self):
        first = self.enqueue(1)
        self.git("push", "-q", str(self.pulls), f"{self.head}:refs/pull/2/head")
        second = self.enqueue(2)
        self.move_pr_head(1)
        self.watcher("run")
        self.assertEqual(self.statuses(), {first: "blocked", second: "done"})

    def test_a_ticket_waiting_for_its_dependency_starts_no_session(self):
        waiting = self.enqueue(2, "--depends-on", "https://github.com/example/app/pull/1")
        result = self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.assertEqual(json.loads(self.watcher("status").stdout)["open"]["waiting_dependency"],
                         [waiting])
        dependency = self.enqueue(1)
        self.watcher("run")
        self.assertEqual(self.statuses(), {dependency: "done", waiting: "done"})
        self.assertEqual(self.lines("handled.log"), [str(dependency), str(waiting)])
        self.assertNotIn("starting", result.stdout)

    def test_a_returned_ticket_keeps_its_place_and_counts_as_no_progress(self):
        (self.control / "requeue").touch()
        first, second = self.enqueue(1), self.enqueue(2)
        self.watcher("run")
        self.assertEqual(self.statuses(), {first: "queued", second: "queued"})
        self.assertEqual(self.queue("status", "--ticket", str(first))["tickets"][0]["position"], 1)
        self.assertEqual(self.state()["no_progress"], 1)
        self.assertIn("backoff", json.loads(self.watcher("status").stdout)["reason"])

    def test_an_explicit_retry_after_a_block_resets_the_backoff(self):
        (self.control / "requeue").touch()
        ticket = self.enqueue(1)
        self.watcher("run")
        self.assertIn("backoff", json.loads(self.watcher("status").stdout)["reason"])
        (self.control / "requeue").unlink()
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "blocked", "--note", "needs a fix")
        self.queue("set", "--ticket", str(ticket), "--status", "queued", "--note", "retry")
        self.watcher("run")
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(self.statuses(), {ticket: "done"})

    def test_a_grouped_install_waits_while_runtime_work_is_queued(self):
        (self.control / "defer").touch()
        (self.control / "meeting").touch()  # the gate would defer an install now
        merged = self.enqueue(1)
        self.watcher("run")  # merged, install grouped
        (self.control / "defer").unlink()
        self.enqueue(2)
        result = self.watcher("run")
        self.assertIn("builder session (queued)", result.stdout)  # no gate asked first
        self.assertEqual(self.statuses()[merged], "done")  # the fake installs the group too

    def merged_waiting(self, pr, flag="--retry-install"):
        ticket = self.enqueue(pr)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install", flag,
                   "--note", "merged; install grouped")
        return ticket

    def test_four_plus_one_installs_the_group_before_the_fifth_even_while_the_gate_is_busy(self):
        group = [self.merged_waiting(pr) for pr in (1, 2, 3, 4)]
        fifth = self.enqueue(5)  # no origin/main in this fixture: counts as runtime
        (self.control / "meeting").touch()
        self.watcher("run")
        self.assertEqual(self.sessions(), [])
        status = json.loads(self.watcher("status").stdout)
        self.assertEqual((status["open"]["install_first"], status["open"]["held_for_install"]),
                         (group, [fifth]))
        (self.control / "meeting").unlink()
        self.state_reset_install_attempt()
        result = self.watcher("run")
        self.assertIn("builder session (retry_install)", result.stdout)
        self.assertEqual(self.lines("handled.log"), [str(fifth)])  # after the group's install
        self.assertEqual(set(self.statuses().values()), {"done"})

    def state_reset_install_attempt(self):
        state = self.state()
        state["last_install_attempt"] = 0
        (self.root / "whytap-build-queue-watcher-state.json").write_text(json.dumps(state))

    def test_an_install_held_for_a_person_holds_runtime_work_but_not_documentation(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        held = self.merged_waiting(1, flag="--hold")
        runtime = self.queue("enqueue", "--pr", "https://github.com/example/app/pull/2",
                             "--head", self.make_commit("Sources/App/A.swift"), "--title", "App",
                             "--checks", "x", "--acceptance", "x", "--source", "claude",
                             "--session", WORKER)["ticket"]
        self.assertEqual(runtime["runtime"], 1)
        self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.git("checkout", "-q", "-B", "docs", self.head)
        docs = self.queue("enqueue", "--pr", "https://github.com/example/app/pull/3",
                          "--head", self.make_commit("docs/guide.md"), "--title", "Docs",
                          "--checks", "x", "--acceptance", "x", "--source", "claude",
                          "--session", WORKER)["ticket"]
        self.assertEqual(docs["runtime"], 0)
        self.watcher("run")
        self.assertEqual(self.lines("handled.log"), [str(docs["id"])])
        self.assertEqual(self.statuses(), {held: "pending_install", runtime["id"]: "queued",
                                           docs["id"]: "done"})

    def make_commit(self, path):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(path)
        self.git("add", "-A")
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-qm", path)
        return self.git("rev-parse", "HEAD").strip()

    def test_an_isolated_pr_waits_for_an_install_marked_first(self):
        first = self.merged_waiting(1, flag="--install-first")
        isolated = self.enqueue(2)
        (self.control / "meeting").touch()
        self.watcher("run")
        self.assertEqual(self.sessions(), [])
        self.assertIn("deferred install", self.state()["last_reason"])
        (self.control / "meeting").unlink()
        self.state_reset_install_attempt()
        self.watcher("run")
        self.assertEqual(self.statuses(), {first: "done", isolated: "done"})

    def test_a_hold_on_one_member_stops_the_automatic_install_of_the_group(self):
        first, held = self.merged_waiting(1), self.merged_waiting(2)
        self.queue("set", "--ticket", str(first), "--status", "pending_install", "--install-first",
                   "--note", "group, gate busy")
        # The session persisted a hold on one member, then stopped.
        self.queue("set", "--ticket", str(held), "--status", "pending_install", "--hold",
                   "--note", "a person must approve the permission prompt")
        runtime = self.enqueue(3)
        self.watcher("run")  # the gate is clear
        self.assertEqual(self.sessions(), [])
        status = json.loads(self.watcher("status").stdout)
        self.assertEqual((status["open"]["retry_install"], status["open"]["waiting_install"],
                          status["open"]["held_for_install"]), ([], [first, held], [runtime]))
        self.queue("set", "--ticket", str(held), "--status", "pending_install", "--install-first",
                   "--note", "the person acted")
        self.state_reset_install_attempt()
        self.assertIn("builder session (retry_install)", self.watcher("run").stdout)
        self.assertEqual(set(self.statuses().values()), {"done"})

    def test_oversized_numbers_in_the_probe_are_unknown(self):
        huge = "1" + "0" * 400
        for output in ('{"load": %s, "cpus": 8}' % huge, '{"load": 1, "cpus": %s}' % huge,
                       '{"load": %s, "cpus": %s}' % (huge, huge), '{"load": 1e308, "cpus": 4}'):
            (self.control / "environment.json").write_text(output)
            result = self.watcher("environment")
            self.assertTrue(json.loads(result.stdout)["clear"], output)
        self.configure_watcher(load_limit_per_cpu=int(huge))
        self.assertTrue(json.loads(self.watcher("environment").stdout)["clear"])
        self.enqueue(1)
        self.watcher("run")
        self.assertEqual(self.statuses(), {1: "done"})

    def test_malformed_or_failed_probes_are_unknown_and_never_block(self):
        for output in ("[]", '"locked"', '{"screen_locked": "yes", "load": "317", "cpus": 0}',
                       "{not json"):
            (self.control / "environment.json").write_text(output)
            result = json.loads(self.watcher("environment").stdout)
            self.assertTrue(result["clear"], output)
        failing = self.base / "failing-probe.py"
        failing.write_text('print(\'{"screen_locked": true}\'); raise SystemExit(2)\n')
        self.configure_watcher(environment_command=[sys.executable, str(failing)],
                               load_limit_per_cpu="x")
        result = json.loads(self.watcher("environment").stdout)
        self.assertTrue(result["clear"])
        self.assertEqual(result["load_limit"], 2.0 * result["cpus"])
        (self.control / "environment.json").write_text("[]")
        self.configure_watcher()
        self.enqueue(1)
        self.watcher("run")
        self.assertEqual(self.statuses(), {1: "done"})

    def test_session_reads_the_builder_rules_from_origin_main(self):
        self.enqueue(1)
        self.make_origin({"scripts/build-queue-builder-prompt.md": "ORIGIN MAIN RULES\nFIFO\n"})
        self.configure_watcher(prompt_from_origin=True)
        result = self.watcher("run")
        self.assertTrue(self.sessions()[0]["origin_rules"])
        merged = subprocess.check_output(["git", "--git-dir", str(self.base / "origin.git"),
                                          "rev-parse", "main"], text=True).strip()
        self.assertIn("rules from origin/main " + merged, result.stdout)

    def test_failed_fetch_uses_the_installed_rules_not_a_cached_main(self):
        self.enqueue(1)
        self.make_origin({"scripts/build-queue-builder-prompt.md": "ORIGIN MAIN RULES\nFIFO\n"})
        self.git("fetch", "-q", "origin")  # a cached origin/main exists
        self.git("remote", "set-url", "origin", str(self.base / "missing.git"))
        self.configure_watcher(prompt_from_origin=True)
        result = self.watcher("run")
        self.assertFalse(self.sessions()[0]["origin_rules"])
        self.assertNotIn("rules from origin/main", result.stdout + result.stderr)

class ActivationTests(WatcherTests):
    builder = "previous-builder-chat"

    def launch_agent(self):
        return self.base / "LaunchAgents" / "ai.whytap.build-queue-watcher.plist"

    def test_activate_installs_everything_and_deactivate_restores_the_builder(self):
        result = json.loads(self.watcher("activate", "--allow-local").stdout)
        self.assertEqual(result["previous_builder"], self.builder)
        self.assertEqual(self.queue("status")["builder"]["builder_thread"], ACTOR)
        for name in ("exodia-build-queue.py", "whytap-build-queue-watcher.py",
                     "whytap-build-queue-builder-prompt.md"):
            self.assertTrue((self.root / name).is_file(), name)
        plist = self.launch_agent().read_text()
        self.assertIsNone(re.search(r"@[A-Z_]+@", plist))  # a path may contain "@"
        self.assertIn(str(self.root / "whytap-build-queue-watcher.py"), plist)
        self.assertIn(str(self.root / "exodia-build-queue.sqlite3"), plist)
        if sys.platform == "darwin":
            subprocess.run(["plutil", "-lint", str(self.launch_agent())], check=True,
                           capture_output=True)
        self.assertIn("bootstrap gui/", self.lines("launchctl.log")[-1])
        # The installed copy works on its own, from launchd's bare environment.
        self.enqueue(1)
        subprocess.run([sys.executable, str(self.root / "whytap-build-queue-watcher.py"), "run"],
                       cwd="/", env=self.env, check=True, capture_output=True)
        self.assertEqual(self.statuses(), {1: "done"})

        result = json.loads(self.watcher("deactivate").stdout)
        self.assertEqual(result["builder"], self.builder)
        self.assertFalse(self.launch_agent().exists())
        self.assertIn("bootout gui/", self.lines("launchctl.log")[-1])
        self.queue("claim", actor=ACTOR, ok=False)

    def test_activation_waits_for_the_active_build_and_a_free_lock(self):
        self.enqueue(1)
        self.queue("claim")
        self.assertIn("in progress", json.loads(self.watcher("activate", "--allow-local", ok=False).stderr)["error"])
        self.queue("set", "--ticket", "1", "--status", "done", "--note", "x")
        (self.root / "exodia-integration.lock").mkdir()
        self.assertIn("lock", json.loads(self.watcher("activate", "--allow-local", ok=False).stderr)["error"])
        self.assertFalse(self.launch_agent().exists())
        self.assertEqual(self.queue("status")["builder"]["builder_thread"], self.builder)

    def test_activation_that_cannot_load_the_agent_keeps_the_previous_builder(self):
        (self.control / "bootstrap-fails").touch()
        self.watcher("activate", "--allow-local", ok=False)
        self.assertEqual(self.queue("status")["builder"]["builder_thread"], self.builder)

    def test_activation_fixes_the_watchdog_scope_before_any_session(self):
        path = self.root / "whytap-build-queue-watchdog.json"
        self.assertFalse(path.exists())
        self.watcher("activate", "--allow-local")
        self.assertTrue(json.loads(path.read_text())["undelivered_since"])

    def merged_scripts(self, **changed):
        names = ("build-queue.py", "build-queue-watcher.py", "build-queue-builder-prompt.md",
                 "build-queue-preview-prompt.md", "build-queue-watcher.plist.template")
        return {"scripts/" + n: changed.get(n, (SCRIPTS / n).read_bytes()) for n in names}

    def test_activation_refuses_scripts_that_differ_from_origin_main(self):
        self.make_origin(self.merged_scripts(**{"build-queue-watcher.py": b"# merged\n"}))
        error = json.loads(self.watcher("activate", ok=False).stderr)["error"]
        self.assertIn("origin/main", error)
        self.assertIn("build-queue-watcher.py", error)
        self.assertNotIn("build-queue.py,", error)
        self.assertFalse(self.launch_agent().exists())
        self.assertEqual(self.queue("status")["builder"]["builder_thread"], self.builder)

    def test_activation_installs_scripts_identical_to_origin_main(self):
        self.make_origin(self.merged_scripts())
        self.assertTrue(json.loads(self.watcher("activate").stdout)["activated"])

    def test_activation_refuses_a_cached_main_when_the_fetch_fails(self):
        self.make_origin(self.merged_scripts())
        self.git("fetch", "-q", "origin")
        self.git("remote", "set-url", "origin", str(self.base / "missing.git"))
        error = json.loads(self.watcher("activate", ok=False).stderr)["error"]
        self.assertIn("Could not fetch", error)
        self.assertFalse(self.launch_agent().exists())

    def test_activation_never_interrupts_a_running_session(self):
        self.watcher("activate", "--allow-local")
        (self.control / "hold").touch()
        self.enqueue(1)
        self.env["WHYTAP_BUILD_QUEUE_ACTOR"] = ACTOR
        running = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the session to hold its build")
        log = len(self.lines("launchctl.log"))
        self.assertIn("running", json.loads(self.watcher("activate", "--allow-local", ok=False).stderr)["error"])
        self.assertIn("running", json.loads(self.watcher("deactivate", ok=False).stderr)["error"])
        self.assertEqual(len(self.lines("launchctl.log")), log)
        (self.control / "holding").unlink()
        self.assertEqual(running.wait(timeout=30), 0)


def load_tests(loader, _tests, _pattern):
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(WatcherTests))
    for name in loader.getTestCaseNames(ActivationTests):
        if name.startswith(("test_activat",)):
            suite.addTest(ActivationTests(name))
    return suite


    # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
    def test_a_ticket_whose_dependency_stays_blocked_is_returned_without_a_session(self):
        self.configure_watcher(stale_dependency_minutes=0)
        (self.control / "noop").touch()
        parent = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(parent), "--status", "blocked", "--note", "finding")
        child = self.enqueue(2, "--depends-on", "https://github.com/example/app/pull/1")
        self.watcher("run")
        self.assertEqual(self.statuses()[child], "blocked")
        self.assertEqual(self.sessions(), [])

    def test_notes_keep_their_tail_and_the_archive_keeps_every_older_line(self):
        self.configure_watcher(notes_max_bytes=4000)
        notes, archive = self.root / "whytap-builder-notes", self.root / "whytap-builder-notes.old"
        notes.write_text("".join(f"first {n:03}\n" for n in range(500)))
        self.enqueue(1)
        self.watcher("run")
        kept = notes.read_text().splitlines()
        self.assertEqual((len(kept), kept[-1]), (120, "first 499"))
        self.assertEqual(archive.read_text().splitlines(),
                         [f"first {n:03}" for n in range(380)])
        # A second rotation appends; one that has nothing older to move changes nothing.
        with notes.open("a") as output:
            output.write("".join(f"second {n:03}\n" for n in range(400)))
        self.enqueue(2)
        self.watcher("run")
        self.assertEqual(notes.read_text().splitlines()[-1], "second 399")
        older = archive.read_text().splitlines()
        self.assertEqual((older[0], older[379], older[380]), ("first 000", "first 379",
                                                              "first 380"))
        self.assertEqual(len(older) + 120, 900)
        notes.write_text("x" * 5000 + "\n")
        self.enqueue(3)
        self.watcher("run")
        self.assertEqual(archive.read_text().splitlines(), older)
        self.assertEqual(len(notes.read_text()), 5001)


if __name__ == "__main__":
    unittest.main()
