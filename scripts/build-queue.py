#!/usr/bin/env python3
"""Local, durable FIFO for the shared app builder. Never builds or launches apps.

WHY: .project-docs/decisions/2026-10-19-build-queue.md
Only Python's standard library is required. All worktrees share the Git common
directory; queue metadata stays local and survives build/ cleanup.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import plistlib
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import uuid


STATES = ("queued", "in_progress", "pending_install", "done", "blocked",
          "cancelled", "superseded", "previewing", "awaiting_approval", "approved",
          "releasing")
TRANSITIONS = {
    "queued": {"cancelled"},
    # WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
    # previewing -> queued: the environment stopped the preview (keeps its place).
    "previewing": {"awaiting_approval", "blocked", "queued", "superseded"},
    # A preview the owner is checking that no longer composes with main.
    "awaiting_approval": {"blocked"},
    # WHY: .project-docs/decisions/2026-11-26-release-batches.md
    # approved: waits for the next release batch and stays in the owner's app.
    # releasing -> pending_install: this member is merged (the batch's checkpoint);
    # -> approved: the environment stopped the batch before its merge, without blame.
    "approved": {"cancelled"},
    "releasing": {"pending_install", "done", "blocked", "approved"},
    # in_progress -> queued returns a ticket without blaming the PR (the environment
    # stopped it, an undeclared dependency is not merged yet); it keeps its place.
    "in_progress": {"pending_install", "done", "blocked", "queued"},
    # pending_install -> pending_install records a prepared candidate, a person who
    # must act, or an install that must come first, without leaving the group.
    "pending_install": {"done", "blocked", "superseded", "pending_install"},
    "blocked": {"queued", "cancelled", "superseded"},
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def git(*args):
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.PIPE).strip()


def common_dir():
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))


# WHY: .project-docs/decisions/2026-11-23-builder-queue-cheap-fixes.md
PULL_REMOTE_ENV = "WHYTAP_BUILD_QUEUE_PULL_REMOTE"
MERGED = ("done", "pending_install")  # pending_install: merged, the install waits
# WHY: .project-docs/decisions/2026-11-23-builder-queue-group-install.md
GROUP_LIMIT = 4  # merged runtime PRs that one install may carry
# retry: '' a person decides (legacy), 'meeting' automatic and grouped, 'first'
# automatic and before any other runtime work, 'hold' a person must act and other
# runtime work waits. 'first' and 'hold' are the install boundary.
BOUNDARY = ("first", "hold")
# Paths that never reach the app bundle; anything else makes a PR a runtime change.
NOT_RUNTIME = re.compile(r"(docs/|\.project-docs/|Tests/|\.github/|scripts/build-queue|"
                         r"scripts/test-|[^/]+\.md$)")


def changes_runtime(head):
    """Whether this commit changes anything that reaches the app, against its merge base
    with origin/main: both sides of renames, deletions included. Unknown counts as
    runtime."""
    try:
        base = git("merge-base", "origin/main", head)
        paths = git("diff", "--name-only", "--no-renames", base, head).splitlines()
    except (subprocess.CalledProcessError, OSError):
        return True
    return any(not NOT_RUNTIME.match(path) for path in paths if path)


def install_boundary(db):
    """True while merged runtime work must be installed before more runtime work is
    merged: an install marked first or held for a person, or a full group."""
    waiting = db.execute("SELECT retry FROM tickets WHERE status='pending_install'").fetchall()
    return (any(t["retry"] in BOUNDARY for t in waiting)
            or sum(1 for t in waiting if t["retry"] in ("meeting", "first")) >= GROUP_LIMIT)


def remote_heads():
    """Current head of every open PR from GitHub's pull refs, without a model and
    without credentials (`git ls-remote`), with the time the read started. None when
    unknown: offline, no such remote, a timeout. Unknown never blocks anything."""
    started = now()
    remote = os.environ.get(PULL_REMOTE_ENV) or "origin"
    try:
        output = subprocess.run(
            ["git", "ls-remote", remote, "refs/pull/*/head"], capture_output=True, text=True,
            timeout=30, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    except (OSError, subprocess.TimeoutExpired):
        return None
    if output.returncode != 0:
        return None
    heads = {}
    for line in output.stdout.splitlines():
        match = re.fullmatch(r"([0-9a-f]{40})\trefs/pull/([1-9]\d*)/head", line.strip())
        if match:
            heads[int(match.group(2))] = match.group(1)
    return {"started": started, "heads": heads}


def pr_number(url):
    return int(url.rsplit("/", 1)[-1])


def unmet_dependencies(db, ticket):
    """Dependency PRs of this ticket that are not merged through the queue yet: the
    latest ticket of each must be done or pending_install."""
    waiting = []
    for pr in json.loads(ticket["depends_on"] or "[]"):
        latest = db.execute("SELECT status FROM tickets WHERE pr=? ORDER BY id DESC LIMIT 1",
                            (pr,)).fetchone()
        if not latest or latest["status"] not in MERGED:
            waiting.append(pr)
    return waiting


# WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
STALE_DEPENDENCY_MINUTES = 120
RESUBMIT_PRIORITY_LIMIT = 2  # resubmissions after a block that keep the PR's place


def age_minutes(stamp, at=None):
    try:
        then = datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return 0.0
    return ((at or datetime.now(timezone.utc)) - then).total_seconds() / 60


def return_stale_dependencies(db, minutes=STALE_DEPENDENCY_MINUTES):
    """Model-free: a queued ticket whose dependency PR has been blocked or cancelled
    for longer than `minutes` goes back to its author instead of waiting for days.
    Returns the returned ticket IDs."""
    returned = []
    for item in db.execute("SELECT * FROM tickets WHERE status='queued' "
                           "ORDER BY queued_at, id").fetchall():
        for pr in json.loads(item["depends_on"] or "[]"):
            latest = db.execute("SELECT id, status, updated_at FROM tickets WHERE pr=? "
                                "ORDER BY id DESC LIMIT 1", (pr,)).fetchone()
            if (latest and latest["status"] in ("blocked", "cancelled")
                    and age_minutes(latest["updated_at"]) > minutes):
                note = (f"Returned without review: dependency {pr} has been {latest['status']} "
                        f"(ticket #{latest['id']}) for over {minutes // 60} h. Resubmit once it "
                        f"is merged through the queue, or drop --depends-on if it is no "
                        f"longer needed.")
                # auto_returned: a resubmission keeps its place without spending the
                # PR's resubmission priority (nothing was wrong with the PR itself).
                db.execute("UPDATE tickets SET status='blocked', note=?, updated_at=?, "
                           "auto_returned=1 WHERE id=?", (note, now(), item["id"]))
                event(db, item["id"], "blocked", note,
                      deliver=item["source"] in ("codex", "claude"))
                returned.append(item["id"])
                break
    return returned


def protected_tests(value):
    """A JSON list of test names (Module.Class/test or Class/test), or a ValueError."""
    try:
        tests = json.loads(value)
    except ValueError:
        tests = None
    if not isinstance(tests, list) or not all(
            isinstance(t, str) and re.fullmatch(r"[\w.]+/\w+", t) for t in tests):
        raise ValueError("--tests is a JSON list of test names like "
                         "\"SidekeyTests.PlannerExternalChangesTests/testName\"")
    return sorted(set(tests))


def check_dependencies(db, pr, depends_on):
    """The one check of every write that changes the dependency graph (a new head, or
    a returned head that comes back with its dependencies): refuse a dependency that
    already waits on this PR, directly or through other open tickets."""
    open_graph = {}
    for t in db.execute("SELECT pr, depends_on FROM tickets WHERE status IN "
                        "('queued', 'blocked', 'in_progress', 'previewing', 'awaiting_approval', "
                        "'approved', 'releasing') AND pr != ?", (pr,)):
        open_graph.setdefault(t["pr"], set()).update(json.loads(t["depends_on"] or "[]"))
    for dependency in depends_on:
        seen, stack = set(), [dependency]
        while stack:
            current = stack.pop()
            if current == pr:
                raise ValueError(dependency + " already depends on this PR"
                                 + ("" if current == dependency else " (through other PRs)"))
            if current not in seen:
                seen.add(current)
                stack.extend(open_graph.get(current, ()))


def reenter_review(db, ticket_id, keep_place, note, deliver=False):
    """The one way an existing ticket's head re-enters review (`set --status queued`,
    or the author resubmitting a head returned without review). Its FIFO place
    (queued_at) is kept or moved to the end; its head-observation stamp
    (submitted_at) is always now, so a remote snapshot started before the return
    never judges it. Pending protected-data tests are validated again from the start."""
    stamp = now()
    db.execute("UPDATE tickets SET status='queued', note=?, updated_at=?, retry='', "
               "auto_returned=0, protected_pending='[]', submitted_at=?, "
               "queued_at=CASE WHEN ? THEN queued_at ELSE ? END WHERE id=?",
               (note, stamp, stamp, int(keep_place), stamp, ticket_id))
    event(db, ticket_id, "queued", note, deliver=deliver)


# ---------------------------------------------------------------------------
# Preview lane and release batches.
# WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md,
#      .project-docs/decisions/2026-11-26-release-batches.md
# Simplicity first: a rule that cannot be enforced here sends the PR to normal
# validation instead. No stacked previews; the installed app is the record of what
# the owner sees (its Info.plist names its build, main base and preview members).

# Changed lines (and any line of a changed Swift file) that can reach stored data,
# credentials, permissions, signing, updates, files, processes or code loaded at
# run time, directly or through a type that names a state gateway.
PREVIEW_UNSAFE_CONTENT = re.compile(
    r"(?i:SecItem|kSecAttr|keychain|UserDefaults|@AppStorage|@SceneStorage|Codable|"
    r"Decodable|Encodable|NSKeyedArchiver|NSKeyedUnarchiver|PropertyListEncoder|"
    r"PropertyListDecoder|JSONEncoder|JSONDecoder|sqlite|CREATE\s+TABLE|ALTER\s+TABLE|"
    r"migrat|schemaVersion|applicationSupportDirectory|Application Support|FileManager|"
    r"FileHandle|\.write\(|\bwrite\(to|contentsOfFile|fileURLWithPath|NSHomeDirectory|"
    r"removeItem|AVCaptureDevice|requestAccess|AXIsProcessTrusted|CGRequest|CGPreflight|"
    r"SMAppService|\bTCC\b|entitlement|SPUUpdater|SUUpdater|Sparkle|codesign|LaunchAgent|"
    r"\bBundle\s*\(|Bundle\.main\.(url|path)|principalClass|dlopen|dlsym|"
    r"NSClassFromString|NSSelectorFromString|\bProcess\s*\(|NSTask|posix_spawn|"
    r"(?<![.\w])system\s*\(|environment\[|setenv|unsetenv)"
    # A state gateway named by its type: settings, stores, defaults, preferences,
    # databases, repositories, credentials, archives, backups, ledgers, manifests.
    r"|\b\w*(Settings|Store|Storage|Defaults|Preferences|Persist\w*|Database|Repository|"
    r"Credential\w*|Secret\w*|Vault|Backup\w*|Archive\w*|Ledger|Manifest|Migration\w*)\b")
PREVIEW_IMAGE_MAGIC = {".png": (b"\x89PNG\r\n\x1a\n",), ".jpg": (b"\xff\xd8\xff",),
                       ".jpeg": (b"\xff\xd8\xff",), ".pdf": (b"%PDF-",)}
PREVIEW_TEXT_RESOURCES = (".strings", ".stringsdict", ".xcstrings", ".svg")

# WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
# Restore-point tier. When the owner's installed app can make restore points (its
# Info.plist declares ExodiaRestorePointVersion), the outgoing app saves his settings
# and local data right before a preview replaces it, and a rollback restores those
# files. A preview may then change settings and stores code. What a restore point
# cannot undo stays out: provider keys and Case (never in a restore point), signing,
# packaging and updates, permissions, the restore mechanism and startup, data outside
# restore points (History, meeting audio), deletions, processes, the network (sent is
# sent) and code loaded at run time. Paths first, then any use in the old or the new
# text of a changed Swift file, comments and string text aside.
RESTORE_POINT_VERSION = 1
RESTORE_POINT_SECTIONS = ("settings", "meetings", "history", "workspace", "planner")
RESTORE_POINT_MAX_AGE_MINUTES = 60
RESTORE_POINT_EXCLUDED_PATHS = re.compile(
    r"^Sources/Sidekey/(Backup|Auth|Case|Permissions|Privacy|Updates|Sync|History)/"
    r"|^Sources/Sidekey/(SidekeyAppMain|InstallationGuard|ApplicationInstanceCoordinator|"
    r"AppRelauncher|BuildConfig|PermissionsHelper)\.swift$"
    # The app's entry point and the other binaries (CLI and MCP helper, Case kit,
    # the onboarding preview tool) have their own startup and handover rules.
    r"|^Sources/(SidekeyApp|WhytapCLI|WhytapCaseKit|OnboardingPreview|OnboardingPreviewKit)/")
RESTORE_POINT_EXCLUDED_CONTENT = re.compile(
    r"(?i:SecItem|kSec[A-Z]|keychain|TokenStore|ProviderKeyStore|password|"
    r"codesign|SecCode|SecStaticCode|entitlement|Sparkle|SPUUpdater|SUUpdater|appcast|"
    r"AXIsProcessTrusted|CGRequest|CGPreflight|requestAccess|AVCaptureDevice|"
    r"SMAppService|\bTCC\b|LaunchAgent|tapCreate|"
    r"\bProcess\s*\(|NSTask|posix_spawn|(?<![.\w])system\s*\(|NSAppleScript|osascript|"
    r"URLSession|URLRequest|httpMethod|NSSharingService|"
    r"removeItem|trashItem|replaceItem|\bunlink\s*\(|"
    r"\bBundle\s*\(|Bundle\.main\.(url|path)|principalClass|dlopen|dlsym|"
    r"NSClassFromString|NSSelectorFromString|environment\[|setenv|unsetenv|"
    r"history\.sqlite|HistoryStore|meetings-staging|MeetingsStaging)"
    # Types, case-sensitive: `.caseVault` is a hover tool, `CaseVault` the vault.
    r"|\bCaseVault\w*|\b\w*(Credential|Secret)\w*\b")
PREVIEW_VIDEO = {".mp4": b"ftyp", ".mov": b"ftyp", ".m4v": b"ftyp"}


def swift_code(text):
    """Swift source without comments and string text (interpolated code kept), so
    a feature's copy that names Keychain or Sparkle is not mistaken for using it."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    out.append("\n" if text[i] == "\n" else "")
                    i += 1
            continue
        literal = re.match(r'(#*)("""|")', text[i:i + 12])
        if literal:
            hashes, quote = literal.group(1), literal.group(2)
            close, escape = quote + hashes, "\\" + hashes
            i += literal.end()
            while i < n and not text.startswith(close, i):
                if text.startswith(escape + "(", i):
                    i += len(escape) + 1
                    depth, start = 1, i
                    while i < n and depth:
                        depth += {"(": 1, ")": -1}.get(text[i], 0)
                        i += 1
                    out.append(" " + text[start:i - 1] + " ")
                    continue
                if text.startswith(escape, i):
                    i += len(escape) + 1
                    continue
                if text[i] == "\n":
                    out.append("\n")
                    if quote == '"':
                        break
                i += 1
            i += len(close)
            out.append('""')
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def preview_input_kind(path):
    """The preview-safe kind of a changed path, or None (unknown: normal validation)."""
    suffix = Path(path).suffix.lower()
    if path.startswith("Sources/") and suffix == ".swift":
        return "swift"
    if path.startswith("Tests/") and suffix == ".swift":
        return "test"
    if path.startswith(("docs/", ".project-docs/")) and suffix == ".md" or \
            re.fullmatch(r"[^/]+\.md", path):
        return "documentation"
    if path.startswith("Resources/") and suffix in PREVIEW_IMAGE_MAGIC:
        return "image"
    if path.startswith("Resources/") and suffix in PREVIEW_TEXT_RESOURCES:
        return "text resource"
    return None


