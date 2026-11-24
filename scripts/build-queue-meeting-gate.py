#!/usr/bin/env python3
"""Read-only, fail-closed meeting check for the local build queue. No audio capture.

WHY: .project-docs/decisions/2026-11-24-meeting-gate-whytap-activity.md
"""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def evaluate(report, now):
    observed = datetime.fromisoformat(report['observed_at'].replace('Z', '+00:00'))
    age = (now - observed).total_seconds()
    samples = report['samples']
    if not 0 <= age <= 5 or len(samples) != 3:
        return 'unknown', 'stale_or_incomplete_probe'
    if any(s['status'] == 'busy' for s in samples):
        return 'busy', next(s['reason'] for s in samples if s['status'] == 'busy')
    if not all(s['status'] == 'clear' and s['reason'] == 'no_call_audio_observed' for s in samples):
        return 'unknown', 'meeting_cannot_be_excluded'
    return 'clear', 'three_current_snapshots_without_call_audio'


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
        status, reason = evaluate(report, now)
        evidence = {'status': status, 'reason': reason, 'observed_at': report['observed_at'],
                    'sample_count': len(report['samples']), 'audio_captured': False,
                    'samples': [s['reason'] for s in report['samples']]}
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        status = 'unknown'
        evidence = {'status': status, 'reason': 'probe_failed_or_timed_out',
                    'observed_at': datetime.now(timezone.utc).isoformat(), 'audio_captured': False}
    print(json.dumps(evidence, sort_keys=True))
    return 0 if status == 'clear' else 1


if __name__ == '__main__':
    sys.exit(main())
