#!/usr/bin/env python3
# Shortcut Keeper scanner: reads the ACTUAL shortcuts from each app's own config files. It is the outside judge.
# Plain run prints a table and flags keys claimed twice. --json prints machine output for keeper.py.
# Reads keydeck.json and manual.json from SHORTCUT_KEEPER_HOME (default: this file's folder).
import json, os, plistlib, subprocess, sys, sqlite3
from keeper_core import cocoa, carbon, combo, by_combo, find_clashes   # pure decoders and clash rule (tested on Linux)

H = os.path.expanduser('~'); AS = H + '/Library/Application Support'
HERE = os.environ.get('SHORTCUT_KEEPER_HOME') or os.path.dirname(os.path.abspath(__file__))
KC = {0:'A',1:'S',2:'D',3:'F',4:'H',5:'G',6:'Z',7:'X',8:'C',9:'V',11:'B',12:'Q',13:'W',14:'E',15:'R',16:'Y',17:'T',
      18:'1',19:'2',20:'3',21:'4',22:'6',23:'5',24:'=',25:'9',26:'7',27:'-',28:'8',29:'0',30:']',31:'O',32:'U',33:'[',
      34:'I',35:'P',36:'Return',37:'L',38:'J',39:"'",40:'K',41:';',43:',',44:'/',45:'N',46:'M',47:'.',48:'Tab',
      49:'Space',50:'`',51:'Delete',53:'Esc',123:'Left',124:'Right',125:'Down',126:'Up'}
MODK = {59:'ctrl',62:'rctrl',58:'opt',61:'ropt',55:'cmd',54:'rcmd',56:'shift',60:'rshift',63:'fn',57:'capslock'}
HID = {**{4+i: chr(65+i) for i in range(26)}, **{30+i: str((i+1) % 10) for i in range(10)},
       40:'Return',41:'Esc',42:'Delete',43:'Tab',44:'Space',45:'-',46:'=',47:'[',48:']',51:';',52:"'",53:'`',54:',',55:'.',56:'/'}
HIDMOD = {224:'ctrl',225:'shift',226:'opt',227:'cmd',228:'rctrl',229:'rshift',230:'ropt',231:'rcmd'}

PS = subprocess.run(['ps', '-axo', 'comm'], capture_output=True, text=True).stdout
def is_running(app): return ('/' + app + '.app/') in PS

rows = []
def add(key, owner, action, src, app=None, kind='listener'):
    rows.append({'combo': key, 'owner': owner, 'action': action, 'source': src,
                 'running': is_running(app or owner), 'kind': kind})

def dread(dom):
    r = subprocess.run(['defaults', 'export', dom, '-'], capture_output=True)
    try: return plistlib.loads(r.stdout)
    except Exception: return {}

# Wispr Flow
try:
    s = json.load(open(AS + '/Wispr Flow/config.json'))['prefs']['user']['shortcuts']
    for k, a in s.items():
        codes = [int(x) for x in k.split('+')]
        mods = [MODK[c] for c in codes if c in MODK]; keys = [KC.get(c, str(c)) for c in codes if c not in MODK]
        add(combo(mods, '+'.join(keys)) or '?', 'Wispr Flow', a, 'config.json')
except Exception as e: add('?', 'Wispr Flow', 'read error ' + str(e), '')

# BetterWispr
try:
    w = json.load(open(AS + '/BetterWispr/workspace.json'))
    sc = w.get('settings', {}).get('shortcut') or w.get('shortcut')
    if sc and sc.get('keyCode') is not None:
        add(combo(carbon(sc.get('modifiers', 0)), KC.get(sc['keyCode'], str(sc['keyCode']))), 'BetterWispr', 'dictate', 'workspace.json')
except Exception as e: add('?', 'BetterWispr', 'read error ' + str(e), '')

# KeyboardShortcuts-lib apps (Floaty, ChatGPT Classic)
for dom, owner, app in [('com.floatytool.floaty', 'Floaty', 'Floaty'), ('com.openai.chat', 'ChatGPT Classic', 'ChatGPT Classic')]:
    d = dread(dom)
    for k, v in d.items():
        if k.startswith('KeyboardShortcuts_') and isinstance(v, str) and v.startswith('{'):
            j = json.loads(v)
            add(combo(carbon(j['carbonModifiers']), KC.get(j['carbonKeyCode'], str(j['carbonKeyCode']))), owner, k[18:], dom, app)

# Rectangle Pro (only shortcuts stored in prefs; untouched defaults are not stored)
d = dread('com.knollsoft.Hookshot')
for k, v in d.items():
    if isinstance(v, dict) and 'keyCode' in v and 'modifierFlags' in v:
        add(combo(cocoa(int(v['modifierFlags'])), KC.get(int(v['keyCode']), str(v['keyCode']))), 'Rectangle Pro', k, 'defaults')
