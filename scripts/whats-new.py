#!/usr/bin/env python3
"""Check the What's New list a release ships with (Resources/WhatsNew.json).

    scripts/whats-new.py check 2.2.28

A public release needs an entry for its version: the short list a person sees
in a window after the update. A release that changed nothing a person can
notice still needs its entry, with "items": [] (no window opens for it).
The app drops the whole list when one field has the wrong type, so every
field's type is checked here. The limits match WhatsNewCatalog in the app,
which a unit test keeps equal.
"""

import argparse
import json
import re
import sys
from pathlib import Path

MAX_ITEMS = 5
MAX_TITLE = 36
MAX_BODY = 120
DEFAULT_FILE = Path(__file__).resolve().parent.parent / "Resources" / "WhatsNew.json"


def version_key(text):
    """The numbers the app compares: "2.3" and "2.3.0" are one version."""
    parts = [int(part) for part in text.split(".")]
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def is_version(value):
    return isinstance(value, str) and re.fullmatch(r"\d+(\.\d+)*", value) is not None


def numeric_prefix(text):
    """The numbers a display version starts with ("2.2.28-rc1" is 2.2.28), like the app."""
    match = re.match(r"\d+(\.\d+)*", text) if isinstance(text, str) else None
    return match.group(0) if match else None


def text_problem(value):
    """Why an optional text field cannot ship, or None."""
    if not isinstance(value, str):
        return "is not text"
    if not value.strip():
        return "is empty"
    return None


def item_problems(name, item, seen_titles):
    if not isinstance(item, dict):
        return [f"{name}: an item is not an object"]
    found = []
    title = item.get("title")
    body = item.get("body")
    if not isinstance(title, str) or not title.strip():
        return [f"{name}: an item has no title"]
    if title in seen_titles:
        found.append(f"{name}: two items are titled {title!r}")
    seen_titles.add(title)
    if len(title) > MAX_TITLE:
        found.append(f"{name}: title over {MAX_TITLE} characters: {title!r}")
    if not isinstance(body, str) or not body.strip():
        found.append(f"{name}: {title!r} has no body")
    elif len(body) > MAX_BODY:
        found.append(f"{name}: body over {MAX_BODY} characters: {title!r}")
    if isinstance(body, str) and re.search(r"#\d+|\bPR\b", f"{title} {body}"):
        found.append(f"{name}: {title!r} reads like a pull request, not like a change for a person")
    for field in ("symbol", "video"):
        if field in item and item[field] is not None:
            problem = text_problem(item[field])
            if problem:
                found.append(f'{name}: {title!r}: "{field}" {problem}')
    if "link" in item and item["link"] is not None:
        link = item["link"]
        if not isinstance(link, dict):
            found.append(f'{name}: {title!r}: "link" is not an object')
        else:
            for field in ("title", "settings"):
                problem = text_problem(link.get(field)) if field in link else "is missing"
                if problem:
                    found.append(f'{name}: {title!r}: "link.{field}" {problem}')
    return found


def problems(catalog, version):
    """Every reason the list cannot ship for `version`; empty when it can."""
    found = []
    releases = catalog.get("releases") if isinstance(catalog, dict) else None
    if not isinstance(releases, list):
        return ['the file needs a "releases" list']
    keys = {}
    for release in releases:
        if not isinstance(release, dict):
            found.append("a release is not an object")
            continue
        name = release.get("version")
        if not is_version(name):
            found.append(f"a release has no numeric version: {name!r}")
            continue
        key = version_key(name)
        if key in keys:
            same = "more than once" if keys[key] == name else f"also as {keys[key]} (the same version to the app)"
            found.append(f"version {name} is listed {same}")
        keys.setdefault(key, name)
        if "date" in release and release["date"] is not None:
            date = release["date"]
            if not isinstance(date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
                found.append(f'{name}: "date" is not a YYYY-MM-DD text: {date!r}')
        items = release.get("items")
        if not isinstance(items, list):
            found.append(f'{name}: "items" is missing (use [] for a release with nothing to show)')
            continue
        if len(items) > MAX_ITEMS:
            found.append(f"{name}: {len(items)} items, at most {MAX_ITEMS}")
        titles = set()
        for item in items:
            found.extend(item_problems(name, item, titles))
    wanted = numeric_prefix(version)
    if wanted is None:
        found.append(f"the version to check is not numeric: {version!r}")
    elif version_key(wanted) not in keys:
        found.append(
            f'no entry for {version}: add {{"version": "{version}", "items": [...]}} to Resources/WhatsNew.json '
            '(or "items": [] when nothing changed for the person) before the VERSION change'
        )
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="fail unless the list can ship for this version")
    check.add_argument("version")
    check.add_argument("--file", type=Path, default=DEFAULT_FILE)
    args = parser.parse_args(argv)

    try:
        catalog = json.loads(args.file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"whats-new: cannot read {args.file}: {error}", file=sys.stderr)
        return 1
    found = problems(catalog, args.version)
    for problem in found:
        print(f"whats-new: {problem}", file=sys.stderr)
    if found:
        return 1
    wanted = version_key(numeric_prefix(args.version))
    entry = next(release for release in catalog["releases"] if version_key(release["version"]) == wanted)
    shown = len(entry["items"])
    print(f"whats-new: {args.version} ships {shown} item(s)" if shown else f"whats-new: {args.version} shows no window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
