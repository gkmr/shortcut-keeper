#!/bin/bash
# v103: "after" skips when the next call is already live (back-to-back calls)
D="$(cd "$(dirname "$0")/../.." && pwd)"
[ "${2:-}" = after ] && [ -f "$D/.state/director.state" ] && { echo "== ${1:-check} (after) $(date '+%F %T'): next call already live, after-call check skipped" >> "$D/.state/e2e-live.txt"; exit 0; }
# Checks a REAL test meeting (Zoom, Meet, Teams, Webex ...) after Claude or the user started it and started the recorders
# (Krisp, Granola, Wispr's Meeting Recorder, BetterWispr's notetaker). Read only: it moves nothing. Layout v14 (2026-10-28).
#   tests/macos/e2e-live-check.sh <label> during   the Director handled the call: call window pinned under the camera, every app in
#                                             its slot, no visible overlaps, the ask boxes reachable
#   tests/macos/e2e-live-check.sh <label> after    the call ended: nothing pinned, Krisp back in its slot
# Results go to .state/e2e-live.txt (one block per run) with a screenshot in .state/e2e-live/<label>-<phase>.jpg.
OUT="$D/.state/e2e-live.txt"; SH="$D/.state/e2e-live"; mkdir -p "$SH"
label="${1:-call}"; phase="${2:-during}"; fail=0
say() { echo "$*" | tee -a "$OUT"; }
ok() { say "  PASS $*"; }; bad() { say "  FAIL $*"; fail=1; }
say "== $label ($phase) $(date '+%F %T')"
W="$("$D/bin/wins" --all)"
pins="$(echo "$W" | awk -F'\t' '$4=="Floaty" && $2=="L3"')"   # pins only, not Floaty's open menu
lid=layout-transcripts
# Wispr's notetaker (v13: the Director starts it with each meeting): recording / idle / none, from its Meeting Recorder window
wf="$(mktemp -t wst)"; osascript -l JavaScript "$D/bin/wisprnote.js" state > "$wf" 2>/dev/null & wp=$!; wi=0
while kill -0 "$wp" 2>/dev/null && [ "$wi" -lt 20 ]; do sleep 1; wi=$((wi + 1)); done
kill -0 "$wp" 2>/dev/null && { kill "$wp" 2>/dev/null; echo timeout > "$wf"; }
wst="$(cat "$wf")"; rm -f "$wf"
# a busy Accessibility queue (a long Krisp read) times the window read out: then Wispr's helper on the mic means recording
[ "$wst" = timeout ] && { "$D/bin/micusers" 2>/dev/null | grep -q 'com.electron.wispr-flow' && wst=recording || wst=idle; }
if [ "$phase" = during ]; then
  if [ -f "$D/.state/director.state" ]; then
    IFS='|' read -r KIND APP WHAT T0 TITLE < "$D/.state/director.state"
    [ "$KIND" != none ] && ok "Director found the call: $KIND, $WHAT, \"$TITLE\"" || bad "Director running but found no call window"
    case "$APP" in com.apple.mobilephone|com.apple.FaceTime) lid=layout-call ;; esac
  else bad "Director did not start (Krisp not recording, or watch.sh missed it)"; fi
  [ "$(/bin/bash "$D/director.sh" test | grep -o 'place=[a-z]*')" = "place=desk" ] && lid="$lid-desk"
  n="$(echo "$pins" | grep -c .)"
  # the call box is 685x414; a browser window with a tab group or an infobar has a taller minimum height, which is fine
  # v15: the call box is 656,39 880x621 (from Claude's edge to Granola's, down to the bottom row); a few points shorter is fine
  if [ "$n" = 1 ] && echo "$pins" | grep -qE "	(685,39 686x(6[01][0-9]|62[01])|1280,30 1280x(7[5-6][0-9]))	"; then ok "one pin, under the camera: $(echo "$pins" | cut -f5,6)"
  else bad "pins: ${pins:-none}"; fi
  # by frame: Floaty keeps the window title from when it pinned (the next call in the same window still shows the first one)
  cf="$(echo "$W" | awk -F'\t' -v t="$TITLE" '$4!="Floaty" && $2=="L0" && index($5, t) {print $6; exit}')"
  [ -n "$TITLE" ] && { [ -n "$cf" ] && echo "$pins" | awk -F'\t' -v f="$cf" '$6==f' | grep -q . && ok "the pin is on the call window ($cf)" || bad "the pin is not on \"$TITLE\" (${cf:-window not found})"; }
  "$D/bin/micusers" 2>/dev/null | grep -q org.betterwispr.app && ok "BetterWispr is taking notes" || say "  NOTE BetterWispr is not taking notes"
  [ "$wst" = recording ] && ok "Wispr is taking notes" || say "  NOTE Wispr is not taking notes (${wst:-Wispr not running})"
  chk="$(/usr/bin/python3 "$D/layout.py" "$lid" --check 2>&1 | cut -d' ' -f3-)"
  echo "$chk" | grep -q OFF && bad "layout: $chk" || ok "layout: $chk"
  # each point must reach the app that owns that spot (laptop coordinates)
  if [ "${lid%-desk}" = "$lid" ]; then
    # 1028,1245 = Krisp's ask box, where BetterWispr's recording pill used to sit. v14 (2026-10-28): Claude full
    # height on the left; Granola top right; bottom row Krisp | BetterWispr's notes panel | Wispr (bottom right)
    # v16 (2026-10-28): Claude bottom left, the top left free for the user's own windows (not checked)
    # v17 (2026-10-28): Claude bottom left half; Krisp then Wispr to its right; BetterWispr top row, right of the call
    for spec in "1000,1240:Claude" "1000,900:Claude" "1700,400:Granola" "1500,1000:krisp" "1500,1245:krisp" "1860,1000:BetterWispr" "1920,700:Wispr Flow"; do
      p="${spec%%:*}"; want="${spec#*:}"; got="$("$D/bin/wins" --at "$p" | cut -f2)"
      [ "$got" = "$want" ] && ok "click at $p reaches $want" || say "  NOTE click at $p reaches $got, expected $want (that app may be closed)"
    done
  fi