def preview_admission(base, head):
    """Why base..head may not be installed before validation: a list of reasons, empty
    when every changed input is of a preview-safe kind (regular file, allowed path and
    type, verified content) and no Swift file it changes can reach state. Unknown is
    never admissible."""
    try:
        raw = git("diff", "--raw", "--no-renames", "-z", "--no-abbrev", base, head)
        fields = raw.split("\0")
        reasons = []
        for index in range(0, len(fields) - 1, 2):
            meta, path = fields[index], fields[index + 1]
            if not meta.startswith(":") or not path:
                continue
            old_mode, new_mode, _old, new_blob, _status = meta[1:].split(" ", 4)
            kind = preview_input_kind(path)
            if kind is None:
                reasons.append(path + " (not a preview-safe kind of input)")
                continue
            if {old_mode, new_mode} - {"100644", "000000"}:
                reasons.append(path + " (mode %s -> %s: only regular files)" % (old_mode,
                                                                                 new_mode))
                continue
            if RESTORE_POINT_EXCLUDED_PATHS.search(path):
                # Startup, the restore mechanism, credentials, permissions, updates and
                # other binaries: never previewed, whatever the content.
                reasons.append(path + " (outside what a preview may change)")
                continue
            if new_mode == "000000":
                content = b""
            else:
                content = subprocess.check_output(["git", "cat-file", "blob", new_blob])
            if kind == "image":
                if not content.startswith(PREVIEW_IMAGE_MAGIC[Path(path).suffix.lower()]) \
                        and new_mode != "000000":
                    reasons.append(path + " (not the image its name says)")
                continue
            if b"\0" in content:
                reasons.append(path + " (binary content)")
                continue
            if kind in ("swift", "text resource"):
                text = content.decode("utf-8")
                diff = git("diff", "--no-renames", "-U0", base, head, "--", path)
                changed = [line[1:] for line in diff.splitlines()
                           if line[:1] in "+-" and not line.startswith(("+++", "---"))]
                # A changed Swift file is judged whole: a changed line may call
                # anything else in it.
                lines = changed + (text.splitlines() if kind == "swift" else [])
                hits = sorted({m.group(0) for line in lines
                               for m in [PREVIEW_UNSAFE_CONTENT.search(line)] if m})
                if hits:
                    reasons.append(path + " (reaches " + ", ".join(hits[:4]) + ")")
        return reasons
    except (subprocess.CalledProcessError, OSError, UnicodeDecodeError, ValueError):
        return ["the change could not be read"]


