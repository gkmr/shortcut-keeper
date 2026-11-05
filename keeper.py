#!/usr/bin/env python3
"""Shortcut Keeper: desired-state-as-code for macOS keyboard and mouse shortcuts.

Desired state: keys.json (what every shortcut SHOULD be).
Actual state:  scan.py --json (read from each app's own config files) + system checks.
Outside judge: the apps' config files, re-read after any fix. The sheet is never the judge.

Usage: keeper.py [--fix] [--quiet] [--json]
  --fix    restore drifted 'enforce' items when it is safe (no call, you idle 2+ min); backups first
Writes: status.json, keys.md (rich cheat sheet), reports/YYYY-MM-DD.md, reports/CHANGELOG.md (shortcut history, only on change)
Exit:   0 = healthy, 1 = issues remain, 2 = setup error
Env:    SHORTCUT_KEEPER_HOME       folder with keys.json, status.json, reports/ (default: this file's folder)
        SHORTCUT_KEEPER_SCAN_JSON  replay a saved scan.py --json output instead of scanning (tests, offline review)
        SHORTCUT_KEEPER_CALL_HOOK  optional shell command; its first line containing "recording" = a call is live
        SHORTCUT_KEEPER_NOTIFY     optional command run as: <cmd> "<summary>" "<report path>" when something changed or
                                   needs a human (see examples/notify-example.sh); unset = silent
The comparison itself lives in keeper_core.py (pure, tested on Linux).
"""
import json, os, sys, subprocess, datetime, plistlib, shutil, time, re
import keeper_core

H = os.path.expanduser('~'); AS = H + '/Library/Application Support'
CODE = os.path.dirname(os.path.abspath(__file__))   # scan.py, rectsync.py and bin/ live next to this file
D = os.environ.get('SHORTCUT_KEEPER_HOME') or CODE   # keys.json, status.json, reports/, backups/, .state/
ARGS = set(sys.argv[1:]); FIX = '--fix' in ARGS; QUIET = '--quiet' in ARGS
NOW = datetime.datetime.now(); TODAY = NOW.strftime('%Y-%m-%d'); STAMP = NOW.strftime('%Y-%m-%d %H:%M')
WISPR_EXE = '/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow'

def run(cmd, timeout=60):
    try: return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
    except Exception as e: return subprocess.CompletedProcess(cmd, 99, '', str(e))

def jload(p, fb=None):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return fb

def jsave(p, obj, indent=2):
    tmp = p + '.tmp'
    with open(tmp, 'w') as f: json.dump(obj, f, indent=indent, ensure_ascii=False)
    os.replace(tmp, p)

def dread(dom):
    r = subprocess.run(['defaults', 'export', dom, '-'], capture_output=True)
    try: return plistlib.loads(r.stdout)
    except Exception: return {}

def pids_exact(path):
    out = run(['ps', '-axo', 'pid=,comm=']).stdout.splitlines()
    res = []
    for line in out:
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == path: res.append(int(parts[0]))
    return res

def app_installed(name):
    return any(os.path.exists(p) for p in ['/Applications/%s.app' % name, H + '/Applications/%s.app' % name,
                                            '/Applications/Utilities/%s.app' % name, '/System/Applications/%s.app' % name])

pretty = keeper_core.pretty

K = jload(D + '/keys.json')
if not K or 'keys' not in K:
    print('keeper: keys.json missing or invalid'); sys.exit(2)
K_BEFORE = json.dumps(K, sort_keys=True)
RESERVED = keeper_core.RESERVED

# ---------------------------------------------------------------- evaluation
def scan():
    replay = os.environ.get('SHORTCUT_KEEPER_SCAN_JSON')
    if replay: return jload(replay, {'rows': [], 'clashes': [], 'error': 'could not read ' + replay})
    py = '/usr/bin/python3' if os.path.exists('/usr/bin/python3') else sys.executable
    out = run([py, CODE + '/scan.py', '--json'], timeout=90).stdout
    try: return json.loads(out)
    except Exception: return {'rows': [], 'clashes': [], 'error': out[-300:]}

