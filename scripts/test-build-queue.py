#!/usr/bin/env python3
"""Exercise concurrency and recovery using disposable repositories only."""

from concurrent.futures import ThreadPoolExecutor
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
        # The preview lane is on and one orchestrator relays the owner's decisions.
        (self.repo / ".git" / "whytap-build-queue-builder.json").write_text(
            json.dumps({"preview_lane": True}))
        self.token = Path(self.temp.name) / "orchestrator-token"
        self.token.write_text("t" * 40)
        self.call("configure-orchestrator", "--orchestrator", "orchestrator",
                  "--token-file", str(self.token))

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

    # WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
    def preview(self, pr, head, ok=True, session="worker", depends_on=()):
        extra = [a for url in depends_on for a in ("--depends-on", url)]
        return self.call("enqueue", "--pr", f"https://github.com/example/app/pull/{pr}",
                         "--head", head, "--title", f"Preview {pr}", "--checks", "branch build",
                         "--acceptance", "Open the window; it does not lag", "--session", session,
                         "--preview", *extra, ok=ok)

    def await_approval(self, ticket, build="1801"):
        """What the preview session records after a verified install."""
        current = self.ticket(ticket)
        train = [{"ticket": t["ticket"], "head": t["head"]}
                 for t in self.call("status")["preview_train"]]
        train.append({"ticket": ticket, "head": current["head"]})
        return self.call("set", "--ticket", str(ticket), "--status", "awaiting_approval",
                         "--note", "installed", "--preview-build", build,
                         "--installed-train", json.dumps(train))

    def decide(self, command, ticket, *extra, actor="orchestrator", ok=True, token=True,
               head=None, build=None):
        current = self.ticket(ticket)
        args = ["--ticket", str(ticket), "--head", head or current["head"],
                "--build", build or current["preview_build"] or "0", *extra]
        if token:
            args += ["--token-file", str(self.token)]
        return self.call(command, *args, actor=actor, ok=ok)

    def ui_change(self, name="Sources/App/Window.swift", content="ui"):
        self.git("checkout", "-q", "--detach", self.head)
        return self.commit({name: content})

    def test_a_preview_is_built_before_review_and_validated_only_after_approval(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        normal = self.enqueue(9)["ticket"]["id"]
        first = self.preview(1, self.ui_change())["ticket"]["id"]
        # The validation lane never takes a preview; the preview lane takes it at once.
        self.assertEqual(self.call("claim")["ticket"]["id"], normal)
        claimed = self.call("preview-claim")
        self.assertEqual((claimed["ticket"]["id"], claimed["train"]), (first, []))
        self.assertEqual(self.ticket(first)["status"], "previewing")
        self.await_approval(first)
        second = self.preview(2, self.ui_change("Sources/App/Other.swift"))["ticket"]["id"]
        joined = self.call("preview-claim")
        self.assertEqual([t["ticket"] for t in joined["train"]], [first])
        self.await_approval(second)
        self.assertEqual([t["ticket"] for t in self.call("status")["preview_train"]],
                         [first, second])
        # Only the orchestrator relays the owner's decision; not the author, not the builder.
        for actor in ("worker", "builder", "", "someone-else"):
            self.decide("approve", first, "--by", "owner: OK", "--note", "x",
                      actor=actor, ok=False)
        self.decide("approve", first, "--by", "owner: feature OK",
                  "--note", "relayed", actor="orchestrator")
        approved = self.ticket(first)
        self.assertEqual((approved["status"], approved["lane"]), ("approved", "approved"))
        self.assertEqual(json.loads(approved["approval"])["relayed_by"], "orchestrator")
        # Approved features wait for a release batch and stay in the owner's app.
        self.update(normal, "done")
        self.assertFalse(self.call("claim")["claimed"])
        self.assertEqual([t["ticket"] for t in self.call("status")["preview_train"]],
                         [first, second])
        self.assertTrue(any("owner approved" in e["note"] for e in
                            self.call("events", "--pending", "--ticket", str(first))))

    def test_a_rejected_preview_returns_to_its_author_and_the_train_is_rebuilt(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        first = self.preview(1, self.ui_change())["ticket"]["id"]
        self.call("preview-claim")
        self.await_approval(first)
        self.decide("reject", first, "--note", "the window lags",
                  actor="orchestrator")
        rejected = self.ticket(first)
        self.assertEqual(rejected["status"], "blocked")
        self.assertIn("the window lags", rejected["note"])
        claim = self.call("preview-claim")
        self.assertEqual((claim["claimed"], claim["rebuild"], claim["train"]), (False, True, []))
        # The fix keeps the preview's place and goes straight to the preview lane.
        fix = self.preview(1, self.ui_change(content="faster"))["ticket"]
        self.assertEqual(fix["queued_at"], rejected["queued_at"])
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], fix["id"])
        self.await_approval(fix["id"])
        self.assertFalse(self.call("status")["preview_rebuild"])

    def test_a_fix_pushed_while_its_preview_builds_replaces_it(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        first = self.preview(1, self.ui_change())["ticket"]["id"]
        self.call("preview-claim")
        fix = self.preview(1, self.ui_change(content="second"))["ticket"]["id"]
        self.await_approval(first)
        self.assertEqual(self.ticket(first)["status"], "superseded")
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], fix)

    def test_a_preview_touching_data_or_permissions_goes_to_the_normal_lane(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        for pr, path in enumerate(("Sources/App/HistoryStore.swift", "Package.resolved",
                                   "Resources/Sidekey.entitlements",
                                   "Sources/App/SettingsMigration.swift"), start=1):
            ticket = self.preview(pr, self.ui_change(path))["ticket"]["id"]
            claim = self.call("preview-claim")
            self.assertEqual((claim["claimed"], claim["moved_to_normal_lane"]), (False, [ticket]))
            moved = self.ticket(ticket)
            self.assertEqual((moved["status"], moved["lane"]), ("queued", ""))
            self.assertIn(path, moved["note"])
            self.assertEqual(self.call("claim")["ticket"]["id"], ticket)
            self.update(ticket, "done")

    def test_a_stacked_preview_waits_for_its_parent_in_the_train(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        parent_url = "https://github.com/example/app/pull/1"
        child = self.preview(2, self.ui_change("Sources/App/Child.swift"),
                             depends_on=[parent_url])["ticket"]["id"]
        self.assertEqual(self.call("preview-claim")["waiting_for_dependencies"], [child])
        parent = self.preview(1, self.ui_change())["ticket"]["id"]
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], parent)
        self.await_approval(parent)
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], child)
        self.await_approval(child)
        # A release without the parent cannot merge the child: it waits for a later batch.
        self.decide("approve", child, "--by", "owner", "--note", "x",
                  actor="orchestrator")
        claim = self.call("release", "--by", "owner: release", "--token-file", str(self.token), actor="orchestrator")
        self.assertEqual(claim["tickets"], [child])
        self.assertEqual(self.call("claim")["waiting_for_dependencies"], [child])
        self.assertEqual(self.ticket(child)["status"], "approved")
        # With the parent approved too, one batch carries both, parent first.
        self.decide("approve", parent, "--by", "owner", "--note", "x",
                  actor="orchestrator")
        self.call("release", "--by", "owner: release", "--token-file", str(self.token), actor="orchestrator")
        batch = self.call("claim")
        self.assertEqual([t["id"] for t in batch["tickets"]], [parent, child])

    # Release batches (.project-docs/decisions/2026-11-26-release-batches.md)

    def approved_preview(self, pr):
        ticket = self.preview(pr, self.ui_change(f"Sources/App/F{pr}.swift"))["ticket"]["id"]
        self.call("preview-claim")
        self.await_approval(ticket)
        self.decide("approve", ticket, "--by", "owner: OK", "--note", "x",
                  actor="orchestrator")
        return ticket

    def test_approved_features_go_out_together_as_one_release(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        first, second = self.approved_preview(1), self.approved_preview(2)
        normal = self.enqueue(9)["ticket"]["id"]
        self.call("release", "--by", "owner: ship it", actor="worker", ok=False)
        self.call("release", "--by", "x", actor="builder", ok=False)  # only --auto
        started = self.call("release", "--by", "owner: ship it", "--token-file", str(self.token), actor="orchestrator")
        self.assertEqual((started["batch"], started["tickets"]), (1, [first, second]))
        self.call("release", "--by", "again", "--token-file", str(self.token), actor="orchestrator", ok=False)
        # The batch goes before other validation work and is claimed whole.
        batch = self.call("claim")
        self.assertEqual((batch["batch"], [t["id"] for t in batch["tickets"]]),
                         (1, [first, second]))
        self.assertEqual({self.ticket(t)["status"] for t in (first, second)}, {"releasing"})
        held = self.call("claim")
        self.assertEqual([t["id"] for t in held["active_batch"]["tickets"]], [first, second])
        self.assertEqual(len(self.call("status")["preview_train"]), 2)
        # A failure attributed to one member blocks only it; it leaves the app's train.
        self.call("set", "--ticket", str(second), "--status", "blocked",
                  "--note", "bisect: F2 breaks HistoryTests/testOrder")
        self.assertTrue(self.call("status")["preview_rebuild"])
        self.call("set", "--ticket", str(first), "--status", "done", "--note", "build 1802")
        self.assertEqual(self.call("claim")["ticket"]["id"], normal)

    def test_a_batch_member_can_return_without_blame_and_auto_release_needs_the_builder(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        first = self.approved_preview(1)
        self.call("release", "--by", "auto: 1 approved", "--auto", actor="orchestrator", ok=False)
        self.call("release", "--by", "auto: 1 approved", "--auto")
        self.call("claim")
        self.call("set", "--ticket", str(first), "--status", "approved",
                  "--note", "environment stopped the batch")
        self.assertEqual(self.ticket(first)["status"], "approved")
        self.assertEqual(self.call("release", "--by", "r", "--token-file", str(self.token), actor="orchestrator")["batch"], 2)

    def test_without_a_configured_orchestrator_no_decision_is_relayed(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        db = sqlite3.connect(self.repo / ".git" / "exodia-build-queue.sqlite3")
        db.execute("DELETE FROM config WHERE key='orchestrator'")
        db.commit()
        db.close()
        ticket = self.preview(1, self.ui_change())["ticket"]["id"]
        self.call("preview-claim")
        self.await_approval(ticket)
        error = self.decide("approve", ticket, "--by", "owner", "--note", "x",
                          actor="orchestrator", ok=False)["error"]
        self.assertIn("activate --orchestrator", error)

    def test_resubmission_after_a_block_keeps_its_place_twice(self):
        places = []
        ticket = self.enqueue(1)["ticket"]
        other = self.enqueue(2)["ticket"]["id"]
        for round_ in range(3):
            self.assertEqual(self.call("claim")["ticket"]["id"], ticket["id"])
            self.update(ticket["id"], "blocked")
            head = self.ui_change(f"Sources/App/Fix{round_}.swift")
            ticket = self.enqueue(1, head=head)["ticket"]
            places.append(ticket["position"])
        self.assertEqual(places, [1, 1, 2])  # the third resubmission goes behind #2
        self.assertEqual(self.call("claim")["ticket"]["id"], other)

    def test_a_ticket_whose_dependency_stays_blocked_goes_back_to_its_author(self):
        parent = self.enqueue(1)["ticket"]["id"]
        child = self.call("enqueue", "--pr", "https://github.com/example/app/pull/2",
                          "--head", self.head, "--title", "Child", "--checks", "x",
                          "--acceptance", "x", "--session", "worker",
                          "--depends-on", "https://github.com/example/app/pull/1")["ticket"]["id"]
        self.call("claim")
        self.update(parent, "blocked")
        self.assertEqual(self.call("return-stale-dependencies")["returned"], [])
        self.assertEqual(self.call("return-stale-dependencies", "--minutes", "0")["returned"],
                         [child])
        returned = self.ticket(child)
        self.assertEqual(returned["status"], "blocked")
        self.assertIn("dependency", returned["note"])
        self.assertEqual(self.call("events", "--pending", "--ticket", str(child))[-1]["status"],
                         "blocked")
        self.call("return-stale-dependencies", actor="worker", ok=False)

    def test_open_status_lists_open_work_and_its_history_only(self):
        old = self.enqueue(1)["ticket"]["id"]
        self.call("claim")
        self.call("set", "--ticket", str(old), "--status", "done", "--note", "n" * 2000)
        history = self.enqueue(2)["ticket"]["id"]
        self.call("claim")
        self.call("set", "--ticket", str(history), "--status", "blocked", "--note", "b" * 2000)
        current = self.enqueue(2, head=self.ui_change())["ticket"]["id"]
        listed = self.call("status", "--open")["tickets"]
        self.assertEqual([t["id"] for t in listed], [history, current])
        self.assertLess(len(listed[0]["note"]), 700)
        self.assertEqual(len(self.call("status")["tickets"]), 3)

    # Builder review of #626 (2026-11-26): each scenario of its workflow probe.

    def installed_preview(self, pr=1, name=None):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        ticket = self.preview(pr, self.ui_change(name or f"Sources/App/View{pr}.swift"))["ticket"]
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], ticket["id"])
        self.await_approval(ticket["id"])
        return self.ticket(ticket["id"])

    def test_resubmitted_preview_keeps_place_when_build_in_flight(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        first = self.preview(1, self.ui_change())["ticket"]
        self.call("preview-claim")
        self.preview(2, self.ui_change("Sources/App/SecondView.swift"))
        fixed = self.preview(1, self.ui_change(content="fixed"))["ticket"]
        self.assertEqual(first["queued_at"], fixed["queued_at"])
        self.await_approval(first["id"])
        self.assertEqual(self.ticket(first["id"])["status"], "superseded")
        self.assertEqual(fixed["id"], self.call("preview-claim")["ticket"]["id"])

    def test_old_preview_cannot_return_to_queue_after_replacement(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        first = self.preview(1, self.ui_change())["ticket"]
        self.call("preview-claim")
        newest = self.preview(1, self.ui_change(content="fixed"))["ticket"]
        self.update(first["id"], "queued")
        self.assertEqual(self.ticket(first["id"])["status"], "superseded")
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], newest["id"])

    def test_normal_resubmission_reconciles_installed_preview(self):
        installed = self.installed_preview()
        self.assertFalse(self.call("status")["preview_rebuild"])
        replacement = self.enqueue(1, self.ui_change(content="fixed"))["ticket"]
        self.assertEqual(replacement["lane"], "")
        self.assertEqual(self.ticket(installed["id"])["status"], "superseded")
        self.assertTrue(self.call("status")["preview_rebuild"])

    def test_stale_head_snapshot_ignores_a_priority_resubmission(self):
        old = self.enqueue(1, self.ui_change(content="first"))["ticket"]
        self.call("claim")
        self.update(old["id"], "blocked")
        self.git("push", "-q", str(self.pulls), f"{old['head']}:refs/pull/1/head")
        import time
        time.sleep(0.01)
        new = self.enqueue(1, self.ui_change(content="revised"))["ticket"]
        self.assertEqual(new["queued_at"], old["queued_at"])  # kept its place
        self.git("push", "-q", "-f", str(self.pulls), f"{new['head']}:refs/pull/1/head")
        self.assertEqual(self.call("claim")["ticket"]["id"], new["id"])
        self.assertGreater(self.ticket(new["id"])["submitted_at"], old["queued_at"])

    def test_rebuilding_rejected_parent_excludes_dependent_preview(self):
        parent = self.installed_preview()
        self.git("checkout", "-q", "--detach", parent["head"])
        child = self.preview(2, self.commit({"Sources/App/ChildView.swift": "// child"}),
                             depends_on=[parent["pr"]])["ticket"]
        self.assertEqual(self.call("preview-claim")["ticket"]["id"], child["id"])
        self.await_approval(child["id"])
        self.decide("reject", parent["id"], "--note", "revise")
        self.assertEqual(self.ticket(child["id"])["status"], "blocked")
        claim = self.call("preview-claim")
        self.assertEqual((claim["train"], claim["rebuild"]), ([], True))

    def test_finishing_earlier_rebuild_preserves_new_decision(self):
        first = self.installed_preview(1)
        second = self.preview(2, self.ui_change("Sources/App/SecondView.swift"))["ticket"]
        self.call("preview-claim")
        self.await_approval(second["id"])
        self.decide("reject", first["id"], "--note", "revise")
        snapshot = self.call("preview-claim")
        self.assertTrue(snapshot["rebuild"])
        built = json.dumps([{"ticket": t["ticket"], "head": t["head"]} for t in snapshot["train"]])
        self.decide("reject", second["id"], "--note", "revise too")
        # The rebuild of the older snapshot cannot be recorded as current any more.
        self.call("preview-rebuilt", "--installed-train", built, ok=False)
        self.assertTrue(self.call("status")["preview_rebuild"])
        self.call("preview-rebuilt", "--installed-train", "[]")
        self.assertFalse(self.call("status")["preview_rebuild"])

    def test_preview_does_not_cross_install_hold(self):
        ordinary = self.enqueue(9)["ticket"]
        self.call("claim")
        self.call("set", "--ticket", str(ordinary["id"]), "--status", "pending_install",
                  "--hold", "--note", "manual permission")
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        self.preview(1, self.ui_change())
        claim = self.call("preview-claim")
        self.assertEqual((claim["claimed"], claim["held_for_install"]), (False, [ordinary["id"]]))
        # Grouped installs and protected-data checks pending also wait.
        self.call("set", "--ticket", str(ordinary["id"]), "--status", "pending_install",
                  "--retry-install", "--note", "protected-data tests pending")
        self.assertFalse(self.call("preview-claim")["claimed"])

    def test_dependency_return_does_not_spend_review_priority(self):
        parent = self.enqueue(9)["ticket"]
        self.call("claim")
        self.update(parent["id"], "blocked")
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        child = self.preview(1, self.ui_change(), depends_on=[parent["pr"]])["ticket"]
        self.call("return-stale-dependencies", "--minutes", "0")
        self.assertEqual(self.ticket(child["id"])["status"], "blocked")
        again = self.preview(1, self.ui_change(content="again"),
                             depends_on=[parent["pr"]])["ticket"]
        self.assertEqual((again["queued_at"], again["resubmits"]), (child["queued_at"], 0))

    def test_admission_reads_the_whole_composition_and_the_changed_lines(self):
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        ui = self.ui_change("Sources/App/Panel.swift", "let width = 12\n")
        self.assertEqual(self.call("preview-admit", "--base", self.head, "--commit", ui),
                         {"admissible": True, "reasons": []})
        for name, content in (("Sources/App/Panel.swift", "UserDefaults.standard.set(1)\n"),
                              ("Sources/App/Model.swift", "struct A: Codable {}\n"),
                              ("scripts/helper.sh", "echo\n"), ("Makefile", "all:\n")):
            change = self.ui_change(name, content)
            result = self.call("preview-admit", "--base", self.head, "--commit", change)
            self.assertFalse(result["admissible"], name)
            self.assertIn(name, result["reasons"][0])
        self.assertFalse(self.call("preview-admit", "--base", self.head,
                                   "--commit", "0" * 40)["admissible"])  # unknown: closed
        risky = self.preview(5, self.ui_change("Sources/App/Keys.swift", "SecItemAdd(q, nil)\n"))
        claim = self.call("preview-claim")
        self.assertEqual(claim["moved_to_normal_lane"], [risky["ticket"]["id"]])

    def test_decisions_need_the_token_and_the_exact_head_and_build(self):
        ticket = self.installed_preview()
        self.decide("approve", ticket["id"], "--by", "owner", "--note", "x", token=False, ok=False)
        self.decide("approve", ticket["id"], "--by", "owner", "--note", "x", build="9", ok=False)
        self.decide("approve", ticket["id"], "--by", "owner", "--note", "x", head="a" * 40,
                    ok=False)
        wrong = Path(self.temp.name) / "wrong-token"
        wrong.write_text("w" * 40)
        self.call("approve", "--ticket", str(ticket["id"]), "--head", ticket["head"], "--build",
                  "1801", "--by", "owner", "--note", "x", "--token-file", str(wrong),
                  actor="orchestrator", ok=False)
        self.decide("approve", ticket["id"], "--by", "owner: OK", "--note", "x")
        self.assertEqual(self.ticket(ticket["id"])["status"], "approved")

    def test_the_composition_is_rechecked_right_before_the_handoff(self):
        first = self.installed_preview(1)
        second = self.preview(2, self.ui_change("Sources/App/Second.swift"))["ticket"]
        self.call("preview-claim")
        planned = json.dumps([{"ticket": first["id"], "head": first["head"]},
                              {"ticket": second["id"], "head": second["head"]}])
        self.assertTrue(self.call("preview-current", "--installed-train", planned)["current"])
        self.decide("reject", first["id"], "--note", "no")
        self.assertFalse(self.call("preview-current", "--installed-train", planned)["current"])
        self.call("set", "--ticket", str(second["id"]), "--status", "awaiting_approval",
                  "--note", "x", "--preview-build", "1802", "--installed-train", planned,
                  ok=False)

    def test_a_disabled_lane_sends_previews_to_normal_validation(self):
        (self.repo / ".git" / "whytap-build-queue-builder.json").write_text("{}")
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        routed = self.preview(1, self.ui_change())["ticket"]
        self.assertEqual(routed["lane"], "")
        (self.repo / ".git" / "whytap-build-queue-builder.json").write_text(
            json.dumps({"preview_lane": True}))
        queued = self.preview(2, self.ui_change("Sources/App/B.swift"))["ticket"]
        self.assertEqual(self.call("preview-lane-off")["moved_to_normal_lane"], [queued["id"]])
        self.assertEqual(self.call("claim")["ticket"]["id"], routed["id"])

if __name__ == "__main__":
    unittest.main()
