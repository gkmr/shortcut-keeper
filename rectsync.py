#!/usr/bin/env python3
"""rectsync.py: Rectangle Pro's four meeting app layouts, generated from keys.json.
One source of truth: the layout entries' deck.apps / deck.rects / deck.titles drive layout.py (what the Director and the
Key Deck X C V B keys run), the Key Deck and Raycast pictures, and this copy in Rectangle Pro's menu.
  python3 rectsync.py           report: "in sync" or the layouts that differ (exit 1)
  python3 rectsync.py --write   back up Rectangle's prefs, rewrite the four layouts in place, restart Rectangle Pro
                                (refuses during a Zoom meeting or while Krisp is recording)
Rectangle moves an app's main window only, so it gets one rect per app (Krisp's main window, not its call widget); a slot
whose title hint starts with "panel:" (a floating panel; none since BetterWispr's October 2026 update moved its notes into
its main window, which Rectangle now places) is left out, and so is a "picture:" slot (the call box drawn in the Video
call tile; Webcam Mode places the real call window). Phone and FaceTime share the call slot.
keeper.py uses diff() for rule rect-layouts and write() as fixer "rectlayouts"."""
import datetime, json, os, subprocess, sys, time
from fractions import Fraction

D = os.environ.get('SHORTCUT_KEEPER_HOME') or os.path.dirname(os.path.abspath(__file__))
EXE = '/Applications/Rectangle Pro.app/Contents/MacOS/Rectangle Pro'
NAMES = {89: 'Video call', 904: 'Phone call', 920: 'Desk video call', 930: 'Desk phone call'}
BASE = {89: 940, 904: 910, 920: 950, 930: 960}   # child ids are BASE + 1, 2, ...


def run(c, **kw): return subprocess.run(c, shell=isinstance(c, str), capture_output=True, text=True, **kw)


def frac(v):
    f = Fraction(v).limit_denominator(2056)
    return str(f.numerator) if f.denominator == 1 else '%d/%d' % (f.numerator, f.denominator)


def val(s):
    a, _, b = str(s).partition('/')
    return float(a) / (float(b) if b else 1.0)


def expected(K):
    """{group id: [children]} with Rectangle's own geometry: fractions of the screen, y measured from the BOTTOM."""
    out = {}
    for k in K['keys']:
        d = k.get('deck') or {}
        gid = d.get('rect_custom')
        if gid not in NAMES or not d.get('apps'): continue
        titles = d.get('titles') or [''] * len(d['apps'])
        kids, seen = [], set()
        for apps, t, r in zip(d['apps'], titles, d['rects']):
            if (t or '').startswith('panel:') or apps.startswith('picture:') or apps in seen: continue   # one rect per app in Rectangle
            seen.add(apps)
            x, top, w, h = r
            for b in apps.split('|'):
                kids.append({'bundleId': b, 'x': frac(x), 'y': frac(max(0.0, round(1 - top - h, 4))), 'w': frac(w), 'h': frac(h)})
        out[gid] = kids
    return out


def norm(kids):
    return sorted((c['bundleId'], round(val(c['x']), 3), round(val(c['y']), 3), round(val(c['w']), 3), round(val(c['h']), 3)) for c in kids)


def read_specs():
    r = run(['defaults', 'read', 'com.knollsoft.Hookshot', 'appSpecs'])
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else []


def diff(K):
    """Names of the Rectangle layouts that do not match keys.json (empty list = in sync)."""
    have = {g.get('id'): g for g in read_specs()}
    bad = []
    for gid, kids in expected(K).items():
        g = have.get(gid)
        if not g or g.get('name') != NAMES[gid] or norm(g.get('children', [])) != norm(kids): bad.append(NAMES[gid])
    return bad


def call_live():
    """A call is live when the Meeting Director is handling one (.state/director.state, under 4 h old) or Krisp is taking
    the mic (bin/micusers). Krisp's 2026-10 redesign hid the recording timer a status script read, so that script
    alone said "no recording" during calls (seen 2026-10-27)."""
    st = D + '/.state/director.state'
    if os.path.exists(st) and time.time() - os.path.getmtime(st) < 4 * 3600: return 'the Meeting Director is handling a call'
    if 'ai.krisp.krispMac' in run([D + '/bin/micusers']).stdout: return 'Krisp is using the mic'
    return ''


def busy():
    if run(['pgrep', '-x', 'CptHost']).returncode == 0: return 'a Zoom meeting is open'
    live = call_live()
    if live: return live
    hook = os.environ.get('SHORTCUT_KEEPER_CALL_HOOK')   # optional: a command that prints your recorder's status line
    hdr = run(hook, timeout=40).stdout if hook else ''
    if 'recording' in hdr and 'no recording' not in hdr: return 'the call hook says a call is being recorded'
    return ''


def write(K):
    why = busy()
    if why: return 'Rectangle layouts not synced: %s' % why
    want = expected(K)
    specs = read_specs()
    bk = '%s/backups/%s' % (D, datetime.date.today().isoformat()); os.makedirs(bk, exist_ok=True)
    run(['defaults', 'export', 'com.knollsoft.Hookshot', '%s/com.knollsoft.Hookshot.plist.%s' % (bk, time.strftime('%H%M%S'))])
    def group(gid):
        kids = [dict(c, display=-3, id=BASE[gid] + 1 + i, loc=9) for i, c in enumerate(want[gid])]
        return {'loc': 0, 'isGroup': True, 'id': gid, 'name': NAMES[gid], 'children': kids}
    seen = set(); new = []
    for g in specs:   # replace in place so Rectangle's menu keeps its order
        if g.get('id') in want: new.append(group(g['id'])); seen.add(g['id'])
        else: new.append(g)
    new += [group(gid) for gid in want if gid not in seen]
    ids = [c['id'] for g in new for c in g.get('children', [])] + [g['id'] for g in new]
    if len(ids) != len(set(ids)): return 'Rectangle layouts not synced: duplicate ids'
    was = EXE in run(['ps', '-axo', 'comm=']).stdout
    if was:
        run(['osascript', '-e', 'tell application "Rectangle Pro" to quit'])
        for _ in range(14):
            time.sleep(0.5)
            if EXE not in run(['ps', '-axo', 'comm=']).stdout: break
    run(['defaults', 'write', 'com.knollsoft.Hookshot', 'appSpecs', '-string', json.dumps(new, separators=(',', ':'))])
    if was: run(['open', '-g', '-a', 'Rectangle Pro'])
    return 'Rectangle meeting layouts synced with Key Deck (%s)' % ', '.join(NAMES[g] for g in want)


if __name__ == '__main__':
    K = json.load(open(D + '/keys.json'))
    if '--write' in sys.argv:
        print(write(K))
    bad = diff(K)
    print('in sync' if not bad else 'out of sync: ' + ', '.join(bad))
    sys.exit(1 if bad else 0)
