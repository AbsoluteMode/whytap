#!/usr/bin/env python3
"""Exercise concurrency and recovery using disposable repositories only."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-queue.py")


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
        self.call("configure", "--builder-thread", "builder")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def call(self, *args, actor="builder", cwd=None, ok=True, env=None):
        result = subprocess.run(["python3", str(SCRIPT), "--actor", actor, *args],
                                cwd=cwd or self.repo, capture_output=True, text=True,
                                env={**os.environ, **(env or {})})
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


if __name__ == "__main__":
    unittest.main()
