#!/usr/bin/env python3
"""Linux-safe tests for Shortcut Keeper's diff logic. No macOS, no network, no real app configs.

The fixtures in examples/ are invented: keys.example.json is the desired state, fixtures/scan-healthy.json and
fixtures/scan-drift.json are what scan.py would print on a Mac in each case.
  python3 -m unittest discover -s tests -p 'test_*.py' -v
"""
import copy, json, os, subprocess, sys, tempfile, time, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import keeper_core as kc  # noqa: E402

EX = os.path.join(ROOT, 'examples')
FIX = os.path.join(EX, 'fixtures')
FIXER_BY_OWNER = {'Wispr Flow': 'wispr', 'BetterWispr': 'betterwispr', 'Rectangle Pro': 'rectangle'}   # as in keeper.py
TODAY = '2026-11-05'


def load(name):
    with open(os.path.join(FIX, name)) as f: return json.load(f)


def desired():
    with open(os.path.join(EX, 'keys.example.json')) as f: return json.load(f)


def everything_installed(name): return True


def by_id(issues): return {i['id']: i for i in issues}


class Notation(unittest.TestCase):
    def test_modifier_flags(self):
        self.assertEqual(kc.cocoa(1966080), ['ctrl', 'opt', 'shift', 'cmd'])        # Rectangle Pro's Hyper
        self.assertEqual(kc.carbon(6912), ['ctrl', 'opt', 'shift', 'cmd'])         # BetterWispr's Hyper
        self.assertEqual(kc.cocoa(786432), ['ctrl', 'opt'])

    def test_combo_order_and_hyper(self):
        self.assertEqual(kc.combo(['cmd', 'shift'], '4'), 'shift+cmd+4')
        self.assertEqual(kc.combo(kc.cocoa(1966080), 'Y'), 'HYPER+Y')
        self.assertEqual(kc.combo(['fn'], ''), 'fn')

    def test_pretty(self):
        self.assertEqual(kc.pretty('HYPER+W'), 'Caps W')
        self.assertEqual(kc.pretty('shift+cmd+4'), '⇧⌘4')
        self.assertEqual(kc.pretty('ctrl+opt+Y'), '⌃⌥Y')
        self.assertEqual(kc.pretty('rctrl'), 'Right Ctrl')


class Clashes(unittest.TestCase):
    def test_senders_and_stopped_apps_never_clash(self):
        rows = [{'combo': 'HYPER+/', 'owner': 'Key Deck', 'running': True, 'kind': 'listener'},
                {'combo': 'HYPER+/', 'owner': 'Logi Options+', 'running': True, 'kind': 'sender'},
                {'combo': 'HYPER+W', 'owner': 'Key Deck', 'running': True, 'kind': 'listener'},
                {'combo': 'hyper+w', 'owner': 'Floaty', 'running': False, 'kind': 'listener'}]
        self.assertEqual(kc.find_clashes(rows), [])

    def test_two_running_listeners_clash(self):
        rows = load('scan-drift.json')['rows']
        self.assertEqual(kc.find_clashes(rows), [{'combo': 'hyper+w', 'owners': ['Floaty', 'Key Deck']}])

    def test_fixtures_carry_the_clashes_the_scanner_would_print(self):
        for name in ('scan-healthy.json', 'scan-drift.json'):
            s = load(name)
            self.assertEqual(s['clashes'], kc.find_clashes(s['rows']), name)


class CompareHealthy(unittest.TestCase):
    def test_healthy_scan_leaves_only_the_pending_todo(self):
        K = desired(); before = json.dumps(K, sort_keys=True)
        issues, changes = kc.compare(K, load('scan-healthy.json'), TODAY, everything_installed, FIXER_BY_OWNER)
        self.assertEqual([(i['level'], i['id'], i['who']) for i in issues], [('todo', 'ticktick-quick-add', 'GK')])
        self.assertEqual(changes, [])
        self.assertEqual(json.dumps(K, sort_keys=True), before, 'a healthy run must not rewrite keys.json')
        ok, summary, counts = kc.summarize(issues)
        self.assertTrue(ok)
        self.assertEqual(summary, 'All shortcuts healthy, 1 to-do for you')
        self.assertEqual(counts['todo'], 1)


