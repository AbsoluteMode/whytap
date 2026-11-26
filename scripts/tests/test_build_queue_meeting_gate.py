import importlib.util
import plistlib
import unittest
from datetime import datetime, timezone, timedelta
from pathlib import Path
spec=importlib.util.spec_from_file_location('gate',Path(__file__).resolve().parents[1]/'build-queue-meeting-gate.py')
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
class GateEvidenceTests(unittest.TestCase):
    def test_fresh_clear_only(self):
        now=datetime.now(timezone.utc)
        report={'observed_at':now.isoformat(),'samples':[{'status':'clear','reason':'no_call_audio_observed'}]*3}
        self.assertEqual(gate.evaluate(report,now)[0],'clear')
        report['samples'][1]={'status':'busy','reason':'microphone_in_use'}
        self.assertEqual(gate.evaluate(report,now)[0],'busy')
    def test_unknown_never_means_clear(self):
        now=datetime.now(timezone.utc)
        report={'observed_at':now.isoformat(),'samples':[{'status':'clear','reason':'no_call_audio_observed'},{'status':'unknown','reason':'read_failed'},{'status':'clear','reason':'no_call_audio_observed'}]}
        self.assertEqual(gate.evaluate(report,now)[0],'unknown')
    def test_old_future_or_incomplete_evidence_rejected(self):
        now=datetime.now(timezone.utc)
        for offset,count in [(-6,3),(1,3),(0,2)]:
            report={'observed_at':(now+timedelta(seconds=offset)).isoformat(),'samples':[{'status':'clear','reason':'no_call_audio_observed'}]*count}
            self.assertEqual(gate.evaluate(report,now)[0],'unknown')
class ScreenStateTests(unittest.TestCase):
    """The install gate refuses every console state but an unlocked screen in front
    (review item 3 on ticket 635): a resumed candidate, a deferred retry and a screen
    that locked after packaging all pass this one function before the Quit."""
    def session(self, **values):
        user = {'kCGSSessionUserIDKey': 501, 'kCGSSessionOnConsoleKey': True, **values}
        return plistlib.dumps({'IOConsoleUsers': [user]})
    def test_only_an_unlocked_screen_in_front_is_clear(self):
        cases = [
            (self.session(CGSSessionScreenIsLocked=False), 'clear'),
            (self.session(), 'clear'),
            (self.session(CGSSessionScreenIsLocked=True), 'busy'),
            (self.session(kCGSSessionOnConsoleKey=False), 'busy'),
            (self.session(kCGSSessionUserIDKey=502), 'busy'),
            (plistlib.dumps({'IOConsoleUsers': []}), 'busy'),
            (self.session(CGSSessionScreenIsLocked='yes'), 'unknown'),
            (plistlib.dumps({'IOConsoleUsers': 'odd'}), 'unknown'),
            (b'not a plist', 'unknown'),
            (b'', 'unknown'),
            # Review of ticket 647 item 2: only typed flags count.
            (self.session(kCGSSessionOnConsoleKey='No'), 'unknown'),
            (self.session(kCGSSessionOnConsoleKey='Yes'), 'unknown'),
            (self.session(kCGSSessionOnConsoleKey=1), 'unknown'),
            (self.session(kCGSSessionOnConsoleKey={}), 'unknown'),
            (self.session(CGSSessionScreenIsLocked=0), 'unknown'),
            (self.session(kCGSSessionUserIDKey='501'), 'unknown'),
            (self.session(kCGSSessionUserIDKey=True), 'unknown'),
            (plistlib.dumps({'IOConsoleUsers': ['odd']}), 'unknown'),
            (plistlib.dumps({'IOConsoleUsers': [
                {'kCGSSessionUserIDKey': 501, 'kCGSSessionOnConsoleKey': True},
                {'kCGSSessionUserIDKey': 501, 'kCGSSessionOnConsoleKey': True,
                 'CGSSessionScreenIsLocked': True}]}), 'unknown'),
            (plistlib.dumps({'IOConsoleUsers': [
                {'kCGSSessionUserIDKey': 502, 'kCGSSessionOnConsoleKey': True},
                {'kCGSSessionUserIDKey': 501, 'kCGSSessionOnConsoleKey': True}]}), 'clear'),
            (plistlib.dumps({'IOConsoleUsers': [
                {'kCGSSessionUserIDKey': 501, 'kCGSSessionOnConsoleKey': False},
                {'kCGSSessionUserIDKey': 501, 'kCGSSessionOnConsoleKey': True}]}), 'clear'),
        ]
        for data, expected in cases:
            with self.subTest(data=data[:60]):
                self.assertEqual(gate.screen_state(data, 501)[0], expected)
