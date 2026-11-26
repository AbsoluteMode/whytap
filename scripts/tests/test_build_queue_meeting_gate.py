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
if __name__=='__main__':unittest.main()