def evaluate(adopt=True):
    """Return (issues, changes, needs_ax). Mutates K only for adopt/add/remove when adopt=True."""
    S = scan()
    issues, changes = keeper_core.compare(K, S, TODAY, app_installed, FIXER_BY_OWNER, adopt=adopt)
    def issue(level, id_, text, fixer=None, who='agent', fix_hint=None):
        issues.append({'level': level, 'id': id_, 'text': text, 'fixer': fixer, 'who': who, 'fix': fix_hint})
    # rules read the live Mac (defaults, launchctl, app files): elsewhere they are skipped and say so
    rules = K.get('rules', []) if sys.platform == 'darwin' else []
    if K.get('rules') and not rules:
        issue('info', 'rules-skipped', '%d rules not checked: they read macOS settings' % len(K['rules']))
    for rule in rules:
        ok, detail, fixer = check_rule(rule)
        if ok is None: continue
        if not ok:
            pol = rule.get('policy')
            lvl = keeper_core.rule_issue_level(pol)   # enforce = high, report = info (report only), else medium
            who = 'agent' if fixer else 'GK'
            issue(lvl, rule['id'], '%s: %s' % (rule['text'], detail), fixer=fixer, who=who, fix_hint=rule.get('gk_fix'))
    # AX-only items (Raycast hotkeys, Gemini settings) come from the agent's weekly check
    ax = jload(D + '/ax_check.json', {}) or {}
    ax_ids = [k['id'] for k in K['keys'] if k.get('verify', {}).get('by') in ('raycast_ax', 'gemini_ax')] + \
             [r['id'] for r in K.get('rules', []) if r.get('check', {}).get('by') == 'gemini_ax']
    fresh = False
    try: fresh = (NOW - datetime.datetime.fromisoformat(ax.get('checked_at', '2000-01-01'))).days < 8
    except Exception: pass
    needs_ax = [] if fresh else ax_ids
    if fresh:
        for id_, res in (ax.get('results') or {}).items():
            if res != 'ok': issue('high', id_, 'AX check: ' + str(res), who='agent')
    return issues, changes, needs_ax

