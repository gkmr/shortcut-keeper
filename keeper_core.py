"""keeper_core.py: the pure part of Shortcut Keeper. No subprocess, no file writes, no macOS calls.

keeper.py (the daily check) and scan.py (the outside judge) import these functions, so the same code runs on the Mac and in
the Linux test suite (tests/test_keeper_core.py) against fixtures in examples/fixtures/.

  compare(K, S, ...)    desired state (keys.json) vs actual state (scan.py --json): issues and changes
  find_clashes(rows)    two running apps listening on the same key
  fix_blockers(...)     why an automatic fix must wait (a call is live, the user is active)
  combo(), cocoa(), carbon(), pretty()   key notation helpers
"""
import collections, os, re

# macOS keys an app should not take (reported as low, unless keys.json acknowledged_reserved lists the combo)
RESERVED = {'cmd+space': 'Spotlight', 'shift+cmd+3': 'screenshot', 'shift+cmd+4': 'screenshot', 'shift+cmd+5': 'screenshot',
            'opt+cmd+esc': 'Force Quit', 'ctrl+space': 'input source switch', 'ctrl+opt+space': 'input source switch',
            'cmd+tab': 'app switcher', 'cmd+`': 'next window of the same app', 'ctrl+cmd+q': 'lock screen',
            'cmd+q': 'quit', 'cmd+w': 'close window', 'cmd+h': 'hide', 'cmd+m': 'minimize', 'shift+cmd+/': 'Help menu'}

LEVELS = ['high', 'medium', 'todo', 'low', 'info']
IDLE_MIN_S = 120              # a fix waits until the keyboard and mouse have been idle this long
DIRECTOR_FRESH_S = 4 * 3600   # a Meeting Director state file younger than this = a call is being handled


# ---------------------------------------------------------------- key notation
def cocoa(f):
    """NSEvent modifier flags (Rectangle Pro, TickTick) to modifier names."""
    m = []
    if f & 262144: m.append('ctrl')
    if f & 524288: m.append('opt')
    if f & 131072: m.append('shift')
    if f & 1048576: m.append('cmd')
    return m


def carbon(f):
    """Carbon modifier flags (KeyboardShortcuts-library apps, BetterWispr) to modifier names."""
    m = []
    if f & 4096: m.append('ctrl')
    if f & 2048: m.append('opt')
    if f & 512: m.append('shift')
    if f & 256: m.append('cmd')
    return m


def combo(mods, key):
    """Canonical combo string: modifiers in a fixed order, all four of ctrl opt shift cmd folded into HYPER."""
    order = ['fn', 'ctrl', 'rctrl', 'opt', 'ropt', 'shift', 'rshift', 'cmd', 'rcmd']
    mods = sorted(set(mods), key=lambda x: order.index(x) if x in order else 99)
    if set(mods) >= {'ctrl', 'opt', 'shift', 'cmd'}:
        mods = ['HYPER'] + [m for m in mods if m not in ('ctrl', 'opt', 'shift', 'cmd')]
    return '+'.join(mods + ([key] if key else []))


def pretty(c):
    """Combo string to what the cheat sheet shows: HYPER+W -> 'Caps W', shift+cmd+4 -> '⇧⌘4'."""
    p = c.split('+')
    if p[0] == 'HYPER': return 'Caps ' + ' '.join(p[1:])
    sym = {'ctrl': '⌃', 'opt': '⌥', 'shift': '⇧', 'cmd': '⌘'}
    words = {'fn': 'Fn', 'rctrl': 'Right Ctrl', 'ropt': 'Right ⌥', 'rcmd': 'Right ⌘', 'rshift': 'Right ⇧'}
    head = ''.join(sym[x] for x in p if x in sym)
    rest = [words.get(x, x) for x in p if x not in sym]
    return (head + ' '.join(rest)) if head else ' '.join(rest)


# ---------------------------------------------------------------- clashes
def by_combo(rows):
    by = collections.defaultdict(list)
    for r in rows: by[r['combo'].lower()].append(r)
    return by


def find_clashes(rows):
    """Two different running listener apps on the same key. Senders (mouse gestures that send keys) never clash."""
    clashes = []
    for k, rs in sorted(by_combo(rows).items()):
        owners = sorted({r['owner'] for r in rs if r['running'] and r['kind'] == 'listener'})
        if len(owners) > 1: clashes.append({'combo': k, 'owners': owners})
    return clashes


