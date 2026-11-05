#!/bin/bash
# End-to-end check of the Meeting Director on the real screen, no real call needed (about 3 minutes).
#   tests/macos/e2e-calls.sh     results in .state/e2e.txt; ends on the user's layout (Phone call)
# Opens test pages in their own Comet window, runs director.sh start and stop like Krisp does, and reads the windows back:
#   Meet page -> pinned under the camera (685,39 685x414 on the laptop) then put back; Teams, Webex and Zoom web pages -> same;
#   idle Google Voice page (no call audio) -> NOT pinned; nothing but a plain browser window -> NOT pinned;
#   Key Deck strict pin with a title that matches nothing -> NOT pinned; Phone window via Key Deck -> pinned and put back.
# Never runs during a call (Zoom meeting or Krisp recording) and never closes a window it did not open.
D="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$D/.state/e2e.txt"; KL="$D/.state/keydeck.log"; P="$D/tests/macos/pages"
export DIRECTOR_SETTLE=9 DIRECTOR_QUIET=1 DIRECTOR_NO_BW=1   # notetakers only on the first (Meet) page, see nt_case
say() { echo "$*" | tee -a "$OUT"; }
ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes' && { echo "screen is locked (windows are not readable): not testing" > "$OUT"; exit 1; }
pgrep -x CptHost >/dev/null && { echo "in a Zoom meeting: not testing" > "$OUT"; exit 1; }
[ -f "$D/.state/director.state" ] && { echo "director is handling a call: not testing" > "$OUT"; exit 1; }
PAUSE="$D/.state/watch-paused.$$"; touch "$PAUSE"; trap 'rm -f "$PAUSE"' EXIT   # v94/v102: the Krisp watcher stands down while this test runs (its own file)
real_call() { "$D/bin/micusers" 2>/dev/null | grep -qiE 'comet|chrome|safari|thebrowser|zoom|whatsapp|teams|webex|slack|facetime|avconferenced|callservicesd'; }
abort_if_call() { if real_call; then echo "  STOPPED: a real call took the mic at $(date '+%T'); the test leaves it to the watcher" | tee -a "$OUT"; rm -f "$PAUSE"; exit 3; fi; }   # v102
real_call && { echo "a call app is on the mic (a real call): not testing" > "$OUT"; exit 1; }
: > "$OUT"; say "Meeting Director end-to-end test $(date '+%F %T')"
fr() { /usr/bin/osascript -e "tell application \"System Events\" to tell process \"$1\" to get (position of (first window whose name contains \"$2\")) & (size of (first window whose name contains \"$2\"))" 2>/dev/null | tr -d ' '; }
close_test() { /usr/bin/osascript -e "tell application \"System Events\" to tell process \"Comet\" to click (first button of (first window whose name contains \"$1\") whose subrole is \"AXCloseButton\")" >/dev/null 2>&1; }
open_page() { /usr/bin/open -na "Comet" --args --new-window "file://$P/$1.html"; sleep 4; }
kl() { wc -l < "$KL" | tr -d ' '; }
pinned_since() { tail -n +"$(( $1 + 1 ))" "$KL" | grep -E "webcam on|nothing pinned|webcam:" | tail -1; }
FAIL=0; ok() { say "  PASS $*"; }; bad() { say "  FAIL $*"; FAIL=1; }
CAM="685,39,686,621"   # v19 call box (laptop, centred on the camera); the desk box is picked below
[ "$("$D/director.sh" test 2>/dev/null | sed -nE 's/.*place=([a-z]+).*/\1/p')" = desk ] && CAM="1280,30,1280,762"   # the 38" ultrawide: 3840 x 1600, visible 3840 x 1524 at y 30
near() { python3 -c "import sys;a=[float(x) for x in sys.argv[1].split(',')];b=[float(x) for x in sys.argv[2].split(',')];sys.exit(0 if len(a)==4 and max(abs(x-y) for x,y in zip(a,b))<=24 else 1)" "$1" "$2"; }
call_case() {   # page, title fragment, expect pin (1/0)
  local page="$1" frag="$2" want="$3"
  abort_if_call; say "$page page:"; open_page "$page"
  local f0; f0="$(fr Comet "$frag")"; [ -n "$f0" ] || { bad "test window did not open"; return; }
  say "  $(/bin/bash "$D/director.sh" test)"
  local n; n="$(kl)"; rm -f "$D/.state/director.state"
  /bin/bash "$D/director.sh" start
  local f1 l j; for j in 1 2 3 4 5 6 7 8; do sleep 1; f1="$(fr Comet "$frag")"; l="$(pinned_since "$n")"; near "$f1" "$CAM" && break; done
  real_call && { /bin/bash "$D/director.sh" stop; close_test "$frag"; abort_if_call; }
  if [ "$want" = 1 ]; then
    { echo "$l" | grep -q "webcam on" && near "$f1" "$CAM"; } && ok "pinned under the camera at $f1" || bad "expected pinned under the camera, window at $f1, log: $l"
  else
    { ! echo "$l" | grep -q "webcam on"; } && ok "not pinned (window stays at $f1)" || bad "pinned but should not be: $l"
  fi
  sleep 12   # layout watch (settle 9) finishes
  say "  layout: $(tail -1 "$D/.state/layout.log" | cut -d' ' -f3- | cut -c1-220)"
  /bin/bash "$D/director.sh" stop; sleep 3
  local f2 i; for i in 1 2 3 4 5 6 7 8 9; do f2="$(fr Comet "$frag")"; near "$f2" "$f0" && break; sleep 1; done
  if [ "$want" = 1 ]; then near "$f2" "$f0" && ok "put back at $f2" || bad "not put back: $f2, was $f0"; fi
  close_test "$frag"; sleep 1
}
# v94: the Meet page with the notetakers on: the Director starts BetterWispr and Wispr, their windows must land in
# their slots, and the stop ends both. v21 (2026-11-03): no BetterWispr panel floating over Granola: its notes go to its main
# window, which waits behind Granola; its pill sits at the bottom of the right edge; a panel BetterWispr reopens goes back too.
bwopen() { "$D/bin/axpress" org.betterwispr.app Notetaker "Open beside your call" standard >/dev/null 2>&1; }   # v109c: native (System Events took 90 s)
above() { "$D/bin/wins" --all | awk -F'\t' -v a="$1" -v t="$2" -v b="$3" -v u="$4" '$4==a && $5==t && $2=="L0" && !x {x=NR} $4==b && $5==u && $2=="L0" && !y {y=NR} END {exit !(x && y && x < y)}'; }
win() { "$D/bin/wins" --all | awk -F'\t' -v a="$1" -v t="$2" -v l="$3" '$4==a && $5==t && (l=="" || $2==l) {print $6; exit}' | tr ' x' ',,'; }
nt_case() {
  local frag="abc-defg-hij" MAIN="1296,39,760,621" PILL="1753,1020,440,240" REC="1456,660,600,622"
  [ "$PLACE" = desk ] && MAIN="2560,30,1280,762" && PILL="3530,1292,440,240" && REC="2840,792,1000,762"
  abort_if_call; say "meet page with the notetakers (BetterWispr and Wispr started and stopped by the Director):"; open_page meet
  local f0; f0="$(fr Comet "$frag")"; [ -n "$f0" ] || { bad "test window did not open"; return; }
  local n; n="$(kl)"; local dn; dn="$(wc -l < "$D/.state/director.log" | tr -d ' ')"; rm -f "$D/.state/director.state"
  DIRECTOR_NO_BW= /bin/bash "$D/director.sh" start
  local f1 l j; for j in 1 2 3 4 5 6 7 8; do sleep 1; f1="$(fr Comet "$frag")"; l="$(pinned_since "$n")"; near "$f1" "$CAM" && break; done
  { echo "$l" | grep -q "webcam on" && near "$f1" "$CAM"; } && ok "pinned under the camera at $f1" || bad "expected pinned under the camera, window at $f1, log: $l"
  # v99: the pill on the seam under the call, centred on the call (= the camera line)
  local sl sx sy sw seamy; sl="$(tail -n +"$(( n + 1 ))" "$KL" | grep "strip: shown" | tail -1)"
  sx="$(echo "$sl" | sed -nE 's/.*pill ([0-9]+)x[0-9]+ at ([0-9-]+),([0-9-]+).*/\2/p')"; sy="$(echo "$sl" | sed -nE 's/.*pill ([0-9]+)x[0-9]+ at ([0-9-]+),([0-9-]+).*/\3/p')"
  sw="$(echo "$sl" | sed -nE 's/.*pill ([0-9]+)x.*/\1/p')"; seamy=660; [ "$PLACE" = desk ] && seamy=792
  local cx; cx="$(echo "$CAM" | awk -F, '{print $1 + $3 / 2}')"
  if [ -n "$sx" ] && [ ! -f "$D/.state/strip.json" ] || ! grep -q "\"$PLACE\"" "$D/.state/strip.json" 2>/dev/null; then
    [ -n "$sx" ] && [ $(( sx + sw / 2 - ${cx%.*} )) -le 3 ] && [ $(( ${cx%.*} - sx - sw / 2 )) -le 3 ] && [ $(( sy + 13 - seamy )) -le 3 ] && [ $(( seamy - sy - 13 )) -le 3 ] \
      && ok "pill on the seam under the call (${sw}x26 at $sx,$sy)" || bad "pill: ${sl:-not shown}"
  else say "  NOTE pill at a spot the user chose (.state/strip.json): $sl"; fi
  local dl; dl="$(tail -n +"$((dn + 1))" "$D/.state/director.log")"
  echo "$dl" | grep -q "BetterWispr's notetaker started\|BetterWispr already taking notes" && ok "BetterWispr's notetaker on" || bad "BetterWispr's notetaker: $(echo "$dl" | grep -i betterwispr | tail -1 | cut -c21-140)"
  echo "$dl" | grep -q "Wispr's notetaker started\|Wispr's notetaker already running" && ok "Wispr's notetaker on" || bad "Wispr's notetaker: $(echo "$dl" | grep -i "wispr's" | tail -1 | cut -c21-140)"
  local i p r m q
  for i in $(seq 1 25); do p="$(win BetterWispr Notetaker L3)"; m="$(win BetterWispr Notetaker L0)"; q="$(win BetterWispr "" L3)"; r="$(win "Wispr Flow" "Meeting Recorder")"
    [ -z "$p" ] && near "$m" "$MAIN" && near "$q" "$PILL" && near "$r" "$REC" && break; sleep 1; done
  [ -z "$p" ] && ok "no BetterWispr panel floating over Granola" || bad "BetterWispr's floating panel still at $p"
  near "$m" "$MAIN" && ok "BetterWispr's notes in its main window, in its slot ($m)" || bad "BetterWispr's main window at ${m:-none}, slot $MAIN"
  for i in 1 2 3 4 5 6 7 8; do above Granola Granola BetterWispr Notetaker && break; sleep 1; done
  above Granola Granola BetterWispr Notetaker && ok "Granola in front of BetterWispr's main window" || bad "BetterWispr's main window is not behind Granola"
  local fa; fa="$(lsappinfo info -only name "$(lsappinfo front)" | head -1 | sed -nE 's/^"([^"]*)".*/\1/p')"
  [ "$fa" != BetterWispr ] && [ "$fa" != "Wispr Flow" ] && ok "the focus stays with $fa (not taken by BetterWispr or Wispr)" || bad "the focus is with $fa"
  near "$q" "$PILL" && ok "BetterWispr's pill at the bottom of the right edge ($q)" || bad "BetterWispr's pill window at ${q:-none}, slot $PILL"
  near "$r" "$REC" && ok "Wispr's Meeting Recorder in its slot ($r)" || bad "Wispr's Meeting Recorder at ${r:-none}, slot $REC"
  sleep 2; for i in 1 2 3 4 5; do above krisp Krisp "Wispr Flow" "Meeting Recorder" && break; sleep 1; done   # the guard puts Krisp back within 2 s
  above krisp Krisp "Wispr Flow" "Meeting Recorder" && ok "Krisp on top, Wispr peeking out on the right (the default pick)" || bad "Wispr's recorder is over Krisp"
  local gl; gl="$(tail -n +"$(( n + 1 ))" "$KL" | grep -c "guard: Krisp back on top")"
  [ "$gl" -le 3 ] && ok "no tug of war over Krisp and Wispr ($gl guard raises)" || bad "the guard raised Krisp $gl times (a tug of war)"
  bwopen; sleep 1; p="$(win BetterWispr Notetaker L3)"; say "  BetterWispr's own 'Open beside your call' pressed: panel at ${p:-none}"
  for i in $(seq 1 12); do sleep 1; p="$(win BetterWispr Notetaker L3)"; [ -z "$p" ] && break; done
  [ -z "$p" ] && ok "the reopened panel went back to the main window within ${i} s" || bad "the reopened panel stayed at $p"
  say "  layout: $(tail -1 "$D/.state/layout.log" | cut -d' ' -f3- | cut -c1-220)"
  dn="$(wc -l < "$D/.state/director.log" | tr -d ' ')"
  DIRECTOR_NO_BW= /bin/bash "$D/director.sh" stop; sleep 3
  local f2; for i in 1 2 3 4 5 6 7 8 9; do f2="$(fr Comet "$frag")"; near "$f2" "$f0" && break; sleep 1; done
  near "$f2" "$f0" && ok "put back at $f2" || bad "not put back: $f2, was $f0"
  for i in $(seq 1 40); do dl="$(tail -n +"$((dn + 1))" "$D/.state/director.log")"; echo "$dl" | grep -q "after-call check" && break; sleep 1; done
  echo "$dl" | grep -q "BetterWispr's notetaker stopped" && ok "BetterWispr's notetaker stopped" || bad "BetterWispr stop: $(echo "$dl" | grep -i betterwispr | tail -1 | cut -c21-140)"
  echo "$dl" | grep -q "Wispr's notetaker stopped" && ok "Wispr's notetaker stopped" || bad "Wispr stop: $(echo "$dl" | grep -i "wispr's" | tail -1 | cut -c21-140)"
  [ -z "$(win BetterWispr Notetaker L3)" ] && ok "BetterWispr's panel closed" || bad "BetterWispr's panel still open at $(win BetterWispr Notetaker L3)"
  [ -z "$(win "Wispr Flow" "Meeting Recorder")" ] && ok "Wispr's Meeting Recorder closed" || bad "Wispr's Meeting Recorder still open at $(win "Wispr Flow" "Meeting Recorder")"
  say "  $(echo "$dl" | grep "stop: unpinned, notetakers off" | tail -1 | cut -c21-)"
  close_test "$frag"; sleep 1
}
PLACE="$("$D/director.sh" test 2>/dev/null | sed -nE 's/.*place=([a-z]+).*/\1/p')"
nt_case
[ -n "${E2E_ONLY_NT:-}" ] && { [ $FAIL = 0 ] && say "RESULT: ALL PASS (notetaker case only)" || say "RESULT: SOME FAILED (notetaker case only)"; exit $FAIL; }
call_case teams "Microsoft Teams" 1
call_case webex "Webex Meeting" 1
call_case zoomweb "Zoom Meeting" 1
call_case voice "Voice - Calls" 0
abort_if_call; say "plain browser window only (Krisp recording, no call window):"
n="$(kl)"; rm -f "$D/.state/director.state"; /bin/bash "$D/director.sh" start; sleep 4
l="$(pinned_since "$n")"; { ! echo "$l" | grep -q "webcam on"; } && ok "nothing pinned" || bad "pinned: $l"
say "  $(tail -1 "$D/.state/director.log" | cut -c1-200)"
sleep 12; /bin/bash "$D/director.sh" stop
say "Key Deck strict pin, title matches nothing:"
n="$(kl)"; /usr/bin/open -g "keydeck://webcam?bundle=ai.perplexity.comet&title=zzz-no-such-window&strict=1"; sleep 3
l="$(pinned_since "$n")"; echo "$l" | grep -q "nothing pinned" && ok "$l" || bad "log: $l"
say "Key Deck Phone window (what a real phone call does):"
if pgrep -x Phone >/dev/null; then
  p0="$(fr Phone "Phone")"; n="$(kl)"; /usr/bin/open -g "keydeck://webcam?bundle=com.apple.mobilephone&title=&strict=0"; sleep 3
  p1="$(fr Phone "Phone")"; l="$(pinned_since "$n")"
  { echo "$l" | grep -q "webcam on" && near "$p1" "$CAM"; } && ok "Phone pinned at $p1" || bad "Phone at $p1, log: $l"
  /usr/bin/open -g "keydeck://webcam-off"; sleep 3; p2="$(fr Phone "Phone")"; near "$p2" "$p0" && ok "Phone put back at $p2" || bad "Phone at $p2, was $p0"
else say "  skipped: Phone is not open"; fi
abort_if_call; say "All four layouts:"
for i in $(seq 1 45); do pgrep -f "layout.py" >/dev/null || break; sleep 1; done   # v94: the after-call "Krisp back" settle (30 s) must finish first, or it pulls Krisp to the other screen's slot mid-check
LAST=layout-call; [ "$PLACE" = desk ] && LAST=layout-call-desk   # end on the phone layout of this screen
for id in $(printf '%s\n' layout-transcripts layout-transcripts-desk layout-call-desk layout-call | grep -v "^$LAST$") $LAST; do
  /usr/bin/python3 "$D/layout.py" "$id" --settle 5 > /tmp/e2e-layout.txt 2>&1 && ok "$(cut -d' ' -f3- /tmp/e2e-layout.txt | cut -c1-230)" || bad "$(cut -d' ' -f3- /tmp/e2e-layout.txt | cut -c1-230)"
done
[ $FAIL = 0 ] && say "RESULT: ALL PASS" || say "RESULT: SOME FAILED"
