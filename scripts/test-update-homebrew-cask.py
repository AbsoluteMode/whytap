#!/usr/bin/env python3
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cask", Path(__file__).with_name("update-homebrew-cask.py"))
cask = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cask)

OLD_SHA = "a" * 64
NEW_SHA = "b" * 64
CASK = f'''cask "whytap" do
  version "2.2.25"
  sha256 "{OLD_SHA}"

  url "https://github.com/AbsoluteMode/whytap/releases/download/v#{{version}}/Whytap-latest.dmg"
  name "Whytap"
  homepage "https://whytap.ai/"

  auto_updates true
  app "Whytap.app"
end
'''


class FakeGitHub:
    """Stands in for `gh api`: one cask file in the tap, one release."""

    def __init__(self, text=CASK, digest=None, tag="v2.2.26", conflicts=0):
        self.text, self.blob, self.digest, self.tag = text, "blob1", digest, tag
        self.conflicts, self.puts = conflicts, []

    def __call__(self, args, stdin=None):
        path = args[-1] if "PUT" not in args else args[args.index("PUT") + 1]
        if "PUT" in args:
            fields = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in args if "=" in a and not a.startswith("-")}
            if self.conflicts:
                self.conflicts -= 1
                self.blob = "blob-moved"
                raise cask.CaskError("gh api failed: 409 sha does not match")
            if fields["sha"] != self.blob:
                raise cask.CaskError("gh api failed: 409 sha does not match")
            self.text = base64.b64decode(fields["content"]).decode()
            self.blob = f"blob{len(self.puts) + 2}"
            self.puts.append(fields["message"])
            return "{}"
        if "/contents/" in path:
            return json.dumps({"content": base64.b64encode(self.text.encode()).decode(), "sha": self.blob})
        if "/releases/" in path:
            asset = {"name": "Whytap-latest.dmg"}
            if self.digest:
                asset["digest"] = f"sha256:{self.digest}"
            return json.dumps({"tag_name": self.tag, "assets": [asset]})
        raise AssertionError(path)


class RewriteTests(unittest.TestCase):
    def test_new_release_changes_only_version_and_sha(self):
        updated = cask.rewrite_cask(CASK, "2.2.26", NEW_SHA)
        self.assertEqual(updated, CASK.replace("2.2.25", "2.2.26", 1).replace(OLD_SHA, NEW_SHA))
        self.assertIn("v#{version}/Whytap-latest.dmg", updated)

    def test_same_release_is_unchanged(self):
        self.assertEqual(cask.rewrite_cask(CASK, "2.2.25", OLD_SHA), CASK)

    def test_downgrade_is_refused_unless_allowed(self):
        with self.assertRaises(cask.CaskError):
            cask.rewrite_cask(CASK, "2.2.24", NEW_SHA)
        self.assertIn('version "2.2.24"', cask.rewrite_cask(CASK, "2.2.24", NEW_SHA, allow_downgrade=True))

    def test_two_digit_components_compare_numerically(self):
        self.assertIn('"2.2.100"', cask.rewrite_cask(CASK, "2.2.100", NEW_SHA))
        with self.assertRaises(cask.CaskError):
            cask.rewrite_cask(CASK.replace("2.2.25", "2.10.0"), "2.9.9", NEW_SHA)

    def test_malformed_inputs_are_refused(self):
        for version, sha in [("2.2", NEW_SHA), ("v2.2.26", NEW_SHA), ("2.2.26", "XYZ"), ("2.2.26", NEW_SHA.upper())]:
            with self.assertRaises(cask.CaskError, msg=(version, sha)):
                cask.rewrite_cask(CASK, version, sha)

    def test_cask_with_duplicate_or_missing_lines_is_refused(self):
        with self.assertRaises(cask.CaskError):
            cask.rewrite_cask(CASK + '  version "1.0.0"\n', "2.2.26", NEW_SHA)
        with self.assertRaises(cask.CaskError):
            cask.rewrite_cask(CASK.replace(f'sha256 "{OLD_SHA}"', "sha256 :no_check"), "2.2.26", NEW_SHA)

    def test_url_of_another_repository_is_refused(self):
        with self.assertRaises(cask.CaskError):
            cask.rewrite_cask(CASK.replace("AbsoluteMode/whytap", "someone/else"), "2.2.26", NEW_SHA)
        self.assertIn("someone/else", cask.rewrite_cask(CASK.replace("AbsoluteMode/whytap", "someone/else"),
                                                        "2.2.26", NEW_SHA, repo="someone/else"))