def restore_point_admission(base, head):
    """Why base..head may not be previewed even with a restore point: a list of reasons,
    empty when it may. Unknown is never admissible."""
    try:
        raw = git("diff", "--raw", "--no-renames", "-z", "--no-abbrev", base, head)
        fields = raw.split("\0")
        reasons = []
        for index in range(0, len(fields) - 1, 2):
            meta, path = fields[index], fields[index + 1]
            if not meta.startswith(":") or not path:
                continue
            old_mode, new_mode, old_blob, new_blob, _status = meta[1:].split(" ", 4)
            suffix = Path(path).suffix.lower()
            kind = preview_input_kind(path)
            if kind is None and path.startswith("Resources/") and suffix in PREVIEW_VIDEO:
                kind = "video"
            if kind is None and path.startswith("Resources/") and suffix == ".md":
                kind = "documentation"
            if kind is None:
                reasons.append(path + " (not a preview-safe kind of input)")
                continue
            if {old_mode, new_mode} - {"100644", "000000"}:
                reasons.append(path + " (mode %s -> %s: only regular files)" % (old_mode,
                                                                                 new_mode))
                continue
            if RESTORE_POINT_EXCLUDED_PATHS.search(path):
                reasons.append(path + " (outside what a restore point can undo)")
                continue
            blobs = [b for b, mode in ((new_blob, new_mode), (old_blob, old_mode))
                     if mode != "000000"]
            contents = [subprocess.check_output(["git", "cat-file", "blob", b]) for b in blobs]
            if kind in ("image", "video"):
                magic = PREVIEW_IMAGE_MAGIC.get(suffix) or ()
                head_bytes = contents[0] if new_mode != "000000" else b""
                if new_mode != "000000" and not (
                        head_bytes.startswith(magic) if kind == "image"
                        else head_bytes[4:8] == PREVIEW_VIDEO[suffix]):
                    reasons.append(path + " (not the " + kind + " its name says)")
                continue
            if any(b"\0" in content for content in contents):
                reasons.append(path + " (binary content)")
                continue
            texts = [content.decode("utf-8") for content in contents]
            if kind == "swift":
                texts = [swift_code(text) for text in texts]
            elif kind == "text resource":
                diff = git("diff", "--no-renames", "-U0", base, head, "--", path)
                texts = ["\n".join(line[1:] for line in diff.splitlines()
                                   if line[:1] in "+-" and not line.startswith(("+++", "---")))]
            else:
                continue
            hits = sorted({m.group(0) for text in texts for line in text.splitlines()
                           for m in [RESTORE_POINT_EXCLUDED_CONTENT.search(line)] if m})
            if hits:
                reasons.append(path + " (reaches " + ", ".join(hits[:4]) + ")")
        return reasons
    except (subprocess.CalledProcessError, OSError, UnicodeDecodeError, ValueError):
        return ["the change could not be read"]


def preview_tier(base, head, app=None):
    """How base..head may be previewed: {"tier": "plain"} touches no state, {"tier":
    "restore_point"} needs a restore point made by the outgoing app before the swap
    (only when the installed app can make one), {"tier": None, "reasons": [...]} goes
    to normal validation."""
    # What a restore point cannot undo is never previewed, in either tier.
    reasons = restore_point_admission(base, head)
    if reasons:
        return {"tier": None, "reasons": reasons}
    strict = preview_admission(base, head)
    if not strict:
        return {"tier": "plain", "reasons": []}
    app = installed_app() if app is None else app
    if not app or app.get("restore_points", 0) < RESTORE_POINT_VERSION:
        return {"tier": None, "reasons": strict + [
            "the installed app makes no restore points, so state changes are not previewed"]}
    return {"tier": "restore_point", "reasons": []}


def restore_points_dir():
    """Where the app keeps its restore points (`PreviewRestorePoints.Store`)."""
    return Path(os.environ.get("WHYTAP_RESTORE_POINTS_DIR") or Path.home() / "Library" /
                "Application Support" / "com.rootwise.sidekey" / "restore-points")


def restore_point_record(restore_point):
    """The restore point's record on this Mac, or None. The ID is a UUID, never a path."""
    try:
        name = str(uuid.UUID(str(restore_point)))
    except ValueError:
        return None
    root = restore_points_dir()
    try:
        record = json.loads((root / (name + ".json")).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict) or not (root / (name + ".exodiabackup")).is_file():
        return None
    record["id"] = name
    return record


def installed_app_path():
    return Path(os.environ.get("WHYTAP_INSTALLED_APP") or "/Applications/Whytap.app")


