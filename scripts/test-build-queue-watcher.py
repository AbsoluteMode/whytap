#!/usr/bin/env python3
"""Exercise the on-demand builder watcher with a disposable repository, queue,
fake builder session, fake meeting gate and fake launchctl. Nothing here reaches
a real model, the real queue, launchd or an application."""

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


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
                             "inbox": '"author_notices": "whycode_inbox"' in prompt,
                             "cwd": os.getcwd()}) + "\n")
if (control / "noop").exists():
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
                    "WHYTAP_WATCHER_LAUNCH_AGENTS": str(base / "LaunchAgents")}
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
            "poll_seconds": 0.1, "notify": False, "prompt_from_origin": False,
            # Never the real Whycode: a fake one only where a test makes its folder.
            "whycode_inbox": str(self.base / "Whycode" / "inbox"), "inbox_settle_seconds": 0,
            **overrides}))

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
                                 *args], cwd=self.repo, capture_output=True, text=True)
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

    def test_watchdog_reports_an_author_no_whycode_inbox_reaches(self):
        self.configure_watcher(undelivered_minutes=0)
        self.set_environment(screen_locked=True)
        self.watcher("run")  # the watchdog's scope starts with its first check
        time.sleep(0.01)
        self.queue("enqueue", "--pr", "https://github.com/example/app/pull/7", "--head",
                   self.head, "--title", "Fixture", "--checks", "Fixture", "--acceptance",
                   "Fixture", "--source", "other", "--session", "agent-app-control")
        self.queue("set", "--ticket", "1", "--status", "cancelled", "--note", "dropped")
        self.watcher("run")
        alert = next(a for a in self.alerts() if a["condition"] == "undelivered:1")
        self.assertIn("Whycode is not installed", alert["detail"])

    def test_a_broken_queue_file_never_stops_the_watcher(self):
        self.enqueue(1)
        self.configure_watcher(environment_command=["/nonexistent/probe"])
        self.watcher("run")  # unknown environment does not block
        self.assertEqual(self.statuses(), {1: "done"})

    def cancel(self, ticket):
        """A state change the author did not cause: its event waits for a notice."""
        self.queue("set", "--ticket", str(ticket), "--status", "cancelled", "--note", "dropped")
        return ticket

    def watchdog_state(self):
        return json.loads((self.root / "whytap-build-queue-watchdog.json").read_text())

    def test_unacknowledged_event_stays_raised_after_a_day(self):
        self.configure_watcher(undelivered_minutes=0)
        self.set_environment(screen_locked=True)
        self.watcher("run")
        state = self.watchdog_state()
        state["undelivered_since"] = "2000-01-01T00:00:00+00:00"
        (self.root / "whytap-build-queue-watchdog.json").write_text(json.dumps(state))
        self.cancel(self.enqueue(1))
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
        self.cancel(before)
        self.cancel(after)
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
        # One line over the limit: archived whole, the notes keep its newest part.
        notes.write_text("x" * 5000 + "\n")
        self.enqueue(3)
        self.watcher("run")
        self.assertEqual(archive.read_text().splitlines(), older + ["x" * 5000])
        self.assertLessEqual(notes.stat().st_size, 2000)
        self.assertTrue(notes.read_text().startswith("[...] x"))

    def test_every_byte_bound_of_the_notes_counts_utf8_bytes(self):
        """Review item 5 on ticket 635: the notes and the archive stay within their
        byte bounds whatever the text, and keep whole lines where a line fits."""
        spec = importlib.util.spec_from_file_location("watcher_bytes", WATCHER)
        watcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(watcher)
        samples = {"ascii": "build ok", "two-byte": "сборка готова", "three-byte": "构建完成",
                   "four-byte": "\U0001F680\U0001F527", "mixed": "ok \u00e9 \u4e2d \U0001F680"}
        for name, text in samples.items():
            with self.subTest(name):
                lines = [f"{n:05} {text}\n".encode() for n in range(4000)]
                data = b"".join(lines)
                for limit in (1, 7, 100, 4096, len(data) - 1, len(data), len(data) + 1):
                    tail = watcher.tail_lines(data, limit)
                    self.assertLessEqual(len(tail), limit)
                    self.assertTrue(data.endswith(tail))
                    if limit >= len(lines[-1]):  # a whole line fits: only whole lines
                        self.assertTrue(tail == data or tail in
                                        [b"".join(lines[i:]) for i in range(len(lines))])
        self.configure_watcher(notes_max_bytes=4000)
        notes, archive = self.root / "whytap-builder-notes", self.root / "whytap-builder-notes.old"
        bound = watcher.NOTES_ARCHIVE_MAX_BYTES
        line = "старая заметка \U0001F680 " + "ж" * 40 + "\n"
        archive.write_text(line * (bound // len(line.encode()) + 200))  # over the bound
        notes.write_text("".join(f"{n:03} новая \U0001F527 {'ю' * 30}\n" for n in range(400)))
        self.enqueue(1)
        self.watcher("run")
        self.assertLessEqual(notes.stat().st_size, 4000)
        self.assertLessEqual(archive.stat().st_size, bound)
        moved = archive.read_text().splitlines()
        self.assertEqual(moved[0], line.rstrip("\n"))  # starts at a whole line
        kept = notes.read_text().splitlines()
        self.assertEqual(int(moved[-1][:3]) + 1, int(kept[0][:3]))  # nothing lost between

    def test_an_overlong_line_is_bounded_without_cutting_a_character(self):
        """Review of ticket 641: every shape of overlong line, every cut offset."""
        spec = importlib.util.spec_from_file_location("watcher_cuts", WATCHER)
        watcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(watcher)
        for char in ("a", "é", "中", "\U0001F680"):
            line = (char * 60 + "\n").encode()
            for limit in range(0, len(line) + 2):
                with self.subTest(char=char, limit=limit):
                    for cut in (watcher.utf8_tail(line, limit), watcher.tail_lines(line * 3, limit)):
                        self.assertLessEqual(len(cut), limit)
                        cut.decode("utf-8")  # never a split character
        notes, archive = self.root / "whytap-builder-notes", self.root / "whytap-builder-notes.old"
        rocket = "\U0001F680" * 60  # 240 bytes on one line
        shapes = {"alone": [rocket], "newest after older lines": ["older one", "older two", rocket],
                  "oldest before short lines": [rocket, "newer one", "newer two"]}
        for number, (shape, lines) in enumerate(shapes.items(), 1):
            with self.subTest(shape):
                archive.unlink(missing_ok=True)
                self.configure_watcher(notes_max_bytes=101)
                notes.write_text("\n".join(lines) + "\n")
                self.enqueue(number)
                self.watcher("run")
                kept, moved = notes.read_bytes(), archive.read_bytes()
                self.assertLessEqual(len(kept), 101)
                kept.decode("utf-8"), moved.decode("utf-8")
                text = moved.decode() + kept.decode()
                for whole in lines:  # every complete line survives whole somewhere
                    self.assertIn(whole, text if whole != rocket else moved.decode())
                if lines[-1] != rocket:
                    self.assertTrue(kept.decode().endswith(lines[-1] + "\n"))

    # --- Whycode inbox notices ------------------------------------------------------
    # WHY: .project-docs/decisions/2026-11-27-build-queue-whycode-inbox.md

    def fake_whycode(self):
        if self.builder != ACTOR:
            self.skipTest("the watcher acknowledges as the activated builder")
        self.inbox = self.base / "Whycode" / "inbox"
        (self.inbox / "receipts").mkdir(parents=True)
        self.watcher("run")  # like activation: notices cover events from here on
        time.sleep(0.01)

    def notices(self):
        return [json.loads(path.read_text()) for path in sorted(self.inbox.glob("*.json"))]

    def whycode_answers(self, notice, status, **extra):
        """What Whycode does: take the file, then write (or rewrite) the receipt."""
        (self.inbox / (notice["id"] + ".json")).unlink(missing_ok=True)
        (self.inbox / "receipts" / (notice["id"] + ".json")).write_text(json.dumps(
            {"version": 1, "id": notice["id"], "status": status, **extra}))

    def ticket_events(self, ticket):
        return self.queue("events", "--ticket", str(ticket))

    def test_a_blocked_author_gets_one_notice_acknowledged_only_when_delivered(self):
        self.fake_whycode()
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "blocked", "--note",
                   "FINDING-1: the refresh races the Keychain read")
        self.watcher("run")
        [notice] = self.notices()
        events = self.ticket_events(ticket)
        self.assertRegex(notice["id"], r"^whytap-build-queue:[0-9a-f]{8}:events:%d-%d$"
                         % (events[1]["id"], events[-1]["id"]))
        self.assertEqual((notice["version"], notice["project"], notice["conversation"],
                          notice["source"]), (1, str(self.repo), WORKER, "whytap-build-queue"))
        self.assertIn("blocked", notice["title"])
        for expected in ("FINDING-1: the refresh races the Keychain read",
                         "Fix every finding by class", "origin/main",
                         "enqueue --pr https://github.com/example/app/pull/1",
                         "in_progress"):  # the start rides along
            self.assertIn(expected, notice["text"])
        self.assertTrue(all(e["acknowledged_at"] is None for e in events[1:]))
        self.whycode_answers(notice, "queued", waiting="the session's turn to end")
        self.watcher("run")
        self.assertEqual(self.notices(), [])
        self.assertTrue(all(e["acknowledged_at"] is None for e in self.ticket_events(ticket)[1:]))
        self.whycode_answers(notice, "delivered", target={"kind": "session"})
        self.watcher("run")
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(ticket)))
        self.configure_watcher(undelivered_minutes=-1)
        self.watcher("run")
        self.assertEqual(self.notices(), [])
        self.assertEqual(self.alerts(), [])

    def test_a_start_rides_along_and_an_open_ticket_settles_first(self):
        self.fake_whycode()
        self.configure_watcher(validate_while_locked=False, inbox_settle_seconds=3600,
                               undelivered_minutes=-1)
        self.set_environment(screen_locked=True)
        ticket = self.enqueue(1)
        self.queue("claim")
        self.watcher("run")
        self.assertEqual(self.notices(), [])
        self.assertEqual(self.alerts(), [])  # a start alone is no state change to tell
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install", "--note",
                   "merged at abc1234; install waits for the meeting")
        self.watcher("run")
        self.assertEqual(self.notices(), [])  # still settling: more may follow at once
        self.configure_watcher(validate_while_locked=False, undelivered_minutes=-1)
        self.watcher("run")
        [notice] = self.notices()
        self.assertIn("merged, install pending", notice["title"])
        self.assertIn("install waits for the meeting", notice["text"])
        self.assertIn("Acceptance steps", notice["text"])
        self.assertIn("in_progress", notice["text"])

    def test_a_rejected_notice_alerts_at_once_and_is_retried_under_a_new_id(self):
        self.fake_whycode()
        self.configure_watcher(inbox_retry_minutes=999, inbox_max_attempts=2,
                               undelivered_minutes=999)
        self.cancel(self.enqueue(1))
        self.watcher("run")
        [first] = self.notices()
        self.whycode_answers(first, "rejected", reason="unknown project: /nowhere")
        self.watcher("run")  # raised at once, long before undelivered_minutes
        alert = next(a for a in self.alerts() if a["condition"] == "undelivered:1")
        self.assertIn("unknown project: /nowhere", alert["detail"])
        self.assertEqual(self.notices(), [])  # the retry waits for its interval
        self.configure_watcher(inbox_retry_minutes=0, inbox_max_attempts=2,
                               undelivered_minutes=999)
        self.watcher("run")
        [second] = self.notices()
        self.assertEqual(second["id"], first["id"] + ".r2")
        self.whycode_answers(second, "rejected", reason="rate cap: 50 waiting")
        self.watcher("run")
        self.watcher("run")
        self.assertEqual(self.notices(), [])  # attempts used up: only the alert remains
        alerts = [(a["state"], a.get("detail", "")) for a in self.alerts()]
        self.assertEqual([state for state, _ in alerts], ["raised", "cleared", "raised"])
        self.assertIn("rate cap: 50 waiting", alerts[-1][1])

    def test_a_notice_lost_without_a_receipt_is_written_again_under_its_id(self):
        self.fake_whycode()
        self.cancel(self.enqueue(1))
        self.watcher("run")
        [notice] = self.notices()
        self.watcher("run")  # Whycode is closed: nothing is sent twice
        self.assertEqual([n["id"] for n in self.notices()], [notice["id"]])
        (self.inbox / (notice["id"] + ".json")).unlink()
        self.watcher("run")  # no file and no receipt: the same id again, idempotent
        self.assertEqual(self.notices(), [notice])

    def test_an_authors_own_resubmission_wakes_nobody(self):
        self.fake_whycode()
        self.configure_watcher(undelivered_minutes=-1)
        self.set_environment(screen_locked=True)
        self.configure_watcher(validate_while_locked=False, undelivered_minutes=-1)
        first = self.enqueue(1)
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit",
                 "--allow-empty", "-qm", "fix")
        self.head = self.git("rev-parse", "HEAD").strip()
        second = self.enqueue(1)
        self.assertEqual(self.statuses()[first], "superseded")
        self.watcher("run")
        self.assertEqual(self.notices(), [])
        self.assertEqual(self.alerts(), [])
        self.assertTrue(all(e["acknowledged_at"] for t in (first, second)
                            for e in self.ticket_events(t)))

    def test_results_from_before_the_inbox_scope_stay_with_the_alert(self):
        if self.builder != ACTOR:
            self.skipTest("the watcher acknowledges as the activated builder")
        self.configure_watcher(undelivered_minutes=-1)
        self.watcher("run")  # an older watcher: its watchdog scope began long ago
        self.cancel(self.enqueue(1))
        # This version is activated only now: the notice scope starts after the event.
        (self.root / "whytap-build-queue-inbox.json").write_text(json.dumps(
            {"since": "2999-01-01T00:00:00+00:00", "messages": {}}))
        self.inbox = self.base / "Whycode" / "inbox"
        (self.inbox / "receipts").mkdir(parents=True)
        self.watcher("run")
        self.assertEqual(self.notices(), [])
        alert = next(a for a in self.alerts() if a["condition"] == "undelivered:1")
        self.assertIn("before the inbox scope", alert["detail"])

    def watcher_module(self):
        spec = importlib.util.spec_from_file_location("watcher_inbox", WATCHER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def deliver(self, module=None):
        module = module or self.watcher_module()
        return module.deliver_notices(self.root, module.load_config(self.root))

    def test_the_prompt_keeps_harness_link_until_the_watcher_delivers_itself(self):
        # An installed watcher from before this change reads the merged prompt from
        # origin/main: without `author_notices` in its run context the builder must keep
        # delivering through Harness Link.
        prompt = (SCRIPTS / "build-queue-builder-prompt.md").read_text()
        messages = prompt[prompt.index("## Messages"):prompt.index("## End of the run")]
        self.assertIn('`"whycode_inbox"`', messages)
        self.assertIn("Missing: the installed watcher predates that delivery", messages)
        self.assertIn("`link_send`", messages)
        self.assertIn("`ack --event <id>` only after", messages)
        self.enqueue(1)
        self.watcher("run")
        self.assertTrue(self.sessions()[0]["inbox"])  # this watcher says it delivers

    def test_a_new_author_head_gets_no_outdated_block_notice(self):
        self.fake_whycode()
        first = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(first), "--status", "blocked", "--note", "finding")
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit",
                 "--allow-empty", "-qm", "new reviewed head")
        self.head = self.git("rev-parse", "HEAD").strip()
        second = self.enqueue(1)
        self.assertEqual(self.statuses(), {first: "superseded", second: "queued"})
        self.deliver()
        self.assertEqual(self.notices(), [])
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(first)))

    def queue_a_dependency_return(self):
        parent = self.enqueue(1)
        child = self.enqueue(2, "--depends-on", "https://github.com/example/app/pull/1")
        self.cancel(parent)
        self.assertIn(child, self.queue("return-stale-dependencies", "--minutes", "0")["returned"])
        return child

    def test_a_resubmitted_unchanged_head_gets_no_outdated_block_notice(self):
        self.fake_whycode()
        child = self.queue_a_dependency_return()
        self.assertEqual(self.enqueue(2), child)
        self.assertEqual(self.statuses()[child], "queued")
        self.configure_watcher(undelivered_minutes=-1)
        self.deliver()
        self.assertFalse(any(f"ticket #{child}:" in n["text"] for n in self.notices()))
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(child)))

    def test_a_dependency_return_asks_to_wait_not_to_change_code(self):
        self.fake_whycode()
        child = self.queue_a_dependency_return()
        self.deliver()
        notice = next(n for n in self.notices() if f"ticket #{child}:" in n["text"])
        self.assertIn("Resubmit once it is merged through the queue", notice["text"])
        self.assertIn("waits for its dependency", notice["title"])
        self.assertNotIn("Fix every finding by class", notice["text"])

    def test_a_moved_head_return_asks_to_enqueue_the_newer_head_only(self):
        self.fake_whycode()
        ticket = self.enqueue(1)
        self.move_pr_head(1)
        self.watcher("run")  # check-heads returns it, then the tick delivers
        [notice] = self.notices()
        self.assertIn(f"ticket #{ticket}:", notice["text"])
        self.assertIn("head moved", notice["title"])
        self.assertNotIn("Fix every finding by class", notice["text"])

    def test_a_requeue_after_a_block_replaces_the_block_notice(self):
        self.fake_whycode()
        self.configure_watcher(validate_while_locked=False, undelivered_minutes=-1)
        self.set_environment(screen_locked=True)
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "blocked", "--note", "finding")
        self.queue("set", "--ticket", str(ticket), "--status", "queued", "--note", "builder fixed it")
        self.watcher("run")
        self.assertEqual(self.notices(), [])  # the block is history; the requeue rides along
        self.assertEqual(self.alerts(), [])

    def test_a_malformed_receipt_stops_no_other_notice(self):
        self.fake_whycode()
        self.cancel(self.enqueue(1))
        self.deliver()
        [first] = self.notices()
        for bad in ("[]", "{}", json.dumps({"id": first["id"], "status": "lost"}), "not json"):
            (self.inbox / "receipts" / (first["id"] + ".json")).write_text(bad)
            self.deliver()
        second = self.cancel(self.enqueue(2))
        self.deliver()
        self.assertTrue(any(f"ticket #{second}:" in n["text"] for n in self.notices()))
        self.assertTrue(all(e["acknowledged_at"] is None for e in self.ticket_events(1)[1:]))

    def test_a_notice_published_while_its_record_fails_is_not_sent_twice(self):
        self.fake_whycode()
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install", "--note",
                   "pending marker")
        module = self.watcher_module()
        with patch.object(module, "write_json", side_effect=OSError("disk full")):
            self.deliver(module)
        [first] = self.notices()
        self.assertIn("pending marker", first["text"])
        self.queue("set", "--ticket", str(ticket), "--status", "done", "--note", "done marker")
        self.deliver()
        [second] = [n for n in self.notices() if n["id"] != first["id"]]
        self.assertIn("done marker", second["text"])
        self.assertNotIn("pending marker", second["text"])
        # Whycode took the first one meanwhile: only its receipt is left as evidence.
        state = self.root / "whytap-build-queue-inbox.json"
        state.write_text(json.dumps({**json.loads(state.read_text()), "messages": {}}))
        self.whycode_answers(first, "delivered", target={"kind": "session"})
        self.deliver()
        events = self.ticket_events(ticket)
        self.assertTrue(all(e["acknowledged_at"] for e in events if e["status"] != "done"))

    def lose_the_record_of_a_published_retry(self):
        """A rejected first attempt is recorded, then its retry is published while the
        record write fails (#696 review)."""
        self.fake_whycode()
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install", "--note",
                   "pending marker")
        self.deliver()
        [original] = self.notices()
        self.whycode_answers(original, "rejected", reason="temporary rejection")
        self.deliver()  # records the rejection
        module = self.watcher_module()
        config = module.load_config(self.root)
        later = time.time() + config["inbox_retry_minutes"] * 60 + 2
        with patch.object(module, "write_json", side_effect=OSError("disk full")):
            module.deliver_notices(self.root, config, later)
        [retry] = self.notices()
        self.assertEqual(retry["id"], original["id"] + ".r2")
        return ticket, module, config, later, retry

    def check_lost_retry(self, receipt_only, transition):
        ticket, module, config, later, retry = self.lose_the_record_of_a_published_retry()
        if receipt_only:
            self.whycode_answers(retry, "delivered", target={"kind": "session"})
        if transition:
            self.queue("set", "--ticket", str(ticket), "--status", "done", "--note",
                       "done marker")
        module.deliver_notices(self.root, config, later + 2)
        notices = [n for n in self.notices() if n["id"] != retry["id"]]
        if transition:
            [done] = notices
            self.assertIn("done marker", done["text"])
            self.assertNotIn("pending marker", done["text"])
        else:
            self.assertEqual(notices, [])  # nothing new, nothing sent twice
        if not receipt_only:
            self.whycode_answers(retry, "delivered", target={"kind": "session"})
            module.deliver_notices(self.root, config, later + 4)
        pending = [e for e in self.ticket_events(ticket) if e["status"] != "done"]
        self.assertTrue(all(e["acknowledged_at"] for e in pending), pending)
        state = json.loads((self.root / "whytap-build-queue-inbox.json").read_text())
        self.assertEqual(state["messages"][retry["id"]]["status"], "delivered")

    def test_a_lost_retry_record_is_recovered_from_its_file(self):
        self.check_lost_retry(receipt_only=False, transition=False)

    def test_a_lost_retry_record_is_recovered_from_its_file_after_a_transition(self):
        self.check_lost_retry(receipt_only=False, transition=True)

    def test_a_lost_retry_record_is_recovered_from_its_receipt(self):
        self.check_lost_retry(receipt_only=True, transition=False)

    def test_a_lost_retry_record_is_recovered_from_its_receipt_after_a_transition(self):
        self.check_lost_retry(receipt_only=True, transition=True)

    def check_unpersisted_rejection(self, receipt_only, transition):
        """The original record still says `sent` on disk: the same failed write lost both
        the rejection and the retry (#703 review)."""
        self.fake_whycode()
        self.configure_watcher(inbox_retry_minutes=0)
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install", "--note",
                   "first outcome")
        self.deliver()
        [first] = self.notices()
        self.whycode_answers(first, "rejected", reason="temporary rejection")
        if transition:
            self.queue("set", "--ticket", str(ticket), "--status", "done", "--note",
                       "latest outcome")
        module = self.watcher_module()
        with patch.object(module, "write_json", side_effect=OSError("disk full")):
            self.deliver(module)
        [retry] = self.notices()
        self.assertIn("first outcome", retry["text"])
        self.assertEqual("latest outcome" in retry["text"], transition)
        state = json.loads((self.root / "whytap-build-queue-inbox.json").read_text())
        self.assertEqual(state["messages"][first["id"]]["status"], "sent")
        if receipt_only:
            self.whycode_answers(retry, "delivered", target={"kind": "session"})
        self.deliver()
        self.assertEqual([n["id"] for n in self.notices()], [] if receipt_only else [retry["id"]])
        if not receipt_only:
            self.whycode_answers(retry, "delivered", target={"kind": "session"})
            self.deliver()
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(ticket)))
        self.assertEqual(self.notices(), [])

    def test_an_unpersisted_rejection_and_lost_retry_recover_from_the_file(self):
        self.check_unpersisted_rejection(receipt_only=False, transition=False)

    def test_an_unpersisted_rejection_and_lost_retry_recover_from_the_file_after_a_transition(self):
        self.check_unpersisted_rejection(receipt_only=False, transition=True)

    def test_an_unpersisted_rejection_and_lost_retry_recover_from_the_receipt(self):
        self.check_unpersisted_rejection(receipt_only=True, transition=False)

    def test_an_unpersisted_rejection_and_lost_retry_recover_from_the_receipt_after_a_transition(self):
        self.check_unpersisted_rejection(receipt_only=True, transition=True)

    def test_a_newer_result_goes_out_while_an_older_notice_waits_for_its_retry(self):
        self.fake_whycode()
        self.configure_watcher(inbox_retry_minutes=999)
        ticket = self.enqueue(1)
        self.queue("claim")
        self.queue("set", "--ticket", str(ticket), "--status", "pending_install", "--note",
                   "pending marker")
        self.deliver()
        [first] = self.notices()
        self.whycode_answers(first, "rejected", reason="rate cap: busy")
        self.queue("set", "--ticket", str(ticket), "--status", "done", "--note", "done marker")
        self.deliver()
        [done] = self.notices()  # not held back by the older notice's retry
        self.assertIn("done marker", done["text"])
        self.assertNotIn("pending marker", done["text"])
        newest = self.ticket_events(ticket)[-1]["id"]
        self.assertTrue(done["id"].endswith(f":events:{newest}-{newest}"))
        self.whycode_answers(done, "delivered", target={"kind": "session"})
        self.configure_watcher(inbox_retry_minutes=0, undelivered_minutes=-1)
        self.watcher("run")
        self.assertEqual(self.notices(), [])  # the older result is history now
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(ticket)))
        self.assertNotIn("undelivered:1", [a["condition"] for a in self.alerts()
                                           if a["state"] == "raised"][-1:])

    def test_structured_but_invalid_record_fields_stop_no_other_notice(self):
        self.fake_whycode()
        first = self.cancel(self.enqueue(1))
        self.deliver()
        [notice] = self.notices()
        path = self.root / "whytap-build-queue-inbox.json"
        original = json.loads(path.read_text())
        broken = [("events", None), ("events", [[]]), ("events", []), ("events", ["2"]),
                  ("events", [True]), ("attempt", "invalid"), ("attempt", 0),
                  ("status", "lost"), ("ticket", "1"), ("sent", "now"), ("payload", []),
                  ("receipt", "x"), ("reason", 7)]
        for number, (field, value) in enumerate(broken, 2):
            with self.subTest(field=field, value=value):
                state = json.loads(json.dumps(original))
                state["messages"][notice["id"]][field] = value
                path.write_text(json.dumps(state))
                other = self.cancel(self.enqueue(number))
                result = self.watcher("run")  # delivery and the watchdog read it
                self.assertNotIn("failed", result.stdout + result.stderr)
                texts = [n["text"] for n in self.notices()]
                self.assertTrue(any(f"ticket #{other}:" in text for text in texts))
                # The dropped record's notice is recovered from its file, not resent.
                self.assertEqual(sum(f"ticket #{first}:" in text for text in texts), 1)

    def journal(self):
        return self.root / "whytap-build-queue-inbox.json"

    def damage_journal(self, change):
        state = json.loads(self.journal().read_text())
        change(state)
        self.journal().write_text(json.dumps(state))

    def test_no_journal_value_can_abort_or_redirect_delivery(self):
        # #708 review: the sender keeps no state it trusts, so no value in its journal,
        # however typed, can stop a notice or acknowledge another ticket's events.
        self.fake_whycode()
        first = self.cancel(self.enqueue(1))
        self.deliver()
        [notice] = self.notices()
        self.whycode_answers(notice, "rejected", reason="fixture")
        self.deliver()
        self.assertEqual(json.loads(self.journal().read_text())["messages"][notice["id"]]
                         ["status"], "rejected")  # what people read
        damage = [("rejected", 10 ** 309), ("events", None), ("ticket", "x"),
                  ("attempt", 10 ** 309), ("status", "delivered")]
        for number, (field, value) in enumerate(damage, 2):
            with self.subTest(field=field):
                self.damage_journal(lambda state: state["messages"][notice["id"]].update(
                    {field: value}))
                other = self.cancel(self.enqueue(number))
                self.deliver()
                self.assertTrue(any(f"ticket #{other}:" in n["text"] for n in self.notices()))
                self.assertTrue(all(e["acknowledged_at"] is None
                                    for e in self.ticket_events(first)[1:]))

    def test_a_delivered_receipt_acknowledges_only_its_own_range(self):
        self.fake_whycode()
        first = self.cancel(self.enqueue(1))
        self.deliver()
        [notice] = self.notices()
        self.whycode_answers(notice, "delivered", target={"kind": "session"})
        unrelated = self.cancel(self.enqueue(2))
        unrelated_event = self.ticket_events(unrelated)[-1]["id"]
        for change in (lambda m: m.update(events=[unrelated_event]),   # another ticket's event
                       lambda m: m.update(ticket=unrelated),            # wrong ticket
                       lambda m: m.update(events=[unrelated_event + 50])):  # out of range
            self.damage_journal(lambda state: change(state["messages"][notice["id"]]))
        self.deliver()
        self.assertIsNone(self.ticket_events(unrelated)[-1]["acknowledged_at"])
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(first)))
        self.assertTrue(any(f"ticket #{unrelated}:" in n["text"] for n in self.notices()))

    def test_a_receipt_alone_settles_its_batch_without_any_journal(self):
        self.fake_whycode()
        ticket = self.cancel(self.enqueue(1))
        self.deliver()
        [notice] = self.notices()
        self.journal().write_text(json.dumps({"since": json.loads(
            self.journal().read_text())["since"]}))  # every record gone
        self.whycode_answers(notice, "delivered", target={"kind": "orchestrator"})
        self.deliver()
        self.assertTrue(all(e["acknowledged_at"] for e in self.ticket_events(ticket)))
        self.assertEqual(self.notices(), [])

    def test_evidence_that_does_not_match_the_queue_acknowledges_nothing(self):
        self.fake_whycode()
        self.configure_watcher(undelivered_minutes=999)
        first = self.cancel(self.enqueue(1))
        second = self.cancel(self.enqueue(2))
        self.deliver()
        notices = {n["id"]: n for n in self.notices()}
        sender = next(iter(notices)).rsplit(":events:", 1)[0]
        a = self.ticket_events(first)[-1]["id"]
        b = self.ticket_events(second)[-1]["id"]
        for name in (f"{sender}:events:{a}-{b}",      # a range across two tickets
                     f"{sender}:events:{b + 40}-{b + 41}",  # events the queue does not have
                     f"{sender}:events:{b}-{a}"):     # backwards
            (self.inbox / "receipts" / (name + ".json")).write_text(json.dumps(
                {"version": 1, "id": name, "status": "delivered"}))
        for notice in notices.values():
            (self.inbox / (notice["id"] + ".json")).unlink()  # Whycode took them, no answer yet
            (self.inbox / "receipts" / (notice["id"] + ".json")).write_text(json.dumps(
                {"version": 1, "id": notice["id"], "status": "queued"}))
        self.watcher("run")
        for ticket in (first, second):
            self.assertTrue(all(e["acknowledged_at"] is None
                                for e in self.ticket_events(ticket)[1:]))
        alert = next(a for a in self.alerts() if a["condition"] == "inbox_invalid")
        self.assertIn("3 Whycode inbox", alert["detail"])

    def test_the_retry_interval_runs_from_the_receipt_file_time(self):
        self.fake_whycode()
        self.configure_watcher(inbox_retry_minutes=30)
        self.cancel(self.enqueue(1))
        self.deliver()
        [notice] = self.notices()
        self.whycode_answers(notice, "rejected", reason="busy")
        self.deliver()
        self.assertEqual(self.notices(), [])  # rejected just now: not due
        receipt = self.inbox / "receipts" / (notice["id"] + ".json")
        os.utime(receipt, (time.time() - 31 * 60,) * 2)
        self.deliver()
        self.assertEqual([n["id"] for n in self.notices()], [notice["id"] + ".r2"])

    def test_a_retry_in_flight_clears_the_earlier_rejection_from_the_alert(self):
        self.fake_whycode()
        self.configure_watcher(inbox_retry_minutes=999, undelivered_minutes=999)
        self.cancel(self.enqueue(1))
        self.deliver()
        [first] = self.notices()
        self.whycode_answers(first, "rejected", reason="rate cap: busy")
        self.watcher("run")  # raised: nothing else is on its way
        self.assertEqual(self.notices(), [])
        self.configure_watcher(inbox_retry_minutes=0, undelivered_minutes=999)
        self.watcher("run")  # the retry is out: the rejection no longer counts
        self.assertEqual([n["id"] for n in self.notices()], [first["id"] + ".r2"])
        self.assertEqual([(a["state"], a["condition"]) for a in self.alerts()],
                         [("raised", "undelivered:1"), ("cleared", "undelivered:1")])

    def test_a_malformed_recovered_notice_stops_no_other_ticket(self):
        for broken in ("[]", '"text"', "7", "{", json.dumps({"id": "someone-else"})):
            with self.subTest(broken=broken):
                self.tearDown_inbox()
                self.fake_whycode()
                self.cancel(self.enqueue(len(self.statuses()) + 1))
                module = self.watcher_module()
                with patch.object(module, "write_json", side_effect=OSError("disk full")):
                    self.deliver(module)
                [notice] = self.notices()
                (self.inbox / (notice["id"] + ".json")).write_text(broken)
                second = self.cancel(self.enqueue(len(self.statuses()) + 1))
                self.deliver()
                texts = [path.read_text() for path in self.inbox.glob("*.json")]
                self.assertTrue(any(f"ticket #{second}:" in text for text in texts))

    def tearDown_inbox(self):
        """Each subtest starts with an empty fake Whycode and notice record."""
        shutil.rmtree(self.base / "Whycode", ignore_errors=True)
        (self.root / "whytap-build-queue-inbox.json").unlink(missing_ok=True)

    def test_a_corrupt_notice_record_stops_no_delivery(self):
        self.fake_whycode()
        path = self.root / "whytap-build-queue-inbox.json"
        state = json.loads(path.read_text())
        state["messages"] = {"broken": [], "also": "x"}
        path.write_text(json.dumps(state))
        ticket = self.cancel(self.enqueue(1))
        self.deliver()
        self.assertTrue(any(f"ticket #{ticket}:" in n["text"] for n in self.notices()))
        path.write_text("[]")  # an unreadable record file starts a new scope
        self.watcher("run")
        self.assertIn("since", json.loads(path.read_text()))

    def test_lengths_are_counted_in_whycodes_units(self):
        self.fake_whycode()
        ticket = self.enqueue(1, "--title", "\U0001F9EA" * 130)
        self.queue("set", "--ticket", str(ticket), "--status", "cancelled", "--note",
                   "\U0001F9EA" * 11000 + "\x01" * 9000)
        self.deliver()
        [notice] = self.notices()
        units = lambda text: len(text.encode("utf-16-le")) // 2
        self.assertLessEqual(units(notice["title"]), 200)
        self.assertLessEqual(units(notice["text"]), 20000)
        self.assertLessEqual(len(json.dumps(notice, ensure_ascii=False).encode()), 128 * 1024)
        self.assertNotIn("\ud83e", notice["text"])  # no character is cut in half
        self.assertIn("(the rest: status --ticket %d)" % ticket, notice["text"])

    def test_a_long_note_fits_whycodes_limit(self):
        self.fake_whycode()
        ticket = self.enqueue(1)
        self.queue("set", "--ticket", str(ticket), "--status", "cancelled", "--note", "x" * 30000)
        self.watcher("run")
        [notice] = self.notices()
        self.assertLessEqual(len(notice["text"]), 20000)
        self.assertIn("[...] (the rest: status --ticket %d)" % ticket, notice["text"])
        self.assertLessEqual(len(json.dumps(notice).encode()), 128 * 1024)


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
        inbox = json.loads((self.root / "whytap-build-queue-inbox.json").read_text())
        self.assertTrue(inbox["since"])

    def merged_scripts(self, **changed):
        names = ("build-queue.py", "build-queue-watcher.py", "build-queue-builder-prompt.md",
                 "build-queue-watcher.plist.template")
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


if __name__ == "__main__":
    unittest.main()
