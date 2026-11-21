#!/usr/bin/env python3
"""install-dashboard and Monitor's deleted list, from the user's side.

WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
"""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "customize_monitor", Path(__file__).resolve().parents[1] / "customize.py")
customize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(customize)


def snapshot(dashboard_id: str, title: str) -> str:
    return json.dumps({"id": dashboard_id, "title": title,
                       "widgets": [{"id": "w", "kind": "text", "title": "Synthetic", "value": "Fixture"}]})


class MonitorDashboardInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="whytap-monitor-install-")
        self.home = Path(self.temporary.name).resolve()
        self.monitor = self.home / "Library/Application Support/com.rootwise.sidekey/Monitor"
        self.dashboards = self.monitor / "dashboards"
        self.dashboards.mkdir(parents=True)
        self.removed = self.monitor / "removed-dashboards.json"
        self.source = self.home / "proposed.json"
        home = patch.object(Path, "home", return_value=self.home)
        home.start()
        self.addCleanup(home.stop)
        self.addCleanup(self.temporary.cleanup)

    def install(self, *extra):
        errors = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
            code = customize.main(["install-dashboard", str(self.source), "--flavor", "prod", *extra])
        return code, errors.getvalue()

    def removed_ids(self):
        return json.loads(self.removed.read_text())["removed"]

    def test_broken_list_keeps_the_previous_snapshot_on_replace(self):
        previous = self.dashboards / "fixture-a.json"
        previous.write_text(snapshot("fixture-a", "Previous"))
        self.source.write_text(snapshot("fixture-a", "Proposed"))
        self.removed.write_text("{invalid JSON\n")

        code, error = self.install("--replace")

        self.assertEqual(code, 2)
        self.assertIn("removed-dashboards.json", error)
        self.assertEqual(json.loads(previous.read_text())["title"], "Previous")
        self.assertEqual(self.removed.read_text(), "{invalid JSON\n")

    def test_broken_list_creates_nothing_and_a_retry_after_fixing_it_installs(self):
        self.source.write_text(snapshot("fixture-b", "Fresh"))
        self.removed.write_text("{invalid JSON\n")

        code, _ = self.install()
        self.assertEqual(code, 2)
        self.assertFalse((self.dashboards / "fixture-b.json").exists())

        self.removed.write_text('{"removed": []}\n')
        code, error = self.install()
        self.assertEqual(code, 0, error)
        self.assertTrue((self.dashboards / "fixture-b.json").is_file())

    def test_reinstalling_a_deleted_board_lists_it_again_and_keeps_other_deletions(self):
        self.removed.write_text('{"removed": ["fixture-a", "openai-usage"]}\n')
        self.source.write_text(snapshot("fixture-a", "Back"))

        code, error = self.install()

        self.assertEqual(code, 0, error)
        self.assertEqual(self.removed_ids(), ["openai-usage"])
        self.assertEqual(os.stat(self.removed).st_mode & 0o777, 0o600)

    def test_dry_run_changes_nothing(self):
        self.removed.write_text('{"removed": ["fixture-a"]}\n')
        self.source.write_text(snapshot("fixture-a", "Back"))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = customize.main(["install-dashboard", str(self.source), "--flavor", "prod", "--dry-run"])
        self.assertEqual(code, 0)
        self.assertIn("listed again", output.getvalue())
        self.assertEqual(self.removed_ids(), ["fixture-a"])
        self.assertFalse((self.dashboards / "fixture-a.json").exists())

    def test_installer_waits_for_whytaps_lock_and_keeps_its_deletion(self):
        """Whytap saves a new deletion while holding the lock; the installer must merge, not overwrite."""
        self.removed.write_text('{"removed": ["fixture-a"]}\n')
        lock = os.open(self.monitor / customize.REMOVED_DASHBOARDS_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)

        def whytap_deletes_meanwhile():
            time.sleep(0.2)
            self.removed.write_text('{"removed": ["fixture-a", "newly-deleted"]}\n')
            os.close(lock)

        writer = threading.Thread(target=whytap_deletes_meanwhile)
        writer.start()
        self.assertTrue(customize.forget_removed_dashboard(self.monitor, "fixture-a"))
        writer.join()
        self.assertEqual(self.removed_ids(), ["newly-deleted"])

    def test_held_lock_times_out_without_changes(self):
        self.removed.write_text('{"removed": ["fixture-a"]}\n')
        previous = self.dashboards / "fixture-a.json"
        previous.write_text(snapshot("fixture-a", "Previous"))
        self.source.write_text(snapshot("fixture-a", "Proposed"))
        lock = os.open(self.monitor / customize.REMOVED_DASHBOARDS_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        self.addCleanup(os.close, lock)

        with patch.object(customize, "REMOVED_DASHBOARDS_LOCK_SECONDS", 0.1):
            code, error = self.install("--replace")

        self.assertEqual(code, 2)
        self.assertIn("try again", error)
        self.assertEqual(json.loads(previous.read_text())["title"], "Previous")
        self.assertEqual(self.removed_ids(), ["fixture-a"])


if __name__ == "__main__":
    unittest.main()
