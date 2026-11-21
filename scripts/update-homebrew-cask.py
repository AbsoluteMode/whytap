#!/usr/bin/env python3
"""Keep the Whytap Homebrew cask in step with a published release.

The cask lives in the public tap AbsoluteMode/homebrew-tap (Casks/whytap.rb). It
pins one release tag and the SHA-256 of that release's Whytap-latest.dmg, so
`brew install absolutemode/tap/whytap` installs exactly the archive that was
published. Only `version` and `sha256` change between releases.

  update-homebrew-cask.py update --version 2.2.26 [--dmg PATH] [--dry-run]
  update-homebrew-cask.py check                    # is the tap on the latest release?

`update` is called by scripts/upload-release.sh after a production release is
published; run it by hand to catch up. It edits the cask through the GitHub
contents API (one commit, conditional on the file's blob SHA), so it needs no
clone and no GitHub Actions. It refuses a downgrade, a cask whose url does not
point at this repository's release assets, and a hash that disagrees with the
digest GitHub reports for the published asset.

WHY: .project-docs/decisions/2026-11-21-homebrew-tap.md
"""

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

DEFAULT_REPO = "AbsoluteMode/whytap"
DEFAULT_TAP = "AbsoluteMode/homebrew-tap"
CASK_PATH = "Casks/whytap.rb"
ASSET_NAME = "Whytap-latest.dmg"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_LINE = re.compile(r'^(\s*version\s+)"([^"]*)"', re.MULTILINE)
SHA_LINE = re.compile(r'^(\s*sha256\s+)"([^"]*)"', re.MULTILINE)


class CaskError(Exception):
    pass


def version_key(version):
    if not VERSION_RE.match(version):
        raise CaskError(f"not a release version: {version!r}")
    return tuple(int(part) for part in version.split("."))


def parse_cask(text):
    versions, shas = VERSION_LINE.findall(text), SHA_LINE.findall(text)
    if len(versions) != 1 or len(shas) != 1:
        raise CaskError("the cask must contain exactly one version and one sha256 line")
    return versions[0][1], shas[0][1]


def rewrite_cask(text, version, sha256, repo=DEFAULT_REPO, allow_downgrade=False):
    """Return the cask text for a new release; raise CaskError if it is unsafe."""
    new_key = version_key(version)
    if not SHA_RE.match(sha256):
        raise CaskError("sha256 must be 64 lowercase hex characters")
    current_version, _ = parse_cask(text)
    if current_version != "latest" and not allow_downgrade and new_key < version_key(current_version):
        raise CaskError(f"refusing to move the cask back from {current_version} to {version}")
    expected_url = f"https://github.com/{repo}/releases/download/v#{{version}}/{ASSET_NAME}"
    if f'url "{expected_url}"' not in text:
        raise CaskError(f"the cask url does not point at the {repo} release asset {ASSET_NAME}")
    text = VERSION_LINE.sub(lambda m: f'{m.group(1)}"{version}"', text, count=1)
    return SHA_LINE.sub(lambda m: f'{m.group(1)}"{sha256}"', text, count=1)


def run_gh(args, stdin=None):
    result = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if result.returncode != 0:
        raise CaskError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
    return result.stdout


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "whytap-release"})
    with urllib.request.urlopen(request, timeout=300) as response, open(destination, "wb") as out:
        for block in iter(lambda: response.read(1024 * 1024), b""):
            out.write(block)


def published_digest(repo, tag):
    """The sha256 GitHub reports for the release's DMG, or None if it reports none."""
    release = json.loads(run_gh(["api", f"repos/{repo}/releases/tags/{tag}"]))
    for asset in release.get("assets", []):
        if asset.get("name") == ASSET_NAME:
            digest = asset.get("digest") or ""
            return digest[len("sha256:"):] if digest.startswith("sha256:") else None
    raise CaskError(f"release {tag} has no asset named {ASSET_NAME} (is it still a draft?)")


def release_hash(repo, version, dmg):
    tag = f"v{version}"
    reported = published_digest(repo, tag)
    if dmg:
        local = sha256_file(dmg)
    else:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / ASSET_NAME
            download(f"https://github.com/{repo}/releases/download/{tag}/{ASSET_NAME}", target)
            local = sha256_file(target)
    if reported and reported != local:
        raise CaskError(f"sha256 {local} disagrees with the {reported} GitHub reports for {tag}")
    return local


def read_cask(tap):
    answer = json.loads(run_gh(["api", f"repos/{tap}/contents/{CASK_PATH}"]))
    return base64.b64decode(answer["content"]).decode("utf-8"), answer["sha"]


def write_cask(tap, text, blob_sha, version):
    run_gh(["api", "-X", "PUT", f"repos/{tap}/contents/{CASK_PATH}",
            "-f", f"message=Whytap {version}",
            "-f", f"content={base64.b64encode(text.encode('utf-8')).decode('ascii')}",
            "-f", f"sha={blob_sha}", "-f", "branch=main"])


def update(args):
    version_key(args.version)
    sha256 = release_hash(args.repo, args.version, args.dmg)
    for attempt in range(2):
        current, blob_sha = read_cask(args.tap)
        updated = rewrite_cask(current, args.version, sha256, args.repo, args.allow_downgrade)
        if updated == current:
            print(f"Homebrew cask already at {args.version} ({sha256[:12]}…); nothing to do")
            return 0
        if args.dry_run:
            print(f"Would set {args.tap} {CASK_PATH} to {args.version} sha256 {sha256}")
            return 0
        try:
            write_cask(args.tap, updated, blob_sha, args.version)
        except CaskError:
            if attempt == 1:
                raise
            continue  # the file moved under us: read it again once
        print(f"Homebrew cask {args.tap} now at {args.version} sha256 {sha256}")
        return 0
    return 1


def check(args):
    release = json.loads(run_gh(["api", f"repos/{args.repo}/releases/latest"]))
    version = release["tag_name"].lstrip("v")
    reported = published_digest(args.repo, release["tag_name"])
    current_version, current_sha = parse_cask(read_cask(args.tap)[0])
    if current_version != version or (reported and current_sha != reported):
        print(f"STALE: cask is {current_version} ({current_sha[:12]}…), latest release is {version}")
        return 1
    print(f"Homebrew cask is on the latest release {version}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=DEFAULT_REPO, help="source repository (owner/name)")
    parser.add_argument("--tap", default=DEFAULT_TAP, help="tap repository (owner/name)")
    commands = parser.add_subparsers(dest="command", required=True)
    up = commands.add_parser("update", help="point the cask at a published release")
    up.add_argument("--version", required=True)
    up.add_argument("--dmg", help="local Whytap-latest.dmg of that release (default: download it)")
    up.add_argument("--dry-run", action="store_true")
    up.add_argument("--allow-downgrade", action="store_true")
    commands.add_parser("check", help="exit 1 if the cask is not on the latest release")
    args = parser.parse_args(argv)
    try:
        return update(args) if args.command == "update" else check(args)
    except CaskError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
