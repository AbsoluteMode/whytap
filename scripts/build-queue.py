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
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile


STATES = ("queued", "in_progress", "pending_install", "done", "blocked",
          "cancelled", "superseded", "previewing", "awaiting_approval", "approved",
          "releasing")
# WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
# A preview ticket (lane 'preview') is built and installed for the owner before any
# review or full suite: previewing -> awaiting_approval. `approve` moves it to the
# validation lane ('approved', queued, keeping its place); `reject` returns it.
TRANSITIONS = {
    "queued": {"cancelled"},
    # previewing -> queued: the environment stopped the preview (keeps its place).
    "previewing": {"awaiting_approval", "blocked", "queued"},
    # WHY: .project-docs/decisions/2026-11-26-release-batches.md
    # approved: the owner accepted the feature; it waits for the next release batch
    # (`release`) and stays in the preview train meanwhile. releasing: one batch is
    # reviewed, tested, merged and installed together; -> approved returns a batch
    # member without blame (the environment stopped the batch).
    "approved": {"cancelled"},
    "releasing": {"done", "pending_install", "blocked", "approved"},
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


def unmet_dependencies(db, ticket, preview=False):
    """Dependency PRs of this ticket that are not merged through the queue yet: the
    latest ticket of each must be done or pending_install. A preview also accepts a
    dependency that is itself in the preview train (awaiting_approval)."""
    accepted = MERGED + (("awaiting_approval", "approved", "releasing") if preview else ())
    waiting = []
    for pr in json.loads(ticket["depends_on"] or "[]"):
        latest = db.execute("SELECT status FROM tickets WHERE pr=? ORDER BY id DESC LIMIT 1",
                            (pr,)).fetchone()
        if not latest or latest["status"] not in accepted:
            waiting.append(pr)
    return waiting


# WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
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


# Paths whose change can alter stored user data, permissions, signing or updates. A
# preview that touches one is not installed before validation: it goes to the normal
# lane (review, full suite, merge, then install). Conservative on purpose.
PREVIEW_UNSAFE = re.compile(
    r"(^Package\.(swift|resolved)$|^Resources/[^/]*\.entitlements$|^Resources/Info\.plist"
    r"|^scripts/(build-dmg\.sh|release-provenance\.py|user-release\.sh|upload-release\.sh"
    r"|build-queue)|^Sources/.*(?i:migrat|keychain|permission|tcc|entitlement|updat|sparkle"
    r"|schema|persist|database|sqlite|backup|signing|store))")


# Fail closed: a preview may change only app sources, ordinary resources, tests and
# documentation. Anything else (scripts, packages, build settings, root files) is
# outside the verified preview scope.
PREVIEW_SCOPE = re.compile(r"^(Sources/|Resources/|Tests/|docs/|\.project-docs/|[^/]+\.md$)")
# Changed lines that can touch stored data, permissions, signing or updates whatever
# the file is called.
PREVIEW_UNSAFE_CONTENT = re.compile(
    r"(?i:SecItem|kSecAttr|keychain|UserDefaults|@AppStorage|@SceneStorage|Codable|"
    r"Decodable|Encodable|NSKeyedArchiver|PropertyListEncoder|JSONEncoder|sqlite|"
    r"CREATE\s+TABLE|ALTER\s+TABLE|migrat|schemaVersion|applicationSupportDirectory|"
    r"Application Support|FileManager\.default\.(remove|move|replace)|removeItem|"
    r"AVCaptureDevice\.requestAccess|requestAccess|AXIsProcessTrusted|CGRequest|"
    r"CGPreflight|SMAppService|TCC|entitlement|SPUUpdater|SUUpdater|Sparkle|"
    r"codesign|LaunchAgent)")


def preview_admission(base, head):
    """Why the change from `base` to `head` may not be installed before validation: a
    list of reasons, empty when it is admissible. Unknown is never admissible."""
    try:
        paths = git("diff", "--name-only", "--no-renames", base, head).splitlines()
        reasons = []
        for path in (p for p in paths if p):
            if not PREVIEW_SCOPE.match(path):
                reasons.append(path + " (outside the preview scope)")
            elif PREVIEW_UNSAFE.search(path):
                reasons.append(path)
        for path in (p for p in paths if p.startswith(("Sources/", "Resources/"))):
            diff = git("diff", "--no-renames", "-U0", base, head, "--", path)
            hits = sorted({m.group(0) for line in diff.splitlines()
                           if line[:1] in "+-" and not line.startswith(("+++", "---"))
                           for m in [PREVIEW_UNSAFE_CONTENT.search(line)] if m})
            if hits:
                reasons.append(path + " (changes " + ", ".join(hits[:4]) + ")")
        return reasons
    except (subprocess.CalledProcessError, OSError, UnicodeDecodeError):
        return ["the change could not be read"]


def preview_unsafe_paths(head):
    """Reasons this commit (against its merge base with origin/main) may not be
    previewed; ["..."] when unknown: never admissible."""
    try:
        base = git("merge-base", "origin/main", head)
    except (subprocess.CalledProcessError, OSError):
        return ["the merge base with origin/main could not be read"]
    return preview_admission(base, head)


TRAIN = "(status IN ('awaiting_approval', 'approved', 'releasing') OR " \
        "(status='queued' AND lane='release'))"


def preview_train(db, exclude_pr=None):
    """PRs in the owner's app that main does not contain yet, in order: previews he is
    checking, approved features waiting for a release and a release in progress."""
    return [{"ticket": t["id"], "pr": t["pr"], "head": t["head"], "title": t["title"],
             "status": t["status"]}
            for t in db.execute("SELECT * FROM tickets WHERE " + TRAIN +
                                " ORDER BY queued_at, id").fetchall() if t["pr"] != exclude_pr]


def installed_preview(db):
    """The composition recorded as installed: [{"ticket", "head"}], or None."""
    try:
        value = json.loads(config(db).get("installed_preview", "null"))
    except ValueError:
        return None
    return value if isinstance(value, list) else None


def preview_rebuild_needed(db):
    """Whether the owner's app differs from the current train: a member it carries left
    the train without being merged (rejected, blocked, superseded, cancelled, moved to
    the normal lane), or a train member is missing from it. Derived from the recorded
    snapshot, so a decision taken after a rebuild started is never lost."""
    installed = installed_preview(db)
    if installed is None:
        return False
    carried = {(m.get("ticket"), m.get("head")) for m in installed if isinstance(m, dict)}
    for ticket, head in carried:
        item = db.execute("SELECT status, head FROM tickets WHERE id=?", (ticket,)).fetchone()
        if not item or item["head"] != head:
            return True
        if item["status"] not in MERGED and not db.execute(
                "SELECT 1 FROM tickets WHERE id=? AND " + TRAIN, (ticket,)).fetchone():
            return True
    return any((t["ticket"], t["head"]) not in carried for t in preview_train(db))


def record_installed(db, value, claimed=None):
    """Store the composition a verified install carries. It must be the current train
    (plus the ticket just previewed), each with its exact head."""
    try:
        members = json.loads(value)
        pairs = {(int(m["ticket"]), str(m["head"])) for m in members}
    except (ValueError, TypeError, KeyError):
        raise ValueError("--installed-train is a JSON list of {\"ticket\": id, \"head\": sha}")
    expected = {(t["ticket"], t["head"]) for t in preview_train(db)}
    if claimed is not None:
        expected.add((claimed["id"], claimed["head"]))
    if pairs != expected:
        raise ValueError("The installed composition is not the current train: rebuild it "
                         "(expected " + json.dumps(sorted(expected)) + ")")
    db.execute("INSERT OR REPLACE INTO config VALUES ('installed_preview', ?)",
               (json.dumps([{"ticket": t, "head": h} for t, h in sorted(pairs)]),))


def drop_dependents(db, pr, reason):
    """Train members and queued previews that need `pr` cannot stay in the owner's app
    without it: they go back to their authors too (transitively)."""
    pending = [pr]
    while pending:
        parent = pending.pop()
        for item in db.execute(
                "SELECT * FROM tickets WHERE (" + TRAIN + " OR (status='queued' AND "
                "lane='preview')) AND status != 'releasing'").fetchall():
            if parent in json.loads(item["depends_on"] or "[]"):
                note = f"Returned with {parent}: {reason}. Resubmit after it is fixed."
                db.execute("UPDATE tickets SET status='blocked', note=?, updated_at=? "
                           "WHERE id=?", (note, now(), item["id"]))
                event(db, item["id"], "blocked", note, deliver=True)
                pending.append(item["pr"])


def orchestrator_token(args):
    """The relay's secret: WHYTAP_ORCHESTRATOR_TOKEN or the file named by --token-file."""
    if getattr(args, "token_file", None):
        return Path(args.token_file).expanduser().read_text().strip()
    return os.environ.get("WHYTAP_ORCHESTRATOR_TOKEN", "").strip()


def require_orchestrator(db, actor, token):
    """The owner's decisions reach the queue only through the configured orchestrator,
    which proves itself with the token whose SHA-256 the maintainer configured. This is
    local, same-user protection against other sessions, not remote authentication."""
    settings = config(db)
    expected = settings.get("orchestrator")
    digest = settings.get("orchestrator_token_sha256")
    if not expected or not digest:
        raise ValueError("No orchestrator is configured: the maintainer runs "
                         "`build-queue-watcher.py activate --orchestrator <id> "
                         "--orchestrator-token-file <path>`")
    if actor != expected or not token or hashlib.sha256(token.encode()).hexdigest() != digest:
        raise ValueError("The owner's decisions are relayed only by the configured "
                         "orchestrator with its token")


def start_release(db, by, note, actor):
    """Move every approved feature into one release batch (queued, lane 'release'),
    keeping each one's place. Returns the batch number and tickets, or None."""
    members = db.execute("SELECT * FROM tickets WHERE status='approved' "
                         "ORDER BY queued_at, id").fetchall()
    if not members:
        return None
    batch = int(config(db).get("last_batch", "0")) + 1
    db.execute("INSERT OR REPLACE INTO config VALUES ('last_batch', ?)", (str(batch),))
    stamp = now()
    for item in members:
        db.execute("UPDATE tickets SET status='queued', lane='release', batch=?, note=?, "
                   "updated_at=? WHERE id=?",
                   (batch, f"Release {batch}: {by}", stamp, item["id"]))
        event(db, item["id"], "queued", f"In release batch {batch} ({by}; relayed by {actor}). "
              f"One review, one full suite, merge and one install follow. {note}".strip(),
              deliver=True)
    return {"batch": batch, "tickets": [t["id"] for t in members]}


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
        if "lane" not in columns:
            # '' normal validation; 'preview' built for the owner's check first;
            # 'approved' the owner accepted the preview, validation follows.
            db.execute("ALTER TABLE tickets ADD COLUMN lane TEXT NOT NULL DEFAULT ''")
        if "resubmits" not in columns:
            # Resubmissions after a block that kept the PR's place (at most two).
            db.execute("ALTER TABLE tickets ADD COLUMN resubmits INTEGER NOT NULL DEFAULT 0")
        if "approval" not in columns:
            # JSON: who relayed the owner's approval, when, and the quoted words.
            db.execute("ALTER TABLE tickets ADD COLUMN approval TEXT NOT NULL DEFAULT ''")
        for column, sql in (
                # When the head was submitted; FIFO priority may reuse an older queued_at.
                ("submitted_at", "TEXT NOT NULL DEFAULT ''"),
                ("preview_build", "TEXT NOT NULL DEFAULT ''"),  # build shown to the owner
                ("auto_returned", "INTEGER NOT NULL DEFAULT 0")):  # returned without a model
            if column not in columns:
                db.execute(f"ALTER TABLE tickets ADD COLUMN {column} {sql}")
                if column == "submitted_at":
                    db.execute("UPDATE tickets SET submitted_at=queued_at")
        if "batch" not in columns:
            # The release batch a ticket belongs to (0: none).
            db.execute("ALTER TABLE tickets ADD COLUMN batch INTEGER NOT NULL DEFAULT 0")
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
            for dependency in args.depends_on:
                for t in db.execute("SELECT depends_on FROM tickets WHERE pr=? AND status IN "
                                    "('queued', 'blocked', 'in_progress')", (dependency,)):
                    if args.pr in json.loads(t["depends_on"]):
                        raise ValueError(dependency + " already depends on this PR")
            # Read before the supersede below changes its status.
            previous = db.execute("SELECT * FROM tickets WHERE pr=? ORDER BY id DESC LIMIT 1",
                                  (args.pr,)).fetchone()
            for t in old:
                db.execute("UPDATE tickets SET status='superseded', updated_at=? WHERE id=?",
                           (now(), t["id"]))
                event(db, t["id"], "superseded", "Replaced by a newly reviewed commit")
            stamp = now()
            # WHY: .project-docs/decisions/2026-11-26-preview-before-validation.md
            # A resubmission after a block keeps the PR's earlier place, at most
            # RESUBMIT_PRIORITY_LIMIT times; a fix to a preview the owner is checking
            # keeps it always (that loop is the owner's own).
            queued_at, resubmits, place = stamp, 0, ""
            if previous and previous["queued_at"] < stamp:
                fix = previous["status"] in ("awaiting_approval", "approved", "previewing") or (
                    previous["status"] == "blocked" and previous["lane"] == "preview")
                if fix:
                    queued_at, resubmits = previous["queued_at"], previous["resubmits"]
                    place = "; keeps the place of preview #%d" % previous["id"]
                elif previous["status"] == "blocked" and previous["auto_returned"]:
                    # Returned without a model (moved head, blocked dependency): the
                    # place is kept and no resubmission priority is spent.
                    queued_at, resubmits = previous["queued_at"], previous["resubmits"]
                    place = "; keeps the place of #%d (returned without review)" % previous["id"]
                elif (previous["status"] == "blocked"
                        and previous["resubmits"] < RESUBMIT_PRIORITY_LIMIT):
                    queued_at, resubmits = previous["queued_at"], previous["resubmits"] + 1
                    place = "; resubmission %d of %d keeps the place of #%d" % (
                        resubmits, RESUBMIT_PRIORITY_LIMIT, previous["id"])
                else:
                    resubmits = previous["resubmits"]
            lane = "preview" if args.preview else ""
            routed = ""
            if lane and not preview_lane_enabled():
                lane, routed = "", ("; the preview lane is off, so it goes through normal "
                                    "validation (review, full suite, merge, install)")
            cursor = db.execute(
                "INSERT INTO tickets(pr,head,title,source,session,host,checks,acceptance,"
                "dependencies,depends_on,runtime,lane,resubmits,queued_at,submitted_at,"
                "updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (args.pr, args.head, args.title, args.source, args.session, args.host,
                 args.checks, json.dumps(args.acceptance), args.dependencies,
                 json.dumps(args.depends_on), int(args.runtime), lane, resubmits,
                 queued_at, stamp, stamp))
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
                query += (" WHERE pr IN (SELECT pr FROM tickets WHERE status IN ('queued', "
                          "'in_progress', 'pending_install', 'previewing', "
                          "'awaiting_approval', 'approved', 'releasing'))")
            query += " ORDER BY queued_at, id"
            result = {"builder": config(db), "install_boundary": install_boundary(db),
                      "preview_train": preview_train(db),
                      "preview_rebuild": preview_rebuild_needed(db),
                      "installed_preview": installed_preview(db),
                      "tickets": [ticket_json(db, t[0])
                                  for t in db.execute(query, params).fetchall()]}
            if args.open and not args.ticket:
                for t in result["tickets"]:
                    if t["status"] in ("done", "superseded", "cancelled", "blocked") \
                            and len(t["note"]) > 600:
                        t["note"] = t["note"][:600] + " [...] (status --ticket %d)" % t["id"]
            return result

        if args.command == "claim":
            require_builder(db, args.actor)
            active = db.execute("SELECT id FROM tickets WHERE status='in_progress'").fetchone()
            if active:
                return {"claimed": False, "active": ticket_json(db, active[0])}
            releasing = [t[0] for t in db.execute(
                "SELECT id FROM tickets WHERE status='releasing' ORDER BY queued_at, id")]
            if releasing:
                return {"claimed": False, "active": None, "active_batch": {
                    "batch": row(db, releasing[0])["batch"],
                    "tickets": [ticket_json(db, t) for t in releasing]}}
            batch = claim_release(db, args)
            if batch:
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
            token = Path(args.token_file).expanduser().read_text().strip()
            if len(token) < 32:
                raise ValueError("The orchestrator token must be at least 32 characters")
            db.execute("INSERT OR REPLACE INTO config VALUES ('orchestrator', ?)",
                       (args.orchestrator,))
            db.execute("INSERT OR REPLACE INTO config VALUES ('orchestrator_token_sha256', ?)",
                       (hashlib.sha256(token.encode()).hexdigest(),))
            return {"orchestrator": args.orchestrator, "token": "configured"}

        if args.command == "preview-admit":
            reasons = preview_admission(args.base, args.commit)
            return {"admissible": not reasons, "reasons": reasons}

        if args.command == "preview-current":
            # Right before the Quit: is the composition about to be installed still the
            # current train (members and heads)? Pending decisions change it.
            try:
                pairs = {(int(m["ticket"]), str(m["head"])) for m in json.loads(args.installed_train)}
            except (ValueError, TypeError, KeyError):
                raise ValueError("--installed-train is a JSON list of {ticket, head}")
            expected = {(t["ticket"], t["head"]) for t in preview_train(db)}
            active = db.execute("SELECT id, head FROM tickets WHERE status='previewing'").fetchone()
            if active:
                expected.add((active["id"], active["head"]))
            return {"current": pairs == expected,
                    "train": sorted([list(pair) for pair in expected])}

        if args.command == "preview-lane-off":
            require_builder(db, args.actor)
            moved = []
            for item in db.execute("SELECT * FROM tickets WHERE status='queued' AND "
                                   "lane='preview'").fetchall():
                note = ("The preview lane was switched off: this PR goes through normal "
                        "validation (review, full suite, merge, install).")
                db.execute("UPDATE tickets SET lane='', note=?, updated_at=? WHERE id=?",
                           (note, now(), item["id"]))
                event(db, item["id"], "queued", note, deliver=True)
                moved.append(item["id"])
            return {"moved_to_normal_lane": moved}

        if args.command == "release":
            # WHY: .project-docs/decisions/2026-11-26-release-batches.md
            if args.auto:
                require_builder(db, args.actor)  # the watcher's count trigger
            else:
                require_orchestrator(db, args.actor, orchestrator_token(args))
            if db.execute("SELECT 1 FROM tickets WHERE status='releasing' OR "
                          "(status='queued' AND lane='release')").fetchone():
                raise ValueError("A release batch is already open; the next one starts after it")
            started = start_release(db, args.by, args.note, args.actor)
            return started or {"batch": None, "tickets": [], "note": "nothing is approved"}

        if args.command in ("approve", "reject"):
            item = row(db, args.ticket)
            if item["status"] != "awaiting_approval":
                raise ValueError("Only a preview awaiting the owner's approval can be "
                                 + args.command + "d; #%d is %s" % (item["id"], item["status"]))
            require_orchestrator(db, args.actor, orchestrator_token(args))
            if args.actor == item["session"]:
                raise ValueError("A PR's own session cannot relay the owner's decision on it")
            # The decision is about what the owner saw: this head in this build.
            if args.head != item["head"] or str(args.build) != item["preview_build"]:
                raise ValueError("The owner saw head %s in build %s; this decision names head "
                                 "%s in build %s" % (item["head"], item["preview_build"] or "?",
                                                     args.head, args.build))
            stamp = now()
            if args.command == "approve":
                approval = json.dumps({"by": args.by, "relayed_by": args.actor, "at": stamp,
                                       "note": args.note})
                # Stays in the owner's app (the train) until its release batch is merged.
                db.execute("UPDATE tickets SET status='approved', lane='approved', approval=?, "
                           "note=?, updated_at=? WHERE id=?",
                           (approval, "Owner approved the preview: " + args.by, stamp, item["id"]))
                event(db, item["id"], "approved", "The owner approved the feature (" + args.by +
                      "). It stays in his app and goes out with the next release batch: one "
                      "review, one full suite, merge and one install.", deliver=True)
            else:
                db.execute("UPDATE tickets SET status='blocked', note=?, updated_at=? WHERE id=?",
                           ("Owner's changes to the preview: " + args.note, stamp, item["id"]))
                event(db, item["id"], "blocked", "The owner sent the preview back: " + args.note +
                      " Push the fix and enqueue it again with --preview.", deliver=True)
                drop_dependents(db, item["pr"], "the owner sent it back")
            return ticket_json(db, item["id"])

        if args.command == "preview-rebuilt":
            require_builder(db, args.actor)
            record_installed(db, args.installed_train)
            return {"preview_rebuild": preview_rebuild_needed(db),
                    "preview_train": preview_train(db)}

        if args.command == "return-stale-dependencies":
            require_builder(db, args.actor)
            return {"returned": return_stale_dependencies(db, args.minutes)}

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
            stamp = now()
            status = args.status
            newer = db.execute("SELECT id FROM tickets WHERE pr=? AND id>? LIMIT 1",
                               (item["pr"], item["id"])).fetchone()
            if item["status"] == "previewing" and newer:
                # A fix arrived while this preview was built: whatever this build's
                # outcome, the newer ticket replaces it and only it is claimed next.
                status = "superseded"
            elif status == "awaiting_approval":
                if not args.preview_build or not args.installed_train:
                    raise ValueError("awaiting_approval records what the owner sees: "
                                     "--preview-build <n> --installed-train <json>")
                record_installed(db, args.installed_train, claimed=item)
                db.execute("UPDATE tickets SET preview_build=? WHERE id=?",
                           (str(args.preview_build), item["id"]))
            if item["status"] == "releasing" and status == "blocked":
                drop_dependents(db, item["pr"], "it failed in its release batch")
            args.status = status
            # A ticket requeued after a block goes to the end; one returned from
            # in_progress or previewing without a block keeps its place (its queued_at).
            requeued = args.status == "queued" and item["status"] not in ("in_progress",
                                                                          "previewing")
            # Recover/retry explicitly; no lease expiry silently starts a duplicate build.
            db.execute("UPDATE tickets SET status=?, note=?, updated_at=?, retry=?, "
                       "queued_at=CASE WHEN ? THEN ? ELSE queued_at END WHERE id=?",
                       (args.status, args.note, stamp, retry, requeued, stamp, args.ticket))
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


