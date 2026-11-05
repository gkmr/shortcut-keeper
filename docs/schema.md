# keys.json schema

`keys.json` is the desired state: one entry per shortcut, mouse gesture or ring slot, plus the rules and fixers that keep
them true. `examples/keys.example.json` is a 15-entry sample that uses every policy and every verify type. The real file
this repo grew from had 106 entries.

Readers: `keeper.py` and `keeper_core.py` (the check), `layout.py` and `rectsync.py` (meeting layouts), Key Deck
(`keydeck/KeyDeck.swift`, the on-screen deck) and the Raycast extension (`raycast-ext/`). Only `keeper.py` writes it, and
only when something was adopted, added or removed.

## Combo notation

A combo is the canonical form `scan.py` prints and `keys.json` stores in `combo` and `verify.combos`:

- modifiers in this order, joined by `+`: `fn`, `ctrl`, `rctrl`, `opt`, `ropt`, `shift`, `rshift`, `cmd`, `rcmd`
- then the key: `A` to `Z`, `0` to `9`, `Space`, `Return`, `Tab`, `Esc`, `Delete`, `Left`, `Right`, `Up`, `Down`, punctuation
- all four of `ctrl opt shift cmd` together become `HYPER` (Caps Lock as a Hyper key): `HYPER+W`
- a modifier alone is a combo too: `fn`, `rctrl`, `capslock`

`keeper_core.pretty()` turns a combo into what the cheat sheet shows: `HYPER+W` is `Caps W`, `shift+cmd+4` is `⇧⌘4`.

## Top level

| Field | Type | Meaning |
|:--|:--|:--|
| `version` | int | Schema version. Currently `1`. |
| `updated` | date | Set by keeper.py whenever it rewrites the file. |
| `about` | string | A note for humans. Not read by code. |
| `sections` | list of `{id, title}` | Section order for `keys.md` and the Raycast list. Every entry's `section` must be one of these ids. |
| `keys` | list of entries | The shortcuts. See below. |
| `rules` | list of rules | Checks that are not a single key (Hyper key on, Spotlight off, a LaunchAgent loaded). See below. |
| `fixers` | object | The values the automatic fixers write back. See below. |
| `acknowledged_reserved` | list of combos (lower case) | macOS-reserved keys you took on purpose (for example `cmd+space` for a launcher). Without this an app on a reserved key is a `low` issue. |
| `ignore` | list of `{owner, action, why}` | Scan rows that are never reported as new (`action` missing = every row of that owner). |
| `deck_theme` | `auto`, `light` or `dark` | Key Deck's appearance. |
| `removed` | list of entries | Entries keeper archived because their app is gone. Each keeps its fields plus `removed` (date) and an optional `why`. |

## Entries (`keys[]`)

| Field | Type | Meaning |
|:--|:--|:--|
| `id` | string, unique | Stable id. New shortcuts get `<owner>-<action>` slugs, for example `floaty-pin`. |
| `section` | string | A `sections[].id`. Keeper files new shortcuts under `other`. |
| `keys` | string | Human notation shown on the sheet: `Caps W`, `⌃⌥C`, `Gesture down`. Keeper rewrites it when it adopts a change. |
| `action` | string | What the shortcut does, in plain words. |
| `app` | string | The app that owns it. Also the name keeper looks for in `/Applications` before archiving an entry. |
| `note` | string, optional | Extra line on the sheet. |
| `combo` | combo, optional | The canonical key. Used for adopt comparisons, for clash detection on keys no config file shows, and by Key Deck and Raycast to press the key. |
| `policy` | `enforce`, `adopt` or `watch` | What drift means. `enforce`: restore it (high issue, fixed by `--fix` when a fixer exists). `adopt`: the app's new key becomes the desired state. `watch`: report only (info). |
| `verify` | object | How the key is checked. See below. |
| `also` | list of scan actions, optional | More scan actions that belong to this entry (one row for four resize keys), so they are not reported as new. |
| `pending` | string, optional | A click path for the human. While the wanted combo is missing the entry is a `todo`, not an error. |
| `sheet` | bool, default `true` | `false` keeps the entry out of `keys.md` and Key Deck's rows (it is still checked). |
| `isNew` | date, set by keeper | Marks a shortcut keeper discovered. Dropped after 7 days. |
| `app_path` | path, optional | When set and missing, the entry is archived under `removed`. |
| `deck` | object, optional | How Key Deck draws and runs it. See below. |