else
  [ -z "$pins" ] && ok "nothing pinned after the call" || bad "still pinned: $pins"
  kf="$(echo "$W" | awk -F'\t' '$4=="krisp" && $5=="Krisp" {print $6}' | tail -1)"
  case "$kf" in 1371,660\ 5[1-3][0-9]x6[12][0-9]) ok "Krisp back in its slot ($kf)" ;; *) say "  NOTE Krisp at ${kf:-closed} (it is put back 3 min after the recording stops)" ;; esac
  bwp="$(echo "$W" | awk -F'\t' '$4=="BetterWispr" && $5=="Notetaker" && $2=="L3"')"
  [ -z "$bwp" ] && ok "BetterWispr's notes panel closed" || say "  NOTE BetterWispr's notes panel still open (closed 3 min after the recording stops, unless it still records)"
  [ "$wst" = recording ] && say "  NOTE Wispr's notetaker still running (the Director stops only one it started)" || ok "Wispr's notetaker stopped"
fi
# a synthetic key combo that leaves ⌃⌥⇧⌘ "held" makes every later synthetic click a modified click (Oct 27: hid every app)
mods="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); $.CGEventSourceFlagsState(1) & 0x1E0000' 2>/dev/null)"
[ "${mods:-0}" = 0 ] && ok "no modifier keys stuck down" || bad "modifier keys stuck down (flags $mods)"
# E2E_NO_SHOT=1: no screenshot (the Director runs the after check by itself after every call)
[ -z "${E2E_NO_SHOT:-}" ] && screencapture -x -t jpg "$SH/$label-$phase.jpg" 2>/dev/null && sips -Z 1600 "$SH/$label-$phase.jpg" >/dev/null 2>&1
[ $fail = 0 ] && say "  RESULT PASS" || say "  RESULT FAIL"
exit $fail
