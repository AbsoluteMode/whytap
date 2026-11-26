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
        audio_clear = lambda: ('clear', {'reason': 'three_current_snapshots_without_call_audio'})
        audio_busy = lambda: ('busy', {'reason': 'microphone_in_use'})
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
                status, evidence = gate.handoff(lambda: calls.append(1) or next(sequence), audio)
                self.assertEqual(status, expected)
                if screens[0][0] != 'clear':
                    self.assertEqual(len(calls), 1)  # no audio sampled on a locked Mac
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