def installed_app():
    """What the owner's app is, read from the installed bundle itself (never from queue
    state): {"build", "base", "members": [{"ticket", "head"}]}. An app without a
    composition record carries no preview. None when the bundle cannot be read."""
    try:
        with open(installed_app_path() / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    members, base = [], str(info.get("ExodiaSourceRevision", ""))
    try:
        composition = json.loads(info.get("ExodiaBuildComposition") or "{}")
        base = str(composition.get("base") or base)
        members = [{"ticket": int(m["ticket"]), "head": str(m["head"])}
                   for m in composition.get("members", [])]
    except (ValueError, TypeError, KeyError, AttributeError):
        members = None  # unreadable: never a basis for a decision
    try:
        restore_points = int(info.get("ExodiaRestorePointVersion") or 0)
    except (TypeError, ValueError):
        restore_points = 0
    return {"build": str(info.get("CFBundleVersion", "")), "base": base, "members": members,
            "restore_points": restore_points}


TRAIN = "(status IN ('awaiting_approval', 'approved', 'releasing') OR " \
        "(status='queued' AND lane='release'))"


def preview_train(db):
    """PRs the owner's app must carry that main does not contain yet, in order:
    previews he is checking, approved features waiting for a release and a release in
    progress (its members leave the train once merged)."""
    return [{"ticket": t["id"], "pr": t["pr"], "head": t["head"], "title": t["title"],
             "status": t["status"]}
            for t in db.execute("SELECT * FROM tickets WHERE " + TRAIN +
                                " ORDER BY queued_at, id").fetchall()]


def pairs(members):
    return {(int(m["ticket"]), str(m["head"])) for m in members}


def preview_rebuild_needed(db, app=None):
    """The owner's app differs from the train: it carries a member that left the train
    unmerged (rejected, blocked, superseded, moved to the normal lane) or lacks one.
    Derived from the installed bundle, so an interrupted swap or a decision taken
    while a build ran is never lost. Unknown never triggers a rebuild."""
    app = installed_app() if app is None else app
    if not app or app["members"] is None:
        return False
    merged = {t["id"] for t in db.execute("SELECT id FROM tickets WHERE status IN "
                                          "('done', 'pending_install')")}
    carried = {pair for pair in pairs(app["members"]) if pair[0] not in merged}
    return carried != pairs(preview_train(db))


def local_install_blockers(db):
    """Merged work that still waits for a local install, or protected-data tests that
    must pass first: previews and release batches wait for it. A pending_install
    ticket without a retry flag (a historical public-release receipt, an install a
    person resolves) needs no local handoff from the queue."""
    return [t["id"] for t in db.execute(
        "SELECT id, retry, protected_pending FROM tickets WHERE status='pending_install' "
        "ORDER BY id").fetchall()
        if t["retry"] in ("meeting", "first", "hold") or json.loads(t["protected_pending"]
                                                                    or "[]")]


def stacked_on(db, item):
    """Open PRs this preview needs that main does not contain: declared dependencies
    not merged yet, or another open ticket's head in its history."""
    needs = list(unmet_dependencies(db, item))
    for other in db.execute("SELECT pr, head FROM tickets WHERE pr != ? AND status IN "
                            "('queued', 'in_progress', 'previewing', 'awaiting_approval', "
                            "'approved', 'releasing', 'blocked')", (item["pr"],)):
        try:
            inside = subprocess.run(["git", "merge-base", "--is-ancestor", other["head"],
                                     item["head"]], capture_output=True).returncode == 0
            merged = subprocess.run(["git", "merge-base", "--is-ancestor", other["head"],
                                     "origin/main"], capture_output=True).returncode == 0
        except OSError:
            return ["its history could not be read"]
        if inside and not merged and other["pr"] not in needs:
            needs.append(other["pr"])
    return needs


def to_normal_lane(db, item, reason):
    note = ("No preview before validation: " + reason + ". It stays queued for the normal "
            "review, full suite and merge before any install.")
    db.execute("UPDATE tickets SET lane='', note=?, updated_at=? WHERE id=?",
               (note, now(), item["id"]))
    event(db, item["id"], "queued", note, deliver=item["source"] in ("codex", "claude"))


def watcher_settings():
    try:
        settings = json.loads((common_dir() / "whytap-build-queue-builder.json").read_text())
    except (OSError, ValueError, subprocess.CalledProcessError):
        return {}
    return settings if isinstance(settings, dict) else {}


def preview_lane_enabled():
    return watcher_settings().get("preview_lane") is True


def orchestrator_token(args):
    """The relay's secret: WHYTAP_ORCHESTRATOR_TOKEN or the file named by --token-file."""
    if getattr(args, "token_file", None):
        return Path(args.token_file).expanduser().read_text().strip()
    return os.environ.get("WHYTAP_ORCHESTRATOR_TOKEN", "").strip()


def require_orchestrator(db, actor, token):
    """The owner's decisions reach the queue only through the configured orchestrator,
    never the builder, proved with the token whose SHA-256 the maintainer configured.
    Local, same-user protection against other sessions, not remote authentication."""
    settings = config(db)
    expected = settings.get("orchestrator")
    digest = settings.get("orchestrator_token_sha256")
    if not expected or not digest:
        raise ValueError("No orchestrator is configured: the maintainer runs "
                         "`build-queue-watcher.py activate --orchestrator <id> "
                         "--orchestrator-token-file <path>`")
    if actor == settings.get("builder_thread"):
        raise ValueError("The builder never relays the owner's decisions")
    if actor != expected or not token or hashlib.sha256(token.encode()).hexdigest() != digest:
        raise ValueError("The owner's decisions are relayed only by the configured "
                         "orchestrator with its token")


def start_release(db, by, note, actor):
    """Every approved feature into one release batch, merge order = FIFO (previews are
    never stacked, so members need nothing of each other)."""
    members = db.execute("SELECT * FROM tickets WHERE status='approved' "
                         "ORDER BY queued_at, id").fetchall()
    if not members:
        return None
    batch = int(config(db).get("last_batch", "0")) + 1
    db.execute("INSERT OR REPLACE INTO config VALUES ('last_batch', ?)", (str(batch),))
    for order, item in enumerate(members, 1):
        db.execute("UPDATE tickets SET lane='release', batch=?, batch_order=? WHERE id=?",
                   (batch, order, item["id"]))
        reenter_review(db, item["id"], True,
                       f"In release batch {batch} ({by}; relayed by {actor}). One review, one "
                       f"full suite, merge and one install follow. {note}".strip(),
                       deliver=True)
    return {"batch": batch, "tickets": [t["id"] for t in members]}


def claim_release(db, args):
    """The open release batch, claimed whole in its persisted merge order: members
    become `releasing`. A member whose PR head moved goes back to its author; the
    others go on."""
    first = db.execute("SELECT batch FROM tickets WHERE status='queued' AND lane='release' "
                       "ORDER BY batch LIMIT 1").fetchone()
    if not first:
        return None
    members = db.execute("SELECT * FROM tickets WHERE status='queued' AND lane='release' AND "
                         "batch=? ORDER BY batch_order, id", (first["batch"],)).fetchall()
    returned, claimed = [], []
    for item in members:
        if block_moved_head(db, item, args.remote_heads):
            returned.append(item["id"])
        else:
            claimed.append(item["id"])
    for ticket in claimed:
        db.execute("UPDATE tickets SET status='releasing', owner=?, updated_at=? WHERE id=?",
                   (args.actor, now(), ticket))
        event(db, ticket, "releasing", "Release batch %d started: one review, one full suite, "
              "merge and one install for all its features" % first["batch"])
    return {"claimed": bool(claimed), "batch": first["batch"],
            "tickets": [ticket_json(db, t) for t in claimed], "returned_moved_heads": returned}


def active_batch(db):
    releasing = [t[0] for t in db.execute(
        "SELECT id FROM tickets WHERE status='releasing' ORDER BY batch_order, id")]
    if not releasing:
        return None
    return {"batch": row(db, releasing[0])["batch"],
            "tickets": [ticket_json(db, t) for t in releasing]}


def preview_claim(db, args):
    """The preview lane's next step, model-free. Merged work waiting for its local
    install goes first, also before a recovered preview. Otherwise the active preview,
    or the oldest admissible queued preview, or a rebuild when the app differs from
    the train."""
    held = local_install_blockers(db)
    active = db.execute("SELECT * FROM tickets WHERE status='previewing'").fetchone()
    if held:
        if active:  # recovered later from the start; it keeps its place
            reenter_review(db, active["id"], True, "Preview paused: merged work waits for "
                           "its install first")
        return {"claimed": False, "active": None, "held_for_install": held,
                "rebuild": False, "train": preview_train(db)}
    if active:
        return {"claimed": False, "active": ticket_json(db, active["id"]),
                "train": preview_train(db), "data_restore": pending_data_restore(db)}
    returned, normal_lane = [], []
    for item in db.execute("SELECT * FROM tickets WHERE status='queued' AND lane='preview' "
                           "ORDER BY queued_at, id").fetchall():
        if block_moved_head(db, item, args.remote_heads):
            returned.append(item["id"])
            continue
        needs = stacked_on(db, item)
        if needs:
            to_normal_lane(db, item, "it builds on open PRs (" + ", ".join(needs) + ")")
            normal_lane.append(item["id"])
            continue
        try:
            base = git("merge-base", "origin/main", item["head"])
            admitted = preview_tier(base, item["head"])
        except (subprocess.CalledProcessError, OSError):
            admitted = {"tier": None, "reasons": ["the merge base with origin/main could not "
                                                  "be read"]}
        unsafe = admitted["reasons"] if admitted["tier"] is None else []
        if unsafe:
            to_normal_lane(db, item, "it changes inputs outside the preview scope ("
                           + "; ".join(unsafe[:8]) + ")")
            normal_lane.append(item["id"])
            continue
        db.execute("UPDATE tickets SET status='previewing', owner=?, preview_tier=?, "
                   "updated_at=? WHERE id=?",
                   (args.actor, admitted["tier"], now(), item["id"]))
        event(db, item["id"], "previewing", "Preview build started (no review or full suite "
              "before the owner's check)" + (
                  "; it changes settings or stores code, so the outgoing app makes a "
                  "restore point first" if admitted["tier"] == "restore_point" else ""))
        return {"claimed": True, "ticket": ticket_json(db, item["id"]),
                "train": preview_train(db), "returned_moved_heads": returned,
                "moved_to_normal_lane": normal_lane, "data_restore": pending_data_restore(db)}
    restore = pending_data_restore(db)
    return {"claimed": False, "active": None,
            "rebuild": preview_rebuild_needed(db) or bool(restore),
            "train": preview_train(db), "returned_moved_heads": returned,
            "moved_to_normal_lane": normal_lane, "data_restore": restore}


def pending_data_restore(db):
    """The owner's rollback of his data, relayed with `reject --restore-data`: applied
    by the next install, after the swap and before the launch. None when there is none."""
    value = config(db).get("pending_data_restore")
    return json.loads(value) if value else None


def handoff_problems(db, base, members, ticket=None, build=None):
    """Right before the Quit, under the app lock: why this composition must not replace
    the owner's app now. Empty when it may."""
    problems = []
    held = local_install_blockers(db)
    if held:
        problems.append("merged work waits for its install first: " +
                        ", ".join("#%d" % t for t in held))
    expected = pairs(preview_train(db))
    if ticket is not None:
        item = row(db, ticket)
        newer = db.execute("SELECT id FROM tickets WHERE pr=? AND id>?",
                           (item["pr"], item["id"])).fetchone()
        if item["status"] != "previewing" or newer:
            problems.append("#%d is no longer the preview to build (%s%s)" % (
                item["id"], item["status"], ", a newer head was submitted" if newer else ""))
        expected.add((item["id"], item["head"]))
    if pairs(members) != expected:
        problems.append("the composition is not the current train: expected " +
                        json.dumps(sorted(expected)))
    app = installed_app()
    if build is not None and app and app["build"].isdigit() and int(app["build"]) >= build:
        problems.append("the installed app is already build %s: rebuild with a higher number"
                        % app["build"])
    if app and app["base"] and subprocess.run(
            ["git", "merge-base", "--is-ancestor", app["base"], base],
            capture_output=True).returncode != 0:
        problems.append("the installed app's main %s is not in this base %s: recompose"
                        % (app["base"][:12], base[:12]))
    for member in members:
        try:
            if subprocess.run(["git", "merge-base", "--is-ancestor", member["head"], base],
                              capture_output=True).returncode == 0:
                problems.append("#%d is already in main: recompose" % member["ticket"])
        except OSError:
            problems.append("the composition could not be read")
    return problems


def block_moved_head(db, ticket, snapshot):
    """A queued ticket whose PR head moved after submission goes back to its author
    before any builder reviews the old commit. True when it was returned. Only a
    ticket queued before the remote read started is judged: one submitted (or
    requeued) while the read was in flight may be newer than the snapshot."""
    submitted = ticket["submitted_at"] or ticket["queued_at"]
    if not snapshot or submitted >= snapshot["started"]:
        return False
    current = snapshot["heads"].get(pr_number(ticket["pr"]))
    if not current or current == ticket["head"]:
        return False
    # GitHub moves refs/pull/<n>/head a little after a push: a ref that still shows
    # an ancestor of the submitted commit is lagging, not moved.
    if subprocess.run(["git", "merge-base", "--is-ancestor", current, ticket["head"]],
                      capture_output=True).returncode == 0:
        return False
    note = (f"The PR head moved after submission: this ticket is {ticket['head']}, the PR "
            f"is now {current}. Review that commit and enqueue it with --head {current}.")
    db.execute("UPDATE tickets SET status='blocked', note=?, updated_at=?, auto_returned=1 "
               "WHERE id=?", (note, now(), ticket["id"]))
    # No builder wrote this: the next builder delivers it from `events --pending`,
    # whatever the author's harness (Harness Link reaches codex and claude).
    event(db, ticket["id"], "blocked", note, deliver=ticket["source"] in ("codex", "claude"))
    return True


DOCUMENTATION_SCRIPTS_ENV = "WHYTAP_PROJECT_DOCUMENTATION_SCRIPTS"
DOCUMENTATION_CHECKS = (
    ("sync_agent_guidance.py", ("--check",),
     "AGENTS.md / CLAUDE.md differ from .project-docs/agent-context.md. Edit only "
     "agent-context.md, then run sync_agent_guidance.py --project-root . --write."),
    ("validate_project_documentation.py", ("--tracked-documentation",),
     "Project documentation validation failed (English-only records, reciprocal "
     "related links, sources, sensitive content)."),
)


def documentation_scripts():
    """Locate the project-documentation skill without naming anyone's home path."""
    override = os.environ.get(DOCUMENTATION_SCRIPTS_ENV)
    if override:
        candidates = [Path(override).expanduser()]
    else:
        home = Path.home()
        tail = "skills/project-documentation/scripts"
        candidates = [found for root in (".codex", ".claude") for found in
                      (home / root / "plugins" / "cache").glob("*/project-documentation/*/" + tail)]
        candidates += [home / root / tail for root in (".claude", ".codex", ".agents")]
    usable = [c for c in candidates
              if all((c / name).is_file() for name, _, _ in DOCUMENTATION_CHECKS)]
    if override and not usable:
        raise ValueError(DOCUMENTATION_SCRIPTS_ENV + " does not contain the validators")
    # Several installed copies can coexist; the most recently updated one wins.
    return max(usable, key=lambda c: max((c / name).stat().st_mtime
                                         for name, _, _ in DOCUMENTATION_CHECKS), default=None)


def documentation_preflight(head):
    """Reject mechanical documentation failures at submission, not after a build turn.

    WHY: .project-docs/decisions/2026-11-19-on-demand-build-queue-builder.md
    The reviewed commit is checked, not the caller's working tree. The builder
    still validates the integrated result; this only removes the cheap round trip.
    """
    try:
        git("cat-file", "-e", head + ":.project-docs/agent-context.md")
    except subprocess.CalledProcessError:
        return "not_applicable"
    scripts = documentation_scripts()
    if scripts is None:
        return "unavailable"
    scratch = Path(tempfile.mkdtemp(prefix="whytap-enqueue-docs-")).resolve()
    tree = scratch / "tree"
    try:
        git("worktree", "add", "--detach", "--quiet", str(tree), head)
        for name, flags, hint in DOCUMENTATION_CHECKS:
            result = subprocess.run(
                [sys.executable, str(scripts / name), "--project-root", str(tree), *flags],
                capture_output=True, text=True, timeout=300)
            if result.returncode != 0:
                output = (result.stdout + result.stderr).strip().replace(str(tree) + "/", "")
                raise ValueError("Not queued: " + hint + " Fix it on the branch, push and "
                                 "enqueue the newly reviewed head.\n" + name + " output:\n"
                                 + output[-3000:])
    except subprocess.TimeoutExpired:
        raise ValueError("Not queued: documentation checks timed out")
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)],
                       capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)
    return "passed"


