#!/usr/bin/env python3
"""Exercise concurrency and recovery using disposable repositories only."""

from concurrent.futures import ThreadPoolExecutor
import importlib.util
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-queue.py")


# The suite runs inside agent sessions; their own identities must not leak into fixtures.
HERMETIC_ENV = {k: v for k, v in os.environ.items()
                if k not in ("CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID")}


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/example/app.git")
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.pulls = Path(self.temp.name) / "pulls.git"  # GitHub's refs/pull/<n>/head
        subprocess.run(["git", "init", "-q", "--bare", str(self.pulls)], check=True)
        self.call("configure", "--builder-thread", "builder")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def call(self, *args, actor="builder", cwd=None, ok=True, env=None):
        result = subprocess.run(["python3", str(SCRIPT), "--actor", actor, *args],
                                cwd=cwd or self.repo, capture_output=True, text=True,
                                env={**HERMETIC_ENV, "WHYTAP_BUILD_QUEUE_PULL_REMOTE": str(self.pulls),
                                     **(env or {})})
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def enqueue(self, pr=1, head=None, session="worker", cwd=None, ok=True, env=None):
        return self.call("enqueue", "--pr", f"https://github.com/example/app/pull/{pr}",
                         "--head", head or self.head, "--title", "Fixture change",
                         "--checks", "Isolated test checks", "--acceptance", "Fixture acceptance",
                         "--session", session, cwd=cwd, ok=ok, env=env)

    def commit(self, files):
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if content is None:
                path.unlink()
            else:
                path.write_text(content)
        self.git("add", "-A")
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "-qm", "documentation fixture")
        return self.git("rev-parse", "HEAD").strip()

    def fake_validators(self):
        """Stand-ins with the real scripts' names and arguments."""
        scripts = Path(self.temp.name) / "validators"
        scripts.mkdir()
        (scripts / "sync_agent_guidance.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            "root = Path(sys.argv[sys.argv.index('--project-root') + 1])\n"
            "assert '--check' in sys.argv\n"
            "same = (root / 'AGENTS.md').read_text() == "
            "(root / '.project-docs/agent-context.md').read_text()\n"
            "print('identical' if same else 'AGENTS.md differs from agent-context.md')\n"
            "sys.exit(0 if same else 1)\n")
        (scripts / "validate_project_documentation.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            "root = Path(sys.argv[sys.argv.index('--project-root') + 1])\n"
            "assert '--tracked-documentation' in sys.argv\n"
            "bad = (root / '.project-docs/decisions/bad.md').exists()\n"
            "print(str(root / '.project-docs/decisions/bad.md') + "
            "': missing reciprocal related link' if bad else 'passed')\n"
            "sys.exit(1 if bad else 0)\n")
        return {"WHYTAP_PROJECT_DOCUMENTATION_SCRIPTS": str(scripts)}

    def update(self, ticket, status):
        return self.call("set", "--ticket", str(ticket), "--status", status,
                         "--note", "Test evidence")

    def test_fifo_and_pending_install_does_not_block_next_work(self):
        first = self.enqueue()["ticket"]["id"]
        second = self.enqueue(2)["ticket"]["id"]
        self.assertEqual(self.call("claim")["ticket"]["id"], first)
        self.assertFalse(self.call("claim")["claimed"])
        self.update(first, "pending_install")
        self.assertEqual(self.call("claim")["ticket"]["id"], second)
        self.assertEqual(self.call("status")["tickets"][0]["status"], "pending_install")

    def test_simultaneous_submissions_are_idempotent(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.enqueue(), range(16)))
        self.assertEqual(sum(r["created"] for r in results), 1)
        self.assertEqual(len({r["ticket"]["id"] for r in results}), 1)

    def test_simultaneous_claims_have_one_winner(self):
        for pr in range(1, 5):
            self.enqueue(pr)
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.call("claim"), range(8)))
        self.assertEqual(sum(r["claimed"] for r in results), 1)

    def test_worktrees_share_queue_and_installed_helper(self):
        worktree = Path(self.temp.name) / "worker"
        self.git("worktree", "add", "--detach", "-q", str(worktree), "HEAD")
        self.enqueue(cwd=worktree)
        self.assertEqual(len(self.call("status")["tickets"]), 1)
        installed = self.call("install")["helper"]
        result = subprocess.check_output(["python3", installed, "status"], cwd=worktree)
        self.assertEqual(len(json.loads(result)["tickets"]), 1)

    def test_only_builder_can_claim_update_or_ack(self):
        ticket = self.enqueue()["ticket"]["id"]
        for args in (("claim",), ("set", "--ticket", str(ticket), "--status", "cancelled",
                                  "--note", "test"), ("ack", "--event", "1")):
            self.call(*args, actor="worker", ok=False)
        self.assertEqual(self.call("claim")["ticket"]["id"], ticket)

    def test_crash_does_not_expire_claim_and_retry_goes_to_back(self):
        first = self.enqueue()["ticket"]["id"]
        second = self.enqueue(2)["ticket"]["id"]
        self.call("claim")
        # Every call is a separate exited process; no TTL can reclaim active work.
        self.assertFalse(self.call("claim")["claimed"])
        self.update(first, "blocked")
        self.update(first, "queued")
        self.assertEqual(self.call("claim")["ticket"]["id"], second)

    def test_new_commit_supersedes_queued_request_but_not_active_candidate(self):
        first = self.enqueue()["ticket"]["id"]
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "new reviewed fixture")
        new_head = self.git("rev-parse", "HEAD").strip()
        new = self.enqueue(head=new_head)["ticket"]["id"]
        self.assertNotEqual(new, first)
        self.assertEqual(self.call("status")["tickets"][0]["status"], "superseded")
        self.call("claim")
        self.git("-c", "user.name=Queue Test", "-c", "user.email=queue@example.invalid",
                 "commit", "--allow-empty", "-qm", "third fixture")
        self.enqueue(head=self.git("rev-parse", "HEAD").strip(), ok=False)
        self.assertEqual(self.call("status")["tickets"][1]["head"], new_head)

    def test_resubmission_cannot_redirect_callback(self):
        self.enqueue()
        self.enqueue(session="other-worker", ok=False)
        self.assertEqual(self.call("status")["tickets"][0]["session"], "worker")

    def test_repository_rename_cannot_create_duplicate_pr_requests(self):
        self.git("remote", "set-url", "origin", "git@github.com:AbsoluteMode/whytap.git")
        def submit(repository):
            return self.call("enqueue", "--pr", f"https://github.com/AbsoluteMode/{repository}/pull/1",
                             "--head", self.head, "--title", "Fixture", "--checks", "Fixture checks",
                             "--acceptance", "Fixture acceptance", "--session", "worker")
        first = submit("exodia")
        second = submit("whytap")
        self.assertEqual(first["ticket"]["id"], second["ticket"]["id"])
        self.assertFalse(second["created"])
        self.enqueue(ok=False)

    def test_worker_cannot_change_builder_callback_host(self):
        self.call("configure", "--builder-thread", "builder", "--host", "different",
                  actor="worker", ok=False)
        self.assertEqual(self.call("status")["builder"]["builder_host"], "local")

    def test_notification_outbox_survives_restart_and_ack(self):
        self.enqueue()
        self.call("claim")
        pending = self.call("events", "--pending")
        self.assertEqual([e["status"] for e in pending], ["queued", "in_progress"])
        self.call("ack", "--event", str(pending[0]["id"]))
        self.assertEqual(len(self.call("events", "--pending")), 1)
        self.assertEqual(len(self.call("events", "--ticket", "1")), 2)

    def test_terminal_ticket_cannot_be_requeued(self):
        self.enqueue()
        self.call("claim")
        self.update(1, "done")
        self.call("set", "--ticket", "1", "--status", "queued", "--note", "test", ok=False)
        self.assertIsNone(self.call("claim")["active"])


    def test_guidance_drift_is_rejected_at_submission(self):
        env = self.fake_validators()
        head = self.commit({".project-docs/agent-context.md": "guidance v2\n",
                            "AGENTS.md": "guidance v1\n"})
        error = self.enqueue(head=head, ok=False, env=env)["error"]
        self.assertIn("agent-context.md", error)
        self.assertIn("--write", error)
        self.assertEqual(self.call("status")["tickets"], [])

    def test_documentation_validator_failure_is_rejected_with_its_output(self):
        env = self.fake_validators()
        head = self.commit({".project-docs/agent-context.md": "guidance\n",
                            "AGENTS.md": "guidance\n",
                            ".project-docs/decisions/bad.md": "record\n"})
        error = self.enqueue(head=head, ok=False, env=env)["error"]
        self.assertIn("missing reciprocal related link", error)
        # The temporary checkout's location is not part of the message.
        self.assertIn("\n.project-docs/decisions/bad.md", error)
        self.assertEqual(self.call("status")["tickets"], [])
        self.assertEqual(len(self.git("worktree", "list").splitlines()), 1)

    def test_reviewed_head_is_checked_not_the_working_tree(self):
        env = self.fake_validators()
        good = self.commit({".project-docs/agent-context.md": "guidance\n",
                            "AGENTS.md": "guidance\n"})
        self.commit({".project-docs/decisions/bad.md": "record\n"})
        result = self.enqueue(head=good, env=env)
        self.assertTrue(result["created"])
        self.assertEqual(result["documentation_checks"], "passed")
        self.assertIn("passed", self.call("events", "--ticket", "1")[0]["note"])
        # An uncommitted fix does not make the committed head acceptable.
        bad = self.git("rev-parse", "HEAD").strip()
        (self.repo / ".project-docs/decisions/bad.md").unlink()
        self.enqueue(pr=2, head=bad, ok=False, env=env)

    def test_missing_validators_are_reported_not_silently_passed(self):
        head = self.commit({".project-docs/agent-context.md": "guidance\n"})
        empty_home = Path(self.temp.name) / "home"
        empty_home.mkdir()
        result = self.enqueue(head=head, env={"HOME": str(empty_home)})
        self.assertEqual(result["documentation_checks"], "unavailable")
        self.call("configure", "--builder-thread", "builder")
        missing = {"WHYTAP_PROJECT_DOCUMENTATION_SCRIPTS": str(empty_home)}
        self.enqueue(pr=2, head=head, ok=False, env=missing)

    def test_accepted_head_stays_idempotent_whatever_the_validators_say_later(self):
        head = self.commit({".project-docs/agent-context.md": "guidance\n",
                            "AGENTS.md": "drifted\n"})
        empty_home = Path(self.temp.name) / "home"
        empty_home.mkdir()
        first = self.enqueue(head=head, env={"HOME": str(empty_home)})
        again = self.enqueue(head=head, env=self.fake_validators())
        self.assertFalse(again["created"])
        self.assertEqual(again["ticket"]["id"], first["ticket"]["id"])

    def test_concurrent_first_calls_after_an_upgrade_migrate_once(self):
        import sqlite3
        for _ in range(5):
            db = sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3")
            db.execute("ALTER TABLE tickets DROP COLUMN retry")
            db.commit()
            db.close()
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda _: self.call("status"), range(8)))

    def test_repository_without_project_documentation_skips_the_checks(self):
        self.assertEqual(self.enqueue(env=self.fake_validators())["documentation_checks"],
                         "not_applicable")

    def test_retry_install_marks_only_a_deferred_install(self):
        self.enqueue()
        self.call("claim")
        self.call("set", "--ticket", "1", "--status", "done", "--note", "x",
                  "--retry-install", ok=False)
        waiting = self.call("set", "--ticket", "1", "--status", "pending_install",
                            "--note", "candidate ready", "--retry-install")
        self.assertEqual(waiting["retry"], "meeting")
        self.assertEqual(self.update(1, "done")["retry"], "")

    def test_builder_identity_can_come_from_the_watcher_environment(self):
        self.enqueue()
        result = subprocess.run(["python3", str(SCRIPT), "claim"], cwd=self.repo,
                                capture_output=True, text=True,
                                env={**os.environ, "WHYTAP_BUILD_QUEUE_ACTOR": "builder",
                                     "CODEX_THREAD_ID": "some-other-thread"})
        self.assertTrue(json.loads(result.stdout)["claimed"])

    def submit(self, *extra, env=None, ok=True):
        return self.call("enqueue", "--pr", "https://github.com/example/app/pull/9", "--head",
                         self.head, "--title", "Fixture", "--checks", "Fixture",
                         "--acceptance", "Fixture", *extra, env=env, ok=ok)

    def test_claude_code_author_is_detected_from_its_session_uuid(self):
        session = "0b0e6f3a-5d1c-4a8e-9f2b-7c3d1e2f4a5b"
        result = self.submit(env={"CLAUDE_CODE_SESSION_ID": session})
        self.assertEqual((result["ticket"]["source"], result["ticket"]["session"]),
                         ("claude", session))
        self.assertEqual(result["delivery"], "harness_link")

    def test_codex_thread_wins_over_a_claude_session_in_the_environment(self):
        result = self.submit(env={"CODEX_THREAD_ID": "thread-1",
                                  "CLAUDE_CODE_SESSION_ID": "0b0e6f3a-5d1c-4a8e-9f2b-7c3d1e2f4a5b"})
        self.assertEqual((result["ticket"]["source"], result["ticket"]["session"]),
                         ("codex", "thread-1"))

    def test_claude_display_name_is_refused_and_other_is_inbox_only(self):
        error = self.submit("--source", "claude", "--session", "one-mcp", ok=False)["error"]
        self.assertIn("UUID", error)
        result = self.submit("--source", "other", "--session", "one-mcp")
        self.assertEqual(result["delivery"], "inbox_only")

    def test_metrics_count_returns_and_waits_without_writing(self):
        first = self.enqueue()["ticket"]["id"]
        self.call("claim")
        self.update(first, "blocked")
        second = self.commit({"fix.txt": "fixed"})
        self.enqueue(head=second)
        self.enqueue(2)
        self.call("claim")
        self.update(first + 1, "done")
        self.call("claim")
        self.call("set", "--ticket", str(first + 2), "--status", "pending_install",
                  "--note", "Candidate signed; microphone in use", "--retry-install")
        queue = self.repo / ".git" / "exodia-build-queue.sqlite3"
        before = queue.stat().st_mtime_ns
        result = subprocess.run(["python3", str(SCRIPT.with_name("build-queue-metrics.py")),
                                 "--since", "2000-01-01"], cwd=self.repo, capture_output=True,
                                text=True, env=HERMETIC_ENV, check=True)
        metrics = json.loads(result.stdout)
        self.assertEqual((metrics["tickets"], metrics["prs"]), (3, 2))
        self.assertEqual(metrics["returns"]["total"], 1)
        self.assertEqual(metrics["returns"]["per_pr"], {"0": 1, "1": 1})
        self.assertEqual(metrics["pr_to_done_minutes"]["with_returns"]["n"], 1)
        self.assertEqual(metrics["deferred_installs"], {"meeting or microphone": 1})
        self.assertEqual(metrics["queue_wait_minutes"]["n"], 3)
        self.assertEqual(queue.stat().st_mtime_ns, before)

    def test_author_addresses_are_validated_whole_and_stored_canonically(self):
        session = "0B0E6F3A-5D1C-4A8E-9F2B-7C3D1E2F4A5B"
        stored = self.submit("--source", "claude", "--session", session)["ticket"]["session"]
        self.assertEqual(stored, session.lower())
        for bad in (session.lower() + "\n", " " + session.lower()):
            self.assertIn("UUID", self.submit("--source", "claude", "--session", bad,
                                              ok=False)["error"])
            self.assertIn("UUID", self.submit(env={"CLAUDE_CODE_SESSION_ID": bad},
                                              ok=False)["error"])
        self.assertIn("letters", self.submit("--source", "codex", "--session", "thread 1",
                                             ok=False)["error"])
        self.assertIn("letters", self.submit(env={"CODEX_THREAD_ID": "thread-1\n"},
                                             ok=False)["error"])

    def metrics(self, since, until):
        result = subprocess.run(["python3", str(SCRIPT.with_name("build-queue-metrics.py")),
                                 "--since", since, "--until", until], cwd=self.repo,
                                capture_output=True, text=True, env=HERMETIC_ENV, check=True)
        return json.loads(result.stdout)

    def test_metrics_use_only_events_before_the_cutoff_and_clip_waits(self):
        first = self.enqueue()["ticket"]["id"]
        self.call("claim")
        self.update(first, "blocked")
        second = self.enqueue(head=self.commit({"fix.txt": "fixed"}))["ticket"]["id"]
        self.call("claim")
        self.update(second, "done")
        db = sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3")
        stamps = {"queued": "00:00", "in_progress": "00:10", "blocked": "01:05",
                  "superseded": "01:06", "done": "01:08"}
        for status, clock in stamps.items():
            db.execute("UPDATE events SET created_at=? WHERE ticket=? AND status=?",
                       (f"2026-01-01T{clock}:00+00:00", first, status))
        db.execute("UPDATE tickets SET queued_at='2026-01-01T00:00:00+00:00' WHERE id=?",
                   (first,))
        for status, clock in (("queued", "01:06"), ("in_progress", "01:07"), ("done", "01:08")):
            db.execute("UPDATE events SET created_at=? WHERE ticket=? AND status=?",
                       (f"2026-01-01T{clock}:00+00:00", second, status))
        db.execute("UPDATE tickets SET queued_at='2026-01-01T01:06:00+00:00' WHERE id=?",
                   (second,))
        db.commit()
        db.close()
        logs = self.repo / ".git" / "whytap-build-queue-logs"
        logs.mkdir()
        (logs / "watcher.log").write_text("\n".join([
            "2026-01-01T00:00:00+00:00 waiting: screen locked",
            "2026-01-01T00:10:00+00:00 watchdog: queue waits: screen locked",
            "2026-01-01T00:30:00+00:00 waiting: load 50 on 14 CPUs (limit 28)",
            "2026-01-01T00:40:00+00:00 starting codex builder session (queued)",
            "2026-01-01T00:50:00+00:00 waiting: screen locked"]) + "\n")
        metrics = self.metrics("2026-01-01T00:05:00+00:00", "2026-01-01T01:00:00+00:00")
        self.assertEqual(metrics["returns"]["total"], 0)
        self.assertEqual(metrics["status_at_cutoff"], {"in_progress": 1})
        self.assertEqual(metrics["pr_to_done_minutes"]["with_returns"]["n"], 0)
        self.assertEqual(metrics["attempts_open_at_cutoff"], 1)
        self.assertEqual(metrics["queue_wait_minutes"]["n"], 1)  # carry-in queued at 00:00
        self.assertEqual(metrics["environment_wait_minutes"], {"load": 10, "screen locked": 35})
        later = self.metrics("2026-01-01T01:00:00+00:00", "2026-01-01T02:00:00+00:00")
        self.assertEqual(later["returns"]["total"], 1)
        self.assertEqual(later["pr_to_done_minutes"]["with_returns"]["n"], 1)
        self.assertEqual(later["builder_minutes_per_attempt"]["n"], 2)
        self.assertEqual(later["environment_wait_minutes"], {"screen locked": 60})


    def test_metrics_take_times_from_events_not_the_requeue_date(self):
        ticket = self.enqueue()["ticket"]["id"]
        self.call("claim")
        self.update(ticket, "blocked")
        self.update(ticket, "queued")  # requeue resets tickets.queued_at
        self.call("claim")
        self.update(ticket, "done")
        db = sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3")
        ids = [r[0] for r in db.execute("SELECT id FROM events WHERE ticket=? ORDER BY id",
                                        (ticket,))]
        clocks = ["00:00", "00:10", "00:20", "01:05", "01:15", "01:25"]
        for event_id, clock in zip(ids, clocks):
            db.execute("UPDATE events SET created_at=? WHERE id=?",
                       (f"2026-01-01T{clock}:00+00:00", event_id))
        db.execute("UPDATE tickets SET queued_at='2026-01-01T01:05:00+00:00' WHERE id=?",
                   (ticket,))
        db.commit()
        db.close()
        early = self.metrics("2026-01-01T00:00:00+00:00", "2026-01-01T00:55:00+00:00")
        self.assertEqual(early["queue_wait_minutes"]["max"], 10)
        whole = self.metrics("2026-01-01T00:00:00+00:00", "2026-01-01T02:00:00+00:00")
        self.assertEqual(whole["queue_wait_minutes"], {"n": 2, "median": 10.0, "p75": 10.0,
                                                       "p90": 10.0, "max": 10.0})
        self.assertEqual(whole["pr_to_done_minutes"]["with_returns"]["max"], 85)

    def test_meeting_wait_spans_its_rechecks_and_ends_at_idle(self):
        self.enqueue()
        logs = self.repo / ".git" / "whytap-build-queue-logs"
        logs.mkdir()
        (logs / "watcher.log").write_text("\n".join([
            "2026-01-01T00:00:00+00:00 deferred install: meeting gate is not clear",
            "2026-01-01T00:05:00+00:00 deferred install: next meeting check not due",
            "2026-01-01T00:06:00+00:00 watchdog: install waits",
            "2026-01-01T00:10:00+00:00 deferred install: meeting gate is not clear",
            "2026-01-01T00:12:00+00:00 idle"]) + "\n")
        metrics = self.metrics("2026-01-01T00:00:00+00:00", "2026-01-01T00:30:00+00:00")
        self.assertEqual(metrics["environment_wait_minutes"], {"meeting gate": 12})

    def test_a_not_due_line_continues_a_meeting_wait_but_never_starts_one(self):
        self.enqueue()
        logs = self.repo / ".git" / "whytap-build-queue-logs"
        logs.mkdir()
        (logs / "watcher.log").write_text("\n".join([
            "2026-01-01T00:00:00+00:00 deferred install: next meeting check not due",
            "2026-01-01T00:04:00+00:00 idle",
            "2026-01-01T01:00:00+00:00 deferred install: meeting gate is not clear",
            "2026-01-01T01:05:00+00:00 deferred install: meeting gate is not clear; next "
            "check not due",
            "2026-01-01T01:07:00+00:00 idle"]) + "\n")
        early = self.metrics("2026-01-01T00:00:00+00:00", "2026-01-01T00:30:00+00:00")
        self.assertEqual(early["environment_wait_minutes"], {})
        later = self.metrics("2026-01-01T00:30:00+00:00", "2026-01-01T02:00:00+00:00")
        self.assertEqual(later["environment_wait_minutes"], {"meeting gate": 7})

    def ticket(self, ticket_id):
        return self.call("status", "--ticket", str(ticket_id))["tickets"][0]

    def test_a_ticket_returned_without_a_block_keeps_its_place(self):
        first = self.enqueue(1)["ticket"]["id"]
        second = self.enqueue(2)["ticket"]["id"]
        queued_at = self.ticket(first)["queued_at"]
        self.call("claim")
        self.update(first, "queued")
        self.assertEqual((self.ticket(first)["position"], self.ticket(first)["queued_at"]),
                         (1, queued_at))
        self.assertEqual(self.call("claim")["ticket"]["id"], first)
        self.update(first, "blocked")
        self.update(first, "queued")  # after a block: to the end, as before
        self.assertEqual(self.ticket(first)["position"], 2)
        self.assertEqual(self.call("claim")["ticket"]["id"], second)

    def test_a_ticket_waits_for_its_dependency_in_place(self):
        dependency = "https://github.com/example/app/pull/3"
        waiting = self.call("enqueue", "--pr", "https://github.com/example/app/pull/2",
                            "--head", self.head, "--title", "Needs 3", "--checks", "x",
                            "--acceptance", "x", "--session", "worker",
                            "--depends-on", dependency)["ticket"]
        self.assertEqual((waiting["depends_on"], waiting["waiting_for"]), ([dependency], [dependency]))
        other = self.enqueue(4)["ticket"]["id"]
        claimed = self.call("claim")
        self.assertEqual((claimed["ticket"]["id"], claimed["waiting_for_dependencies"]),
                         (other, [waiting["id"]]))
        self.update(other, "done")
        three = self.enqueue(3)["ticket"]["id"]
        self.assertEqual(self.call("claim")["ticket"]["id"], three)
        self.assertEqual(self.ticket(waiting["id"])["position"], 1)
        self.update(three, "pending_install")  # merged; the install waits
        self.assertEqual(self.ticket(waiting["id"])["waiting_for"], [])
        self.assertEqual(self.call("claim")["ticket"]["id"], waiting["id"])

    def test_dependencies_on_itself_or_in_a_cycle_are_refused(self):
        own = "https://github.com/example/app/pull/1"
        self.assertIn("itself", self.call(
            "enqueue", "--pr", own, "--head", self.head, "--title", "x", "--checks", "x",
            "--acceptance", "x", "--session", "worker", "--depends-on", own, ok=False)["error"])
        self.call("enqueue", "--pr", "https://github.com/example/app/pull/2", "--head", self.head,
                  "--title", "x", "--checks", "x", "--acceptance", "x", "--session", "worker",
                  "--depends-on", own)
        self.assertIn("already depends", self.call(
            "enqueue", "--pr", own, "--head", self.head, "--title", "x", "--checks", "x",
            "--acceptance", "x", "--session", "worker", "--depends-on",
            "https://github.com/example/app/pull/2", ok=False)["error"])

    def test_claim_returns_a_ticket_whose_pr_head_moved(self):
        stale = self.enqueue(1)["ticket"]["id"]
        fresh = self.enqueue(2)["ticket"]["id"]
        moved = self.commit({"pushed.txt": "after submission"})
        self.git("push", "-q", str(self.pulls), f"{moved}:refs/pull/1/head",
                 f"{self.head}:refs/pull/2/head")
        claimed = self.call("claim")
        self.assertEqual((claimed["ticket"]["id"], claimed["returned_moved_heads"]), (fresh, [stale]))
        returned = self.ticket(stale)
        self.assertEqual(returned["status"], "blocked")
        self.assertIn("--head " + moved, returned["note"])
        self.assertEqual(self.call("events", "--ticket", str(stale))[-1]["status"], "blocked")

    def test_check_heads_needs_the_builder_and_an_unknown_remote_blocks_nothing(self):
        ticket = self.enqueue(1)["ticket"]["id"]
        self.git("push", "-q", str(self.pulls), f"{self.commit({'a': 'b'})}:refs/pull/1/head")
        self.call("check-heads", actor="worker", ok=False)
        offline = {"WHYTAP_BUILD_QUEUE_PULL_REMOTE": str(Path(self.temp.name) / "missing.git")}
        self.assertEqual(self.call("check-heads", env=offline),
                         {"checked": False, "returned_moved_heads": []})
        self.assertEqual(self.call("claim", env=offline)["ticket"]["id"], ticket)


    def test_a_ticket_queued_while_the_heads_were_read_is_not_judged(self):
        ticket = self.enqueue(1)["ticket"]["id"]
        moved = self.commit({"elsewhere.txt": "pushed"})
        self.git("push", "-q", str(self.pulls), f"{moved}:refs/pull/1/head")
        db = sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3")
        # Submitted after the remote read started (the snapshot may predate it).
        db.execute("UPDATE tickets SET submitted_at='2999-01-01T00:00:00+00:00' WHERE id=?",
                   (ticket,))
        db.commit()
        db.close()
        self.assertEqual(self.call("check-heads")["returned_moved_heads"], [])
        claimed = self.call("claim")
        self.assertEqual((claimed["ticket"]["id"], claimed["returned_moved_heads"]), (ticket, []))

    def test_a_pull_ref_still_showing_an_ancestor_is_lagging_not_moved(self):
        previous = self.head
        submitted = self.commit({"next.txt": "pushed and submitted"})
        self.git("push", "-q", str(self.pulls), f"{previous}:refs/pull/1/head")  # not updated yet
        ticket = self.enqueue(1, head=submitted)["ticket"]["id"]
        self.assertEqual(self.call("check-heads")["returned_moved_heads"], [])
        self.assertEqual(self.call("claim")["ticket"]["id"], ticket)

    def test_a_model_free_return_reaches_the_next_builder_for_claude_authors(self):
        claude = "0b0e6f3a-5d1c-4a8e-9f2b-7c3d1e2f4a5b"
        ticket = self.call("enqueue", "--pr", "https://github.com/example/app/pull/1", "--head",
                           self.head, "--title", "x", "--checks", "x", "--acceptance", "x",
                           "--source", "claude", "--session", claude)["ticket"]["id"]
        moved = self.commit({"pushed.txt": "after submission"})
        self.git("push", "-q", str(self.pulls), f"{moved}:refs/pull/1/head")
        self.assertEqual(self.call("check-heads")["returned_moved_heads"], [ticket])
        pending = self.call("events", "--pending")
        self.assertEqual([(e["ticket"], e["status"], e["session"]) for e in pending],
                         [(ticket, "blocked", claude)])  # its queued receipt is not listed
        self.call("ack", "--event", str(pending[0]["id"]))
        self.assertEqual(self.call("events", "--pending"), [])

    def test_metrics_count_grouped_installs_apart_from_meetings(self):
        for pr, note in ((1, "merged at abc; install grouped"), (2, "microphone in use")):
            ticket = self.enqueue(pr)["ticket"]["id"]
            self.call("claim")
            self.call("set", "--ticket", str(ticket), "--status", "pending_install",
                      "--retry-install", "--note", note)
            self.update(ticket, "done")
        metrics = self.metrics("2000-01-01", "2999-01-01")
        self.assertEqual(metrics["deferred_installs"], {"grouped": 1, "meeting or microphone": 1})

    def merged_waiting(self, pr, flag="--retry-install", note="merged; install grouped"):
        ticket = self.enqueue(pr)["ticket"]["id"]
        self.call("claim")
        self.call("set", "--ticket", str(ticket), "--status", "pending_install", flag, "--note", note)
        return ticket

    def test_a_waiting_install_records_a_candidate_or_a_person_without_leaving_the_group(self):
        ticket = self.merged_waiting(1)
        retry = lambda: sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3").execute(
            "SELECT retry FROM tickets WHERE id=?", (ticket,)).fetchone()[0]
        for flags, expected in (([], ""), (["--retry-install"], "meeting"),
                                (["--install-first"], "first"), (["--hold"], "hold"),
                                ([], "hold")):  # the boundary stays until resolved
            self.call("set", "--ticket", str(ticket), "--status", "pending_install", *flags,
                      "--note", "candidate build 1740 at /private/candidate.app")
            self.assertEqual(retry(), expected, flags)
        self.assertEqual(self.ticket(ticket)["note"], "candidate build 1740 at /private/candidate.app")
        self.assertIn("one of", self.call("set", "--ticket", str(ticket), "--status",
                                          "pending_install", "--hold", "--install-first",
                                          "--note", "x", ok=False)["error"])

    def test_runtime_is_counted_from_the_paths_at_submission(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        docs = self.commit({"docs/guide.md": "words", "README.md": "more words",
                            "Tests/AppTests/T.swift": "test"})
        self.assertEqual(self.enqueue(1, head=docs)["ticket"]["runtime"], 0)
        self.git("checkout", "-q", "-b", "app", self.head)
        app = self.commit({"Sources/App/Feature.swift": "code"})
        self.assertEqual(self.enqueue(2, head=app)["ticket"]["runtime"], 1)

    def test_a_full_group_holds_runtime_work_but_not_documentation(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        group = [self.merged_waiting(pr) for pr in (1, 2, 3)]
        runtime = self.enqueue(5, head=self.commit({"Sources/App/A.swift": "a"}))["ticket"]["id"]
        self.assertEqual(self.call("claim")["ticket"]["id"], runtime)  # 3 + this one = 4
        self.call("set", "--ticket", str(runtime), "--status", "pending_install", "--retry-install",
                  "--note", "merged; install grouped")
        fifth = self.enqueue(6, head=self.commit({"Sources/App/B.swift": "b"}))["ticket"]["id"]
        self.git("checkout", "-q", "-b", "docs", self.head)
        docs = self.enqueue(7, head=self.commit({"docs/c.md": "c"}))["ticket"]["id"]
        claimed = self.call("claim")
        self.assertEqual((claimed["ticket"]["id"], claimed["held_for_install"]), (docs, [fifth]))
        self.update(docs, "done")
        for ticket in group + [runtime]:
            self.update(ticket, "done")  # one install closed the group
        self.assertEqual(self.call("claim")["ticket"]["id"], fifth)

    def test_an_install_first_or_held_for_a_person_comes_before_runtime_work(self):
        legacy = self.merged_waiting(1)
        self.call("set", "--ticket", str(legacy), "--status", "pending_install", "--note", "old")
        for pr, flag in ((2, "--install-first"), (4, "--hold")):
            waiting = self.merged_waiting(pr, flag=flag, note="merged")
            queued = self.enqueue(pr + 1)["ticket"]["id"]  # no origin/main: counts as runtime
            claimed = self.call("claim")
            self.assertEqual((claimed["claimed"], claimed["held_for_install"]), (False, [queued]),
                             flag)
            self.update(waiting, "done")
            self.assertEqual(self.call("claim")["ticket"]["id"], queued)  # legacy holds nothing
            self.update(queued, "done")


    def test_a_deferral_never_lifts_the_install_boundary(self):
        ticket = self.merged_waiting(1, flag="--install-first", note="isolated, gate busy")
        retry = lambda: sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3").execute(
            "SELECT retry FROM tickets WHERE id=?", (ticket,)).fetchone()[0]
        steps = ((["--retry-install"], "first"),  # install step, gate busy
                 ([], "hold"),                    # install step, a person must act
                 (["--retry-install"], "first"),  # the person acted
                 (["--hold"], "hold"), (["--install-first"], "first"))
        for flags, expected in steps:
            self.call("set", "--ticket", str(ticket), "--status", "pending_install", *flags,
                      "--note", "deferred")
            self.assertEqual(retry(), expected, flags)
            self.assertTrue(self.call("status")["install_boundary"])
        queued = self.enqueue(2)["ticket"]["id"]
        self.assertEqual(self.call("claim")["held_for_install"], [queued])
        self.update(ticket, "done")
        self.assertFalse(self.call("status")["install_boundary"])

    # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
    def change(self, name="Sources/App/Window.swift", content="ui"):
        self.git("checkout", "-q", "--detach", self.head)
        return self.commit({name: content})

    def test_resubmission_after_a_block_keeps_its_place_twice(self):
        places = []
        ticket = self.enqueue(1)["ticket"]
        other = self.enqueue(2)["ticket"]["id"]
        for round_ in range(3):
            self.assertEqual(self.call("claim")["ticket"]["id"], ticket["id"])
            self.update(ticket["id"], "blocked")
            ticket = self.enqueue(1, head=self.change(f"Sources/App/Fix{round_}.swift"))["ticket"]
            places.append((ticket["position"], ticket["resubmits"]))
        self.assertEqual(places, [(1, 1), (1, 2), (2, 2)])  # the third goes behind #2
        events = self.call("events", "--ticket", str(ticket["id"]))
        self.assertIn("goes to the end", events[-1]["note"])
        self.assertEqual(self.call("claim")["ticket"]["id"], other)

    def test_a_ticket_whose_dependency_stays_blocked_goes_back_to_its_author(self):
        parent = self.enqueue(1)["ticket"]["id"]
        child = self.call("enqueue", "--pr", "https://github.com/example/app/pull/2",
                          "--head", self.head, "--title", "Child", "--checks", "x",
                          "--acceptance", "x", "--session", "worker",
                          "--depends-on", "https://github.com/example/app/pull/1")["ticket"]
        self.call("claim")
        self.update(parent, "blocked")
        self.assertEqual(self.call("return-stale-dependencies")["returned"], [])  # under 2 h
        self.assertEqual(self.call("return-stale-dependencies", "--minutes", "0")["returned"],
                         [child["id"]])
        returned = self.ticket(child["id"])
        self.assertEqual(returned["status"], "blocked")
        self.assertIn("dependency", returned["note"])
        self.assertEqual(self.call("events", "--pending", "--ticket", str(child["id"]))[-1]
                         ["status"], "blocked")
        self.call("return-stale-dependencies", actor="worker", ok=False)
        # A return without a model keeps the place and spends no resubmission priority.
        again = self.call("enqueue", "--pr", "https://github.com/example/app/pull/2",
                          "--head", self.change(content="again"), "--title", "Child",
                          "--checks", "x", "--acceptance", "x", "--session", "worker",
                          "--depends-on", "https://github.com/example/app/pull/1")["ticket"]
        self.assertEqual((again["queued_at"], again["resubmits"]), (child["queued_at"], 0))

    def stale_snapshot_blocks(self, ticket_id, started, head):
        """Ask the helper's own head check, with a remote snapshot that started at
        `started` and saw `head`, whether it would return this ticket."""
        spec = importlib.util.spec_from_file_location("queue_helper", SCRIPT)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        db = sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3")
        db.row_factory = sqlite3.Row
        cwd = os.getcwd()
        try:
            os.chdir(self.repo)
            ticket = db.execute("SELECT * FROM tickets WHERE id=?", (ticket_id,)).fetchone()
            return helper.block_moved_head(db, ticket, {"started": started,
                                                        "heads": {1: head}})
        finally:
            os.chdir(cwd)
            db.rollback()
            db.close()

    def test_every_way_a_head_reenters_review_refreshes_its_head_check(self):
        """The class of re-entries (review item 2 on ticket 635): a set back to the
        queue from blocked or in_progress, and the author's resubmission of a head
        returned without review. Each keeps or ends its FIFO place as designed and
        is never judged by a remote snapshot that started before it re-entered."""
        elsewhere = self.change("elsewhere.txt", "pushed")

        def blocked_by_builder():
            ticket = self.enqueue(1)["ticket"]
            self.call("claim")
            self.update(ticket["id"], "blocked")
            return ticket, lambda: self.update(ticket["id"], "queued"), False

        def returned_from_in_progress():
            ticket = self.enqueue(1)["ticket"]
            self.call("claim")
            return ticket, lambda: self.update(ticket["id"], "queued"), True

        def returned_without_review():
            parent = self.enqueue(3, head=self.change(content="parent"))["ticket"]
            child = self.call("enqueue", "--pr", "https://github.com/example/app/pull/1",
                              "--head", self.head, "--title", "Child", "--checks", "x",
                              "--acceptance", "x", "--session", "worker", "--depends-on",
                              "https://github.com/example/app/pull/3")["ticket"]
            self.call("claim")
            self.update(parent["id"], "blocked")
            self.call("return-stale-dependencies", "--minutes", "0")
            again = lambda: self.assertTrue(self.enqueue(1)["requeued"])  # drops --depends-on
            return child, again, True

        for scenario in (blocked_by_builder, returned_from_in_progress,
                         returned_without_review):
            with self.subTest(scenario.__name__):
                (self.repo / ".git" / "exodia-build-queue.sqlite3").unlink(missing_ok=True)
                self.call("configure", "--builder-thread", "builder")
                ticket, reenter, keeps_place = scenario()
                snapshot_started = datetime.now(timezone.utc).isoformat(timespec="microseconds")
                reenter()
                after = self.ticket(ticket["id"])
                self.assertEqual(after["status"], "queued")
                self.assertEqual(after["queued_at"] == ticket["queued_at"], keeps_place)
                self.assertGreater(after["submitted_at"], snapshot_started)
                self.assertEqual(after["resubmits"], ticket["resubmits"])
                self.assertFalse(self.stale_snapshot_blocks(ticket["id"], snapshot_started,
                                                            elsewhere))
                # A snapshot read after the re-entry still returns a moved head.
                later = datetime.now(timezone.utc).isoformat(timespec="microseconds")
                self.assertTrue(self.stale_snapshot_blocks(ticket["id"], later, elsewhere))

    def test_only_a_head_returned_without_review_comes_back_by_resubmission(self):
        """Review item 1 on ticket 635, and what stays idempotent."""
        ticket = self.enqueue(1)["ticket"]
        self.assertFalse(self.enqueue(1).get("requeued"))  # queued: idempotent
        self.call("claim")
        self.assertEqual(self.enqueue(1)["ticket"]["status"], "in_progress")
        self.update(ticket["id"], "blocked")  # a builder reviewed and blocked this head
        again = self.enqueue(1)
        self.assertEqual((again["created"], again.get("requeued"), again["ticket"]["status"]),
                         (False, None, "blocked"))
        self.enqueue(1, session="other", ok=False)
        # Returned by the moved-head check: the same head comes back to its place.
        self.update(ticket["id"], "queued")
        self.git("push", "-q", str(self.pulls), f"{self.change(content='moved')}:refs/pull/1/head")
        self.call("check-heads")
        self.assertEqual(self.ticket(ticket["id"])["status"], "blocked")
        self.enqueue(1, session="other", ok=False)  # never another session
        back = self.enqueue(1)
        self.assertEqual((back["requeued"], back["ticket"]["status"]), (True, "queued"))
        self.assertEqual(back["ticket"]["auto_returned"], 0)
        # A newer ticket of the PR exists: the old head never comes back.
        self.git("push", "-q", "-f", str(self.pulls), f"{self.head}:refs/pull/1/head")
        self.assertEqual(self.call("claim")["ticket"]["id"], ticket["id"])
        self.update(ticket["id"], "blocked")
        newer = self.enqueue(1, head=self.change(content="fix"))["ticket"]
        self.assertTrue(newer["id"] > ticket["id"])
        self.assertIsNone(self.enqueue(1).get("requeued"))

    def test_no_write_that_changes_the_dependency_graph_can_close_a_cycle(self):
        """Review of ticket 641: a returned head that comes back, and a new head, both
        pass the same dependency check, direct or through other PRs."""
        url = lambda n: f"https://github.com/example/app/pull/{n}"
        def submit(pr, head, *parents, ok=True):
            args = ["enqueue", "--pr", url(pr), "--head", head, "--title", f"PR {pr}",
                    "--checks", "x", "--acceptance", "x", "--session", "worker"]
            for parent in parents:
                args += ["--depends-on", url(parent)]
            return self.call(*args, ok=ok)
        parent = submit(1, self.change(content="parent"))["ticket"]
        child = submit(2, self.head, 1)["ticket"]
        self.call("claim")
        self.update(parent["id"], "blocked")
        self.assertEqual(self.call("return-stale-dependencies", "--minutes", "0")["returned"],
                         [child["id"]])
        submit(3, self.change(content="three"), 2)  # valid: 3 waits on 2
        submit(4, self.change(content="four"), 3)   # valid: 4 waits on 3
        for parents in ((3,), (4,), (1, 4)):
            with self.subTest(path="returned head comes back", parents=parents):
                submit(2, self.head, *parents, ok=False)
                self.assertEqual(self.ticket(child["id"])["status"], "blocked")
                self.assertEqual(self.ticket(child["id"])["depends_on"], [url(1)])
            with self.subTest(path="new head", parents=parents):
                submit(2, self.change(content=f"fix {parents}"), *parents, ok=False)
        events = self.call("events", "--ticket", str(child["id"]))
        self.assertNotIn("Resubmitted", " ".join(e["note"] for e in events))
        self.assertTrue(submit(2, self.head)["requeued"])  # without the cycle it comes back

    def test_open_status_lists_open_work_and_its_history_only(self):
        old = self.enqueue(1)["ticket"]["id"]
        self.call("claim")
        self.call("set", "--ticket", str(old), "--status", "done", "--note", "n" * 2000)
        history = self.enqueue(2)["ticket"]["id"]
        self.call("claim")
        self.call("set", "--ticket", str(history), "--status", "blocked", "--note", "b" * 2000)
        current = self.enqueue(2, head=self.change())["ticket"]["id"]
        listed = self.call("status", "--open")["tickets"]
        self.assertEqual([t["id"] for t in listed], [history, current])
        self.assertLess(len(listed[0]["note"]), 700)
        self.assertEqual(len(self.call("status")["tickets"]), 3)
        self.assertEqual(len(self.call("status", "--ticket", str(history))["tickets"][0]["note"]),
                         2000)

    def test_stale_head_snapshot_ignores_a_priority_resubmission(self):
        old = self.enqueue(1, self.change(content="first"))["ticket"]
        self.call("claim")
        self.update(old["id"], "blocked")
        self.git("push", "-q", str(self.pulls), f"{old['head']}:refs/pull/1/head")
        new = self.enqueue(1, self.change(content="revised"))["ticket"]
        self.assertEqual(new["queued_at"], old["queued_at"])  # kept its place
        self.git("push", "-q", "-f", str(self.pulls), f"{new['head']}:refs/pull/1/head")
        self.assertEqual(self.call("claim")["ticket"]["id"], new["id"])
        self.assertGreater(self.ticket(new["id"])["submitted_at"], old["queued_at"])

    def test_protected_tests_skipped_behind_a_lock_survive_until_they_pass(self):
        names = ["SidekeyTests.PlannerExternalChangesTests/testMigration",
                 "WhytapCaseKitTests.TodoCommandTests/testLockedFile"]
        ticket = self.enqueue(1)["ticket"]["id"]
        self.call("claim")
        self.call("protected-pending", "--ticket", str(ticket), "--tests", "[1]", ok=False)
        self.call("protected-pending", "--ticket", str(ticket), ok=False)  # neither mode
        self.call("protected-pending", "--ticket", str(ticket), "--tests", json.dumps(names),
                  actor="worker", ok=False)
        self.call("protected-pending", "--ticket", str(ticket), "--tests", json.dumps(names))
        # Merged behind the lock: the install waits; a deferral and a recovery keep them.
        self.call("set", "--ticket", str(ticket), "--status", "pending_install",
                  "--retry-install", "--note", "merged; install waits for an unlocked screen")
        self.call("set", "--ticket", str(ticket), "--status", "pending_install",
                  "--install-first", "--note", "meeting gate busy")
        self.assertEqual(self.call("status")["protected_pending"], names)
        refused = self.call("set", "--ticket", str(ticket), "--status", "done", "--note", "x",
                            ok=False)
        self.assertIn("protected-data tests pending", refused["error"])
        self.call("protected-pending", "--ticket", str(ticket), "--passed", json.dumps(names[:1]),
                  ok=False)  # evidence required
        self.call("protected-pending", "--ticket", str(ticket), "--passed", json.dumps(names[:1]),
                  "--note", "swift test --filter, unlocked")
        self.assertEqual(self.ticket(ticket)["protected_pending"], names[1:])
        self.call("set", "--ticket", str(ticket), "--status", "done", "--note", "x", ok=False)
        self.call("protected-pending", "--ticket", str(ticket), "--passed", json.dumps(names[1:]),
                  "--note", "swift test --filter, unlocked")
        self.update(ticket, "done")
        self.assertEqual(self.call("status")["protected_pending"], [])
        self.call("protected-pending", "--ticket", str(ticket), "--tests", json.dumps(names),
                  ok=False)  # only open tickets

    def test_a_ticket_returned_to_the_queue_drops_its_pending_tests(self):
        ticket = self.enqueue(1)["ticket"]["id"]
        self.call("claim")
        self.call("protected-pending", "--ticket", str(ticket), "--tests",
                  '["SidekeyTests.A/testB"]')
        self.call("set", "--ticket", str(ticket), "--status", "queued", "--note", "load")
        self.assertEqual(self.ticket(ticket)["protected_pending"], [])  # validated again


if __name__ == "__main__":
    unittest.main()
