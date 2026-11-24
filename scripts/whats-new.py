#!/usr/bin/env python3
"""Check the What's New list a release ships with (Resources/WhatsNew.json).

    scripts/whats-new.py check 2.2.28

A public release needs an entry for its version: the short list a person sees
in a window after the update. A release that changed nothing a person can
notice still needs its entry, with "items": [] (no window opens for it).
The limits match WhatsNewCatalog in the app, which a unit test keeps equal.
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


def problems(catalog, version):
    """Every reason the list cannot ship for `version`; empty when it can."""
    found = []
    releases = catalog.get("releases") if isinstance(catalog, dict) else None
    if not isinstance(releases, list):
        return ['the file needs a "releases" list']
    versions = [release.get("version") for release in releases if isinstance(release, dict)]
    for duplicate in sorted({v for v in versions if versions.count(v) > 1}, key=str):
        found.append(f"version {duplicate} is listed more than once")
    for release in releases:
        if not isinstance(release, dict):
            found.append("a release is not an object")
            continue
        name = release.get("version")
        if not isinstance(name, str) or not re.fullmatch(r"\d+(\.\d+)*", name):
            found.append(f"a release has no numeric version: {name!r}")
            continue
        items = release.get("items")
        if not isinstance(items, list):
            found.append(f'{name}: "items" is missing (use [] for a release with nothing to show)')
            continue
        if len(items) > MAX_ITEMS:
            found.append(f"{name}: {len(items)} items, at most {MAX_ITEMS}")
        for item in items:
            title = item.get("title") if isinstance(item, dict) else None
            body = item.get("body") if isinstance(item, dict) else None
            if not isinstance(title, str) or not title.strip():
                found.append(f"{name}: an item has no title")
                continue
            if len(title) > MAX_TITLE:
                found.append(f"{name}: title over {MAX_TITLE} characters: {title!r}")
            if not isinstance(body, str) or not body.strip():
                found.append(f"{name}: {title!r} has no body")
            elif len(body) > MAX_BODY:
                found.append(f"{name}: body over {MAX_BODY} characters: {title!r}")
            if re.search(r"#\d+|\bPR\b", f"{title} {body}"):
                found.append(f"{name}: {title!r} reads like a pull request, not like a change for a person")
    if version not in versions:
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
    entry = next(release for release in catalog["releases"] if release["version"] == args.version)
    shown = len(entry["items"])
    print(f"whats-new: {args.version} ships {shown} item(s)" if shown else f"whats-new: {args.version} shows no window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