def preview_lane_enabled():
    """The watcher's configuration in the Git common directory turns the lane on."""
    try:
        settings = json.loads((common_dir() / "whytap-build-queue-builder.json").read_text())
    except (OSError, ValueError, subprocess.CalledProcessError):
        return False
    return isinstance(settings, dict) and settings.get("preview_lane") is True


def claim_release(db, args):
    """The oldest open release batch, claimed whole: its members become `releasing`
    together. A member whose PR head moved goes back to its author; one waiting for a
    PR outside the batch that is not merged stays queued for the next batch."""
    first = db.execute("SELECT batch FROM tickets WHERE status='queued' AND lane='release' "
                       "ORDER BY batch, queued_at, id LIMIT 1").fetchone()
    if not first:
        return None
    members = db.execute("SELECT * FROM tickets WHERE status='queued' AND lane='release' AND "
                         "batch=? ORDER BY queued_at, id", (first["batch"],)).fetchall()
    in_batch = {t["pr"] for t in members}
    # Merge order: FIFO, but a member after every batch member it depends on.
    ordered, placed = [], set()
    while len(ordered) < len(members):
        for item in members:
            needs = set(json.loads(item["depends_on"] or "[]")) & in_batch
            if item["pr"] not in placed and needs <= placed:
                ordered.append(item)
                placed.add(item["pr"])
                break
        else:  # a cycle cannot be submitted; keep FIFO for whatever is left
            ordered += [t for t in members if t["pr"] not in placed]
            break
    members = ordered
    returned, waiting, claimed = [], [], []
    for item in members:
        outside = [pr for pr in unmet_dependencies(db, item) if pr not in in_batch]
        if outside:
            waiting.append(item["id"])
        elif block_moved_head(db, item, args.remote_heads):
            returned.append(item["id"])
        else:
            claimed.append(item["id"])
    for ticket in waiting:  # back to approved: the next batch takes it
        db.execute("UPDATE tickets SET status='approved', batch=0, updated_at=? WHERE id=?",
                   (now(), ticket))
    for ticket in claimed:
        db.execute("UPDATE tickets SET status='releasing', owner=?, updated_at=? WHERE id=?",
                   (args.actor, now(), ticket))
        event(db, ticket, "releasing", "Release batch %d started: one review, one full suite, "
              "merge and one install for all its features" % first["batch"])
    return {"claimed": bool(claimed), "batch": first["batch"],
            "tickets": [ticket_json(db, t) for t in claimed],
            "returned_moved_heads": returned, "waiting_for_dependencies": waiting}


