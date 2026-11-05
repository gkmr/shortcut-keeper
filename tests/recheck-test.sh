#!/bin/bash
# Tests the Director's background recheck (director.sh watch-call) with fake windows, a private state folder and a
# 1-second interval: nothing is pinned, moved or logged in the real .state.
#   tests/recheck-test.sh     prints PASS/FAIL per step, exit 1 on any failure
D="$(cd "$(dirname "$0")/.." && pwd)"; T="$(mktemp -d)"; F="$T/fake"; fail=0
export DIRECTOR_STATE_DIR="$T" DIRECTOR_FAKE="$F" DIRECTOR_DRY=1 DIRECTOR_RECHECK_EVERY=1
check() { got="$(cut -d'|' -f1,3,5 "$T/director.state" 2>/dev/null)"; [ "$got" = "$2" ] && echo "PASS $1" || { echo "FAIL $1: expected $2, got $got"; fail=1; }; }
printf 'Comet|Example Project - Script Editor - Comet\nMICNONE\n' > "$F"
echo "none||none|111|" > "$T/director.state"
/bin/bash "$D/director.sh" watch-call 111 & W=$!
sleep 2.5; check "no call yet: nothing pinned" "none|none|"
printf 'Comet|Meet - Weekly sync - Camera and microphone recording - Comet\nMIC|ai.perplexity.comet.helper\n' > "$F"
sleep 2.5; check "call starts later: pinned" "video|Google Meet|Meet - Weekly sync"
printf 'Comet|Meet - Weekly sync - Comet\nComet|Meet - Design review - Camera and microphone recording - Comet\nMIC|ai.perplexity.comet.helper\n' > "$F"
sleep 1.2; printf 'Comet|Meet - Design review - Camera and microphone recording - Comet\nMIC|ai.perplexity.comet.helper\n' > "$F"
sleep 3.5; check "next call in a new window: pin moved" "video|Google Meet|Meet - Design review"
printf 'Comet|Inbox - Gmail - Comet\nMIC|ai.perplexity.comet.helper\n' > "$F"
sleep 2.5; check "tab switched away: pin kept" "video|Google Meet|Meet - Design review"
echo "zzz||none|999|" > "$T/director.state"; sleep 2
kill -0 $W 2>/dev/null && { echo "FAIL watcher still running after the session changed"; fail=1; kill $W; } || echo "PASS watcher ends with its session"
grep -c "recheck:" "$T/director.log" | sed 's/^/log lines: /'
rm -rf "$T"; [ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
