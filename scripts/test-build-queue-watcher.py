#!/usr/bin/env python3
"""Exercise the on-demand builder watcher with a disposable repository, queue,
fake builder session, fake meeting gate and fake launchctl. Nothing here reaches
a real model, the real queue, launchd or an application."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent
QUEUE = SCRIPTS / "build-queue.py"
WATCHER = SCRIPTS / "build-queue-watcher.py"
ACTOR = "whytap-on-demand-builder"

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
                             "cwd": os.getcwd()}) + "\n")
if (control / "noop").exists():
    sys.exit(0)
for ticket in queue("status")["tickets"]:
    if ticket["status"] == "pending_install" and ticket["retry"] == "meeting":
        queue("set", "--ticket", str(ticket["id"]), "--status", "done", "--note", "installed")
while True:
    claim = queue("claim")
    ticket = claim.get("ticket") or claim.get("active")
    if not ticket:
        break
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

FAKE_LAUNCHCTL = r'''#!/bin/sh
echo "$@" >> "$FAKE_CONTROL/launchctl.log"
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
                           ("launchctl", FAKE_LAUNCHCTL)):
            (base / name).write_text(body)
        (base / "launchctl").chmod(0o755)
        self.base = base
        self.env = {**os.environ, "FAKE_CONTROL": str(self.control), "FAKE_QUEUE": str(QUEUE),
                    "WHYTAP_WATCHER_LAUNCHCTL": str(base / "launchctl"),
                    "WHYTAP_WATCHER_LAUNCH_AGENTS": str(base / "LaunchAgents")}
        self.env.pop("CODEX_THREAD_ID", None)
        self.configure_watcher()
        self.queue("configure", "--builder-thread", self.builder)

    def configure_watcher(self, **overrides):
        (self.root / "whytap-build-queue-builder.json").write_text(json.dumps({
            "engine": "custom", "command": [sys.executable, str(self.base / "session.py")],
            "meeting_gate_command": [sys.executable, str(self.base / "gate.py")],
            "worktree": str(self.base / "integration"), "retry_install_seconds": 0,
            "notify": False, **overrides}))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def queue(self, *args, actor=None, ok=True):
        result = subprocess.run([sys.executable, str(QUEUE), "--actor", actor or self.builder,
                                 *args], cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def enqueue(self, pr):
        return self.queue("enqueue", "--pr", f"https://github.com/example/app/pull/{pr}",
                          "--head", self.head, "--title", "Fixture", "--checks", "Fixture",
                          "--acceptance", "Fixture", "--source", "claude",
                          "--session", "worker")["ticket"]["id"]

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

    def test_stopping_the_watcher_stops_its_session(self):
        (self.control / "hold").touch()
        self.enqueue(1)
        running = self.start_watcher()
        self.wait_for((self.control / "holding").exists, "the session to hold its build")
        session = self.sessions()[0]["pid"]
        running.send_signal(signal.SIGTERM)
        self.assertEqual(running.wait(timeout=30), 128 + signal.SIGTERM)
        self.assertFalse(self.alive(session))


class ActivationTests(WatcherTests):
    builder = "previous-builder-chat"

    def launch_agent(self):
        return self.base / "LaunchAgents" / "ai.whytap.build-queue-watcher.plist"

    def test_activate_installs_everything_and_deactivate_restores_the_builder(self):
        result = json.loads(self.watcher("activate").stdout)
        self.assertEqual(result["previous_builder"], self.builder)
        self.assertEqual(self.queue("status")["builder"]["builder_thread"], ACTOR)
        for name in ("exodia-build-queue.py", "whytap-build-queue-watcher.py",
                     "whytap-build-queue-builder-prompt.md"):
            self.assertTrue((self.root / name).is_file(), name)
        plist = self.launch_agent().read_text()
        self.assertNotIn("@", plist)
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
        self.assertIn("in progress", json.loads(self.watcher("activate", ok=False).stderr)["error"])
        self.queue("set", "--ticket", "1", "--status", "done", "--note", "x")
        (self.root / "exodia-integration.lock").mkdir()
        self.assertIn("lock", json.loads(self.watcher("activate", ok=False).stderr)["error"])
        self.assertFalse(self.launch_agent().exists())
        self.assertEqual(self.queue("status")["builder"]["builder_thread"], self.builder)


def load_tests(loader, _tests, _pattern):
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(WatcherTests))
    for name in loader.getTestCaseNames(ActivationTests):
        if name.startswith(("test_activat",)):
            suite.addTest(ActivationTests(name))
    return suite


if __name__ == "__main__":
    unittest.main()