def check_rule(rule):
    c = rule.get('check', {}); by = c.get('by')
    try:
        if by == 'wispr_absent':
            s = jload(AS + '/Wispr Flow/config.json', {})['prefs']['user']['shortcuts']
            bad = [x for x in c['codes'] if x in s]
            return (not bad, 'found ' + ', '.join(bad), 'wispr')
        if by == 'defaults':
            v = dread(c['domain']).get(c['key'])
            want = os.path.expanduser(c['equals'])
            return (v == want, 'is %s' % v, 'screencapture')
        if by == 'launchd':
            r = run(['launchctl', 'list', c['label']])
            return (r.returncode == 0, 'agent not loaded', 'launchd:' + c['plist'])
        if by == 'no_new_files':
            p = os.path.expanduser(c['path'])
            if not os.path.isdir(p): return (True, '', None)
            cutoff = time.time() - c['days'] * 86400
            new = [f for f in os.listdir(p) if not f.startswith('.') and os.path.isfile(os.path.join(p, f)) and os.path.getmtime(os.path.join(p, f)) > cutoff]
            if new and c.get('sweep_to'):
                dst = os.path.expanduser(c['sweep_to']); moved = 0
                for f in new:
                    src, tgt = os.path.join(p, f), os.path.join(dst, f)
                    if os.path.exists(tgt): continue
                    shutil.copy2(src, tgt)
                    if os.path.getsize(src) == os.path.getsize(tgt): os.remove(src); moved += 1
                return (False, 'another app grabbed %d screenshot(s) since the last check; moved %d to the sweep folder' % (len(new), moved), None)
            return (not new, '%d new file(s) in %s' % (len(new), c['path']), None)
        if by == 'raycast_hyper':
            hk = dread('com.raycast.macos').get('raycast_hyperKey_state', {})
            ok = hk.get('enabled') in (1, True) and hk.get('keyCode') == 57 and hk.get('includeShiftKey') in (1, True)
            return (ok, 'Raycast Hyper key is %s' % hk, None)
        if by == 'modmap':
            out = run(['defaults', '-currentHost', 'read', '-g']).stdout
            seg = out.split('modifiermapping.%s-0' % c['device'])
            if len(seg) < 2: return (False, 'no modifier mapping for keyboard %s' % c['device'], None)
            body = seg[1][:600]
            ok = re.search(r'Dst = 30064771299;\s*HIDKeyboardModifierMappingSrc = 30064771298', body) is not None
            return (ok, 'Win/Alt swap missing', None)
        if by == 'modmap_caps':   # Raycast's Hyper key needs Caps Lock left as Caps Lock in Modifier Keys on every keyboard
            out = run(['defaults', '-currentHost', 'read', '-g']).stdout
            CAPS = '30064771129'
            bad = [d for d, s_ in re.findall(r'HIDKeyboardModifierMappingDst = (\d+);\s*HIDKeyboardModifierMappingSrc = (\d+);', out) if s_ == CAPS and d != CAPS]
            return (not bad, 'Caps Lock is remapped on %d keyboard(s) in Modifier Keys' % len(bad), None)
        if by == 'no_interceptor':   # a driver-level remapper grabs Caps Lock before Raycast sees it
            found = [p_ for p_ in c['apps'] if os.path.exists(p_)] + [n for n in c.get('procs', []) if run(['pgrep', '-x', n]).returncode == 0]
            return (not found, 'found ' + ', '.join(os.path.basename(f) for f in found), None)
        if by == 'login_item':
            r = run(['osascript', '-e', 'tell application "System Events" to get the name of every login item'])
            return (c['name'] in r.stdout, 'not in Login Items', 'login:' + c['name'] + '|' + c['path'])
        if by == 'rect_panel':
            v = dread('com.knollsoft.Hookshot').get('snapPanelActions')
            n = len(json.loads(v.decode() if isinstance(v, bytes) else v)) if v else 0
            return (n == c['count'], 'panel has %d slots' % n, None)
        if by == 'rect_panel_sync':
            v = dread('com.knollsoft.Hookshot').get('snapPanelActions')
            have = [norm_slot(x) for x in json.loads(v.decode() if isinstance(v, bytes) else v)] if v else []
            want = [norm_slot(x) for x in expected_panel()]
            return (have == want, 'snap panel has %d slots, Key Deck has %d tiles, or the order differs' % (len(have), len(want)), 'rectpanel')
        if by == 'log_errors':
            p = os.path.expanduser(c['path']); since = time.time() - c.get('hours', 26) * 3600; bad = []
            if os.path.exists(p):
                for line in open(p, errors='ignore').read().splitlines()[-3000:]:
                    if not re.search(c['pattern'], line): continue
                    try: t = datetime.datetime.fromisoformat(line.split(' ', 1)[0].replace('Z', '+00:00')).timestamp()
                    except Exception: continue
                    if t >= since: bad.append(line.split(' ', 1)[1][:140])
            return (not bad, '%d in the last day, latest: %s' % (len(bad), bad[-1] if bad else ''), None)
        if by == 'symbolic':
            d = dread('com.apple.symbolichotkeys').get('AppleSymbolicHotKeys', {}).get(c['id'], {})
            en = bool(d.get('enabled', True))
            return (en == c['enabled'], 'is %s' % ('on' if en else 'off'), None)
        if by == 'rect_layouts':   # names AND geometry, generated from the same keys.json entries as layout.py and Key Deck
            import rectsync
            bad = rectsync.diff(K)
            return (not bad, 'out of sync with Key Deck: ' + ', '.join(bad), 'rectlayouts')
        if by == 'wispr_fn_conflict':   # v91: Wispr Flow notices another app reacting to fn and logs it per app (FnConflictNotice)
            n = (jload(AS + '/Wispr Flow/config.json', {}).get('notifications') or {}).get('FnConflictNotice') or {}
            hits = ['%s at %s' % (a, time.strftime('%b %d %I:%M %p', time.localtime(max(ts) / 1000)))
                    for a, ts in sorted((n.get('shownAtByApp') or {}).items()) if ts and max(ts) > c.get('since', 0)]
            return (not hits, 'Wispr saw another app take fn: ' + ', '.join(hits), None)
        if by == 'file_contains':
            p = os.path.expanduser(c['path'])
            ok = os.path.exists(p) and c['text'] in open(p).read()
            return (ok, '%s does not mention %s' % (c['path'], c['text']), None)
        if by == 'gemini_ax':
            return (None, '', None)
    except Exception as e:
        return (False, 'check failed: %s' % e, None)
    return (None, '', None)