class HandoffTests(unittest.TestCase):
    """Review of ticket 641: the screen must be unlocked before and after the audio
    samples, and a failed probe never clears (every order of failure enumerated)."""
    def test_clear_only_when_the_screen_holds_through_the_samples(self):
        clear, locked, unknown = ('clear', 'screen_unlocked'), ('busy', 'screen_locked'), \
            ('unknown', 'screen_state_unreadable')
        now = datetime.now(timezone.utc)
        audio_clear = lambda: ('clear', {'reason': 'three_current_snapshots_without_call_audio',
                                         'observed_at': now.isoformat()})
        audio_busy = lambda: ('busy', {'reason': 'microphone_in_use', 'observed_at': now.isoformat()})
        cases = [((clear, clear), audio_clear, 'clear'),
                 ((locked,), audio_clear, 'busy'), ((unknown,), audio_clear, 'unknown'),
                 ((clear, locked), audio_clear, 'busy'),
                 ((clear, ('busy', 'session_not_on_console')), audio_clear, 'busy'),
                 ((clear, unknown), audio_clear, 'unknown'),
                 ((clear, clear), audio_busy, 'busy')]
        for screens, audio, expected in cases:
            with self.subTest(screens=screens, expected=expected):
                sequence = iter(screens)
                calls = []
                status, evidence = gate.handoff(lambda: calls.append(1) or next(sequence), audio,
                                                now=lambda: now)
                self.assertEqual(status, expected)
                if screens[0][0] != 'clear':
                    self.assertEqual(len(calls), 1)  # no audio sampled on a locked Mac
    def test_audio_evidence_must_still_be_current_at_the_verdict(self):
        """Review of ticket 647 item 1: a delayed or timed-out second screen read
        cannot carry old audio evidence into a Quit; the samples' own time is kept."""
        observed = datetime.now(timezone.utc)
        audio = lambda: ('clear', {'reason': 'three_current_snapshots_without_call_audio',
                                   'observed_at': observed.isoformat()})
        clear = ('clear', 'screen_unlocked')
        cases = [(0, clear, 'clear'), (5, clear, 'clear'), (5.001, clear, 'unknown'),
                 (8, clear, 'unknown'), (10, ('unknown', 'screen_state_unreadable'), 'unknown'),
                 (-1, clear, 'unknown')]
        for delay, second, expected in cases:
            with self.subTest(delay=delay, expected=expected):
                screens = iter([clear, second])
                status, evidence = gate.handoff(lambda: next(screens), audio,
                                                now=lambda: observed + timedelta(seconds=delay))
                self.assertEqual(status, expected)
                self.assertEqual(evidence['observed_at'], observed.isoformat())
        for missing in [{}, {'observed_at': None}, {'observed_at': 'not a time'}]:
            with self.subTest(missing=missing):
                screens = iter([clear, clear])
                status, _ = gate.handoff(lambda: next(screens),
                                         lambda: ('clear', {'reason': 'x', **missing}),
                                         now=lambda: observed)
                self.assertEqual(status, 'unknown')
    def test_a_timed_out_screen_probe_is_unknown(self):
        def times_out(*a, **k):
            raise gate.subprocess.TimeoutExpired('ioreg', 10)
        self.assertEqual(gate.screen_probe(times_out)[0], 'unknown')
    def test_a_failed_probe_is_never_read_as_clearance(self):
        class Result:
            def __init__(self, code, stdout):
                self.returncode, self.stdout = code, stdout
        unlocked = plistlib.dumps({'IOConsoleUsers': [{'kCGSSessionUserIDKey': gate.os.getuid(),
                                                       'kCGSSessionOnConsoleKey': True}]})
        self.assertEqual(gate.screen_probe(lambda *a, **k: Result(0, unlocked))[0], 'clear')
        self.assertEqual(gate.screen_probe(lambda *a, **k: Result(1, unlocked))[0], 'unknown')
        def raises(*a, **k):
            raise OSError('no ioreg')
        self.assertEqual(gate.screen_probe(raises)[0], 'unknown')
if __name__=='__main__':unittest.main()