try:
    j = json.loads(d.get('contextMenuShortcut', '{}'))
    if j: add(combo(cocoa(j['modifierFlags']), KC.get(j['keyCode'], '?')), 'Rectangle Pro', 'contextMenu', 'defaults')
except Exception: pass

# TickTick
d = dread('com.TickTick.task.mac')
for k in ['TKQuickAddTaskHotkeyIdentifier', 'TKShowOrHideAppHotkeyIdentifier', 'TTShowOrHideMainWindowHotkeyIdentifier', 'TTStartOrAbandonPomoHotkeyIdentifier']:
    v = d.get(k)
    if isinstance(v, bytes) and v:
        try:
            p = plistlib.loads(v); o = p['$objects']; root = o[p['$top']['root'].data]
            kc = o[root['KeyCode'].data] if hasattr(root['KeyCode'], 'data') else root['KeyCode']
            mf = o[root['ModifierFlags'].data] if hasattr(root['ModifierFlags'], 'data') else root['ModifierFlags']
            if mf: add(combo(cocoa(int(mf)), KC.get(int(kc), str(kc))), 'TickTick', k.replace('HotkeyIdentifier', ''), 'defaults')
        except Exception: pass

# Key Deck (the deck overlay and Webcam Mode helper)
try:
    kd = json.load(open(HERE + '/keydeck.json'))
    for h in kd.get('hotkeys', []):
        add(h['combo'], 'Key Deck', h['action'], 'keydeck.json', 'Key Deck')
except Exception as e: add('?', 'Key Deck', 'read error ' + str(e), '', 'Key Deck')

# Raycast Hyper key state (Raycast hotkeys themselves live in an encrypted DB: see manual.json)
d = dread('com.raycast.macos'); hk = d.get('raycast_hyperKey_state', {})
if hk.get('enabled'):
    add('capslock', 'Raycast', 'hyperKey shift=%s' % ('on' if hk.get('includeShiftKey') else 'off'), 'defaults')

# Logi Options+ mouse gestures (these SEND keys, so they never count as clashes)
try:
    con = sqlite3.connect('file:' + AS + '/LogiOptionsPlus/settings.db?mode=ro', uri=True)
    blob = con.execute('select file from data').fetchone()[0]; con.close()
    cfg = json.loads(blob)
    def walk(o, path):
        if isinstance(o, dict):
            for k, v in o.items(): yield from walk(v, path + [k])
            if 'keystroke' in o and isinstance(o['keystroke'], dict) and 'nestedCards' in path:
                yield path, o['keystroke']
        elif isinstance(o, list):
            for i, v in enumerate(o): yield from walk(v, path + [str(i)])
    for path, ks in walk(cfg, []):
        if 'custom_gesture' in path:
            direction = path[path.index('custom_gesture') + 2] if len(path) > path.index('custom_gesture') + 2 else '?'
            mods = [HIDMOD.get(m, str(m)) for m in ks.get('modifiers', [])]
            add(combo(mods, HID.get(ks.get('code'), str(ks.get('code')))), 'Logi Options+', 'gesture ' + direction, 'settings.db', 'logioptionsplus_agent', 'sender')
except Exception as e: add('?', 'Logi Options+', 'read error ' + str(e), '', 'Logi Options+', 'sender')

# Manual entries (apps whose shortcuts are not in readable files)
try:
    for m in json.load(open(HERE + '/manual.json')):
        app = m.get('app')
        r = {'combo': m['key'], 'owner': m['owner'], 'action': m['action'], 'source': 'manual.json',
             'running': True if not app else is_running(app), 'kind': m.get('kind', 'listener')}
        rows.append(r)
except Exception as e: add('?', 'manual.json', 'read error ' + str(e), '')

# Clash detection: two different running listener apps on the same key (keeper_core.find_clashes)
by = by_combo(rows)
clashes = find_clashes(rows)

if '--json' in sys.argv:
    print(json.dumps({'rows': rows, 'clashes': clashes}, ensure_ascii=False))
else:
    print('%-28s %s' % ('KEY', 'OWNER: ACTION'))
    cl = {c['combo'] for c in clashes}
    for k, rs in sorted(by.items()):
        print('%-28s %s%s' % (k, ' | '.join('%s%s: %s' % (r['owner'], '' if r['running'] else ' (not running)', r['action']) for r in rs),
                              '  <== CLASH' if k in cl else ''))
    print('\nDUPLICATE KEYS (running apps): %d' % len(clashes))