# ---------------------------------------------------------------- desired vs actual
def compare(K, S, today, app_installed, fixer_by_owner, adopt=True, exists=os.path.exists):
    """Return (issues, changes) for desired state K (keys.json) against actual state S (scan.py --json output).

    Mutates K only when adopt=True: an 'adopt' entry takes the app's new key, a new shortcut is added under "other",
    an entry whose app is gone moves to K['removed']. Rules and the AX check are not here: they read the live system
    (keeper.py check_rule). app_installed(name) and exists(path) are passed in so tests need no real /Applications.
    """
    rows = S.get('rows', [])
    issues, changes = [], []

    def issue(level, id_, text, fixer=None, who='agent', fix_hint=None):
        issues.append({'level': level, 'id': id_, 'text': text, 'fixer': fixer, 'who': who, 'fix': fix_hint})
    if S.get('error'): issue('high', 'scanner', 'scan.py failed: ' + S['error'])

    def rows_for(owner, action=None):
        return [r for r in rows if r['owner'] == owner and (action is None or r['action'] == action)]
    refs = set()
    removed = []
    for k in list(K['keys']):
        v = k.get('verify', {}); by = v.get('by'); pol = k.get('policy', 'watch')
        if k.get('app_path') and not exists(k['app_path']):
            removed.append(k); continue
        if by != 'scan': continue
        owner, act, want = v['owner'], v.get('action'), v.get('combos')
        rs = rows_for(owner, act)
        for r in rs: refs.add((r['owner'], r['action'], r['combo']))
        for a in k.get('also', []):
            for r in rows_for(owner, a): refs.add((r['owner'], r['action'], r['combo']))
        if not rows_for(owner):
            if not app_installed(k.get('app', owner)) and owner not in ('macOS',):
                removed.append(k)
            elif pol in ('enforce', 'adopt'):
                issue('medium', k['id'], '%s: no shortcut found for "%s" (was %s)' % (owner, k['action'], k['keys']),
                      fixer=fixer_by_owner.get(owner) if pol == 'enforce' else None)
            continue
        actual = sorted({r['combo'] for r in rs})
        if want:
            missing = [c for c in want if c not in actual]
            if not missing:
                continue
            if k.get('pending'):
                issue('todo', k['id'], '%s: %s' % (k['keys'], k['pending']), who='GK'); continue
            if pol == 'enforce':
                issue('high', k['id'], '%s "%s" should be %s but is %s' % (owner, k['action'], ', '.join(pretty(c) for c in want),
                      ', '.join(pretty(c) for c in actual) or 'nothing'), fixer=fixer_by_owner.get(owner),
                      who='agent' if fixer_by_owner.get(owner) else 'GK')
            elif pol == 'adopt' and adopt and len(actual) == 1:
                changes.append('%s: %s moved from %s to %s (adopted)' % (owner, k['action'], k['keys'], pretty(actual[0])))
                k['keys'] = pretty(actual[0]); k['combo'] = actual[0]; v['combos'] = actual
            else:
                issue('info', k['id'], '%s "%s" is now %s' % (owner, k['action'], ', '.join(pretty(c) for c in actual)))
        elif act and len(actual) == 1:
            old = k.get('combo')
            if old is None:
                k['combo'] = actual[0]
            elif old != actual[0]:
                if pol == 'adopt' and adopt:
                    changes.append('%s: %s moved from %s to %s (adopted)' % (owner, k['action'], k['keys'], pretty(actual[0])))
                    k['keys'] = pretty(actual[0]); k['combo'] = actual[0]
                elif pol == 'enforce':
                    issue('high', k['id'], '%s "%s" should be %s but is %s' % (owner, k['action'], k['keys'], pretty(actual[0])),
                          fixer=fixer_by_owner.get(owner))
                else:
                    issue('info', k['id'], '%s "%s" is now %s' % (owner, k['action'], pretty(actual[0])))
    if adopt:
        for k in removed:
            K['keys'].remove(k); K.setdefault('removed', []).append(dict(k, removed=today))
            changes.append('removed %s (%s no longer installed)' % (k['keys'], k.get('app')))
    # new shortcuts nobody told us about
    ign = K.get('ignore', [])
    for r in rows:
        if r['source'] == 'manual.json' or not r['running']: continue
        if 'read error' in r['action']:
            issue('medium', 'scan-' + r['owner'], 'Could not read %s settings (%s)' % (r['owner'], r['action'])); continue
        if (r['owner'], r['action'], r['combo']) in refs: continue
        if any(i.get('owner') == r['owner'] and i.get('action') in (None, r['action']) for i in ign): continue
        if r['owner'] == 'Raycast' and r['action'].startswith('hyperKey'): continue
        nid = re.sub(r'[^a-z0-9]+', '-', ('%s-%s' % (r['owner'], r['action'])).lower()).strip('-')
        if any(k['id'] == nid for k in K['keys']): continue
        if adopt:
            K['keys'].append({'id': nid, 'section': 'other', 'keys': pretty(r['combo']), 'action': '%s: %s' % (r['owner'], r['action']),
                              'app': r['owner'], 'combo': r['combo'], 'verify': {'by': 'scan', 'owner': r['owner'], 'action': r['action']},
                              'policy': 'watch', 'isNew': today})
            changes.append('added %s = %s (%s)' % (pretty(r['combo']), r['action'], r['owner']))
    # clashes between running apps
    for c in S.get('clashes', []):
        issue('high', 'clash-' + c['combo'], '%s is claimed by %s' % (pretty(c['combo']), ' and '.join(c['owners'])), who='agent')
    # declared keys that no config file can show (app defaults, Raycast): another app taking them is a clash too
    declared = {}
    for k in K['keys']:
        if k.get('combo') and k.get('app') not in ('macOS',) and k.get('verify', {}).get('by') in ('none', 'raycast_ax', 'gemini_ax'):
            declared.setdefault(k['combo'].lower(), k['app'])
    seen = {c['combo'] for c in S.get('clashes', [])}
    for r in rows:
        c = r['combo'].lower(); app = declared.get(c)
        if app and r['running'] and r['kind'] == 'listener' and r['owner'] != app and c not in seen and r['source'] != 'manual.json':
            seen.add(c)
            issue('high', 'clash-' + c, '%s is claimed by %s and %s' % (pretty(r['combo']), app, r['owner']), who='agent')
    # reserved system keys taken by an app
    ack = {a.lower() for a in K.get('acknowledged_reserved', [])}
    for r in rows:
        c = r['combo'].lower()
        if c in RESERVED and c not in ack and r['running'] and r['kind'] == 'listener' and r['owner'] != 'macOS':
            issue('low', 'reserved-' + c, '%s uses %s, which macOS reserves for %s' % (r['owner'], pretty(r['combo']), RESERVED[c]))
    return issues, changes