def expected_panel():
    """Snap panel slots generated from the Key Deck tiles in keys.json (keeper_core.expected_panel)."""
    return keeper_core.expected_panel(K)

norm_slot = keeper_core.norm_slot

# ---------------------------------------------------------------- fixers (each backs up, then re-verified by evaluate())
def backup(path):
    bd = os.path.join(D, 'backups', TODAY); os.makedirs(bd, exist_ok=True)
    if os.path.exists(path): shutil.copy2(path, os.path.join(bd, os.path.basename(path) + NOW.strftime('.%H%M%S')))

def quit_and_wait(app, exe):
    if not pids_exact(exe): return False
    run(['osascript', '-e', 'tell application "%s" to quit' % app])
    for _ in range(8):
        time.sleep(1)
        if not pids_exact(exe): return True
    for p in pids_exact(exe): run(['kill', '-TERM', str(p)])
    time.sleep(4)
    return True

def fix_wispr():
    p = AS + '/Wispr Flow/config.json'
    was = quit_and_wait('Wispr Flow', WISPR_EXE)
    backup(p); d = jload(p); s = d['prefs']['user']['shortcuts']
    for rule in K['rules']:
        if rule['check'].get('by') == 'wispr_absent':
            for c in rule['check']['codes']: s.pop(c, None)
    for c, a in K['fixers']['wispr_required'].items(): s[c] = a
    jsave(p, d)
    if was: run(['open', '-a', 'Wispr Flow'])
    return 'Wispr Flow shortcuts restored'

def fix_betterwispr():
    p = AS + '/BetterWispr/workspace.json'
    was = quit_and_wait('BetterWispr', '/Applications/BetterWispr.app/Contents/MacOS/BetterWispr')
    backup(p); d = jload(p); d.setdefault('settings', {})['shortcut'] = K['fixers']['betterwispr_shortcut']
    jsave(p, d, indent=None)
    if was: run(['open', '-a', 'BetterWispr'])
    return 'BetterWispr shortcut restored'

def fix_rectangle():
    plist = H + '/Library/Preferences/com.knollsoft.Hookshot.plist'
    was = quit_and_wait('Rectangle Pro', '/Applications/Rectangle Pro.app/Contents/MacOS/Rectangle Pro')
    backup(plist)
    for key, v in K['fixers']['rectangle'].items():
        run(['defaults', 'write', 'com.knollsoft.Hookshot', key, '-dict', 'type', '-int', str(v['type']),
             'keyCode', '-int', str(v['keyCode']), 'modifierFlags', '-int', str(v['modifierFlags'])])
    if was: run(['open', '-a', 'Rectangle Pro'])
    return 'Rectangle Pro shortcuts restored'

