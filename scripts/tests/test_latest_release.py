"""Run the publisher against disposable Git/CLI fixtures; no network or real key."""

import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SIGNATURE = base64.b64encode(b"synthetic signature".ljust(64, b".")).decode()

GH = r'''#!/usr/bin/python3
import json,os,sys,shutil
from pathlib import Path
a=sys.argv[1:];root=Path(os.environ['TEST_RELEASE_ROOT']);remote=root/'remote'
with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(a)+'\n')
if a[:2]==['auth','status']:sys.exit(0)
if a[:2]==['release','view']:sys.exit(0 if a[2]=='beta' else 1)
if a[0]=='api':sys.exit(1)
if a[:2]==['release','download']:
 dest=Path(a[a.index('--dir')+1]);dest.mkdir(exist_ok=True)
 names=[a[i+1] for i,v in enumerate(a) if v=='--pattern']
 if len(names)==1:sys.exit(1)
 for name in names:shutil.copyfile(remote/name,dest/name)
 sys.exit(0)
if a[:2]==['release','upload']:
 remote.mkdir(exist_ok=True)
 for name in a:
  path=Path(name)
  if path.is_file():
   shutil.copyfile(path,remote/path.name)
   if os.environ.get('TEST_CORRUPT_UPLOAD') and path.suffix=='.dmg':
    with (remote/path.name).open('ab') as f:f.write(b'corrupt')
 sys.exit(0)
if a[:2] in [['release','create'],['release','edit']]:sys.exit(0)
sys.exit(70)
'''

GENERATOR = r'''#!/usr/bin/python3
import os,sys,xml.etree.ElementTree as ET
from pathlib import Path
ns='http://www.andymatuschak.org/xml-namespaces/sparkle'
root=ET.Element('rss');channel=ET.SubElement(root,'channel')
for build,url in [('42',sys.argv[sys.argv.index('--download-url-prefix')+1]+'generated-name.dmg'),
                  ('41','https://github.com/AbsoluteMode/whytap/releases/download/v9.9.8/Whytap-latest.dmg')]:
 item=ET.SubElement(channel,'item');ET.SubElement(item,'{'+ns+'}version').text=build
 ET.SubElement(item,'{'+ns+'}minimumSystemVersion').text='14.1'
 ET.SubElement(item,'enclosure',{'url':url,'length':'4','{'+ns+'}edSignature':os.environ['TEST_SIGNATURE']})
ET.ElementTree(root).write(str(Path(sys.argv[-1])/'appcast.xml'))
'''

VERIFIER = r'''#!/usr/bin/python3
import os,sys,json
from pathlib import Path
assert sys.argv[1:3]==['--verify','--ed-key-file']
assert Path(sys.argv[-2]).name.endswith('-latest.dmg')
assert Path(sys.argv[-2]).read_bytes()==b'test'
assert sys.argv[-1]==os.environ['TEST_SIGNATURE']
with (Path(os.environ['TEST_RELEASE_ROOT'])/'calls.jsonl').open('a') as f:
 f.write(json.dumps(['signature-verify',Path(sys.argv[-2]).name])+'\n')
'''


class LatestReleaseTests(unittest.TestCase):
    def run_publisher(self, flavor="prod", corrupt=False):
        temp = tempfile.TemporaryDirectory(prefix="whytap-latest-publisher-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for name in ["scripts", "Resources", "build", "bin", ".build/mock"]:
            (root / name).mkdir(parents=True)
        for name in ["scripts/upload-release.sh", "scripts/release-provenance.py",
                     "Resources/Info.plist.template"]:
            shutil.copyfile(ROOT / name, root / name)
        for name, body in [("bin/gh", GH), (".build/mock/generate_appcast", GENERATOR),
                           (".build/mock/sign_update", VERIFIER)]:
            (root / name).write_text(body)
            (root / name).chmod(0o755)
        (root / "VERSION").write_text("9.9.9\n")
        env = {"PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_CONFIG_NOSYSTEM": "1"}
        def run(*args):
            return subprocess.run(args, cwd=root, env=env, check=True, capture_output=True, text=True)
        run("git", "init", "-q")
        run("git", "config", "user.name", "Release fixture")
        run("git", "config", "user.email", "fixture@example.invalid")
        run("git", "add", ".")
        run("git", "commit", "-qm", "fixture")
        source = run("git", "rev-parse", "HEAD").stdout.strip()
        bundle = "Whytap" if flavor == "prod" else "Whytap-Beta"
        archive = root / f"build/{bundle}-9.9.9-build42.dmg"
        archive.write_bytes(b"test")
        run("/usr/bin/python3", str(root / "scripts/release-provenance.py"), "seal",
            "--project-root", str(root), "--source-sha", source, "--archive", str(archive),
            "--version", "9.9.9", "--build", "42", "--flavor", flavor,
            "--distribution", "community", "--code-signing", "adhoc")
        env.update(PATH=str(root / "bin") + ":/usr/bin:/bin", FLAVOR=flavor,
                   APP_BUNDLE_NAME=bundle, SHORT_VERSION="9.9.9", BUILD_VERSION="42",
                   SPARKLE_ED_PRIVATE_KEY=base64.b64encode(b"synthetic fixture seed".ljust(32, b".")).decode(),
                   TEST_RELEASE_ROOT=str(root), TEST_SIGNATURE=SIGNATURE)
        if corrupt:
            env["TEST_CORRUPT_UPLOAD"] = "1"
        result = subprocess.run(["/bin/bash", str(root / "scripts/upload-release.sh")],
                                cwd=root, env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
        return root, bundle, result, calls

    def test_prod_and_beta_publish_one_latest_dmg_with_tag_pinned_feed(self):
        for flavor in ["prod", "beta"]:
            with self.subTest(flavor=flavor):
                root, bundle, result, calls = self.run_publisher(flavor)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                tag = "v9.9.9" if flavor == "prod" else "beta-v9.9.9-b42"
                upload = next(c for c in calls if c[:3] == ["release", "upload", tag])
                assets = [Path(a).name for a in upload if a.endswith((".dmg", ".xml"))]
                self.assertEqual(assets, [bundle + "-latest.dmg", "appcast.xml"])
                self.assertEqual((root / "remote" / (bundle + "-latest.dmg")).read_bytes(), b"test")
                items = ET.parse(root / "remote/appcast.xml").getroot().findall("./channel/item")
                self.assertEqual(items[0].find("enclosure").get("url"),
                                 f"https://github.com/AbsoluteMode/whytap/releases/download/{tag}/{bundle}-latest.dmg")
                self.assertEqual(items[1].find("enclosure").get("url"),
                                 "https://github.com/AbsoluteMode/whytap/releases/download/v9.9.8/Whytap-latest.dmg")
                self.assertIn(["signature-verify", bundle + "-latest.dmg"], calls)
                self.assertTrue(any(c[:3] == ["release", "edit", tag] and "--draft=false" in c for c in calls))

    def test_changed_downloaded_bytes_leave_the_release_unpublished(self):
        _, _, result, calls = self.run_publisher(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("leaving the release as a draft", result.stdout + result.stderr)
        self.assertFalse(any(c[:2] == ["release", "edit"] for c in calls))


if __name__ == "__main__":
    unittest.main()