def rule_issue_level(policy):
    """A failed rule: enforce = high, report = info (report only), anything else = medium."""
    return 'high' if policy == 'enforce' else ('info' if policy == 'report' else 'medium')


# ---------------------------------------------------------------- snap panel (one source: the Key Deck tiles)
def expected_panel(K):
    """Snap panel slots generated from the Key Deck tiles in keys.json: Windows, then Meetings, each by deck.order.
    One source of truth: change a tile in keys.json and both Key Deck and the snap panel follow."""
    rank = {'windows': 0, 'meetings': 1}
    tiles = [k for k in K['keys'] if (k.get('deck') or {}).get('group') in rank and (k.get('deck') or {}).get('panel', True)]
    tiles.sort(key=lambda k: (rank[k['deck']['group']], k['deck'].get('order', 999)))
    out = []
    for k in tiles:
        d = k['deck']
        if 'rect_action' in d: out.append({'windowAction': d['rect_action']})
        elif 'rect_custom' in d: out.append({'customSpecId': d['rect_custom'], 'windowAction': 36})
    return out


def norm_slot(x): return (x.get('windowAction'), x.get('customSpecId'))


# ---------------------------------------------------------------- safety gate for --fix
def fixable(issues):
    """Issues an automatic fixer may act on: high or medium with a fixer."""
    return [i for i in issues if i.get('fixer') and i['level'] in ('high', 'medium')]


def fix_blockers(recorder_line='', zoom_meeting=False, director_state_age=None, mic_users='', idle_seconds=None):
    """Reasons a fix must wait. Empty list = safe to fix now. keeper.py gathers the signals from the live system:
    recorder_line: first line of SHORTCUT_KEEPER_CALL_HOOK's output; zoom_meeting: Zoom's CptHost runs;
    director_state_age: seconds since .state/director.state changed (None = absent); mic_users: bin/micusers output;
    idle_seconds: keyboard and mouse idle time (None = unknown)."""
    why = []
    if 'recording' in recorder_line and 'no recording' not in recorder_line: why.append('the call hook says a call is being recorded')
    if zoom_meeting: why.append('a Zoom meeting is open')
    if director_state_age is not None and director_state_age < DIRECTOR_FRESH_S: why.append('the Meeting Director is handling a call')
    elif 'ai.krisp.krispMac' in mic_users: why.append('Krisp is using the mic')
    if idle_seconds is not None and idle_seconds < IDLE_MIN_S: why.append('you used the keyboard or mouse %ss ago' % idle_seconds)
    return why


def summarize(issues):
    """(ok, summary line, counts) as status.json and the Key Deck pill show them."""
    serious = [i for i in issues if i['level'] in ('high', 'medium')]
    todos = [i for i in issues if i['level'] == 'todo']
    if serious: summary = '%d issue%s: %s' % (len(serious), '' if len(serious) == 1 else 's', serious[0]['text'])
    else: summary = 'All shortcuts healthy' + (', %d to-do for you' % len(todos) if todos else '')
    return (not serious), summary, {l: len([i for i in issues if i['level'] == l]) for l in LEVELS}