class CompareDrift(unittest.TestCase):
    def setUp(self):
        self.K = desired()
        self.issues, self.changes = kc.compare(self.K, load('scan-drift.json'), TODAY, everything_installed, FIXER_BY_OWNER)
        self.by = by_id(self.issues)

    def test_enforced_key_that_drifted_is_high_with_a_fixer(self):
        i = self.by['sixth']
        self.assertEqual((i['level'], i['fixer'], i['who']), ('high', 'rectangle', 'agent'))
        self.assertIn('should be Caps Y but is ⌃⌥Y', i['text'])

    def test_adopt_key_follows_the_app(self):
        k = next(k for k in self.K['keys'] if k['id'] == 'wispr-paste-last')
        self.assertEqual((k['combo'], k['keys']), ('ctrl+opt+V', '⌃⌥V'))
        self.assertIn('Wispr Flow: Paste last dictation again moved from ⌃⌘V to ⌃⌥V (adopted)', self.changes)
        self.assertNotIn('wispr-paste-last', self.by, 'an adopted change is not an issue')

    def test_new_shortcuts_are_added_as_watch_items(self):
        new = {k['id']: k for k in self.K['keys'] if k.get('isNew') == TODAY}
        self.assertEqual(sorted(new), ['chatgpt-classic-togglelauncher', 'floaty-pin', 'ticktick-ttstartorabandonpomo'])
        self.assertTrue(all(k['policy'] == 'watch' and k['section'] == 'other' for k in new.values()))
        self.assertIn('added ⇧⌘P = TTStartOrAbandonPomo (TickTick)', self.changes)

    def test_clashes_are_high(self):
        # find_clashes lowercases combos, so a Hyper clash prints as 'hyper w' (cosmetic, kept as in production)
        self.assertEqual(self.by['clash-hyper+w']['text'], 'hyper w is claimed by Floaty and Key Deck')
        # Rectangle's ⌃⌥← is an untouched default (no config row), so only keys.json knows it: still a clash
        self.assertEqual(self.by['clash-ctrl+opt+left']['text'], '⌃⌥Left is claimed by Rectangle Pro and ChatGPT Classic')

    def test_ignored_and_hyper_rows_are_not_new(self):
        ids = [k['id'] for k in self.K['keys']]
        self.assertNotIn('logi-options-gesture-click', ids)
        self.assertFalse(any(i.startswith('raycast-hyperkey') for i in ids))

    def test_summary_names_the_first_serious_issue(self):
        ok, summary, counts = kc.summarize(self.issues)
        self.assertFalse(ok)
        self.assertTrue(summary.startswith('3 issues: Rectangle Pro "Top center sixth: the call box" should be Caps Y'), summary)
        self.assertEqual((counts['high'], counts['todo']), (3, 1))

    def test_only_issues_with_a_fixer_are_fixable(self):
        self.assertEqual([i['id'] for i in kc.fixable(self.issues)], ['sixth'])

    def test_adopt_false_reports_without_touching_keys(self):
        K = desired(); before = json.dumps(K, sort_keys=True)
        issues, changes = kc.compare(K, load('scan-drift.json'), TODAY, everything_installed, FIXER_BY_OWNER, adopt=False)
        self.assertEqual(changes, [])
        self.assertEqual(json.dumps(K, sort_keys=True), before)
        self.assertEqual(by_id(issues)['wispr-paste-last']['level'], 'info')


