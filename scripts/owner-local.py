#!/usr/bin/env python3
"""Owner-local fast builds: put fixes into the owner's working app right away.

One combined local build = current origin/main + every fix still waiting for the
owner's check (the members), merged in order in a dedicated worktree, built as the
signed local arm64 app and installed into /Applications/Whytap.app when Whytap is
idle. Installing fix B therefore never drops fix A. No build queue, no builder, no
review: the owner tests; accepted fixes later go through one inquisition and one
batch build by the builder.

    python3 scripts/owner-local.py add 539 --accept "Drag a tool out past the glass: it is removed"
    python3 scripts/owner-local.py add 538@accc8def15514183c9ce76cbcdbe5abcd51d3402
    python3 scripts/owner-local.py build            # rebuild and install the current members
    python3 scripts/owner-local.py install          # install the last candidate (after a deferral)
    python3 scripts/owner-local.py drop 538         # the owner rejected it; next build leaves it out
    python3 scripts/owner-local.py status

`add` and `drop` rebuild and install unless --no-install (or --no-build). Members
whose PR is merged are dropped automatically. Exit codes: 0 done, 2 usage, 3 install
deferred (Whytap busy; the candidate is kept: run `install` later), 4 a member does
not merge (nothing built), 5 the build or a check failed, 6 the integration lock
stayed busy.

Everything runs under the shared `exodia-integration.lock` held by this one live
process. Kept: the same signing identity and bundle id (permissions and data
survive), a build number above the installed one, a rollback copy of the replaced
bundle, the meeting and Whytap activity gate right before a normal Quit (never a
force-quit), and build/CURRENT_BUILD.md in the primary checkout.

WHY: .project-docs/decisions/2026-11-28-local-fast-builds-batch-inquisition.md
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

APP = Path(os.environ.get("WHYTAP_OWNER_LOCAL_APP", "/Applications/Whytap.app"))
BUNDLE_ID = "com.rootwise.sidekey"
HOME_DIR = Path(os.environ.get("WHYTAP_OWNER_LOCAL_HOME", Path.home() / ".whytap-owner-local"))
WORKTREE = HOME_DIR / "worktree"
SHA = re.compile(r"[0-9a-f]{40}")
KEEP_ROLLBACKS = 3


class Stop(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def run(*args, cwd=None, check=True, capture=True, env=None):
    result = subprocess.run(list(args), cwd=cwd, text=True, env=env,
                            capture_output=capture)
    if check and result.returncode != 0:
        raise Stop(5, f"{' '.join(args[:4])}: {(result.stderr or result.stdout or '').strip()[-800:]}")
    return result


def common_dir():
    out = run("git", "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    return Path(out)


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def say(text):
    print(text, flush=True)


# ---------------------------------------------------------------- state and lock

def state_path(git):
    return git / "whytap-owner-local.json"


def load_state(git):
    try:
        state = json.loads(state_path(git).read_text())
    except (OSError, ValueError):
        state = {}
    state.setdefault("members", [])
    return state


def save_state(git, state):
    tmp = state_path(git).with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n")
    os.replace(tmp, state_path(git))


class IntegrationLock:
    """The shared mkdir lock of the workflow, owned by this live process."""

    def __init__(self, git, wait_seconds):
        self.path = git / "exodia-integration.lock"
        self.wait = wait_seconds
        self.held = False

    def __enter__(self):
        deadline = time.monotonic() + self.wait
        told = False
        while True:
            try:
                self.path.mkdir()
                break
            except FileExistsError:
                if not told:
                    owner = (self.path / "owner.json")
                    say("waiting for exodia-integration.lock: "
                        + (owner.read_text().strip() if owner.exists() else "owner unknown"))
                    told = True
                if time.monotonic() > deadline:
                    raise Stop(6, "the integration lock stayed busy; nothing changed")
                time.sleep(10)
        self.held = True
        (self.path / "owner.json").write_text(json.dumps({
            "session": "owner-local", "host": socket.gethostname(), "pid": os.getpid(),
            "acquired_at": now()}) + "\n")
        return self

    def __exit__(self, *exc):
        if self.held:
            shutil.rmtree(self.path, ignore_errors=True)


# ---------------------------------------------------------------- members

def parse_ref(text):
    """`539`, `#539` or `539@<sha>` -> (pr, sha or None)."""
    match = re.fullmatch(r"#?([1-9]\d*)(?:@([0-9a-f]{7,40}))?", text.strip())
    if not match:
        raise Stop(2, f"not a PR reference: {text!r} (use 539 or 539@<sha>)")
    return int(match.group(1)), match.group(2)


def fetch_member(repo, pr, pin):
    run("git", "fetch", "-q", "origin", f"+refs/pull/{pr}/head:refs/owner-local/pr-{pr}", cwd=repo)
    head = run("git", "rev-parse", f"refs/owner-local/pr-{pr}", cwd=repo).stdout.strip()
    if pin:
        full = run("git", "rev-parse", "--verify", "-q", pin + "^{commit}", cwd=repo,
                   check=False).stdout.strip()
        if not SHA.fullmatch(full):
            raise Stop(2, f"#{pr}: commit {pin} is not available locally or on the PR")
        if full != head:
            say(f"#{pr}: using pinned {full[:8]} (the PR head is now {head[:8]})")
        head = full
    return head


def merged(pr):
    result = run("gh", "pr", "view", str(pr), "--json", "state", "-q", ".state", check=False)
    return result.returncode == 0 and result.stdout.strip() == "MERGED"


# ---------------------------------------------------------------- compose and build

def installed_info():
    try:
        with open(APP / "Contents" / "Info.plist", "rb") as handle:
            return plistlib.load(handle)
    except (OSError, ValueError):
        return {}


def ensure_worktree(repo):
    if not (WORKTREE / ".git").exists():
        HOME_DIR.mkdir(parents=True, exist_ok=True)
        run("git", "worktree", "add", "-q", "--detach", str(WORKTREE), "origin/main", cwd=repo)


def compose(repo, state):
    ensure_worktree(repo)
    run("git", "fetch", "-q", "origin", "main", cwd=WORKTREE)
    base = run("git", "rev-parse", "origin/main", cwd=WORKTREE).stdout.strip()
    run("git", "reset", "-q", "--hard", cwd=WORKTREE)
    run("git", "clean", "-q", "-fd", cwd=WORKTREE)  # ignored build output stays: incremental
    run("git", "checkout", "-q", "--detach", base, cwd=WORKTREE)
    for member in state["members"]:
        result = run("git", "-c", "user.name=owner-local", "-c",
                     "user.email=owner-local@example.invalid", "merge", "-q", "--no-edit",
                     "-m", f"owner-local: #{member['pr']} {member['head'][:8]}",
                     member["head"], cwd=WORKTREE, check=False)
        if result.returncode != 0:
            run("git", "merge", "--abort", cwd=WORKTREE, check=False)
            raise Stop(4, f"#{member['pr']} {member['head'][:8]} does not merge with main + the "
                          "members before it; nothing was built. Rebase that PR on main or drop it.")
    source = run("git", "rev-parse", "HEAD", cwd=WORKTREE).stdout.strip()
    return base, source


def build(base, source, state):
    info = installed_info()
    installed = int(info.get("CFBundleVersion", "0") or 0)
    number = int(os.environ.get("WHYTAP_OWNER_LOCAL_BUILD") or installed + 1)
    composition = json.dumps({"base": base, "members": [
        {"ticket": m["pr"], "head": m["head"]} for m in state["members"]]})
    log = HOME_DIR / f"build-{number}.log"
    say(f"building {number} from {source[:8]} (main {base[:8]} + "
        + ", ".join(f"#{m['pr']}" for m in state["members"]) + f"); log {log}")
    env = {**os.environ, "EXODIA_LOCAL_INSTALL": "1", "FLAVOR": "prod",
           "BUILD_VERSION": str(number), "EXODIA_BUILD_COMPOSITION": composition}
    with open(log, "w") as handle:
        result = subprocess.run(["./scripts/build-dmg.sh"], cwd=WORKTREE, env=env,
                                stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise Stop(5, f"build-dmg.sh failed (exit {result.returncode}); see {log}")
    built = WORKTREE / "build" / "Whytap.app"
    candidate = HOME_DIR / f"candidate-{number}.app"
    shutil.rmtree(candidate, ignore_errors=True)
    run("ditto", str(built), str(candidate))
    state["candidate"] = {"path": str(candidate), "build": number, "source": source,
                          "base": base, "members": [dict(m) for m in state["members"]],
                          "built_at": now()}
    return candidate


# ---------------------------------------------------------------- install

def requirement(app):
    result = run("codesign", "-d", "-r-", str(app))
    out = result.stdout + result.stderr
    lines = [l for l in out.splitlines() if l.startswith("designated =>")]
    return lines[0] if lines else ""


def verify_candidate(candidate, number):
    run("codesign", "--verify", "--deep", "--strict", str(candidate))
    if APP.exists() and requirement(candidate) != requirement(APP):
        raise Stop(5, "the candidate's designated requirement differs from the installed app's")
    with open(candidate / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or str(info.get("CFBundleVersion")) != str(number):
        raise Stop(5, "the candidate's bundle id or build number is not what was built")
    installed = int(installed_info().get("CFBundleVersion", "0") or 0)
    if number <= installed:
        raise Stop(5, f"the installed app is already build {installed}: rebuild")


def running_pids():
    out = run("pgrep", "-f", str(APP / "Contents" / "MacOS") + "/", check=False).stdout
    return [int(p) for p in out.split()]


def gate():
    # The gate comes from this script's own checkout, not from the caller's
    # working directory: an older primary checkout may not contain it.
    script = Path(__file__).resolve().parent / "build-queue-meeting-gate.py"
    result = run(sys.executable, str(script), cwd=script.parent.parent, check=False)
    try:
        evidence = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        detail = (result.stderr.strip().splitlines() or ["no output"])[-1][:160]
        evidence = {"status": "unknown", "reason": f"gate output unreadable: {detail}"}
    return result.returncode == 0 and evidence.get("status") == "clear", evidence


def install(repo, state):
    candidate_info = state.get("candidate")
    if not candidate_info or not Path(candidate_info["path"]).exists():
        raise Stop(2, "no candidate: run `build` first")
    candidate, number = Path(candidate_info["path"]), candidate_info["build"]
    verify_candidate(candidate, number)
    clear, evidence = gate()
    if not clear:
        state["deferred"] = {"at": now(), "reason": evidence.get("reason", "")}
        receipt(repo, state, deferred=evidence.get("reason", "busy"))
        raise Stop(3, f"install deferred ({evidence.get('reason')}); candidate {number} kept at "
                      f"{candidate}. Run `python3 scripts/owner-local.py install` when Whytap is idle.")
    old = installed_info().get("CFBundleVersion", "unknown")
    # The rollback copy is made before the Quit, so a failure below never leaves the
    # owner without a working app.
    rollback = HOME_DIR / f"rollback-{old}.app"
    shutil.rmtree(rollback, ignore_errors=True)
    run("ditto", str(APP), str(rollback))
    staged = APP.with_name(APP.name + ".owner-local-new")
    previous = APP.with_name(APP.name + ".owner-local-old")
    for leftover in (staged, previous):
        shutil.rmtree(leftover, ignore_errors=True)
    run("ditto", str(candidate), str(staged))
    if running_pids():
        run("osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit', check=False)
        deadline = time.monotonic() + 60
        while running_pids() and time.monotonic() < deadline:
            time.sleep(1)
        if running_pids():
            receipt(repo, state, deferred="normal quit declined")
            raise Stop(3, "Whytap did not quit normally within 60 s; nothing replaced "
                          "(never force-quit). Run `install` again later.")
    os.rename(APP, previous)
    try:
        os.rename(staged, APP)
    except OSError:
        os.rename(previous, APP)
        run("open", "-a", str(APP), check=False)
        raise Stop(5, "could not move the new bundle into place; the previous app was put back")
    shutil.rmtree(previous, ignore_errors=True)
    run("open", "-a", str(APP))
    deadline = time.monotonic() + 30
    while not running_pids() and time.monotonic() < deadline:
        time.sleep(1)
    pids = running_pids()
    run("codesign", "--verify", "--deep", "--strict", str(APP))
    rollbacks = sorted(HOME_DIR.glob("rollback-*.app"), key=lambda p: p.stat().st_mtime)
    for extra in rollbacks[:-KEEP_ROLLBACKS]:
        shutil.rmtree(extra, ignore_errors=True)
    state["installed"] = {**candidate_info, "installed_at": now(), "pid": pids[0] if pids else None,
                          "rollback": str(rollback)}
    state.pop("deferred", None)
    receipt(repo, state)
    say(f"installed Whytap build {number} (pid {pids[0] if pids else 'not running yet'}); "
        f"rollback {rollback}")


# ---------------------------------------------------------------- receipt

def receipt(repo, state, deferred=None):
    primary = common_dir().parent
    path = primary / "build" / "CURRENT_BUILD.md"
    entry = state["installed"] if not deferred else state["candidate"]
    members = entry["members"]
    lines = []
    if deferred:
        lines.append(f"## Ready, not installed — owner-local {entry['build']} ({deferred})")
    else:
        lines.append(f"## Running — owner-local {entry['build']}")
    lines += ["", f"<!-- owner-local-{entry['build']}-{'ready' if deferred else 'running'} -->", "",
              f"- {now()} · Whytap build {entry['build']} from `{entry['source']}` = main "
              f"`{entry['base']}` + " + (", ".join(f"#{m['pr']} `{m['head']}`" for m in members)
                                          or "nothing") + ". Not merged; for the owner's check "
              "(`scripts/owner-local.py`)."]
    if not deferred:
        lines.append(f"- Rollback · `{entry['rollback']}`. PID {entry.get('pid')}.")
    else:
        lines.append(f"- Candidate · `{entry['path']}`; install with "
                     "`python3 scripts/owner-local.py install` when Whytap is idle.")
    for m in members:
        if m.get("accept"):
            lines.append(f"- Acceptance #{m['pr']} · {m['accept']}")
    text = "\n".join(lines) + "\n\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    old = path.read_text() if path.exists() else "# Current working Whytap\n\n"
    head, sep, rest = old.partition("\n\n")
    rest = drop_ready_sections(rest)  # a newer run supersedes every not-installed candidate
    path.write_text(head + "\n\n" + text + rest if sep else old + "\n" + text)


def drop_ready_sections(text):
    kept, skipping = [], False
    for line in text.splitlines(keepends=True):
        if line.startswith("## "):
            skipping = line.startswith("## Ready, not installed — owner-local ")
        if not skipping:
            kept.append(line)
    return "".join(kept)


# ---------------------------------------------------------------- commands

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add", help="add or update fixes, rebuild and install")
    add.add_argument("refs", nargs="+", help="PR number, optionally @<sha> to pin a head")
    add.add_argument("--accept", action="append", default=[],
                     help="'<pr>=<1-3 acceptance steps>' for the receipt")
    drop = sub.add_parser("drop", help="remove fixes (rejected or merged), rebuild and install")
    drop.add_argument("refs", nargs="+")
    sub.add_parser("build", help="rebuild and install the current members")
    sub.add_parser("install", help="install the last candidate (after a deferral)")
    sub.add_parser("status", help="members, candidate and installed build")
    for p in (add, drop):
        p.add_argument("--no-install", action="store_true", help="build only")
        p.add_argument("--no-build", action="store_true", help="only change the member list")
    for p in sub.choices.values():
        p.add_argument("--wait", type=int, default=1800, help="seconds to wait for the lock")
    args = parser.parse_args(argv)
    repo = Path(run("git", "rev-parse", "--show-toplevel").stdout.strip())
    git = common_dir()
    try:
        if args.command == "status":
            print(json.dumps(load_state(git), indent=2))
            return 0
        with IntegrationLock(git, args.wait):
            state = load_state(git)
            if args.command == "install":
                install(repo, state)
                return 0
            if args.command == "add":
                notes = {}
                for item in args.accept:
                    pr, _, text = item.partition("=")
                    notes[parse_ref(pr)[0]] = text.strip()
                for ref in args.refs:
                    pr, pin = parse_ref(ref)
                    head = fetch_member(repo, pr, pin)
                    old = next((m for m in state["members"] if m["pr"] == pr), None)
                    accept = notes.get(pr) or (old or {}).get("accept", "")
                    if old:
                        old.update(head=head, accept=accept)
                    else:
                        state["members"].append({"pr": pr, "head": head, "accept": accept})
            if args.command == "drop":
                gone = {parse_ref(r)[0] for r in args.refs}
                state["members"] = [m for m in state["members"] if m["pr"] not in gone]
            state["members"] = [m for m in state["members"] if not merged(m["pr"])]
            save_state(git, state)
            if getattr(args, "no_build", False):
                print(json.dumps(state["members"], indent=2))
                return 0
            base, source = compose(repo, state)
            build(base, source, state)
            save_state(git, state)
            if getattr(args, "no_install", False):
                say(f"candidate {state['candidate']['build']} ready: {state['candidate']['path']}")
                return 0
            try:
                install(repo, state)
            finally:
                save_state(git, state)
        return 0
    except Stop as stop:
        print(f"owner-local: {stop}", file=sys.stderr)
        return stop.code


if __name__ == "__main__":
    sys.exit(main())
