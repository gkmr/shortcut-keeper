#!/usr/bin/env python3
"""Runs keeper.py itself on Linux against the fixtures, in a temporary SHORTCUT_KEEPER_HOME.

SHORTCUT_KEEPER_SCAN_JSON replays a saved scan, so no app config is read and nothing on this machine changes. The rules
block is dropped from the copied keys.json because every rule reads the live Mac (defaults, launchctl, app files).
"""
import datetime, json, os, shutil, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EX = os.path.join(ROOT, 'examples')


def rjson(p):
    with open(p) as f: return json.load(f)


def wjson(p, obj):
    with open(p, 'w') as f: json.dump(obj, f, indent=2, ensure_ascii=False)


class KeeperEndToEnd(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix='keeper-e2e-')
        K = rjson(os.path.join(EX, 'keys.example.json'))
        K['rules'] = []
        wjson(os.path.join(self.home, 'keys.json'), K)
        ax = {'checked_at': datetime.datetime.now().isoformat(timespec='seconds'), 'results': {'raycast': 'ok', 'gemini': 'ok'}}
        wjson(os.path.join(self.home, 'ax_check.json'), ax)
        self.log = os.path.join(self.home, 'notify.log')

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def keeper(self, scan, *args):
        env = dict(os.environ, SHORTCUT_KEEPER_HOME=self.home, SHORTCUT_KEEPER_SCAN_JSON=os.path.join(EX, 'fixtures', scan),
                   SHORTCUT_KEEPER_NOTIFY=os.path.join(EX, 'notify-example.sh'), SHORTCUT_KEEPER_NOTIFY_LOG=self.log)
        env.pop('SHORTCUT_KEEPER_CALL_HOOK', None)
        r = subprocess.run([sys.executable, os.path.join(ROOT, 'keeper.py'), '--json'] + list(args),
                           capture_output=True, text=True, env=env, timeout=60)
        return r.returncode, json.loads(r.stdout)

    def read(self, *p):
        with open(os.path.join(self.home, *p)) as f: return f.read()

    def test_healthy_run_is_quiet_and_writes_the_sheet(self):
        before = self.read('keys.json')
        code, st = self.keeper('scan-healthy.json')
        self.assertEqual(code, 0)
        self.assertTrue(st['ok'])
        self.assertEqual(st['summary'], 'All shortcuts healthy, 1 to-do for you')
        self.assertEqual((st['keys'], st['needs_ax'], st['changes']), (15, [], []))
        self.assertEqual(self.read('keys.json'), before, 'no change, no rewrite')
        sheet = self.read('keys.md')
        self.assertIn('## Windows', sheet); self.assertIn('| `Caps W` | Webcam Mode', sheet); self.assertNotIn('Spotlight stays off', sheet)
        self.assertIn('**All shortcuts healthy, 1 to-do for you**', self.read('reports', datetime.date.today().isoformat() + '.md'))
        self.assertFalse(os.path.exists(os.path.join(self.home, 'reports', 'CHANGELOG.md')))
        self.assertTrue(os.path.exists(self.log), 'a to-do for the human is worth one notification')

    def test_injected_drift_is_caught_and_the_fix_waits_during_a_call(self):
        os.makedirs(os.path.join(self.home, '.state'))
        with open(os.path.join(self.home, '.state', 'director.state'), 'w') as f:   # a fresh state file = a call is live
            f.write('video|com.example.browser|Google Meet|0|Meet - test\n')
        code, st = self.keeper('scan-drift.json', '--fix')
        self.assertEqual(code, 1)
        high = [i for i in st['issues'] if i['level'] == 'high']
        self.assertEqual(high[0]['id'], 'sixth')
        self.assertEqual(high[0]['fixer'], 'rectangle')
        self.assertEqual(st['deferred'], ['the Meeting Director is handling a call'])
        self.assertEqual(st['fixed'], [], 'nothing is touched while a call is live')
        self.assertFalse(os.path.isdir(os.path.join(self.home, 'backups')), 'no fix ran, so no backup either')
        report = self.read('reports', datetime.date.today().isoformat() + '.md')
        self.assertIn('## Fixes deferred', report); self.assertIn('## HIGH', report)
        K = rjson(os.path.join(self.home, 'keys.json'))
        self.assertEqual(next(k for k in K['keys'] if k['id'] == 'wispr-paste-last')['combo'], 'ctrl+opt+V')
        self.assertEqual(K['updated'], datetime.date.today().isoformat())
        history = self.read('reports', 'CHANGELOG.md')
        self.assertIn('(adopted)', history); self.assertIn('added ⇧⌘P = TTStartOrAbandonPomo (TickTick)', history)
        self.assertIn('3 issues: Rectangle Pro', self.read('notify.log'))

    def test_second_run_after_adopting_is_stable(self):
        self.keeper('scan-drift.json')
        code, st = self.keeper('scan-drift.json')
        self.assertEqual(st['changes'], [], 'adopted and added keys are now part of the desired state')
        self.assertEqual(code, 1, 'the enforced drift and the clashes are still open')


if __name__ == '__main__':
    unittest.main()