### `verify`

| `by` | Checked by | Other fields |
|:--|:--|:--|
| `scan` | `scan.py` rows (the outside judge) | `owner` (scan row owner, required); `action` (scan row action; missing = any row of the owner); `combos` (list; when present every combo must be there, otherwise a single row's combo is compared with `combo`) |
| `rule` | the rule named in `rule` | `rule`: a `rules[].id`. The entry is documentation; the rule carries the check. |
| `raycast_ax` | the weekly on-screen check, recorded in `ax_check.json` | none. Raycast keeps its hotkeys in an encrypted database, so only its Settings window shows them. |
| `gemini_ax` | the weekly on-screen check, recorded in `ax_check.json` | `field` (the settings label) and `value` (the expected text) |
| `none` | nothing (a default no config file stores) | none. If another running app claims this `combo`, that is still a high clash. |

Outcomes for `by: scan`:

| Situation | enforce | adopt | watch |
|:--|:--|:--|:--|
| key matches | nothing | nothing | nothing |
| key differs | high, with the owner's fixer | keys.json follows the app (a change) | info |
| owner has no rows, app installed | medium, with fixer | medium | nothing |
| owner has no rows, app not installed | archived under `removed` | archived | archived |
| `pending` set and key missing | todo for the human | todo | todo |

### `deck`

| Field | Meaning |
|:--|:--|
| `short` | Short label on Key Deck and in Raycast. |
| `url` | What a click runs: `keydeck://...` or `rectangle-pro://execute-action?name=...`. |
| `group` | `windows` or `meetings`: drawn as a tile. Every tile without `panel: false` is also a Rectangle Pro snap panel slot. |
| `order` | Tile order inside its group (and snap panel order). |
| `caption` | Tile caption instead of the keys; text after ` · ` is the tile's sub-label. |
| `caps` | Keycaps to draw instead of the combo; `"|text|"` is plain text between caps. |
| `rect` | One window rectangle `[x, y, w, h]` as fractions of the visible screen, top-left origin, for the tile picture. |
| `rects`, `labels`, `apps`, `titles`, `behind` | Meeting layouts: one rectangle, label, bundle id (`a|b` = either app; `picture:<name>` = drawn only) and window title hint per slot; `behind` lists slots that wait behind others. Title hints: `exact:<title>`, `only:<text>`, `panel:<text>`, `panel:=` (an untitled floating panel). |
| `rect_action` | Rectangle Pro window action id for the snap panel (for example `0` left half, `29` almost maximize). |
| `rect_custom` | Rectangle Pro custom layout id (the meeting layouts: 89, 904, 920, 930). |
| `panel` | `false` keeps a tile out of the snap panel. |
| `aspect` | Width / height of the tile's mini screen: `1.6` laptop, `2.39` ultrawide. |
| `badge` | SF Symbol drawn on the tile (`pin.fill` for Webcam Mode). |
| `run` | `false` = show only (a key you hold, a chord with no single action). |

## Rules (`rules[]`)

| Field | Meaning |
|:--|:--|
| `id` | Unique id. Entries point at it with `verify.rule`. |
| `text` | What must be true, in plain words. Becomes the issue text. |
| `check` | `{by, ...}`, see the table below. |
| `policy` | `enforce` = high (and fixed when the check has a fixer), `report` = info in the report only, anything else (`watch`) = medium. |
| `gk_fix` | Optional click path for the human, printed after the issue. |

| `check.by` | Passes when | Extra fields | Fixer |
|:--|:--|:--|:--|
| `wispr_absent` | none of these Wispr Flow key codes is bound | `codes` | `wispr` |
| `defaults` | `defaults read <domain> <key>` equals the value (`~` expanded) | `domain`, `key`, `equals` | `screencapture` |
| `launchd` | `launchctl list <label>` succeeds | `label`, `plist` | reload the plist |
| `login_item` | the app is a Login Item | `name`, `path` | add it |
| `raycast_hyper` | Raycast's Hyper key is Caps Lock with Shift included | none | none (human) |
| `symbolic` | a macOS symbolic hotkey is on or off as wanted | `id`, `enabled` | none |
| `modmap` | a keyboard keeps its modifier swap | `device` (`vendor-product`) | none |
| `modmap_caps` | no keyboard remaps Caps Lock in Modifier Keys | none | none |
| `no_interceptor` | no driver-level remapper is installed or running | `apps`, `procs` | none |
| `no_new_files` | a folder got no new files in N days (optionally moves them) | `path`, `days`, `sweep_to` | built in (the sweep) |
| `rect_panel` | the Rectangle snap panel has N slots | `count` | none |
| `rect_panel_sync` | the snap panel equals the Key Deck tiles, in order | none | `rectpanel` |
| `rect_layouts` | Rectangle's meeting layouts equal the `deck.rects` in keys.json | `names` | `rectlayouts` |
| `log_errors` | no line matching `pattern` in the last `hours` of a log | `path`, `hours`, `pattern` | none |
| `wispr_fn_conflict` | Wispr Flow saw no other app react to fn since a time | `since` (ms) | none |
| `file_contains` | a file mentions a text | `path`, `text` | none |
| `gemini_ax` | checked on screen weekly (see `ax_check.json`) | `expect` | none |

## Fixers (`fixers`)

| Key | Written by | Value |
|:--|:--|:--|
| `wispr_required` | `fix_wispr` | `{key codes: action}`: the bindings Wispr Flow must have (`"63"` fn, `"62"` right Control, `"49+63"` fn+Space). |
| `betterwispr_shortcut` | `fix_betterwispr` | `{key, keyCode, modifiers}` with Carbon modifier flags (`6912` = Hyper). |
| `rectangle` | `fix_rectangle` | `{Rectangle pref key: {type, keyCode, modifierFlags}}` with Cocoa modifier flags (`1966080` = Hyper). |

Every fixer quits the app if it runs, backs up the file to `backups/<date>/`, writes, reopens the app, and then keeper
re-reads the real config to confirm. A fix counts only when the scan says so.

## Side files

| File | Written by | Shape |
|:--|:--|:--|
| `keydeck.json` | you (Key Deck's own hotkeys) | `{about, hotkeys: [{combo, action}]}`. scan.py reads it as Key Deck's config. Example: `examples/keydeck.example.json`. |
| `manual.json` | you | `[{key, owner, action, app?, kind?}]`: keys no readable file shows (Raycast, Gemini, Claude, macOS). Never reported as new. Example: `examples/manual.example.json`. |
| `ax_check.json` | the weekly on-screen check | `{checked_at, results: {id: "ok" or "drift: <what was seen>"}}`. Older than 8 days = the AX items are listed under `needs_ax`. |
| `status.json` | keeper.py | `{checked_at, ok, summary, counts, issues, fixed, changes, needs_ax, deferred, keys}`. Each issue is `{level, id, text, fixer, who, fix}`; `level` is `high`, `medium`, `todo`, `low` or `info`; `who` is `agent` (a fixer or the scheduled agent can act) or the literal value `GK`, which means the user (the human owner). Key Deck's status pill and Raycast read it. |
| `scan.py --json` | scan.py | `{rows: [{combo, owner, action, source, running, kind}], clashes: [{combo, owners}]}`. `kind` is `listener` (the app reacts to the key) or `sender` (a mouse gesture that sends it; never a clash). Examples: `examples/fixtures/scan-*.json`. |
