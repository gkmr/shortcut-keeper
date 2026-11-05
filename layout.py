#!/usr/bin/env python3
"""layout.py <entry id> [--quiet] [--settle SECONDS] [--check] [--only LABEL[,LABEL]]
  layout-transcripts       Video call       layout-call       Phone call
  layout-transcripts-desk  Desk video call  layout-call-desk  Desk phone call
Places the meeting apps (keys.json deck.apps / deck.rects / deck.titles / deck.labels, fractions of the visible screen,
top-left origin). Picks each app's window by title hint, then the app's main window, then the largest standard window
("exact:<name>" = only a standard window titled exactly that, such as Krisp's main window "Krisp" next to its "Krisp Widget";
"only:<name>" = only a standard window whose title contains it, such as Wispr's Meeting Recorder; "panel:<name>" = only a
floating panel with that name, such as BetterWispr's notes panel "Notetaker", open only while its notetaker runs); skips apps that are
closed (never opens them); keeps windows on screen when an app enforces a minimum size; stacks them in list order (later on
top), so BetterWispr's main window (listed before Krisp) waits behind Krisp (Key Deck's Caps 4 swaps them).
One more slot is computed, not stored: "BetterWispr pill", BetterWispr's recording pill, kept on BetterWispr's own notes
panel, just above its timer and Stop controls (v17; see pill_slot).
--only       place just the slots with these labels (director.sh stop: "--only Krisp" puts Krisp back after a call, when
             Krisp widens its own window to the full screen width).
--undock     place only windows sitting docked on the right edge at (nearly) full height, where Wispr's Meeting Recorder
             and BetterWispr's notes panel open themselves, and the small widgets (Krisp's, Granola's nub) when they drift;
             silent when there is none; after placing a recorder window it raises the meeting windows in order.
--pill-home  BetterWispr's pill back to the bottom center, where BetterWispr keeps it (director.sh stop, after a call).
--keep-order (v107) put windows back in their slots without raising them (director.sh's minute pass: Krisp and Wispr
             stay in the order the user picked)
--raise      bring the meeting windows forward in order (Wispr after Krisp when .state/front-pick says wispr), moving nothing (after Webcam Mode activates the browser). director.sh watch-call runs it every
             minute of a recording, so a panel the user opens late lands in its slot, and a window the user moved stays put.
--settle N   keep watching for N seconds (checks at 2, 5, 9, 14, 20, 30, 45, 60, 90, 120 s). Up to 30 s it pulls back any window
             that drifts or grows (Krisp and Wispr grow once recording starts: that broke a call on 2026-10-21);
             after 30 s it only places windows that appear late (BetterWispr's side panel, Wispr's Meeting Recorder).
--check      read only: report how far each window is from the plan.
Pass = every open app's window within 24 pt of the plan (or larger only because the app has a minimum size, and on screen).
Root causes fixed 2026-10-21: (1) moving before resizing let macOS drop the resize near the screen edge, so the engine now
resizes, moves, waits and repeats (0.15 s each since v93, was 0.3: a 9-window pass in about 3 s); (2) a window larger than planned was taken as the app's minimum and never retried.
Used by director.sh, Key Deck (keydeck://layout?id=...) and the Raycast keys list. Log: .state/layout.log"""
import datetime, json, os, subprocess, sys, time

D = os.environ.get('SHORTCUT_KEEPER_HOME') or os.path.dirname(os.path.abspath(__file__))
TOL = 24
PILL_HINT = 'panel:='   # a floating panel with no title: BetterWispr's recording pill
SCREENS_JS = ('ObjC.import("AppKit"); var a=[]; var s=$.NSScreen.screens; for (var i=0;i<s.count;i++){var x=s.objectAtIndex(i);'
              'var f=x.frame, v=x.visibleFrame; a.push({name: ObjC.unwrap(x.localizedName), f:[f.origin.x,f.origin.y,f.size.width,f.size.height],'
              'v:[v.origin.x,v.origin.y,v.size.width,v.size.height]});} JSON.stringify(a)')
