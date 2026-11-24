#!/usr/bin/env python3
"""Read-only, fail-closed meeting check for the local build queue. No audio capture.

WHY: .project-docs/decisions/2026-11-24-meeting-gate-whytap-activity.md
"""
import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Never overridden: an install would cut off what Whytap itself is recording.
WHYTAP_CAPTURE = 'whytap_capturing_audio'


def evaluate(report, now, override=None):
    observed = datetime.fromisoformat(report['observed_at'].replace('Z', '+00:00'))
    age = (now - observed).total_seconds()
    samples = report['samples']
    if not 0 <= age <= 5 or len(samples) != 3:
        return 'unknown', 'stale_or_incomplete_probe'
    if any(s['status'] == 'busy' and s['reason'] == WHYTAP_CAPTURE for s in samples):
        return 'busy', WHYTAP_CAPTURE
    unreadable = {'incomplete_audio_snapshot', 'audio_process_list_unavailable'}
    if override and not any(s['reason'] in unreadable for s in samples):
        # The owner said no meeting is on; only Whytap's own capture still defers, so
        # it needs a snapshot that could have seen Whytap.
        return 'clear', 'owner_override'
    if any(s['status'] == 'busy' for s in samples):
        return 'busy', next(s['reason'] for s in samples if s['status'] == 'busy')
    if not all(s['status'] == 'clear' and s['reason'] == 'no_call_audio_observed' for s in samples):
        return 'unknown', 'meeting_cannot_be_excluded'
    return 'clear', 'three_current_snapshots_without_call_audio'


def active_override(database, now):
    """The owner's `allow-install` record while it is current and its ticket still waits
    for the install; None otherwise, and on any read problem (the gate stays strict)."""
    try:
        if not database.is_file():
            return None
        db = sqlite3.connect(f'file:{database}?mode=ro', uri=True, timeout=5)
        try:
            found = db.execute("SELECT value FROM config WHERE key='meeting_override'").fetchone()
            if not found:
                return None
            override = json.loads(found[0])
            until = datetime.fromisoformat(override['until'])
            granted = datetime.fromisoformat(override['granted_at'])
            if not granted <= now < until:
                return None
            ticket = db.execute('SELECT status FROM tickets WHERE id=?',
                                (int(override['ticket']),)).fetchone()
            if not ticket or ticket[0] != 'pending_install':
                return None
            return {k: override[k] for k in ('ticket', 'by', 'granted_at', 'until')}
        finally:
            db.close()
    except (sqlite3.Error, ValueError, KeyError, TypeError, OSError):
        return None


def queue_database():
    here = Path(__file__).resolve().parent
    common = subprocess.run(['git', '-C', str(here), 'rev-parse', '--path-format=absolute',
                             '--git-common-dir'], capture_output=True, text=True, timeout=10)
    if common.returncode != 0:
        return None
    return Path(common.stdout.strip()) / 'exodia-build-queue.sqlite3'


def main():
    now = datetime.now(timezone.utc)
    if sys.argv[1:]:
        print(json.dumps({'status': 'unknown', 'reason': 'unsupported_arguments'}))
        return 2
    try:
        source = Path(__file__).with_name('build-queue-meeting-gate.swift')
        result = subprocess.run(['swift', str(source)], capture_output=True, text=True, timeout=20)
        if result.returncode != 0:
            raise ValueError('probe_exit')
        report = json.loads(result.stdout)
        now = datetime.now(timezone.utc)
        try:
            database = queue_database()
        except (OSError, subprocess.TimeoutExpired):
            database = None
        override = active_override(database, now) if database else None
        status, reason = evaluate(report, now, override)
        evidence = {'status': status, 'reason': reason, 'observed_at': report['observed_at'],
                    'sample_count': len(report['samples']), 'audio_captured': False,
                    'samples': [s['reason'] for s in report['samples']]}
        if override and reason == 'owner_override':
            evidence['owner_override'] = override
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        status = 'unknown'
        evidence = {'status': status, 'reason': 'probe_failed_or_timed_out',
                    'observed_at': datetime.now(timezone.utc).isoformat(), 'audio_captured': False}
    print(json.dumps(evidence, sort_keys=True))
    return 0 if status == 'clear' else 1


if __name__ == '__main__':
    sys.exit(main())
