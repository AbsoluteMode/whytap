#!/usr/bin/env python3
"""Local, durable FIFO for the shared app builder. Never builds or launches apps.

WHY: .project-docs/decisions/2026-10-19-build-queue.md
Only Python's standard library is required. All worktrees share the Git common
directory; queue metadata stays local and survives build/ cleanup.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
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
    "in_progress": {"pending_install", "done", "blocked"},
    "pending_install": {"done", "blocked", "superseded"},
    "blocked": {"queued", "cancelled", "superseded"},
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def git(*args):
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.PIPE).strip()


def common_dir():
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))


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


def event(db, ticket, status, note=""):
    db.execute("INSERT INTO events(ticket, status, note, created_at) VALUES (?, ?, ?, ?)",
               (ticket, status, note, now()))


def row(db, ticket):
    result = db.execute("SELECT * FROM tickets WHERE id = ?", (ticket,)).fetchone()
    if result is None:
        raise ValueError("Unknown ticket")
    return result


def ticket_json(db, ticket):
    result = dict(row(db, ticket))
    result["acceptance"] = json.loads(result["acceptance"])
    if result["status"] == "queued":
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
                db.execute("UPDATE tickets SET status='superseded', updated_at=? WHERE id=?",
                           (now(), t["id"]))
                event(db, t["id"], "superseded", "Replaced by a newly reviewed commit")
            stamp = now()
            cursor = db.execute(
                "INSERT INTO tickets(pr,head,title,source,session,host,checks,acceptance,"
                "dependencies,queued_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (args.pr, args.head, args.title, args.source, args.session, args.host,
                 args.checks, json.dumps(args.acceptance), args.dependencies, stamp, stamp))
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
            return {"builder": config(db), "tickets": [ticket_json(db, t[0])
                    for t in db.execute(query, params).fetchall()]}

        if args.command == "claim":
            require_builder(db, args.actor)
            active = db.execute("SELECT id FROM tickets WHERE status='in_progress'").fetchone()
            if active:
                return {"claimed": False, "active": ticket_json(db, active[0])}
            item = db.execute("SELECT id FROM tickets WHERE status='queued' "
                              "ORDER BY queued_at, id LIMIT 1").fetchone()
            if not item:
                return {"claimed": False, "active": None}
            db.execute("UPDATE tickets SET status='in_progress', owner=?, updated_at=? WHERE id=?",
                       (args.actor, now(), item[0]))
            event(db, item[0], "in_progress", "Builder has started; follow this build and its acceptance checks")
            return {"claimed": True, "ticket": ticket_json(db, item[0])}

        if args.command == "set":
            require_builder(db, args.actor)
            item = row(db, args.ticket)
            if args.status not in TRANSITIONS.get(item["status"], set()):
                raise ValueError("Invalid transition: " + item["status"] + " -> " + args.status)
            if args.retry_install and args.status != "pending_install":
                raise ValueError("--retry-install applies only to pending_install")
            stamp = now()
            # Recover/retry explicitly; no lease expiry silently starts a duplicate build.
            db.execute("UPDATE tickets SET status=?, note=?, updated_at=?, retry=?, "
                       "queued_at=CASE WHEN ?='queued' THEN ? ELSE queued_at END WHERE id=?",
                       (args.status, args.note, stamp, "meeting" if args.retry_install else "",
                        args.status, stamp, args.ticket))
            event(db, args.ticket, args.status, args.note)
            return ticket_json(db, args.ticket)

        if args.command == "events":
            query = ("SELECT e.*,t.pr,t.head,t.title,t.source,t.session,t.host FROM events e "
                     "JOIN tickets t ON t.id=e.ticket WHERE 1=1")
            params = []
            if args.pending:
                query += " AND e.acknowledged_at IS NULL AND t.source='codex'"
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
    enqueue.add_argument("--source", choices=("codex", "claude", "other"),
                         help="default: detected from CODEX_THREAD_ID / CLAUDE_CODE_SESSION_ID")
    enqueue.add_argument("--session", default="",
                         help="default: that harness's session ID from the environment")
    enqueue.add_argument("--host", default="local")
    status = commands.add_parser("status")
    status.add_argument("--ticket", type=int)
    commands.add_parser("claim")
    update = commands.add_parser("set")
    update.add_argument("--ticket", type=int, required=True)
    update.add_argument("--status", choices=STATES, required=True)
    update.add_argument("--note", required=True)
    update.add_argument("--retry-install", action="store_true",
                        help="pending_install only: the checked candidate waits for the "
                             "meeting gate; the watcher retries the install by itself")
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
            result = run(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, sqlite3.Error, subprocess.CalledProcessError, OSError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
