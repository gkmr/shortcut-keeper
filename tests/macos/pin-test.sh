#!/bin/bash
# On-screen test of Webcam Mode's pin and unpin (Key Deck + Floaty) with a throwaway TextEdit window. It moves and pins that
# window, so never run it in a scheduled run or during a call. Checks the cases from 2026-10-27:
#   A  pin, then webcam off: unpinned and back where it was
#   B  pin, the window closes (a call ends), then webcam off: nothing else gets pinned (the old code pinned Slack)
#   C  pin, the user unpins it by hand (Floaty's menu), then webcam off: it stays unpinned (a toggle would pin it again)
#   D  pin, Key Deck restarts (a rebuild mid-call), then webcam off: still unpinned and put back
#   E  no modifier keys left held down after all that (the stray ⌘⌥ click that once hid every app)
# Key Deck pins and unpins through Floaty's menu bar menu (no keyboard focus needed); the log line says which way it went.
D="$(cd "$(dirname "$0")/../.." && pwd)"; fail=0
[ -n "$("$D/bin/micusers")" ] && { echo "a call is live (mic in use): not testing"; exit 1; }
# a locked screen hides every window from Accessibility (2026-10-27: the run failed that way)
locked() { ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; }
locked && { echo "screen is locked (windows are not readable): not testing"; exit 1; }
pins() { "$D/bin/wins" --all | awk -F'\t' '$4=="Floaty" && $2=="L3"' | grep -c .; }   # pins only, not Floaty's open menu
new() { /usr/bin/osascript -e 'tell application "TextEdit" to make new document with properties {text:"Key Deck pin test (closes by itself)"}' >/dev/null; sleep 1; }
frame() { "$D/bin/wins" --all | awk -F'\t' '$4=="TextEdit" && $5=="Untitled" {print $6; exit}'; }
on() { open -g "keydeck://webcam?bundle=com.apple.TextEdit&title=Untitled&strict=1"; sleep 4; }
off() { open -g "keydeck://webcam-off"; sleep 4; }
closew() { /usr/bin/osascript -e 'tell application "TextEdit" to close (every window whose name is "Untitled") saving no' >/dev/null; sleep 1; }
ok() { [ "$2" = "$3" ] && echo "PASS $1" || { echo "FAIL $1: expected $3, saw $2"; fail=1; }; }
vis() { /usr/bin/osascript -e "tell application \"System Events\" to set visible of process \"TextEdit\" to $1" >/dev/null 2>&1; }
was="$(/usr/bin/osascript -e 'tell application "System Events" to get visible of process "TextEdit"' 2>/dev/null || echo false)"
vis true; trap 'vis "$was"' EXIT   # Floaty lists only windows on screen; TextEdit goes back to hidden if it was
p0="$(pins)"
new; f0="$(frame)"; on; ok "A pinned" "$(pins)" $((p0 + 1)); off; ok "A unpinned by webcam off" "$(pins)" "$p0"
ok "A back where it was" "$(frame)" "$f0"; closew
new; on; ok "B pinned" "$(pins)" $((p0 + 1)); closew; off; ok "B nothing pinned after the window closed" "$(pins)" "$p0"
new; on; ok "C pinned" "$(pins)" $((p0 + 1))
/usr/bin/osascript "$D/tests/macos/floaty-menu.applescript" "$(printf 'TextEdit \342\200\224 Untitled')" >/dev/null; sleep 1
ok "C the user's own unpin took" "$(pins)" "$p0"
off; ok "C stays unpinned after webcam off" "$(pins)" "$p0"; closew
new; f0="$(frame)"; on; ok "D pinned" "$(pins)" $((p0 + 1))
launchctl kickstart -k "gui/$(id -u)/com.example.keydeck"; sleep 5
off; ok "D unpinned after a Key Deck restart" "$(pins)" "$p0"; ok "D back where it was" "$(frame)" "$f0"; closew
mods="$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); $.CGEventSourceFlagsState(1) & 0x1E0000')"
ok "E no modifier keys held down" "$mods" 0
grep -E "webcam (on|off)|webcam:" "$D/.state/keydeck.log" | tail -8 | sed 's/^/  log: /'
locked && { echo "the screen locked during the run: results not valid, run again"; exit 1; }
[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