SCRIPT = r'''
on pick(bl, hint)
	-- returns {process, window index}, or "closed" / "nowindow". An index, not the window: System Events names a window by
	-- its title, and BetterWispr has two windows called "Notetaker" (2026-10-21: the side panel move hit the dashboard).
	-- "panel:<name>" = only a floating panel (not a standard window) whose title contains <name> (BetterWispr's side panel);
	-- no such panel = skip the app and leave its main window alone.
	set panelOnly to false
	set nameOnly to false
	set exactName to false
	set untitledOnly to false
	if hint starts with "exact:" then
		-- "exact:<name>" = only a standard window titled exactly <name>: Krisp's main window "Krisp", not "Krisp Widget",
		-- the 260 x 200 call widget that is Krisp's main window during calls since its October 2026 redesign
		set exactName to true
		set hint to text 7 thru -1 of hint
	else if hint starts with "panel:" then
		set panelOnly to true
		set hint to text 7 thru -1 of hint
		-- "panel:=" = only a floating panel with no title (BetterWispr's recording pill)
		if hint is "=" then
			set untitledOnly to true
			set hint to ""
		end if
	else if hint starts with "only:" then
		-- "only:<name>" = only a standard window whose title contains <name> (Wispr's Meeting Recorder); none = skip, so
		-- the app's main window never lands in the slot (Wispr's 1140 x 750 hub overflowed it on 2026-10-22)
		set nameOnly to true
		set hint to text 6 thru -1 of hint
	end if
	set AppleScript's text item delimiters to "|"
	set bundles to text items of bl
	set AppleScript's text item delimiters to ""
	tell application "System Events"
		repeat with b in bundles
			set ps to (every process whose bundle identifier is (b as text))
			if (count of ps) > 0 then
				set p to item 1 of ps
				set bestI to 0
				set bestScore to -1
				repeat with i from 1 to (count of windows of p)
					try
						set sr to subrole of window i of p
						set nm to name of window i of p
						if nm is missing value then set nm to ""
						set useIt to false
						if panelOnly then
							-- (AppleScript: x contains "" is false, so an untitled panel is matched by its empty name)
							if sr is not "AXStandardWindow" and ((untitledOnly and nm is "") or ((not untitledOnly) and nm contains hint)) then set useIt to true
						else
							if sr is "AXStandardWindow" and ((not nameOnly) or nm contains hint) and ((not exactName) or nm is hint) then set useIt to true
						end if
						if useIt then
							set s to size of window i of p
							set sc to (item 1 of s) * (item 2 of s)
							try
								if (value of attribute "AXMain" of window i of p) is true then set sc to sc + 50000000
							end try
							if hint is not "" and nm contains hint then set sc to sc + 100000000
							if sc > bestScore then
								set bestScore to sc
								set bestI to i
							end if
						end if
					end try
				end repeat
				if bestI is 0 then return "nowindow"
				return {p, bestI}
			end if
		end repeat
	end tell
	return "closed"
end pick

on run argv
	set mode to item 1 of argv
	set out to ""
	set n to ((count of argv) - 1) div 8
	repeat with i from 0 to n - 1
		set k to i * 8 + 1
		set bl to item (k + 1) of argv
		set hint to item (k + 2) of argv
		set ax1 to (item (k + 3) of argv) as integer
		set ay1 to (item (k + 4) of argv) as integer
		set aw1 to (item (k + 5) of argv) as integer
		set ah1 to (item (k + 6) of argv) as integer
		set rx to (item (k + 7) of argv) as integer
		set bm to (item (k + 8) of argv) as integer
		set pk to pick(bl, hint)
		if class of pk is text then
			set out to out & pk & linefeed
		else
			set p to item 1 of pk
			set wi to item 2 of pk
			tell application "System Events"
				tell window wi of p
					if mode is "raise" then
						try
							perform action "AXRaise"
						end try
					end if
					if mode is "move" or mode is "place" then
						try
							set value of attribute "AXMinimized" to false
						end try
						-- size first, then position, twice: moving first can push the window past the screen edge, and macOS then
						-- drops the resize (root cause of Krisp and Wispr staying giant, 2026-10-21)
						set size to {aw1, ah1}
						set position to {ax1, ay1}
						delay 0.15
						set size to {aw1, ah1}
						set position to {ax1, ay1}
						delay 0.15
						set s to size
						set q to position
						set nx to item 1 of q
						set ny to item 2 of q
						if ((nx + (item 1 of s)) > rx) and ((ax1 + aw1) is not greater than rx) then set nx to rx - (item 1 of s)
						if (ny + (item 2 of s)) > bm then set ny to bm - (item 2 of s)
						if nx is not (item 1 of q) or ny is not (item 2 of q) then set position to {nx, ny}
						if mode is "move" then
							try
								perform action "AXRaise"
							end try
						end if
					end if
					set q to position
					set s to size
					set nm to name
					if nm is missing value then set nm to ""
					set out to out & nm & "|" & (item 1 of q) & "|" & (item 2 of q) & "|" & (item 1 of s) & "|" & (item 2 of s) & linefeed
				end tell
			end tell
		end if
	end repeat
	return out
end run
'''

def run(c, **kw): return subprocess.run(c, capture_output=True, text=True, **kw)