def preview_claim(db, args):
    """The preview lane's next step, model-free: the ticket to preview (oldest queued
    preview whose dependencies are merged or in the train), with the train it joins.
    A preview that touches stored data, permissions, signing or updates goes to the
    normal lane instead; one whose PR head moved goes back to its author."""
    active = db.execute("SELECT id, pr FROM tickets WHERE status='previewing'").fetchone()
    if active:
        return {"claimed": False, "active": ticket_json(db, active["id"]),
                "train": preview_train(db, active["pr"])}
    # A preview installs current main: never while merged work waits for its own
    # install (a group, --install-first, --hold, or protected-data checks pending).
    waiting_install = [t[0] for t in db.execute(
        "SELECT id FROM tickets WHERE status='pending_install'")]
    if waiting_install:
        return {"claimed": False, "active": None, "held_for_install": waiting_install,
                "rebuild": False, "train": preview_train(db)}
    returned, waiting, normal_lane = [], [], []
    for item in db.execute("SELECT * FROM tickets WHERE status='queued' AND lane='preview' "
                           "ORDER BY queued_at, id").fetchall():
        if unmet_dependencies(db, item, preview=True):
            waiting.append(item["id"])
            continue
        if block_moved_head(db, item, args.remote_heads):
            returned.append(item["id"])
            continue
        unsafe = preview_unsafe_paths(item["head"])
        if unsafe:
            listed = "; ".join(unsafe[:8])
            note = ("No preview before validation: this PR touches stored data, permissions, "
                    "signing or updates (" + listed + "). It stays queued for the normal "
                    "review, full suite and merge before any install.")
            db.execute("UPDATE tickets SET lane='', note=?, updated_at=? WHERE id=?",
                       (note, now(), item["id"]))
            event(db, item["id"], "queued", note, deliver=item["source"] in ("codex", "claude"))
            normal_lane.append(item["id"])
            continue
        db.execute("UPDATE tickets SET status='previewing', owner=?, updated_at=? WHERE id=?",
                   (args.actor, now(), item["id"]))
        event(db, item["id"], "previewing", "Preview build started (no review or full suite "
              "before the owner's check)")
        return {"claimed": True, "ticket": ticket_json(db, item["id"]),
                "train": preview_train(db, item["pr"]), "returned_moved_heads": returned,
                "waiting_for_dependencies": waiting, "moved_to_normal_lane": normal_lane}
    return {"claimed": False, "active": None,
            "rebuild": preview_rebuild_needed(db), "train": preview_train(db),
            "returned_moved_heads": returned, "waiting_for_dependencies": waiting,
            "moved_to_normal_lane": normal_lane}


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
                              "full suite and merge follow only after `approve`")
    status = commands.add_parser("status")
    status.add_argument("--ticket", type=int)
    status.add_argument("--open", action="store_true",
                        help="only open work and the earlier tickets of the same PRs")
    commands.add_parser("claim")
    commands.add_parser("preview-claim", help="Next preview to build (preview lane)")
    rebuilt = commands.add_parser("preview-rebuilt",
                                  help="Record the composition a verified install carries")
    rebuilt.add_argument("--installed-train", required=True)
    stale = commands.add_parser("return-stale-dependencies",
                                help="Return queued tickets whose dependency stays blocked")
    stale.add_argument("--minutes", type=int, default=STALE_DEPENDENCY_MINUTES)
    orchestrator = commands.add_parser("configure-orchestrator",
                                       help="The one actor that relays the owner's decisions")
    orchestrator.add_argument("--orchestrator", required=True)
    orchestrator.add_argument("--token-file", required=True,
                              help="a private file holding the orchestrator's secret token")
    admit = commands.add_parser("preview-admit", help="May base..commit be previewed?")
    admit.add_argument("--base", required=True)
    admit.add_argument("--commit", required=True)
    current = commands.add_parser("preview-current",
                                  help="Is this composition still the current train?")
    current.add_argument("--installed-train", required=True)
    commands.add_parser("preview-lane-off", help="Send queued previews to normal validation")
    release = commands.add_parser("release", help="Start one release batch of every "
                                                  "approved feature")
    release.add_argument("--by", required=True, help="the owner's words, or the trigger")
    release.add_argument("--note", default="")
    release.add_argument("--auto", action="store_true",
                         help="the watcher's trigger (as the builder)")
    release.add_argument("--token-file")
    for name in ("approve", "reject"):
        decision = commands.add_parser(name, help="Relay the owner's decision on a preview")
        decision.add_argument("--ticket", type=int, required=True)
        decision.add_argument("--note", required=True)
        decision.add_argument("--head", required=True, help="the head the owner saw")
        decision.add_argument("--build", required=True, help="the preview build he saw")
        decision.add_argument("--token-file")
        if name == "approve":
            decision.add_argument("--by", required=True,
                                  help="who approved and their words, e.g. 'owner: feature OK'")
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
    update.add_argument("--preview-build", help="awaiting_approval: the build the owner sees")
    update.add_argument("--installed-train",
                        help="awaiting_approval: JSON [{ticket, head}] of the installed "
                             "composition (the train plus this ticket)")
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
            if args.command == "release":
                args.ticket = None
            result = run(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, sqlite3.Error, subprocess.CalledProcessError, OSError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
