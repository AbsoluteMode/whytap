#!/usr/bin/env python3
"""Refuse a local install that would not move the working app forward.

`local-install-floor.py <installed Info.plist> <display version> <build>` exits 0
when the candidate may replace the installed app: its build number is higher and
its display version is not lower by Semantic Versioning precedence (a prerelease
sorts below its release, so 2.2.27-beta.1 never replaces 2.2.27). Anything it
cannot compare is refused. Called by build-dmg.sh for EXODIA_LOCAL_INSTALL=1.

WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
"""
import plistlib
import re
import sys

SEMVER = re.compile(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def precedence(version):
    """A sortable key for every display version build-dmg.sh accepts, or None."""
    match = SEMVER.fullmatch(str(version).strip())
    if not match:
        return None
    core = tuple(int(part) for part in match.groups()[:3])
    if match.group(4) is None:
        return core + ((1,),)  # a release sorts above all of its prereleases
    identifiers = tuple((0, int(part), "") if part.isdigit() else (1, 0, part)
                        for part in match.group(4).split("."))
    return core + ((0,) + identifiers,)


def refusal(installed, version, build):
    """Why the candidate may not replace the installed app, or None."""
    try:
        installed_build = int(str(installed.get("CFBundleVersion", "0")).strip() or 0)
        candidate_build = int(build)
    except ValueError:
        return "the build numbers cannot be compared"
    if candidate_build <= installed_build:
        return f"local install build {build} is not higher than the installed {installed_build}"
    installed_version = str(installed.get("CFBundleShortVersionString", "0.0.0"))
    ours, theirs = precedence(version), precedence(installed_version)
    if ours is None or theirs is None:
        return (f"local install version {version} cannot be compared with the installed "
                f"{installed_version}")
    if ours < theirs:
        return f"local install version {version} is lower than the installed {installed_version}"
    return None


def main(argv):
    if len(argv) != 3:
        print("usage: local-install-floor.py <Info.plist> <version> <build>", file=sys.stderr)
        return 2
    try:
        with open(argv[0], "rb") as handle:
            installed = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"ERROR: the installed app's Info.plist cannot be read: {error}", file=sys.stderr)
        return 1
    reason = refusal(installed, argv[1], argv[2])
    if reason:
        print("ERROR: " + reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
