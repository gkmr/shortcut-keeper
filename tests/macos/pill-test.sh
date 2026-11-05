#!/bin/bash
# Key Deck v99 pill on the real screen (about 30 s; moves the pointer briefly, opens and closes one Comet test window):
# pin the Meet test page -> the pill on the seam; drag it off the call -> it stays there (strip.json "screen");
# double-click its grip -> back on the seam; a Granola click -> Granola forward; Call click -> still pinned; unpin.
# Never runs during a call. Results in .state/pill-test.txt.
D="$(cd "$(dirname "$0")/../.." && pwd)"; KL="$D/.state/keydeck.log"; OUT="$D/.state/pill-test.txt"; M="$D/.state/mousedo"
mkdir -p "$D/.state"; [ -x "$M" ] || swiftc -O -o "$M" "$D/tests/macos/mousedo.swift" || exit 2   # synthetic mouse helper
[ -f "$D/.state/director.state" ] && { echo "a call is live: not testing" > "$OUT"; exit 1; }
: > "$OUT"; PAUSE="$D/.state/watch-paused.$$"; touch "$PAUSE"; trap 'rm -f "$PAUSE"' EXIT
real_call() { "$D/bin/micusers" 2>/dev/null | grep -qiE 'comet|chrome|safari|thebrowser|zoom|whatsapp|teams|webex|slack|facetime|avconferenced|callservicesd'; }
abort_if_call() { if real_call; then echo "  STOPPED: a real call took the mic at $(date '+%T'); the test leaves it to the watcher" | tee -a "$OUT"; rm -f "$PAUSE"; exit 3; fi; }   # v102
real_call && { echo "a call app is on the mic (a real call): not testing" > "$OUT"; exit 1; }
: > "$OUT"; say() { echo "$*" | tee -a "$OUT"; }; FAIL=0; ok() { say "  PASS $*"; }; bad() { say "  FAIL $*"; FAIL=1; }
say "Key Deck pill test $(date '+%F %T')"
cp "$D/.state/strip.json" "$D/.state/strip.json.before-test" 2>/dev/null; rm -f "$D/.state/strip.json"
/usr/bin/open -na "Comet" --args --new-window "file://$D/tests/macos/pages/meet.html"; sleep 4
n=$(wc -l < "$KL" | tr -d ' ')
/usr/bin/open -g "keydeck://webcam?bundle=ai.perplexity.comet&title=abc-defg-hij&strict=1"
for i in $(seq 1 10); do sleep 1; tail -n +$((n + 1)) "$KL" | grep -q "strip: shown" && break; done
sl="$(tail -n +$((n + 1)) "$KL" | grep "strip: shown" | tail -1)"
read -r w x y <<< "$(echo "$sl" | sed -nE 's/.*pill ([0-9]+)x[0-9]+ at ([0-9-]+),([0-9-]+).*/\1 \2 \3/p')"
[ -n "$x" ] && ok "pill shown: ${w}x26 at $x,$y" || { bad "pill not shown: $sl"; }
gx=$((x + 9)); gy=$((y + 13))
abort_if_call; n=$(wc -l < "$KL" | tr -d ' ')
"$M" drag "$gx" "$gy" "$gx" $((gy + 420)); sleep 1
d="$(tail -n +$((n + 1)) "$KL" | grep "strip: dropped" | tail -1)"
echo "$d" | grep -q "stays there" && ok "dragged off the call: $(echo "$d" | cut -c22-)" || bad "drag: ${d:-no drop logged}"
grep -q '"mode":"screen"' "$D/.state/strip.json" 2>/dev/null && ok "remembered in strip.json: $(cat "$D/.state/strip.json")" || bad "strip.json: $(cat "$D/.state/strip.json" 2>/dev/null)"
n=$(wc -l < "$KL" | tr -d ' ')
"$M" click "$gx" $((gy + 420)) 2; sleep 1
tail -n +$((n + 1)) "$KL" | grep -q "strip: back to the seam" && ok "double-click on the grip: back to the seam" || bad "double-click: $(tail -n +$((n + 1)) "$KL" | grep strip | tail -1)"
n=$(wc -l < "$KL" | tr -d ' ')
# Granola chip: grip ~18 pt, then Call, Claude, Granola: read the chip spots from the render widths (about x + 165)
"$M" click $((x + 165)) "$gy"; sleep 2
c="$(tail -n +$((n + 1)) "$KL" | grep -E "strip: .* clicked" | tail -1)"
[ -n "$c" ] && ok "a chip click lands: $(echo "$c" | cut -c22-)" || bad "chip click: nothing logged"
n=$(wc -l < "$KL" | tr -d ' ')
"$M" click $((x + 40)) "$gy"; sleep 2
c="$(tail -n +$((n + 1)) "$KL" | grep -E "strip: Call clicked|webcam" | tr '\n' ' ')"
echo "$c" | grep -q "strip: Call clicked" && ! echo "$c" | grep -q "webcam off" && ok "Call click keeps the pin: $(echo "$c" | cut -c1-160)" || bad "Call click: $c"
# v107: the Transcript chip at the right end of the pill copies the live transcript, like Caps T
mkdir -p "$D/.state/shots"; screencapture -x -R "$((x - 10)),$((y - 6)),$((w + 20)),38" "$D/.state/shots/pill-v107.png" 2>/dev/null
n=$(wc -l < "$KL" | tr -d ' ')
"$M" click $((x + w - 34)) "$gy"; sleep 1.5
t="$(tail -n +$((n + 1)) "$KL" | grep -E "strip: Transcript clicked|transcript:" | tr '\n' ' ')"
echo "$t" | grep -q "strip: Transcript clicked" && echo "$t" | grep -qE "transcript: (copied|nothing)" && ok "Transcript chip copies: $(echo "$t" | sed -E 's/.*transcript: //' | cut -c1-90)" || bad "Transcript chip: ${t:-nothing logged}"
/usr/bin/open -g "keydeck://webcam-off"; sleep 3
/usr/bin/osascript -e 'tell application "System Events" to tell process "Comet" to click (first button of (first window whose name contains "abc-defg-hij") whose subrole is "AXCloseButton")' >/dev/null 2>&1
[ -f "$D/.state/strip.json.before-test" ] && mv "$D/.state/strip.json.before-test" "$D/.state/strip.json"
[ $FAIL = 0 ] && say "RESULT: ALL PASS" || say "RESULT: SOME FAILED"