def screens(): return json.loads(run(['osascript', '-l', 'JavaScript', '-e', SCREENS_JS]).stdout)

def screen(desk, ss):
    primary_h = ss[0]['f'][3]
    pick = max(ss, key=lambda s: s['f'][2] / s['f'][3]) if desk else next((s for s in ss if 'built' in s['name'].lower()), ss[0])
    vx, vy, vw, vh = pick['v']
    return pick['name'], vx, primary_h - vy - vh, vw, vh     # AX coordinates: left, top, width, height

def call(mode, slots):
    argv = [mode]
    for s in slots: argv += [s['apps'], s['hint'], str(s['x']), str(s['y']), str(s['w']), str(s['h']), str(s['rx']), str(s['bm'])]
    open('/tmp/keydeck-layout.applescript', 'w').write(SCRIPT)
    r = run(['osascript', '/tmp/keydeck-layout.applescript'] + argv, timeout=60)
    lines = r.stdout.rstrip('\n').split('\n') if r.stdout.strip() else []
    res = []
    for s, l in zip(slots, lines):
        p = l.split('|')
        res.append({'state': p[0]} if len(p) < 5 else {'state': 'ok', 'title': p[0], 'x': float(p[1]), 'y': float(p[2]), 'w': float(p[3]), 'h': float(p[4])})
    return res, (r.stderr.strip()[:200] if r.returncode else '')

def judge(s, f):
    if f['state'] != 'ok':
        h = s['hint']
        why = 'not open' if f['state'] == 'closed' else ('not showing' if h == PILL_HINT else
              'has no %s panel (not recording)' % h[6:] if h.startswith('panel:') else
              ('has no %s window' % h[5:] if h.startswith('only:') else ('has no "%s" window' % h[6:] if h.startswith('exact:') else 'has no window')))
        return 'skip', '%s %s' % (s['name'], why)
    dx, dy, dw, dh = f['x'] - s['x'], f['y'] - s['y'], f['w'] - s['w'], f['h'] - s['h']
    on_screen = f['x'] >= s['sx'] - 2 and f['y'] >= s['sy'] - 2 and f['x'] + f['w'] <= s['rx'] + 2 and f['y'] + f['h'] <= s['bm'] + 2
    if max(abs(dx), abs(dy), abs(dw), abs(dh)) <= TOL: return 'ok', '%s OK' % s['name']
    if abs(dx) <= TOL and abs(dy) <= TOL and dw <= TOL and dh <= TOL and (dw < -TOL or dh < -TOL):   # v102: smaller either way, in place: an app's own
        return 'fixed', '%s %dx%d (its own compact size, in place)' % (s['name'], f['w'], f['h'])   # fixed-size widget (Krisp's call bar)
    if on_screen and dw >= -TOL and dh >= -TOL and (dw > TOL or dh > TOL) and abs(dx) <= TOL + max(dw, 0) and abs(dy) <= TOL + max(dh, 0):
        return 'min', '%s %dx%d (app minimum, planned %dx%d)' % (s['name'], f['w'], f['h'], s['w'], s['h'])
    return 'off', '%s OFF: %dx%d at %d,%d, planned %dx%d at %d,%d' % (s['name'], f['w'], f['h'], f['x'], f['y'], s['w'], s['h'], s['x'], s['y'])