class CompareEdges(unittest.TestCase):
    def test_uninstalled_app_is_archived_not_flagged(self):
        K = desired(); S = load('scan-healthy.json')
        S = dict(S, rows=[r for r in S['rows'] if r['owner'] != 'TickTick'])
        issues, changes = kc.compare(K, S, TODAY, lambda name: name != 'TickTick', FIXER_BY_OWNER)
        self.assertIn('removed Caps A (TickTick no longer installed)', changes)
        self.assertEqual(K['removed'][-1]['removed'], TODAY)
        self.assertNotIn('ticktick-quick-add', by_id(issues))

    def test_installed_app_with_no_keys_is_medium(self):
        K = desired(); S = load('scan-healthy.json')
        S = dict(S, rows=[r for r in S['rows'] if r['owner'] != 'Rectangle Pro'])
        i = by_id(kc.compare(K, S, TODAY, everything_installed, FIXER_BY_OWNER)[0])
        self.assertEqual((i['center']['level'], i['center']['fixer']), ('medium', 'rectangle'))
        self.assertEqual((i['resize']['level'], i['resize']['fixer']), ('medium', None))   # adopt: reported, never fixed

    def test_app_path_gone_moves_entry_to_removed(self):
        K = desired(); K['keys'].append({'id': 'old', 'section': 'other', 'keys': '⌥Space', 'action': 'old launcher',
                                         'app': 'Old App', 'app_path': '/Applications/Old App.app', 'verify': {'by': 'none'}, 'policy': 'watch'})
        _, changes = kc.compare(K, load('scan-healthy.json'), TODAY, everything_installed, FIXER_BY_OWNER, exists=lambda p: False)
        self.assertIn('removed ⌥Space (Old App no longer installed)', changes)

    def test_reserved_key_is_low_unless_acknowledged(self):
        K = desired(); S = copy.deepcopy(load('scan-healthy.json'))
        S['rows'].append({'combo': 'cmd+H', 'owner': 'Floaty', 'action': 'hide', 'source': 'defaults', 'running': True, 'kind': 'listener'})
        i = by_id(kc.compare(K, S, TODAY, everything_installed, FIXER_BY_OWNER)[0])
        self.assertEqual(i['reserved-cmd+h']['level'], 'low')
        K = desired(); K['acknowledged_reserved'].append('cmd+h')
        self.assertNotIn('reserved-cmd+h', by_id(kc.compare(K, S, TODAY, everything_installed, FIXER_BY_OWNER)[0]))

    def test_scanner_failure_is_high(self):
        i = by_id(kc.compare(desired(), {'rows': [], 'clashes': [], 'error': 'boom'}, TODAY, everything_installed, FIXER_BY_OWNER)[0])
        self.assertEqual(i['scanner']['level'], 'high')

    def test_rule_levels(self):
        self.assertEqual([kc.rule_issue_level(p) for p in ('enforce', 'report', 'watch')], ['high', 'info', 'medium'])


class SafetyGate(unittest.TestCase):
    def test_clear(self):
        self.assertEqual(kc.fix_blockers(idle_seconds=600), [])

    def test_user_active_defers(self):
        self.assertEqual(kc.fix_blockers(idle_seconds=30), ['you used the keyboard or mouse 30s ago'])

    def test_call_signals_defer(self):
        why = kc.fix_blockers(recorder_line='krisp: recording 00:12:40', zoom_meeting=True, director_state_age=60, idle_seconds=900)
        self.assertEqual(why, ['the call hook says a call is being recorded', 'a Zoom meeting is open', 'the Meeting Director is handling a call'])
        self.assertEqual(kc.fix_blockers(recorder_line='krisp: no recording'), [])
        self.assertEqual(kc.fix_blockers(director_state_age=5 * 3600, mic_users='123|ai.krisp.krispMac|krisp|1|0'), ['Krisp is using the mic'])


class SnapPanel(unittest.TestCase):
    def test_panel_follows_deck_tiles_in_order(self):
        K = desired()
        self.assertEqual(kc.expected_panel(K), [{'windowAction': 0}, {'windowAction': 43}, {'windowAction': 29}])
        K['keys'][6]['deck']['panel'] = False   # left-half out of the panel
        self.assertEqual([kc.norm_slot(x) for x in kc.expected_panel(K)], [(43, None), (29, None)])