def canonical_pr(url):
    match = re.fullmatch(r"https://github\.com/([\w.-]+)/([\w.-]+)/pull/([1-9]\d*)", url)
    remote = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([\w.-]+)/([\w.-]+?)"
                          r"(?:\.git)?", git("remote", "get-url", "origin"))
    if not match or not remote:
        raise ValueError("Use a GitHub PR from this repository's origin")
    owner, repo, number = match.groups()
    remote_owner, remote_repo = remote.groups()
    # Old worktrees still use the pre-rename URL; it is the same GitHub PR.
    if remote_owner.lower() == "absolutemode" and remote_repo.lower() in ("exodia", "whytap"):
        if owner.lower() == "absolutemode" and repo.lower() in ("exodia", "whytap"):
            return f"https://github.com/AbsoluteMode/whytap/pull/{number}"
    if (owner.lower(), repo.lower()) != (remote_owner.lower(), remote_repo.lower()):
        raise ValueError("The PR does not belong to this repository's origin")
    return f"https://github.com/{remote_owner}/{remote_repo}/pull/{number}"


def validate_head(head):
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("--head must be the exact full 40-character reviewed commit SHA")
    git("cat-file", "-e", head + "^{commit}")


@contextmanager
def database():
    path = common_dir() / "exodia-build-queue.sqlite3"
    # Private local metadata, never a user's keys, content or app stores.
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    try:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS tickets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pr TEXT NOT NULL, head TEXT NOT NULL, title TEXT NOT NULL,
                source TEXT NOT NULL, session TEXT NOT NULL, host TEXT NOT NULL,
                checks TEXT NOT NULL, acceptance TEXT NOT NULL, dependencies TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'queued', owner TEXT,
                queued_at TEXT NOT NULL, updated_at TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
                UNIQUE(pr, head)
            );
            CREATE UNIQUE INDEX IF NOT EXISTS one_builder
                ON tickets(status) WHERE status = 'in_progress';
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ticket INTEGER NOT NULL REFERENCES tickets(id),
                status TEXT NOT NULL, note TEXT NOT NULL, created_at TEXT NOT NULL,
                acknowledged_at TEXT
            );
        """)
        db.execute("BEGIN IMMEDIATE")
        # Inside the write lock: concurrent first calls after an upgrade migrate once.
        if "retry" not in {c[1] for c in db.execute("PRAGMA table_info(tickets)")}:
            # '' = wait for a person or a handoff; 'meeting' = the watcher retries the
            # deferred local install whenever the meeting gate is clear.
            db.execute("ALTER TABLE tickets ADD COLUMN retry TEXT NOT NULL DEFAULT ''")
        if "depends_on" not in {c[1] for c in db.execute("PRAGMA table_info(tickets)")}:
            # JSON list of PR URLs that must be merged through the queue first.
            db.execute("ALTER TABLE tickets ADD COLUMN depends_on TEXT NOT NULL DEFAULT '[]'")
        if "deliver" not in {c[1] for c in db.execute("PRAGMA table_info(events)")}:
            # 1 = written without a builder (a model-free return): listed by
            # `events --pending` for any deliverable author, not only Codex.
            db.execute("ALTER TABLE events ADD COLUMN deliver INTEGER NOT NULL DEFAULT 0")
        if "runtime" not in {c[1] for c in db.execute("PRAGMA table_info(tickets)")}:
            # 1 = the PR changes what reaches the app (counted at submission); older
            # tickets count as runtime.
            db.execute("ALTER TABLE tickets ADD COLUMN runtime INTEGER NOT NULL DEFAULT 1")
        columns = {c[1] for c in db.execute("PRAGMA table_info(tickets)")}
        for column, sql in (
                # Resubmissions after a block that kept the PR's place (at most two).
                ("resubmits", "INTEGER NOT NULL DEFAULT 0"),
                # When this head was submitted; a kept place reuses an older queued_at.
                ("submitted_at", "TEXT NOT NULL DEFAULT ''"),
                # 1 = returned without a model (moved head, blocked dependency).
                ("auto_returned", "INTEGER NOT NULL DEFAULT 0"),
                # JSON list: tests skipped behind a locked screen that must pass on
                # main before this ticket's install (and before it is done).
                ("protected_pending", "TEXT NOT NULL DEFAULT '[]'"),
                # '' normal validation; 'preview' built for the owner's check first;
                # 'approved' accepted by the owner; 'release' in a release batch.
                ("lane", "TEXT NOT NULL DEFAULT ''"),
                # JSON: who relayed the owner's approval, when, and the quoted words.
                ("approval", "TEXT NOT NULL DEFAULT ''"),
                ("preview_build", "TEXT NOT NULL DEFAULT ''"),  # the build the owner saw
                ("batch", "INTEGER NOT NULL DEFAULT 0"),        # release batch (0: none)
                ("batch_order", "INTEGER NOT NULL DEFAULT 0"),  # merge order inside it
                # 'plain' or 'restore_point': how the preview was admitted.
                ("preview_tier", "TEXT NOT NULL DEFAULT ''"),
                # The restore point the outgoing app made before this preview's first
                # install (its ID); a rollback of the owner's data applies it.
                ("restore_point", "TEXT NOT NULL DEFAULT ''")):
            if column not in columns:
                db.execute(f"ALTER TABLE tickets ADD COLUMN {column} {sql}")
                if column == "submitted_at":
                    db.execute("UPDATE tickets SET submitted_at=queued_at")
        db.execute("CREATE UNIQUE INDEX IF NOT EXISTS one_preview "
                   "ON tickets(status) WHERE status = 'previewing'")
        yield db
        db.commit()
    finally:
        db.close()


def config(db):
    return dict(db.execute("SELECT key, value FROM config"))


def require_builder(db, actor):
    expected = config(db).get("builder_thread")
    if not expected or actor != expected:
        raise ValueError("Only the configured builder chat may claim or update work")


def event(db, ticket, status, note="", deliver=False):
    db.execute("INSERT INTO events(ticket, status, note, created_at, deliver) "
               "VALUES (?, ?, ?, ?, ?)", (ticket, status, note, now(), int(deliver)))


def row(db, ticket):
    result = db.execute("SELECT * FROM tickets WHERE id = ?", (ticket,)).fetchone()
    if result is None:
        raise ValueError("Unknown ticket")
    return result


def ticket_json(db, ticket):
    result = dict(row(db, ticket))
    result["acceptance"] = json.loads(result["acceptance"])
    result["depends_on"] = json.loads(result.get("depends_on") or "[]")
    result["protected_pending"] = json.loads(result.get("protected_pending") or "[]")
    if result["status"] == "queued":
        result["waiting_for"] = unmet_dependencies(db, row(db, ticket))
        result["position"] = db.execute(
            "SELECT COUNT(*) FROM tickets WHERE status='queued' AND "
            "(queued_at < ? OR (queued_at = ? AND id <= ?))",
            (result["queued_at"], result["queued_at"], ticket)).fetchone()[0]
    else:
        result["position"] = None
    return result


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SESSION_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")


def author_address(args):
    """Fill the submitting session from the harness environment when not given, so the
    builder can reach it through Harness Link, and validate the whole field. A Claude
    Code address is its session UUID (CLAUDE_CODE_SESSION_ID), stored in lower case; a
    display name like `one-mcp` reaches nobody. No whitespace or control characters,
    whether given as a flag or taken from the environment."""
    if not args.source:
        args.source = "codex" if os.environ.get("CODEX_THREAD_ID") else (
            "claude" if os.environ.get("CLAUDE_CODE_SESSION_ID") else "codex")
    if not args.session:
        args.session = os.environ.get(
            {"codex": "CODEX_THREAD_ID", "claude": "CLAUDE_CODE_SESSION_ID"}.get(args.source, ""),
            "")
    if not args.session:
        return
    if args.source == "claude":
        if not UUID.fullmatch(args.session.lower()):
            raise ValueError("A Claude Code session is addressed by its UUID "
                             "(CLAUDE_CODE_SESSION_ID), not a display name: "
                             + json.dumps(args.session))
        args.session = args.session.lower()
    elif not SESSION_NAME.fullmatch(args.session):
        raise ValueError("Session IDs are letters, digits and . _ : - only: "
                         + json.dumps(args.session))


def submitted(db, args):
    """Cheap argument checks; returns the ticket this exact PR/head already has."""
    if not config(db).get("builder_thread"):
        raise ValueError("Configure the builder before submitting work")
    args.pr = canonical_pr(args.pr)
    validate_head(args.head)
    author_address(args)
    args.depends_on = sorted({canonical_pr(url) for url in args.depends_on or []})
    if args.pr in args.depends_on:
        raise ValueError("A PR cannot depend on itself")
    if not args.session:
        raise ValueError("Set --session (detected from CODEX_THREAD_ID or "
                         "CLAUDE_CODE_SESSION_ID when present)")
    return db.execute("SELECT * FROM tickets WHERE pr=? AND head=?",
                      (args.pr, args.head)).fetchone()


def run(args):
    with database() as db:
        if args.command == "configure":
            previous = config(db).get("builder_thread")
            if previous:
                require_builder(db, args.actor)
                if previous != args.builder_thread and db.execute(
                        "SELECT 1 FROM tickets WHERE status='in_progress'").fetchone():
                    raise ValueError("Finish or recover active work before transferring the builder")
            db.execute("INSERT OR REPLACE INTO config VALUES ('builder_thread', ?)",
                       (args.builder_thread,))
            db.execute("INSERT OR REPLACE INTO config VALUES ('builder_host', ?)", (args.host,))
            return config(db)

        if args.command == "enqueue":
            existing = submitted(db, args)
            if existing:
                if (existing["source"], existing["session"], existing["host"]) != (
                        args.source, args.session, args.host):
                    raise ValueError("This PR/head already belongs to another session")
                newest = db.execute("SELECT MAX(id) FROM tickets WHERE pr=?",
                                    (args.pr,)).fetchone()[0]
                if (existing["status"] == "blocked" and existing["auto_returned"]
                        and existing["id"] == newest):
                    # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
                    # Returned without review (a stale dependency, a moved head): the
                    # untouched head goes back to its place without spending the PR's
                    # resubmission priority. A head a builder reviewed and blocked stays
                    # blocked: its fix is a new head.
                    check_dependencies(db, args.pr, args.depends_on)
                    db.execute("UPDATE tickets SET depends_on=?, dependencies=? WHERE id=?",
                               (json.dumps(args.depends_on), args.dependencies,
                                existing["id"]))
                    reenter_review(db, existing["id"], True,
                                   "Resubmitted by its author after a return without "
                                   "review; keeps its place")
                    return {"created": False, "requeued": True, "builder": config(db),
                            "ticket": ticket_json(db, existing["id"])}
                return {"created": False, "builder": config(db),
                        "ticket": ticket_json(db, existing["id"])}
            old = db.execute("SELECT * FROM tickets WHERE pr=? AND "
                             "status IN ('queued', 'blocked', 'in_progress', 'pending_install', "
                             "'awaiting_approval', 'approved', 'releasing')", (args.pr,)).fetchall()
            if any(t["status"] in ("in_progress", "pending_install", "releasing") for t in old):
                raise ValueError("Builder must reconcile the active/candidate head before resubmission")
            for t in old:
                if (t["source"], t["session"], t["host"]) != (args.source, args.session, args.host):
                    raise ValueError("A previous request for this PR belongs to another session")
            check_dependencies(db, args.pr, args.depends_on)
            # Read before the supersede below changes its status.
            previous = db.execute("SELECT * FROM tickets WHERE pr=? ORDER BY id DESC LIMIT 1",
                                  (args.pr,)).fetchone()
            for t in old:
                db.execute("UPDATE tickets SET status='superseded', updated_at=? WHERE id=?",
                           (now(), t["id"]))
                event(db, t["id"], "superseded", "Replaced by a newly reviewed commit")
            stamp = now()
            # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
            # A fix after a block keeps the PR's earlier place, at most
            # RESUBMIT_PRIORITY_LIMIT times; a return without a model (moved head,
            # blocked dependency) keeps it without spending that priority.
            queued_at, resubmits, place = stamp, 0, ""
            preview_fix = previous is not None and (
                previous["status"] in ("previewing", "awaiting_approval", "approved") or (
                    previous["status"] == "blocked" and previous["lane"] == "preview"))
            if preview_fix:
                # A fix to a preview the owner is checking keeps its place: that loop
                # is the owner's own.
                queued_at, resubmits = previous["queued_at"], previous["resubmits"]
                place = "; keeps the place of preview #%d" % previous["id"]
            elif previous and previous["status"] == "blocked" and previous["queued_at"] < stamp:
                if previous["auto_returned"]:
                    queued_at, resubmits = previous["queued_at"], previous["resubmits"]
                    place = "; keeps the place of #%d (returned without review)" % previous["id"]
                elif previous["resubmits"] < RESUBMIT_PRIORITY_LIMIT:
                    queued_at, resubmits = previous["queued_at"], previous["resubmits"] + 1
                    place = "; resubmission %d of %d keeps the place of #%d" % (
                        resubmits, RESUBMIT_PRIORITY_LIMIT, previous["id"])
                else:
                    resubmits = previous["resubmits"]
                    place = ("; goes to the end: the PR already used %d priority resubmissions"
                             % RESUBMIT_PRIORITY_LIMIT)
            lane, routed = ("preview" if args.preview else ""), ""
            if lane and not args.preview_lane:
                lane, routed = "", ("; the preview lane is off, so it goes through normal "
                                    "validation (review, full suite, merge, install)")
            cursor = db.execute(
                "INSERT INTO tickets(pr,head,title,source,session,host,checks,acceptance,"
                "dependencies,depends_on,runtime,resubmits,lane,queued_at,submitted_at,"
                "updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (args.pr, args.head, args.title, args.source, args.session, args.host,
                 args.checks, json.dumps(args.acceptance), args.dependencies,
                 json.dumps(args.depends_on), int(args.runtime), resubmits, lane, queued_at,
                 stamp, stamp))
            event(db, cursor.lastrowid, "queued", ("Accepted for a preview build before "
                  "validation" if lane else "Accepted into the build queue") +
                  "; documentation checks at submission: " + args.documentation_checks + place
                  + routed)
            return {"created": True, "builder": config(db),
                    "documentation_checks": args.documentation_checks,
                    "delivery": "inbox_only" if args.source == "other" else "harness_link",
                    "ticket": ticket_json(db, cursor.lastrowid)}

        if args.command == "status":
            query = "SELECT id FROM tickets"
            params = ()
            if args.ticket:
                query += " WHERE id=?"
                params = (args.ticket,)
            elif args.open:
                # Open work, plus every earlier ticket of the same PRs (the history a
                # re-block needs), instead of the whole archive.
                query += (" WHERE pr IN (SELECT pr FROM tickets WHERE status IN "
                          "('queued', 'in_progress', 'pending_install', 'previewing', "
                          "'awaiting_approval', 'approved', 'releasing'))")
            query += " ORDER BY queued_at, id"
            tickets = [ticket_json(db, t[0]) for t in db.execute(query, params).fetchall()]
            if args.open and not args.ticket:
                for t in tickets:
                    if t["status"] in ("done", "superseded", "cancelled", "blocked") \
                            and len(t["note"]) > 600:
                        t["note"] = t["note"][:600] + " [...] (status --ticket %d)" % t["id"]
            app = installed_app()
            return {"builder": {k: v for k, v in config(db).items()
                                if k != "orchestrator_token_sha256"},
                    "install_boundary": install_boundary(db),
                    "local_install_blockers": local_install_blockers(db),
                    "preview_train": preview_train(db), "installed_app": app,
                    "preview_rebuild": preview_rebuild_needed(db, app) or bool(
                        pending_data_restore(db)),
                    "data_restore": pending_data_restore(db),
                    "protected_pending": sorted({
                        name for t in db.execute(
                            "SELECT protected_pending FROM tickets WHERE status IN "
                            "('in_progress', 'pending_install', 'blocked')")
                        for name in json.loads(t[0] or "[]")}),
                    "tickets": tickets}

        if args.command == "claim":
            require_builder(db, args.actor)
            active = db.execute("SELECT id FROM tickets WHERE status='in_progress'").fetchone()
            if active:
                return {"claimed": False, "active": ticket_json(db, active[0])}
            batch = active_batch(db)
            if batch:
                return {"claimed": False, "active": None, "active_batch": batch}
            boundary = install_boundary(db)
            if not boundary and not local_install_blockers(db):
                # A release batch changes the app: it respects the install boundary
                # like any runtime ticket; work that changes nothing still goes first.
                batch = claim_release(db, args)
                if batch and batch["claimed"]:
                    return batch
            # FIFO among tickets that can be built now: one waiting for a dependency
            # or, while merged runtime work must be installed first, a runtime ticket
            # keeps its place; one whose PR head moved goes back to its author.
            returned, waiting, held = [], [], []
            boundary = install_boundary(db)
            for item in db.execute("SELECT * FROM tickets WHERE status='queued' AND "
                                   "lane NOT IN ('preview', 'release') "
                                   "ORDER BY queued_at, id").fetchall():
                if unmet_dependencies(db, item):
                    waiting.append(item["id"])
                elif boundary and item["runtime"]:
                    held.append(item["id"])
                elif block_moved_head(db, item, args.remote_heads):
                    returned.append(item["id"])
                else:
                    db.execute("UPDATE tickets SET status='in_progress', owner=?, updated_at=? "
                               "WHERE id=?", (args.actor, now(), item["id"]))
                    event(db, item["id"], "in_progress",
                          "Builder has started; follow this build and its acceptance checks")
                    return {"claimed": True, "ticket": ticket_json(db, item["id"]),
                            "returned_moved_heads": returned, "waiting_for_dependencies": waiting,
                            "held_for_install": held}
            return {"claimed": False, "active": None, "returned_moved_heads": returned,
                    "waiting_for_dependencies": waiting, "held_for_install": held}

        if args.command == "preview-claim":
            require_builder(db, args.actor)
            return preview_claim(db, args)

        if args.command == "configure-orchestrator":
            require_builder(db, args.actor)
            if not args.orchestrator or args.orchestrator == config(db).get("builder_thread"):
                raise ValueError("The orchestrator must be an actor other than the builder")
            token = Path(args.token_file).expanduser().read_text().strip()
            if len(token) < 32:
                raise ValueError("The orchestrator token must be at least 32 characters")
            db.execute("INSERT OR REPLACE INTO config VALUES ('orchestrator', ?)",
                       (args.orchestrator,))
            db.execute("INSERT OR REPLACE INTO config VALUES ('orchestrator_token_sha256', ?)",
                       (hashlib.sha256(token.encode()).hexdigest(),))
            return {"orchestrator": args.orchestrator, "token": "configured"}

        if args.command == "preview-admit":
            admitted = preview_tier(args.base, args.commit)
            return {"admissible": admitted["tier"] is not None, "tier": admitted["tier"],
                    "restore_point_required": admitted["tier"] == "restore_point",
                    "reasons": admitted["reasons"]}

        if args.command == "preview-restore-point":
            # WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
            # After the Quit and before the swap: the outgoing app's restore point is
            # recorded on the preview it protects.
            require_builder(db, args.actor)
            item = row(db, args.ticket)
            if item["status"] != "previewing":
                raise ValueError("A restore point is recorded on the preview being built; "
                                 "#%d is %s" % (item["id"], item["status"]))
            record = restore_point_record(args.restore_point)
            if not record:
                raise ValueError("No restore point %s on this Mac (made with the outgoing "
                                 "app's --restore-point create)" % args.restore_point)
            app = installed_app()
            if not app or str(record.get("appBuild") or "") != app["build"]:
                raise ValueError("Restore point %s was made by build %s, not by the "
                                 "installed app (build %s)" % (
                                     record["id"], record.get("appBuild"),
                                     app["build"] if app else "unknown"))
            try:
                made = datetime.fromisoformat(
                    str(record.get("createdAt", "")).replace("Z", "+00:00"))
                age = (datetime.now(timezone.utc) - made).total_seconds()
            except ValueError:
                age = None
            if age is None or not -300 <= age <= RESTORE_POINT_MAX_AGE_MINUTES * 60:
                raise ValueError("Restore point %s is not from right before this install"
                                 % record["id"])
            if not item["restore_point"]:
                # The first one predates any install of this preview's code.
                db.execute("UPDATE tickets SET restore_point=?, updated_at=? WHERE id=?",
                           (record["id"], now(), item["id"]))
            event(db, item["id"], "previewing", "Restore point %s made by build %s before "
                  "the install" % (record["id"], app["build"]))
            return ticket_json(db, item["id"])

        if args.command == "data-restored":
            # The next install applied the owner's data rollback (or could not).
            require_builder(db, args.actor)
            restore = pending_data_restore(db)
            if not restore or restore["restore_point"] != args.restore_point:
                raise ValueError("No data rollback with restore point %s is pending"
                                 % args.restore_point)
            db.execute("DELETE FROM config WHERE key='pending_data_restore'")
            text = ("The owner's data was rolled back to restore point %s: " if not args.failed
                    else "The data rollback to restore point %s failed, a person must act: "
                    ) % args.restore_point + args.note
            event(db, restore["ticket"], row(db, restore["ticket"])["status"], text,
                  deliver=True)
            return {"data_restore": restore, "applied": not args.failed}

        if args.command == "preview-handoff":
            # WHY: .project-docs/decisions/2026-11-26-release-batches.md
            # Under the app lock, right before the Quit, for every install that carries
            # the train (previews, rebuilds, the builder's installs).
            try:
                members = json.loads(args.members)
                pairs(members)
            except (ValueError, TypeError, KeyError):
                raise ValueError("--members is a JSON list of {\"ticket\": id, \"head\": sha}")
            problems = handoff_problems(db, args.base, members, args.ticket, args.build)
            return {"clear": not problems, "problems": problems}

        if args.command == "preview-lane-off":
            require_builder(db, args.actor)
            moved = []
            for item in db.execute("SELECT * FROM tickets WHERE lane='preview' AND "
                                   "status IN ('queued', 'previewing')").fetchall():
                to_normal_lane(db, item, "the preview lane was switched off")
                if item["status"] == "previewing":
                    reenter_review(db, item["id"], True, "The preview lane was switched off: "
                                   "normal validation")
                moved.append(item["id"])
            return {"moved_to_normal_lane": moved}

        if args.command == "release":
            # WHY: .project-docs/decisions/2026-11-26-release-batches.md
            approved = db.execute("SELECT COUNT(*) FROM tickets WHERE "
                                  "status='approved'").fetchone()[0]
            if args.auto:
                require_builder(db, args.actor)  # the watcher's count trigger
                threshold = args.release_after_approved
                if not isinstance(threshold, int) or isinstance(threshold, bool) \
                        or threshold <= 0:
                    raise ValueError("The count trigger is off (release_after_approved)")
                if approved < threshold:
                    raise ValueError("%d approved features, the trigger needs %d"
                                     % (approved, threshold))
            else:
                require_orchestrator(db, args.actor, orchestrator_token(args))
            if db.execute("SELECT 1 FROM tickets WHERE status='releasing' OR "
                          "(status='queued' AND lane='release')").fetchone():
                raise ValueError("A release batch is already open; the next one starts after it")
            started = start_release(db, args.by, args.note, args.actor)
            return started or {"batch": None, "tickets": [], "note": "nothing is approved"}

        if args.command in ("approve", "reject"):
            require_orchestrator(db, args.actor, orchestrator_token(args))
            item = row(db, args.ticket)
            if item["status"] != "awaiting_approval":
                raise ValueError("Only a preview awaiting the owner's check can be "
                                 + args.command + "d; #%d is %s" % (item["id"], item["status"]))
            if args.actor == item["session"]:
                raise ValueError("A PR's own session cannot relay the owner's decision on it")
            # The decision is about what the owner sees: this head in the build the
            # installed app is now, which must carry it.
            app = installed_app()
            if not app or app["members"] is None:
                raise ValueError("The installed app could not be read; decide after it is")
            if args.head != item["head"] or (item["id"], item["head"]) not in pairs(
                    app["members"]) or str(args.build) != app["build"]:
                raise ValueError("The owner's app is build %s carrying %s; this decision "
                                 "names head %s in build %s" % (
                                     app["build"], json.dumps(sorted(pairs(app["members"]))),
                                     args.head, args.build))
            stamp = now()
            if args.command == "approve":
                approval = json.dumps({"by": args.by, "relayed_by": args.actor, "at": stamp,
                                       "build": app["build"], "note": args.note})
                db.execute("UPDATE tickets SET status='approved', lane='approved', approval=?, "
                           "note=?, updated_at=? WHERE id=?",
                           (approval, "Owner approved the preview: " + args.by, stamp, item["id"]))
                event(db, item["id"], "approved", "The owner approved the feature (" + args.by +
                      "). It stays in his app and goes out with the next release batch: one "
                      "review, one full suite, merge and one install.", deliver=True)
            else:
                if args.restore_data:
                    # WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
                    # Only on the owner's explicit request: the restore replaces what he
                    # changed since, and the app keeps that as its recovery checkpoint.
                    if pending_data_restore(db):
                        raise ValueError("A data rollback is already pending; relay this one "
                                         "after it is applied")
                    if not item["restore_point"] or not restore_point_record(
                            item["restore_point"]):
                        raise ValueError("#%d has no restore point on this Mac; reject without "
                                         "--restore-data" % item["id"])
                    sections = sorted(set(args.sections.split(","))) if args.sections \
                        else list(RESTORE_POINT_SECTIONS)
                    if set(sections) - set(RESTORE_POINT_SECTIONS):
                        raise ValueError("--sections is a comma list of " +
                                         ", ".join(RESTORE_POINT_SECTIONS))
                    db.execute("INSERT OR REPLACE INTO config VALUES ('pending_data_restore', ?)",
                               (json.dumps({"ticket": item["id"],
                                            "restore_point": item["restore_point"],
                                            "sections": sections, "requested_by": args.actor,
                                            "at": stamp}),))
                db.execute("UPDATE tickets SET status='blocked', note=?, updated_at=? WHERE id=?",
                           ("Owner's changes to the preview: " + args.note, stamp, item["id"]))
                event(db, item["id"], "blocked", "The owner sent the preview back: " + args.note +
                      " Push the fix and enqueue it again with --preview.", deliver=True)
            return ticket_json(db, item["id"])

        if args.command == "return-stale-dependencies":
            require_builder(db, args.actor)
            return {"returned": return_stale_dependencies(db, args.minutes)}

        if args.command == "protected-pending":
            # WHY: .project-docs/decisions/2026-11-26-builder-quick-wins.md
            # Tests skipped behind a locked screen are recorded on the ticket before the
            # merge, so an interrupted session, a deferred install or a group keeps them.
            require_builder(db, args.actor)
            if bool(args.tests) == bool(args.passed):
                raise ValueError("Give either --tests (skipped) or --passed (ran on main)")
            item = row(db, args.ticket)
            if item["status"] not in ("in_progress", "pending_install"):
                raise ValueError("Protected-data tests are recorded on an in_progress or "
                                 "pending_install ticket; #%d is %s" % (item["id"], item["status"]))
            pending = set(json.loads(item["protected_pending"] or "[]"))
            if args.passed:
                if not args.note:
                    raise ValueError("--passed needs --note with the run's evidence")
                passed = set(protected_tests(args.passed))
                pending -= passed
                text = "Protected-data tests passed on main: " + ", ".join(sorted(passed)) + \
                       ". " + args.note
            else:
                added = set(protected_tests(args.tests))
                pending |= added
                text = ("Protected-data tests skipped behind a locked screen, pending before "
                        "the install: " + ", ".join(sorted(added)) +
                        (". " + args.note if args.note else ""))
            db.execute("UPDATE tickets SET protected_pending=?, updated_at=? WHERE id=?",
                       (json.dumps(sorted(pending)), now(), item["id"]))
            event(db, item["id"], item["status"], text)
            return ticket_json(db, item["id"])

        if args.command == "check-heads":
            require_builder(db, args.actor)
            if not args.remote_heads:
                return {"checked": False, "returned_moved_heads": []}
            returned = [t["id"] for t in db.execute(
                "SELECT * FROM tickets WHERE status='queued' ORDER BY queued_at, id").fetchall()
                if block_moved_head(db, t, args.remote_heads)]
            return {"checked": True, "returned_moved_heads": returned}

        if args.command == "set":
            require_builder(db, args.actor)
            item = row(db, args.ticket)
            if args.status not in TRANSITIONS.get(item["status"], set()):
                raise ValueError("Invalid transition: " + item["status"] + " -> " + args.status)
            flags = [f for f in ("retry_install", "install_first", "hold") if getattr(args, f)]
            if flags and args.status != "pending_install":
                raise ValueError("--retry-install, --install-first and --hold apply only to "
                                 "pending_install")
            if len(flags) > 1:
                raise ValueError("Use one of --retry-install, --install-first, --hold")
            retry = {"retry_install": "meeting", "install_first": "first",
                     "hold": "hold"}.get(flags[0] if flags else "", "")
            if (args.status == "pending_install" and item["status"] == "pending_install"
                    and item["retry"] in BOUNDARY and retry not in BOUNDARY):
                # The boundary is sticky until the install is resolved: a later
                # deferral never lets other runtime work pass it. Automatic stays
                # first; anything else waits for a person.
                retry = "first" if retry == "meeting" else "hold"
            newer = db.execute("SELECT id FROM tickets WHERE pr=? AND id>? LIMIT 1",
                               (item["pr"], item["id"])).fetchone()
            if item["status"] == "previewing" and newer:
                # A fix arrived while this preview was built: whatever this build's
                # outcome, the newer ticket replaces it (the app is reconciled from
                # what is installed, not from this record).
                args.status = "superseded"
            elif args.status == "awaiting_approval":
                # The installed app must carry exactly the train plus this ticket.
                app = installed_app()
                expected = pairs(preview_train(db)) | {(item["id"], item["head"])}
                if not app or app["members"] is None or pairs(app["members"]) != expected:
                    raise ValueError("The installed app does not carry the current train "
                                     "plus this preview (expected %s): rebuild it"
                                     % json.dumps(sorted(expected)))
                if item["preview_tier"] == "restore_point" and not item["restore_point"]:
                    raise ValueError("#%d changes settings or stores code and was installed "
                                     "without a recorded restore point: roll the app back to "
                                     "the known-good bundle" % item["id"])
                for member in app["members"]:
                    db.execute("UPDATE tickets SET preview_build=? WHERE id=?",
                               (app["build"], member["ticket"]))
            pending = json.loads(item["protected_pending"] or "[]")
            if args.status == "done" and pending:
                raise ValueError("#%d still has protected-data tests pending (%s): run them on "
                                 "main with an unlocked screen and record `protected-pending "
                                 "--passed` first" % (item["id"], ", ".join(pending)))
            if args.status == "queued":
                # A ticket requeued after a block goes to the end; one returned from
                # in_progress or previewing without a block keeps its place (its queued_at).
                reenter_review(db, args.ticket, item["status"] in ("in_progress", "previewing"), args.note)
                return ticket_json(db, args.ticket)
            # Recover/retry explicitly; no lease expiry silently starts a duplicate build.
            db.execute("UPDATE tickets SET status=?, note=?, updated_at=?, retry=? WHERE id=?",
                       (args.status, args.note, now(), retry, args.ticket))
            event(db, args.ticket, args.status, args.note)
            return ticket_json(db, args.ticket)

        if args.command == "events":
            query = ("SELECT e.*,t.pr,t.head,t.title,t.source,t.session,t.host FROM events e "
                     "JOIN tickets t ON t.id=e.ticket WHERE 1=1")
            params = []
            if args.pending:
                query += (" AND e.acknowledged_at IS NULL AND (t.source='codex' OR e.deliver=1)")
            if args.ticket:
                query += " AND e.ticket=?"
                params.append(args.ticket)
            return [dict(e) for e in db.execute(query + " ORDER BY e.id", params)]

        if args.command == "ack":
            require_builder(db, args.actor)
            changed = db.execute("UPDATE events SET acknowledged_at=? WHERE id=?",
                                 (now(), args.event)).rowcount
            if not changed:
                raise ValueError("Unknown event")
            return {"acknowledged": args.event}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--actor", default=os.environ.get("WHYTAP_BUILD_QUEUE_ACTOR")
                        or os.environ.get("CODEX_THREAD_ID", ""))
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("configure")
    setup.add_argument("--builder-thread", required=True)
    setup.add_argument("--host", default="local")
    commands.add_parser("install", help="Copy this helper into the shared Git directory")
    enqueue = commands.add_parser("enqueue")
    for flag in ("pr", "head", "title", "checks"):
        enqueue.add_argument("--" + flag, required=True)
    enqueue.add_argument("--acceptance", action="append", required=True)
    enqueue.add_argument("--dependencies", default="none")
    enqueue.add_argument("--depends-on", action="append", metavar="PR_URL",
                         help="a PR that must be merged through this queue first; the "
                              "ticket keeps its place and is not claimed until then")
    enqueue.add_argument("--source", choices=("codex", "claude", "other"),
                         help="default: detected from CODEX_THREAD_ID / CLAUDE_CODE_SESSION_ID")
    enqueue.add_argument("--session", default="",
                         help="default: that harness's session ID from the environment")
    enqueue.add_argument("--host", default="local")
    enqueue.add_argument("--preview", action="store_true",
                         help="build and install it for the owner's check first; review, "
                              "full suite and merge follow in a release batch after `approve`")
    status = commands.add_parser("status")
    status.add_argument("--ticket", type=int)
    status.add_argument("--open", action="store_true",
                        help="only open work and the earlier tickets of the same PRs")
    commands.add_parser("claim")
    commands.add_parser("preview-claim", help="Next preview to build (preview lane)")
    orchestrator = commands.add_parser("configure-orchestrator",
                                       help="The one actor that relays the owner's decisions")
    orchestrator.add_argument("--orchestrator", required=True)
    orchestrator.add_argument("--token-file", required=True,
                              help="a private file holding the orchestrator's secret token")
    admit = commands.add_parser("preview-admit", help="May base..commit be previewed?")
    admit.add_argument("--base", required=True)
    admit.add_argument("--commit", required=True)
    handoff = commands.add_parser("preview-handoff",
                                  help="May this composition replace the owner's app now?")
    handoff.add_argument("--base", required=True, help="the main SHA it was composed on")
    handoff.add_argument("--members", required=True,
                         help="JSON [{ticket, head}] of the unmerged PRs it carries")
    handoff.add_argument("--ticket", type=int, help="the preview being built, if any")
    handoff.add_argument("--build", type=int, required=True, help="the candidate's build")
    recorded = commands.add_parser("preview-restore-point",
                                   help="Record the outgoing app's restore point on a preview")
    recorded.add_argument("--ticket", type=int, required=True)
    recorded.add_argument("--restore-point", required=True, help="its ID (a UUID)")
    restored = commands.add_parser("data-restored",
                                   help="The pending data rollback was applied (or failed)")
    restored.add_argument("--restore-point", required=True)
    restored.add_argument("--note", required=True, help="evidence: the apply output, launch")
    restored.add_argument("--failed", action="store_true")
    commands.add_parser("preview-lane-off", help="Send previews to normal validation")
    release = commands.add_parser("release", help="Start one release batch of every "
                                                  "approved feature")
    release.add_argument("--by", required=True, help="the owner's words, or the trigger")
    release.add_argument("--note", default="")
    release.add_argument("--auto", action="store_true",
                         help="the watcher's count trigger (as the builder)")
    release.add_argument("--token-file")
    for name in ("approve", "reject"):
        decision = commands.add_parser(name, help="Relay the owner's decision on a preview")
        decision.add_argument("--ticket", type=int, required=True)
        decision.add_argument("--note", required=True)
        decision.add_argument("--head", required=True, help="the head the owner saw")
        decision.add_argument("--build", required=True, help="the build he saw it in")
        decision.add_argument("--token-file")
        if name == "reject":
            decision.add_argument("--restore-data", action="store_true",
                                  help="the owner asked to roll his data back as well")
            decision.add_argument("--sections", help="comma list; default every section")
        if name == "approve":
            decision.add_argument("--by", required=True,
                                  help="who approved and their words, e.g. 'owner: feature OK'")
    stale = commands.add_parser("return-stale-dependencies",
                                help="Return queued tickets whose dependency stays blocked")
    stale.add_argument("--minutes", type=int, default=STALE_DEPENDENCY_MINUTES)
    protected = commands.add_parser(
        "protected-pending", help="Record protected-data tests skipped behind a locked "
                                  "screen, or that they passed")
    protected.add_argument("--ticket", type=int, required=True)
    protected.add_argument("--tests", help="JSON list of skipped test names to add")
    protected.add_argument("--passed", help="JSON list of test names that passed on main")
    protected.add_argument("--note", default="")
    commands.add_parser("check-heads", help="Return queued tickets whose PR head moved")
    update = commands.add_parser("set")
    update.add_argument("--ticket", type=int, required=True)
    update.add_argument("--status", choices=STATES, required=True)
    update.add_argument("--note", required=True)
    update.add_argument("--retry-install", action="store_true",
                        help="pending_install only: the install waits for the meeting gate "
                             "(or for its group); the watcher retries it by itself")
    update.add_argument("--install-first", action="store_true",
                        help="pending_install only: like --retry-install, but installed before "
                             "any other runtime work is claimed (full group, isolated PR next)")
    update.add_argument("--hold", action="store_true",
                        help="pending_install only: a person must act; no other runtime work "
                             "is claimed until this install is resolved")
    events = commands.add_parser("events")
    events.add_argument("--ticket", type=int)
    events.add_argument("--pending", action="store_true")
    ack = commands.add_parser("ack")
    ack.add_argument("--event", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.command == "install":
            destination = common_dir() / "exodia-build-queue.py"
            content = Path(__file__).read_bytes()
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
                temporary = Path(output.name)
                output.write(content)
            temporary.replace(destination)
            result = {"helper": str(destination)}
        else:
            if args.command == "enqueue":
                with database() as db:
                    known = submitted(db, args)
                # Outside the queue transaction: the checks take seconds. An already
                # accepted PR/head stays idempotent and is not checked again.
                args.documentation_checks = (None if known
                                             else documentation_preflight(args.head))
                args.runtime = changes_runtime(args.head)
            # Outside the queue transaction too: one network read, before any lock.
            args.remote_heads = (remote_heads() if args.command in (
                "claim", "check-heads", "preview-claim") else None)
            # The watcher's configuration, read outside the queue transaction.
            settings = watcher_settings()
            args.preview_lane = settings.get("preview_lane") is True
            args.release_after_approved = settings.get("release_after_approved", 0)
            result = run(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, sqlite3.Error, subprocess.CalledProcessError, OSError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