class UpdateFlowTests(unittest.TestCase):
    def run_main(self, fake, *argv):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(cask, "run_gh", fake), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cask.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def dmg(self, directory, content=b"dmg bytes"):
        path = Path(directory) / "Whytap-latest.dmg"
        path.write_bytes(content)
        return str(path), cask.sha256_file(path)

    def test_update_with_local_dmg_commits_once(self):
        with tempfile.TemporaryDirectory() as directory:
            path, sha = self.dmg(directory)
            fake = FakeGitHub(digest=sha)
            code, out, _ = self.run_main(fake, "update", "--version", "2.2.26", "--dmg", path)
        self.assertEqual(code, 0, out)
        self.assertEqual(fake.puts, ["Whytap 2.2.26"])
        self.assertEqual(cask.parse_cask(fake.text), ("2.2.26", sha))

    def test_second_run_changes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            path, sha = self.dmg(directory)
            fake = FakeGitHub(digest=sha)
            self.run_main(fake, "update", "--version", "2.2.26", "--dmg", path)
            code, out, _ = self.run_main(fake, "update", "--version", "2.2.26", "--dmg", path)
        self.assertEqual((code, len(fake.puts)), (0, 1))
        self.assertIn("nothing to do", out)

    def test_hash_that_disagrees_with_github_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _ = self.dmg(directory)
            fake = FakeGitHub(digest=NEW_SHA)
            code, _, err = self.run_main(fake, "update", "--version", "2.2.26", "--dmg", path)
        self.assertEqual((code, fake.puts), (1, []))
        self.assertIn("disagrees", err)

    def test_draft_release_without_asset_is_refused(self):
        fake = FakeGitHub()
        original = fake.__call__

        def no_assets(args, stdin=None):
            if "/releases/" in args[-1]:
                return json.dumps({"tag_name": "v2.2.26", "assets": []})
            return original(args, stdin)

        code, _, err = self.run_main(no_assets, "update", "--version", "2.2.26")
        self.assertEqual(code, 1)
        self.assertIn("no asset", err)

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            path, sha = self.dmg(directory)
            fake = FakeGitHub(digest=sha)
            code, out, _ = self.run_main(fake, "update", "--version", "2.2.26", "--dmg", path, "--dry-run")
        self.assertEqual((code, fake.puts, fake.text), (0, [], CASK))
        self.assertIn("Would set", out)

    def test_concurrent_edit_is_retried_once_then_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            path, sha = self.dmg(directory)
            retried = FakeGitHub(digest=sha, conflicts=1)
            self.assertEqual(self.run_main(retried, "update", "--version", "2.2.26", "--dmg", path)[0], 0)
            stuck = FakeGitHub(digest=sha, conflicts=2)
            code, _, err = self.run_main(stuck, "update", "--version", "2.2.26", "--dmg", path)
        self.assertEqual(code, 1)
        self.assertIn("409", err)

    def test_downgrade_through_the_command_fails_without_a_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            path, sha = self.dmg(directory)
            fake = FakeGitHub(digest=sha, tag="v2.2.24")
            code, _, err = self.run_main(fake, "update", "--version", "2.2.24", "--dmg", path)
        self.assertEqual((code, fake.puts), (1, []))
        self.assertIn("refusing", err)

    def test_check_reports_stale_and_current(self):
        stale = FakeGitHub(digest=NEW_SHA, tag="v2.2.26")
        code, out, _ = self.run_main(stale, "check")
        self.assertEqual(code, 1)
        self.assertIn("STALE", out)
        current = FakeGitHub(text=CASK.replace("2.2.25", "2.2.26").replace(OLD_SHA, NEW_SHA),
                             digest=NEW_SHA, tag="v2.2.26")
        self.assertEqual(self.run_main(current, "check")[0], 0)


if __name__ == "__main__":
    unittest.main()
