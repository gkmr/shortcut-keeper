#!/usr/bin/env python3
"""Checks the four meeting layouts in keys.json against the user's layout rules, with no windows touched.
  tests/layout-test.py [keys.json]     prints PASS/FAIL per check, exit 1 on any failure
Rules (2026-10-27, v19 and v20 2026-10-30, v21 2026-11-03: nothing floats over Granola, BetterWispr's notes wait behind it): no two visible windows overlap; every window at least its app's measured minimum and on screen; Claude's message box (bottom 140 pt of
Claude's slot) covered by nothing; the windows the user reads in front (Granola, BetterWispr's notes panel and, since v13 on
2026-10-28, Wispr's Meeting Recorder) covered by nothing
stacked after them; a 3 x 2 grid whose rows line up across the screen (top: Wispr, call, Granola; bottom: Claude, Krisp,
BetterWispr's panel; Wispr over Claude, Krisp under the call, BetterWispr's panel under Granola);
the call box under the camera, filling the top middle with no gaps (v15); a window marked "behind" really is hidden behind later windows; Rectangle gets one
rect per app. Minimums measured 2026-10-27 by resizing each window to 200 x 200 and reading it back (Wispr's Meeting Recorder
again 2026-10-28: 600 pt tall at the least)."""
import json, os, sys

MIN = {'Claude': (600, 400), 'Granola': (500, 400), 'Krisp': (520, 600), 'BetterWispr': (760, 572), 'Wispr': (500, 600),
       'Krisp widget': (260, 200), 'Granola nub': (42, 70)}
SMALL = ('Krisp widget', 'Granola nub')   # small floating widgets that belong on the right edge
ASK = {'Granola': 80, 'Wispr': 80}   # ask box / recording bar at the bottom of each front window
SCREEN = {False: (2056, 1243), True: (3840, 1524)}
LLM = ('Granola',)   # v21: no always-on-top panel over Granola; read in front: nothing but small edge widgets may sit on them (v18: Wispr peeks behind Krisp by design)
ROOT = os.environ.get('SHORTCUT_KEEPER_HOME') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'keys.json')
K = json.load(open(path))
fail = 0


def check(ok, what):
    global fail
    print(('PASS ' if ok else 'FAIL ') + what)
    if not ok: fail = 1


def px(r, sw, sh): return (r[0] * sw, r[1] * sh, (r[0] + r[2]) * sw, (r[1] + r[3]) * sh)


def overlap(a, b, tol=2):
    return min(a[2], b[2]) - max(a[0], b[0]) > tol and min(a[3], b[3]) - max(a[1], b[1]) > tol


def covered(a, others):   # sample a grid of points in a: every point lies in one of the others
    for i in range(1, 20):
        for j in range(1, 20):
            x, y = a[0] + (a[2] - a[0]) * i / 20, a[1] + (a[3] - a[1]) * j / 20
            if not any(o[0] <= x <= o[2] and o[1] <= y <= o[3] for o in others): return False
    return True


