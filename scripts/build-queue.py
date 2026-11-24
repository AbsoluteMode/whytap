#!/usr/bin/env python3
"""Local, durable FIFO for the shared app builder. Never builds or launches apps.

WHY: .project-docs/decisions/2026-10-19-build-queue.md
Only Python's standard library is required. All worktrees share the Git common
directory; queue metadata stays local and survives build/ cleanup.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
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
          "cancelled", "superseded")
TRANSITIONS = {
    "queued": {"cancelled"},
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
# The owner's one-off "no meeting now" for a waiting install, read by
# build-queue-meeting-gate.py while that ticket is still pending_install.
MEETING_OVERRIDE = "meeting_override"
OVERRIDE_MAX_MINUTES = 120
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


def block_moved_head(db, ticket, snapshot):
    """A queued ticket whose PR head moved after submission goes back to its author
    before any builder reviews the old commit. True when it was returned. Only a
    ticket queued before the remote read started is judged: one submitted (or
    requeued) while the read was in flight may be newer than the snapshot."""
    if not snapshot or ticket["queued_at"] >= snapshot["started"]:
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
    db.execute("UPDATE tickets SET status='blocked', note=?, updated_at=? WHERE id=?",
               (note, now(), ticket["id"]))
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
                             "status IN ('queued', 'blocked', 'in_progress', 'pending_install')",
                             (args.pr,)).fetchall()
            if any(t["status"] in ("in_progress", "pending_install") for t in old):
                raise ValueError("Builder must reconcile the active/candidate head before resubmission")
            for t in old:
                if (t["source"], t["session"], t["host"]) != (args.source, args.session, args.host):
                    raise ValueError("A previous request for this PR belongs to another session")
            for dependency in args.depends_on:
                for t in db.execute("SELECT depends_on FROM tickets WHERE pr=? AND status IN "
                                    "('queued', 'blocked', 'in_progress')", (dependency,)):
                    if args.pr in json.loads(t["depends_on"]):
                        raise ValueError(dependency + " already depends on this PR")
            for t in old:
                db.execute("UPDATE tickets SET status='superseded', updated_at=? WHERE id=?",
                           (now(), t["id"]))
                event(db, t["id"], "superseded", "Replaced by a newly reviewed commit")
            stamp = now()
            cursor = db.execute(
                "INSERT INTO tickets(pr,head,title,source,session,host,checks,acceptance,"
                "dependencies,depends_on,runtime,queued_at,updated_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (args.pr, args.head, args.title, args.source, args.session, args.host,
                 args.checks, json.dumps(args.acceptance), args.dependencies,
                 json.dumps(args.depends_on), int(args.runtime), stamp, stamp))
            event(db, cursor.lastrowid, "queued", "Accepted into the build queue; documentation "
                  "checks at submission: " + args.documentation_checks)
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
            query += " ORDER BY queued_at, id"
            return {"builder": config(db), "install_boundary": install_boundary(db),
                    "tickets": [ticket_json(db, t[0])
                    for t in db.execute(query, params).fetchall()]}

        if args.command == "claim":
            require_builder(db, args.actor)
            active = db.execute("SELECT id FROM tickets WHERE status='in_progress'").fetchone()
            if active:
                return {"claimed": False, "active": ticket_json(db, active[0])}
            # FIFO among tickets that can be built now: one waiting for a dependency
            # or, while merged runtime work must be installed first, a runtime ticket
            # keeps its place; one whose PR head moved goes back to its author.
            returned, waiting, held = [], [], []
            boundary = install_boundary(db)
            for item in db.execute("SELECT * FROM tickets WHERE status='queued' "
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
            # A ticket requeued after a block goes to the end; one returned from
            # in_progress without a block keeps its place (its queued_at).
            requeued = args.status == "queued" and item["status"] != "in_progress"
            # Recover/retry explicitly; no lease expiry silently starts a duplicate build.
            db.execute("UPDATE tickets SET status=?, note=?, updated_at=?, retry=?, "
                       "queued_at=CASE WHEN ? THEN ? ELSE queued_at END WHERE id=?",
                       (args.status, args.note, stamp, retry, requeued, stamp, args.ticket))
            event(db, args.ticket, args.status, args.note)
            return ticket_json(db, args.ticket)

        if args.command == "allow-install":
            # WHY: .project-docs/decisions/2026-11-24-meeting-gate-whytap-activity.md
            # The owner's word that no meeting is on, recorded on the ticket. The
            # builder never grants it to itself.
            if args.actor and args.actor == config(db).get("builder_thread"):
                raise ValueError("Only the owner allows an install despite the meeting gate; "
                                 "the builder never does")
            item = row(db, args.ticket)
            if args.revoke:
                db.execute("DELETE FROM config WHERE key=?", (MEETING_OVERRIDE,))
                note = f"Owner meeting-gate override revoked by {args.by} at {now()}"
                event(db, args.ticket, item["status"], note)
                return {"revoked": True, "ticket": args.ticket}
            if item["status"] != "pending_install":
                raise ValueError("allow-install applies only to a pending_install ticket; "
                                 f"#{args.ticket} is {item['status']}")
            if not 1 <= args.minutes <= OVERRIDE_MAX_MINUTES:
                raise ValueError(f"--minutes must be 1..{OVERRIDE_MAX_MINUTES}")
            said = " ".join(args.said.split())
            if not args.by.strip() or not said:
                raise ValueError("--by and --said (the owner's own words) are required")
            granted = datetime.now(timezone.utc)
            override = {"ticket": args.ticket, "by": args.by.strip(), "said": said[:500],
                        "granted_at": granted.isoformat(timespec="seconds"),
                        "until": (granted + timedelta(minutes=args.minutes))
                        .isoformat(timespec="seconds"),
                        "requested_by": args.actor or "unknown"}
            db.execute("INSERT INTO config(key, value) VALUES (?, ?) ON CONFLICT(key) "
                       "DO UPDATE SET value=excluded.value",
                       (MEETING_OVERRIDE, json.dumps(override, ensure_ascii=False)))
            event(db, args.ticket, "pending_install",
                  f"Owner {override['by']} allowed this install despite the meeting gate at "
                  f"{override['granted_at']} until {override['until']} (recorded by "
                  f"{override['requested_by']}); owner said: {override['said']}. Whytap's own "
                  "recording still defers it.")
            return {"allowed": override}

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
    status = commands.add_parser("status")
    status.add_argument("--ticket", type=int)
    commands.add_parser("claim")
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
    allow = commands.add_parser(
        "allow-install", help="Owner only: the meeting gate lets this waiting install through "
                              "for a while; Whytap's own recording still defers it")
    allow.add_argument("--ticket", type=int, required=True)
    allow.add_argument("--by", default="owner", help="who allowed it (the owner)")
    allow.add_argument("--said", default="", help="the owner's own words, quoted")
    allow.add_argument("--minutes", type=int, default=30)
    allow.add_argument("--revoke", action="store_true")
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
            args.remote_heads = (remote_heads() if args.command in ("claim", "check-heads")
                                 else None)
            result = run(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, sqlite3.Error, subprocess.CalledProcessError, OSError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