def fix_screencapture():
    # macOS 27 reads location-screenshot and location-screenrecording; the old 'location' key is kept for older tools
    p = os.path.expanduser('~/Pictures/Screenshots')
    for rule in K['rules']:
        c = rule['check']
        if c.get('by') == 'defaults' and c.get('domain') == 'com.apple.screencapture': p = os.path.expanduser(c['equals'])
    os.makedirs(p, exist_ok=True)
    for key in ('location', 'location-screenshot', 'location-screenrecording'):
        run(['defaults', 'write', 'com.apple.screencapture', key, p])
    run(['killall', 'screencaptureui']); run(['killall', 'SystemUIServer'])
    return 'screenshot folder restored (location-screenshot, location-screenrecording)'

def fix_rectpanel():
    plist = H + '/Library/Preferences/com.knollsoft.Hookshot.plist'
    was = quit_and_wait('Rectangle Pro', '/Applications/Rectangle Pro.app/Contents/MacOS/Rectangle Pro')
    backup(plist)
    run(['defaults', 'write', 'com.knollsoft.Hookshot', 'snapPanelActions', '-string', json.dumps(expected_panel(), separators=(',', ':'))])
    if was: run(['open', '-a', 'Rectangle Pro'])
    return 'Rectangle snap panel synced with the Key Deck tiles'

def fix_other(fixer):
    if fixer.startswith('launchd:'):
        plist = os.path.expanduser(fixer.split(':', 1)[1])
        run('launchctl bootstrap gui/%d "%s"' % (os.getuid(), plist)); return 'LaunchAgent reloaded'
    if fixer.startswith('login:'):
        name, path = fixer.split(':', 1)[1].split('|')
        run(['osascript', '-e', 'tell application "System Events" to make login item at end with properties {path:"%s", hidden:true}' % path])
        return '%s added to Login Items' % name
    return None

FIXER_BY_OWNER = {'Wispr Flow': 'wispr', 'BetterWispr': 'betterwispr', 'Rectangle Pro': 'rectangle'}
def fix_rectlayouts():
    import rectsync
    return rectsync.write(K)   # backs up Rectangle's prefs itself

FIXERS = {'wispr': fix_wispr, 'betterwispr': fix_betterwispr, 'rectangle': fix_rectangle, 'screencapture': fix_screencapture,
          'rectpanel': fix_rectpanel, 'rectlayouts': fix_rectlayouts}

def safe_to_fix():
    """Gather the live signals, then keeper_core.fix_blockers decides. No call live and 2+ minutes idle = safe."""
    hook = os.environ.get('SHORTCUT_KEEPER_CALL_HOOK')   # e.g. a script that prints your recorder's status line
    hdr = run(hook, timeout=40).stdout if hook else ''
    zoom = run(['pgrep', '-x', 'CptHost']).returncode == 0
    st = D + '/.state/director.state'   # Krisp's redesign hid its timer (2026-10-27): also trust the Director and the mic
    age = time.time() - os.path.getmtime(st) if os.path.exists(st) else None
    mic = '' if age is not None and age < keeper_core.DIRECTOR_FRESH_S else run([CODE + '/bin/micusers']).stdout
    idle = run("ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'").stdout.strip()
    why = keeper_core.fix_blockers(recorder_line=hdr, zoom_meeting=zoom, director_state_age=age, mic_users=mic,
                                   idle_seconds=int(idle) if idle.isdigit() else None)
    return (not why), why

# ---------------------------------------------------------------- rendering
def code(s): return ('`` %s ``' % s) if '`' in s else ('`%s`' % s)

def render_md(status):
    L = ['# My Keys', '', '**Caps** = hold Caps Lock (Hyper). Microsoft keyboard: **Win = ⌥**, **Alt = ⌘**.', '',
         '> %s · checked %s' % (status['summary'], status['checked_at'][:16].replace('T', ' ')), '']
    for sec in K['sections']:
        items = [k for k in K['keys'] if k['section'] == sec['id'] and k.get('sheet', True)]
        if not items: continue
        L += ['## ' + sec['title'], '', '| Keys | What it does | App |', '|:--|:--|:--|']
        for k in items:
            extra = (' · _%s_' % k['note']) if k.get('note') else ''
            new = ' **new**' if k.get('isNew') else ''
            todo = ' _(to set)_' if k.get('pending') else ''
            L.append('| %s | %s%s%s%s | %s |' % (code(k['keys']), k['action'], extra, new, todo, k['app']))
        L.append('')
    with open(D + '/keys.md', 'w') as f: f.write('\n'.join(L))

