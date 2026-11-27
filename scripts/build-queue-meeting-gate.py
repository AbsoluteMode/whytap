#!/usr/bin/env python3
"""Read-only, fail-closed install handoff gate for the local build queue: the
owner's screen is unlocked and in front, and no meeting is running. No audio capture.
Every Quit or swap of the working app (a fresh install, a resumed candidate, a
deferred retry, a preview) passes this one gate right before the Quit.

WHY: .project-docs/decisions/2026-11-24-meeting-gate-whytap-activity.md,
     .project-docs/decisions/2026-11-26-builder-quick-wins.md
"""
import json
import os
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


MAX_EVIDENCE_AGE = 5  # seconds between the audio samples and any verdict built on them


def fresh(observed_at, now):
    """True when audio evidence observed at `observed_at` (ISO 8601) is still current
    at `now`. Every verdict that relies on the samples asks this one function, at the
    moment of that verdict; a missing or unparsable time is never fresh."""
    try:
        observed = datetime.fromisoformat(str(observed_at).replace('Z', '+00:00'))
        age = (now - observed).total_seconds()
    except (TypeError, ValueError):
        return False
    return 0 <= age <= MAX_EVIDENCE_AGE


def evaluate(report, now):
    samples = report['samples']
    if not fresh(report['observed_at'], now) or len(samples) != 3:
        return 'unknown', 'stale_or_incomplete_probe'
    if any(s['status'] == 'busy' for s in samples):
        return 'busy', next(s['reason'] for s in samples if s['status'] == 'busy')
    if not all(s['status'] == 'clear' and s['reason'] == 'no_call_audio_observed' for s in samples):
        return 'unknown', 'meeting_cannot_be_excluded'
    return 'clear', 'three_current_snapshots_without_call_audio'


def screen_state(ioreg_plist, uid):
    """('clear' | 'busy' | 'unknown', reason) for this user's console session, read
    from `ioreg -n Root -d1 -a` like the login window does. Only typed values count:
    the user ID is an integer, on-console and locked are Booleans (locked may be
    absent, which is how an unlocked session reads). Anything else, or more than
    one on-console session for this user, is unknown, and unknown is never clear."""
    unreadable = ('unknown', 'screen_state_unreadable')
    try:
        users = plistlib.loads(ioreg_plist).get('IOConsoleUsers', [])
    except (ValueError, AttributeError, plistlib.InvalidFileException):
        return unreadable
    if not isinstance(users, list):
        return unreadable
    in_front = []
    for user in users:
        if not isinstance(user, dict):
            return unreadable
        session_uid = user.get('kCGSSessionUserIDKey')
        if type(session_uid) is not int:
            return unreadable
        if session_uid != uid:
            continue
        on_console = user.get('kCGSSessionOnConsoleKey', False)
        locked = user.get('CGSSessionScreenIsLocked', False)
        if not isinstance(on_console, bool) or not isinstance(locked, bool):
            return unreadable
        if on_console:
            in_front.append(locked)
    if not in_front:
        return 'busy', 'session_not_on_console'
    if len(in_front) > 1:
        return 'unknown', 'screen_state_conflicting'
    return ('busy', 'screen_locked') if in_front[0] else ('clear', 'screen_unlocked')


def screen_probe(run=subprocess.run):
    """This user's console state now. A failed, timed-out or malformed probe is
    unknown, and unknown is never clear."""
    try:
        result = run(['ioreg', '-n', 'Root', '-d1', '-a'], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown', 'screen_state_unreadable'
    if result.returncode != 0:
        return 'unknown', 'screen_state_unreadable'
    return screen_state(result.stdout, os.getuid())


def audio_probe():
    """Three current audio snapshots: (status, evidence)."""
    try:
        source = Path(__file__).with_name('build-queue-meeting-gate.swift')
        result = subprocess.run(['swift', str(source)], capture_output=True, text=True, timeout=20)
        if result.returncode != 0:
            raise ValueError('probe_exit')
        report = json.loads(result.stdout)
        status, reason = evaluate(report, datetime.now(timezone.utc))
        return status, {'reason': reason, 'observed_at': report['observed_at'],
                        'sample_count': len(report['samples']),
                        'samples': [s['reason'] for s in report['samples']]}
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        return 'unknown', {'reason': 'probe_failed_or_timed_out',
                           'observed_at': datetime.now(timezone.utc).isoformat()}


def now_utc():
    return datetime.now(timezone.utc)


def handoff(screen, audio, now=now_utc):
    """The gate's verdict: the screen before the audio samples (a locked Mac never
    starts them), the samples, and the screen again after them (it must still be
    unlocked and in front when the Quit follows). Clear only when all three are and
    the samples are still current when the verdict is given: a slow second screen
    read cannot carry old audio evidence into a Quit."""
    before = screen()
    if before[0] != 'clear':
        return before[0], {'reason': before[1]}
    status, evidence = audio()
    if status != 'clear':
        return status, evidence
    after = screen()
    if after[0] != 'clear':
        return after[0], {**evidence, 'reason': after[1] + '_after_audio_samples'}
    if not fresh(evidence.get('observed_at'), now()):
        return 'unknown', {**evidence, 'reason': 'audio_evidence_stale_at_verdict'}
    return 'clear', {**evidence, 'screen': 'unlocked_before_and_after'}


def main():
    if sys.argv[1:]:
        print(json.dumps({'status': 'unknown', 'reason': 'unsupported_arguments'}))
        return 2
    status, evidence = handoff(screen_probe, audio_probe)
    # The audio samples' own time stays the evidence time; the verdict time is separate.
    evidence = {'observed_at': now_utc().isoformat(), **evidence, 'decided_at': now_utc().isoformat(),
                'status': status, 'audio_captured': False}
    print(json.dumps(evidence, sort_keys=True))
    return 0 if status == 'clear' else 1


if __name__ == '__main__':
    sys.exit(main())