for lid in ('layout-transcripts', 'layout-call', 'layout-transcripts-desk', 'layout-call-desk'):
    k = next((x for x in K['keys'] if x['id'] == lid), None)
    if not k: check(False, '%s exists' % lid); continue
    d = k['deck']; desk = 'desk' in lid; sw, sh = SCREEN[desk]
    apps, rects, titles, labels = d['apps'], d['rects'], d.get('titles', []), d.get('labels', [])
    behind = set(d.get('behind', []))
    check(len(apps) == len(rects) == len(titles) == len(labels), '%s: apps, rects, titles, labels line up (%d)' % (lid, len(apps)))
    P = [px(r, sw, sh) for r in rects]
    for lab, p in zip(labels, P):
        check(p[0] >= -1 and p[1] >= -1 and (p[2] <= sw + 1 or (lab == 'Krisp widget' and p[0] < sw - 60)) and p[3] <= sh + 1, '%s: %s on screen%s' % (lid, lab, ' (peeking in from the right edge)' if p[2] > sw + 1 else ''))
        if lab in MIN:
            w, h = p[2] - p[0], p[3] - p[1]
            check(w >= MIN[lab][0] - 1 and h >= MIN[lab][1] - 1, '%s: %s %dx%d >= its minimum %dx%d' % (lid, lab, w, h, *MIN[lab]))
    ci = labels.index('Claude')
    box = (P[ci][0], P[ci][3] - 140, P[ci][2], P[ci][3])
    hits = [labels[i] for i, p in enumerate(P) if i != ci and overlap(p, box)]
    check(not hits, '%s: nothing covers Claude\'s message box%s' % (lid, (' (' + ', '.join(hits) + ')') if hits else ''))
    for lab in LLM:
        i = labels.index(lab)
        over = [labels[j] for j in range(i + 1, len(P)) if overlap(P[i], P[j]) and labels[j] not in SMALL]
        check(not over, '%s: %s (read in front) has nothing stacked over it%s' % (lid, lab, (' (' + ', '.join(over) + ')') if over else ''))
    vis = [i for i in range(len(P)) if i not in behind and labels[i] not in SMALL]
    pairs = ['%s/%s' % (labels[a], labels[b]) for x, a in enumerate(vis) for b in vis[x + 1:] if overlap(P[a], P[b]) and {labels[a], labels[b]} != {'Wispr', 'Krisp'}]
    check(not pairs, '%s: no two visible windows overlap (Krisp over Wispr = the peek)%s' % (lid, (' (' + ', '.join(pairs) + ')') if pairs else ''))
    for lab in SMALL:
        if lab in labels:
            p = P[labels.index(lab)]
            # the right 100 pt of an ask box is its empty rounded end (Granola's has no button there, 2026-10-30 screenshot)
            hit = [c for c in ASK if overlap(p, (P[labels.index(c)][0], P[labels.index(c)][3] - ASK[c], P[labels.index(c)][2] - 100, P[labels.index(c)][3]))]
            check(not hit, '%s: %s clear of the ask boxes (their right end aside)%s' % (lid, lab, (' (' + ', '.join(hit) + ')') if hit else ''))
    # v19 (2026-10-30: the call window centred, Claude directly under it, BetterWispr small in the bottom right, the nub and
    # widget stacked on the right edge): thirds on both screens. Left third yours; centre third the call on top (centred on the camera) with Claude
    # right under it at the same x and width; right third Granola on top, Krisp below with Wispr peeking behind it, BetterWispr's
    # always-on-top panel at its smallest in the bottom-right corner (it may sit over Krisp's and Wispr's corner, by design).
    g, kr, cl = (P[labels.index(x)] for x in ('Granola', 'Krisp', 'Claude'))
    wi = labels.index('Wispr'); w_ = P[wi]
    call = next(i for i, a in enumerate(apps) if a.startswith('picture:') or 'mobilephone' in a)
    cb = P[call]
    cam = sw / 2   # laptop: the camera at x 1028 = the middle of 2056; the desk camera sits centred on the LG
    check(wi not in behind and wi < labels.index('Krisp'), "%s: Wispr's Meeting Recorder is listed before Krisp (Krisp on top, Wispr peeks)" % lid)
    check(abs((cb[0] + cb[2]) / 2 - cam) < 2 and abs(cb[1]) < 2, '%s: the call box at the top, centred on the camera (centre x %d)' % (lid, (cb[0] + cb[2]) / 2))
    check(abs(cl[0] - cb[0]) < 2 and abs(cl[2] - cb[2]) < 2 and abs(cl[1] - cb[3]) < 2 and abs(cl[3] - sh) < 2,
          '%s: Claude right under the call, same x and width (%dx%d)' % (lid, cl[2] - cl[0], cl[3] - cl[1]))
    free = (0, 0, cb[0], sh)
    inside = [labels[i] for i, p in enumerate(P) if labels[i] not in SMALL and overlap(p, free)]
    check(not inside and abs(free[2] - sw / 3) < 2, '%s: the left third stays yours (%dx%d)%s' % (lid, free[2], free[3], (' (' + ', '.join(inside) + ')') if inside else ''))
    check(abs(g[0] - cb[2]) < 2 and abs(g[2] - sw) < 2 and abs(g[1]) < 2 and abs(g[3] - cb[3]) < 2, '%s: Granola fills the top of the right third' % lid)
    check(abs(kr[0] - cl[2]) < 2 and abs(kr[1] - cl[1]) < 2 and abs(kr[3] - sh) < 2, '%s: Krisp at the bottom of the right third, next to Claude' % lid)
    check(abs(w_[2] - sw) < 2 and abs(w_[3] - sh) < 2 and abs(w_[1] - kr[1]) < 2 and kr[0] <= w_[0] < kr[2], '%s: Wispr flush right behind Krisp' % lid)
    peek = sw - kr[2]
    check(peek >= 100, '%s: Wispr peeks %d pt to the right of Krisp' % (lid, peek))
    # v21 (2026-11-03: no always-on-top window over Granola; the two pills and Krisp's and Granola's widgets on the right
    # edge, out of the way): BetterWispr's notes go to its main window, which waits
    # behind Granola; down the right edge, below Granola: Wispr's status band (40x52 tab at the middle of the right edge, up to
    # 440x420 with its live-transcript bubble), Granola's nub, Krisp's widget, BetterWispr's pill (its 440x240 window is clear
    # except the pill at its bottom centre, centred in the strip where Wispr peeks out from behind Krisp).
    band = (sw - 440, sh / 2 - 210, sw, sh / 2 + 210)
    nb, kw = P[labels.index('Granola nub')], P[labels.index('Krisp widget')]
    cx = (kr[2] + sw) / 2
    pw = (cx - 220, sh - 262, cx + 220, sh - 22)          # BetterWispr's pill window (layout.py pill_slot, Key Deck Guard.bwPill)
    pill = (cx - 50, pw[3] - 40, cx + 50, pw[3])          # the visible pill, about 100 x 40 at the window's bottom centre
    check('BetterWispr notes' not in labels, "%s: no slot for BetterWispr's floating panel (v21: its notes wait behind Granola)" % lid)
    edge = {'Granola nub': nb, 'Krisp widget': kw, 'BetterWispr pill': pill}
    hit = [l for l, r in edge.items() if overlap(r, band)]
    check(not hit, "%s: Wispr's status band (y %d..%d) kept clear%s" % (lid, band[1], band[3], (' (' + ', '.join(hit) + ')') if hit else ''))
    ks = list(edge)
    pairs2 = ['%s/%s' % (a, b) for x, a in enumerate(ks) for b in ks[x + 1:] if overlap(edge[a], edge[b])]
    check(not pairs2, '%s: nub, widget and pill never overlap%s' % (lid, (' (' + ', '.join(pairs2) + ')') if pairs2 else ''))
    check(nb[1] >= band[3] - 1 and kw[1] >= nb[3] - 1 and pill[1] >= kw[3] - 1,
          '%s: top to bottom on the right edge: Wispr band, Granola nub, Krisp widget, BetterWispr pill' % lid)
    check(abs(nb[2] - sw) < 2 and abs(kw[2] - sw) < 2, '%s: nub and widget flush with the right edge, widget fully on screen' % lid)
    check(pill[0] >= kr[2] - 1 and pill[2] <= sw + 1 and pill[3] <= sh + 1,
          "%s: BetterWispr's pill in the right strip, clear of Krisp (x %d..%d)" % (lid, pill[0], pill[2]))
    over_g = [l for l, r in edge.items() if overlap(r, g)] + (['pill window'] if overlap(pw, g) else [])
    check(not over_g, '%s: nothing floats over Granola%s' % (lid, (' (' + ', '.join(over_g) + ')') if over_g else ''))
    row = [g[3], cb[3], cl[1], kr[1], w_[1]]
    check(max(row) - min(row) < 2, '%s: the two rows meet in one line (y %d)' % (lid, row[0]))
    for b in behind:
        later = [P[j] for j in range(b + 1, len(P)) if j not in behind]
        check(covered(P[b], later), '%s: %s waits fully behind later windows' % (lid, labels[b]))
    check(bool(behind) == ('BetterWispr' in labels), '%s: BetterWispr\'s main window marked behind' % lid)
    check(labels.index('BetterWispr') < labels.index('Granola') and labels.index('BetterWispr') in behind,
          "%s: BetterWispr's main window (where its notes go) waits behind Granola" % lid)
    seen = []
    for a, t in zip(apps, titles):
        if not a.startswith('picture:') and not (t or '').startswith('panel:') and a not in seen: seen.append(a)
    check(len(seen) == len(set(a for a in apps if not a.startswith('picture:'))), '%s: Rectangle gets one rect per app (%d)' % (lid, len(seen)))
ids = [k['id'] for k in K['keys']]
swap = next((k for k in K['keys'] if k['id'] == 'transcript-swap'), None)
check(bool(swap) and swap.get('combo') == 'HYPER+4' and swap['deck'].get('url') == 'keydeck://swap', 'Caps 4 swap key in keys.json')
check(bool(swap) and (swap.get('verify') or {}).get('action') == 'transcript-swap', 'Caps 4 key verified by the scan (keeper will not file it twice)')
check('key-deck-transcript-swap' not in ids, 'no duplicate Caps 4 row under Other apps')
combos = [k.get('combo') for k in K['keys'] if k.get('combo')]
check(combos.count('HYPER+4') == 1, 'HYPER+4 used once in keys.json')
print('ALL PASS' if not fail else 'SOME FAILED')
sys.exit(fail)