def render_report(status):
    os.makedirs(D + '/reports', exist_ok=True)
    L = ['# Shortcut check %s' % STAMP, '', '**%s**' % status['summary'], '']
    for title, items in [('Fixed', status['fixed']), ('Changes to keys.json', status['changes'])]:
        if items: L += ['## ' + title] + ['- ' + x for x in items] + ['']
    for lvl in ['high', 'medium', 'todo', 'low', 'info']:
        xs = [i for i in status['issues'] if i['level'] == lvl]
        if xs: L += ['## ' + lvl.upper()] + ['- [%s] %s%s' % (i['who'], i['text'], (' Fix: ' + i['fix']) if i.get('fix') else '') for i in xs] + ['']
    if status['needs_ax']: L += ['## Needs the weekly AX check', '- ' + ', '.join(status['needs_ax']), '']
    if status['deferred']: L += ['## Fixes deferred', '- ' + '; '.join(status['deferred']), '']
    with open(D + '/reports/%s.md' % TODAY, 'w') as f: f.write('\n'.join(L))

def todos_for_you(issues): return [i for i in issues if i['level'] == 'todo']

# ---------------------------------------------------------------- main
issues, changes, needs_ax = evaluate()
fixed, deferred = [], []
fixable = keeper_core.fixable(issues)
if FIX and fixable:
    ok, why = safe_to_fix()
    if not ok:
        deferred = why
    else:
        done = set()
        for i in fixable:
            f = i['fixer']
            if f in done: continue
            done.add(f)
            msg = FIXERS[f]() if f in FIXERS else fix_other(f)
            if msg: fixed.append(msg)
        time.sleep(3)
        before = {i['id'] for i in issues}
        issues, more, needs_ax = evaluate()
        changes += more
        still = {i['id'] for i in issues}
        fixed = [m for m in fixed] + ['verified: %s' % x for x in sorted(before - still)]
for k in K['keys']:
    if k.get('isNew'):
        try:
            if (NOW - datetime.datetime.fromisoformat(k['isNew'])).days >= 7: k.pop('isNew')
        except Exception: k.pop('isNew', None)
if json.dumps(K, sort_keys=True) != K_BEFORE:
    K['updated'] = TODAY; jsave(D + '/keys.json', K)

serious = [i for i in issues if i['level'] in ('high', 'medium')]
ok, summary, counts = keeper_core.summarize(issues)
status = {'checked_at': NOW.isoformat(timespec='seconds'), 'ok': ok, 'summary': summary,
          'counts': counts,
          'issues': issues, 'fixed': fixed, 'changes': changes, 'needs_ax': needs_ax, 'deferred': deferred,
          'keys': len(K['keys'])}
jsave(D + '/status.json', status)
render_md(status); render_report(status)
if fixed or changes:
    with open(D + '/reports/CHANGELOG.md', 'a') as f:   # shortcut history (the repo's own CHANGELOG.md is separate)
        for x in fixed + changes: f.write('- %s %s\n' % (STAMP, x))
# optional notifier hook: silent when healthy and nothing changed (the Key Deck pill already says so)
notify = os.environ.get('SHORTCUT_KEEPER_NOTIFY')
if notify and (fixed or changes or serious or deferred or todos_for_you(issues)):
    run([notify, summary, D + '/reports/%s.md' % TODAY], timeout=30)
if '--json' in ARGS: print(json.dumps(status, ensure_ascii=False, indent=1))
elif not QUIET: print(summary + (' | fixed: ' + '; '.join(fixed) if fixed else '') + (' | deferred: ' + '; '.join(deferred) if deferred else ''))
sys.exit(1 if serious else 0)
