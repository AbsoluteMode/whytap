"""The release check of Resources/WhatsNew.json: a release needs its entry."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("whats_new", ROOT / "scripts/whats-new.py")
whats_new = importlib.util.module_from_spec(spec)
spec.loader.exec_module(whats_new)


def catalog(*releases):
    return {"releases": list(releases)}


def release(version, *titles):
    return {"version": version, "items": [{"title": title, "body": "What it does now."} for title in titles]}


class WhatsNewCheckTests(unittest.TestCase):
    def test_the_shipped_list_is_valid_for_the_current_version(self):
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        shipped = json.loads((ROOT / "Resources/WhatsNew.json").read_text(encoding="utf-8"))
        self.assertEqual(whats_new.problems(shipped, version), [])

    def test_a_release_without_its_entry_is_refused(self):
        found = whats_new.problems(catalog(release("2.2.27", "Calendar is open")), "2.2.28")
        self.assertEqual(len(found), 1)
        self.assertIn("no entry for 2.2.28", found[0])

    def test_a_release_with_nothing_to_show_passes_with_empty_items(self):
        self.assertEqual(whats_new.problems(catalog(release("2.2.28")), "2.2.28"), [])
        found = whats_new.problems(catalog({"version": "2.2.28"}), "2.2.28")
        self.assertTrue(any('"items" is missing' in problem for problem in found))

    def test_long_or_pull_request_like_text_is_refused(self):
        long_title = release("2.2.28", "x" * (whats_new.MAX_TITLE + 1))
        self.assertTrue(any("title over" in p for p in whats_new.problems(catalog(long_title), "2.2.28")))
        long_body = {"version": "2.2.28", "items": [{"title": "Fine", "body": "y" * (whats_new.MAX_BODY + 1)}]}
        self.assertTrue(any("body over" in p for p in whats_new.problems(catalog(long_body), "2.2.28")))
        many = release("2.2.28", *[f"Item {n}" for n in range(whats_new.MAX_ITEMS + 1)])
        self.assertTrue(any("at most" in p for p in whats_new.problems(catalog(many), "2.2.28")))
        pr = {"version": "2.2.28", "items": [{"title": "Fix", "body": "Merged #443 for Smart."}]}
        self.assertTrue(any("pull request" in p for p in whats_new.problems(catalog(pr), "2.2.28")))
        twice = catalog(release("2.2.28", "One"), release("2.2.28", "Two"))
        self.assertTrue(any("more than once" in p for p in whats_new.problems(twice, "2.2.28")))

    def test_a_field_the_app_cannot_read_is_refused(self):
        """The app drops the whole list on one wrong type; the builder's fixtures of ticket 517."""
        def one(**fields):
            item = {"title": "Calendar is open", "body": "What it does now."}
            item.update(fields)
            return catalog({"version": "2.2.28", "items": [item]})

        wrong = {
            "symbol": one(symbol=7),
            "video": one(video=["agent"]),
            "link": one(link="apiAndModels"),
            "link.settings": one(link={"title": "Open Models", "settings": 3}),
            "link.title": one(link={"settings": "apiAndModels"}),
            "date": catalog({"version": "2.2.28", "date": 20261201, "items": []}),
        }
        for field, broken in wrong.items():
            found = whats_new.problems(broken, "2.2.28")
            self.assertTrue(any(f'"{field}"' in problem for problem in found), (field, found))
        self.assertEqual(whats_new.problems(one(symbol="calendar", video="agent", link={
            "title": "Open Models", "settings": "apiAndModels"}), "2.2.28"), [])
        self.assertEqual(whats_new.problems(one(symbol=None, link=None), "2.2.28"), [], "null is an absent field")
        self.assertTrue(any("not an object" in p for p in whats_new.problems(
            catalog({"version": "2.2.28", "items": ["Calendar is open"]}), "2.2.28")))

    def test_versions_and_titles_the_app_would_confuse_are_refused(self):
        same = catalog(release("2.3", "One"), release("2.3.0", "Two"))
        self.assertTrue(any("the same version to the app" in p for p in whats_new.problems(same, "2.3")))
        self.assertEqual(whats_new.problems(catalog(release("2.3", "One")), "2.3.0"), [], "2.3.0 is the 2.3 entry")
        titles = catalog(release("2.2.28", "One", "One"))
        self.assertTrue(any("two items are titled" in p for p in whats_new.problems(titles, "2.2.28")))
        # A version that is a list or an object is reported, not a crash.
        for odd in ([2, 2, 28], {"major": 2}, 2.2, None):
            twice = catalog({"version": odd, "items": []}, {"version": odd, "items": []}, release("2.2.28"))
            found = whats_new.problems(twice, "2.2.28")
            self.assertEqual(len([p for p in found if "no numeric version" in p]), 2, odd)
        self.assertEqual(whats_new.problems(catalog(release("2.2.28")), "2.2.28-rc1"), [], "the app compares the numbers")
        self.assertTrue(any("not numeric" in p for p in whats_new.problems(catalog(release("2.2.28")), "beta")))

    def test_the_command_fails_on_a_missing_or_damaged_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "WhatsNew.json"
            self.assertEqual(whats_new.main(["check", "2.2.28", "--file", str(path)]), 1)
            path.write_text("{ not json", encoding="utf-8")
            self.assertEqual(whats_new.main(["check", "2.2.28", "--file", str(path)]), 1)
            path.write_text(json.dumps(catalog(release("2.2.28", "Calendar is open"))), encoding="utf-8")
            self.assertEqual(whats_new.main(["check", "2.2.28", "--file", str(path)]), 0)
            self.assertEqual(whats_new.main(["check", "2.2.29", "--file", str(path)]), 1)


if __name__ == "__main__":
    unittest.main()