def pill_slot(d, labels, sx, sy, sw, sh):
    """BetterWispr's recording pill: an untitled floating window, 440 x 240 and transparent except for the pill drawn at its
    bottom center (about 100 x 40). BetterWispr puts it at the bottom center of the screen, on Krisp's ask box (seen
    2026-10-27). Its slot is computed here, not stored in keys.json (so Rectangle and Key Deck never see it): centered under the
    call box with the pill's bottom 4 pt above the bottom row, in the free strip below the call. Only the window's transparent
    part reaches into the call box, and clicks pass through transparent parts."""
    # v15/v17 (2026-10-28): no free strip under the call box any more, so the pill goes on BetterWispr's own notes panel,
    # centered, just above the panel's own controls (timer and Stop, its bottom 70 pt), so it covers nothing of another
    # app and works whether the panel sits in the top row (v17) or the bottom row; its transparent part passes clicks through
    # v109 (no always-on-top window over Granola; the small widgets placed on the right edge, out of the way): the
    # pill at the bottom of the right edge, centred in the strip where Wispr's recorder peeks out from behind Krisp. The window
    # may run past the screen's right edge (BetterWispr leaves it there), so the AppleScript does not pull it back on screen.
    try:
        if 'Krisp' in labels and 'BetterWispr notes' not in labels:
            r = d['rects'][labels.index('Krisp')]
            cx = ((sx + (r[0] + r[2]) * sw) + (sx + sw)) / 2
            return {'apps': 'org.betterwispr.app', 'hint': PILL_HINT, 'name': 'BetterWispr pill',
                    'x': round(cx - 220), 'y': round(sy + sh - 262), 'w': 440, 'h': 240,
                    'sx': round(sx), 'sy': round(sy), 'rx': round(sx + sw), 'bm': round(sy + sh)}
    except ValueError:
        pass
    try:
        if 'BetterWispr notes' in labels:
            r = d['rects'][labels.index('BetterWispr notes')]
            # v99: the corner panel (layout v19) is 380 wide at the right edge: keep the 440-wide pill window on screen
            return {'apps': 'org.betterwispr.app', 'hint': PILL_HINT, 'name': 'BetterWispr pill',
                    'x': min(round(sx + (r[0] + r[2] / 2) * sw - 220), round(sx + sw - 440)), 'y': round(sy + (r[1] + r[3]) * sh - 70 - 240), 'w': 440, 'h': 240,
                    'sx': round(sx), 'sy': round(sy), 'rx': round(sx + sw), 'bm': round(sy + sh)}
        ci = next(i for i, b in enumerate(d['apps']) if b.startswith('picture:') or 'mobilephone' in b)
        top = d['rects'][labels.index('Krisp')][1]
    except (StopIteration, ValueError):
        return None
    r = d['rects'][ci]
    return {'apps': 'org.betterwispr.app', 'hint': PILL_HINT, 'name': 'BetterWispr pill',
            'x': round(sx + (r[0] + r[2] / 2) * sw - 220), 'y': round(sy + top * sh - 240), 'w': 440, 'h': 240,
            'sx': round(sx), 'sy': round(sy), 'rx': round(sx + sw), 'bm': round(sy + sh)}

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args: sys.exit(__doc__)
    settle, only = 0, None
    if '--settle' in sys.argv:
        try: settle = float(sys.argv[sys.argv.index('--settle') + 1]); args = [a for a in args if a != sys.argv[sys.argv.index('--settle') + 1]]
        except Exception: settle = 20
    if '--only' in sys.argv and sys.argv.index('--only') + 1 < len(sys.argv):
        ov = sys.argv[sys.argv.index('--only') + 1]
        only = {x.strip() for x in ov.split(',') if x.strip()}
        args = [a for a in args if a != ov]
    lid, note, ss = args[0], '', screens()
    if 'desk' in lid and not any(x['f'][2] / x['f'][3] > 2 for x in ss):
        lid, note = lid.replace('-desk', ''), ' (no ultrawide connected: used the laptop layout)'
    K = json.load(open(D + '/keys.json'))
    k = next((x for x in K['keys'] if x['id'] == lid), None)
    if not k or not (k.get('deck') or {}).get('apps'): sys.exit('layout.py: %s has no deck.apps in keys.json' % lid)
    d = k['deck']; name, sx, sy, sw, sh = screen('desk' in lid, ss)
    titles = d.get('titles') or [''] * len(d['apps'])
    labels = d.get('labels') or [a.split('.')[-1] for a in d['apps']]
    slots = [{'apps': b, 'hint': t or '', 'name': lab, 'x': round(sx + r[0] * sw), 'y': round(sy + r[1] * sh), 'w': round(r[2] * sw),
              'h': round(r[3] * sh), 'sx': round(sx), 'sy': round(sy), 'rx': round(sx + sw), 'bm': round(sy + sh)}
             for b, r, t, lab in zip(d['apps'], d['rects'], titles, labels)
             if not b.startswith('picture:')]   # picture-only slot (the call box in the Video call tile): Webcam Mode places it
    pill = pill_slot(d, labels, sx, sy, sw, sh)
    if pill: slots.append(pill)
    all_slots = slots
    if '--pill-home' in sys.argv:
        # after a call: BetterWispr's pill back to its own spot, the bottom center of the screen where BetterWispr keeps it
        home = dict(pill or {}, x=round(sx + sw / 2 - 220), y=round(sy + sh - 252))
        if not pill: sys.exit(0)
        res, err = call('read', [home])
        if res and res[0]['state'] == 'ok' and judge(home, res[0])[0] != 'ok':
            res, err = call('move', [home])
            with open(D + '/.state/layout.log', 'a') as f:
                f.write('%s %s on %s: BetterWispr pill back home %s\n' % (datetime.datetime.now().strftime('%F %T'), d.get('short', lid), name,
                                                                         judge(home, res[0])[1] if res else err))
        sys.exit(0)
    if only:
        slots = [s for s in slots if s['name'] in only]
        if not slots: sys.exit('layout.py: no slot labelled %s in %s' % (', '.join(sorted(only)), lid))
        note += ' (only %s)' % ', '.join(s['name'] for s in slots)
    err = ''
    if '--raise' in sys.argv:
        # bring the meeting windows forward in list order, moving nothing: after Webcam Mode activates the browser, all its
        # windows come to the front over the layout (2026-10-27: thirteen Comet windows covered Claude and Granola)
        behind = {i for i in d.get('behind', [])}
        up = [s for i, s in enumerate(slots) if i not in behind]
        try:   # v107: Wispr picked last (Key Deck's .state/front-pick) stays over Krisp
            if open(D + '/.state/front-pick').read().strip() == 'wispr':
                up = [s for s in up if s.get('name') != 'Wispr'] + [s for s in up if s.get('name') == 'Wispr']
        except OSError: pass
        res, err = call('raise', up)
        with open(D + '/.state/layout.log', 'a') as f:
            f.write('%s %s on %s: raised the meeting windows%s\n' % (datetime.datetime.now().strftime('%F %T'), d.get('short', lid), name, ('; error: ' + err) if err else ''))
        sys.exit(1 if err else 0)
    if '--undock' in sys.argv:
        res, err = call('read', slots)
        # Krisp's widget and Granola's nub (kept on the right edge) and BetterWispr's pill (under the call): re-placed whenever they drift
        small = lambda s: s['w'] < 300 or s['hint'] == PILL_HINT
        pick = [s for s, f in zip(slots, res) if f['state'] == 'ok' and judge(s, f)[0] != 'ok' and (
                (f['x'] + f['w'] >= s['rx'] - 20 and f['h'] >= 0.85 * (s['bm'] - s['sy'])) or small(s))]
        if not pick: sys.exit(0)
        call('move', pick); time.sleep(0.6)
        res, err = call('move', pick)
        if any(not small(s) for s in pick):   # a recorder window just opened: the meeting windows back on top, in order
            behind = {i for i in d.get('behind', [])}
            call('raise', [s for i, s in enumerate(all_slots) if i not in behind])
        line = '%s %s on %s: undocked %s%s' % (datetime.datetime.now().strftime('%F %T'), d.get('short', lid), name,
                                              '; '.join(judge(s, f)[1] for s, f in zip(pick, res)), ('; error: ' + err) if err else '')
        with open(D + '/.state/layout.log', 'a') as f: f.write(line + '\n')
        if '--quiet' not in sys.argv: print(line)
        sys.exit(1 if err else 0)
    if '--check' in sys.argv:
        res, err = call('read', slots)
    else:
        MOVE = 'place' if '--keep-order' in sys.argv else 'move'   # v107: --keep-order puts windows back without raising them
        res, err = call(MOVE, slots)
        time.sleep(0.6)
        res, err = call(MOVE, slots)                         # second pass: apps that resize a moment later
        t0, pulled = time.time(), 0
        present = {i for i, f in enumerate(res) if f['state'] == 'ok'}
        for cp in [c for c in (2, 5, 9, 14, 20, 30, 45, 60, 90, 120) if c <= settle]:
            time.sleep(max(0, cp - (time.time() - t0)))
            res, err = call('read', slots)
            # first 30 s: pull back anything that drifted or grew (retry 'min' too: often it is not a minimum). After that only
            # place windows that appeared late (BetterWispr's panel opens when the user starts its notetaker, Wispr's Meeting Recorder
            # when it starts recording), so a window the user moves on purpose mid-call stays where it was put.
            idx = [i for i, (s, f) in enumerate(zip(slots, res)) if judge(s, f)[0] in ('off', 'min') and (cp <= 30 or i not in present)]
            present = {i for i, f in enumerate(res) if f['state'] == 'ok'}   # a window that closes and reopens counts as new again
            if idx:
                pulled += 1
                call(MOVE, [slots[i] for i in idx])
        if settle: res, err = call('read', slots)
    verdicts = [judge(s, f) for s, f in zip(slots, res)]
    bad = [v for v in verdicts if v[0] == 'off']
    line = '%s %s%s on %s: %s%s%s' % (datetime.datetime.now().strftime('%F %T'), d.get('short', lid), note, name,
                                      '; '.join(v[1] for v in verdicts), ('; settle %ds' % settle) if settle else '',
                                      ('; error: ' + err) if err else '')
    with open(D + '/.state/layout.log', 'a') as f: f.write(line + '\n')
    if '--quiet' not in sys.argv: print(line)
    sys.exit(1 if bad or err else 0)

if __name__ == '__main__':
    main()
