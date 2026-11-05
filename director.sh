#!/bin/bash
# Meeting Director. Called by a recorder watcher (a small script that polls the call recorder; not part of this repo):
#   director.sh start   when Krisp starts recording        director.sh stop   when Krisp has been idle for IDLE seconds
#   director.sh test    print what it would detect now     director.sh probe  dump every call app's windows (diagnosis)
# start: finds THE call window, applies the user's layout, then Webcam Mode (top center, pinned with Floaty) on that window only.
#   Pinned only when the window is really a call (a browser window with no meeting tab is never pinned):
#   Zoom meeting window (CptHost runs), Google Meet tab with a meeting code or a "Meet - <name>" tab with live mic, Teams or
#   Webex meeting window (app or browser),
#   Slack huddle window, WhatsApp call window. Weak signals need live call audio too (bin/micusers, Core Audio):
#   a Google Voice tab counts only while that browser records from the mic; FaceTime and Phone only while an Apple call
#   process does (their windows stay open between calls). Nothing found = layout only, nothing pinned.
#   Layout: Phone or FaceTime calls -> "Phone call" (the call app top center); every other call -> "Video call".
#   Desk (a display wider than 2:1 connected) -> the desk variant. The user's layout: Claude left half (queries Krisp),
#   Granola top right and Wispr bottom right (both can query their transcripts), Krisp bottom middle next to Wispr with
#   BetterWispr's notes panel floating on its left part and BetterWispr's main window behind it (Key Deck's Caps 4 swaps
#   them), Krisp's call widget under the call box.
# watch-call: started by start, rechecks every minute during the recording (a call that starts later, or the next call in a
#   new window, gets pinned; Wispr's Meeting Recorder or BetterWispr's notes panel opened late, docked on the right edge,
#   goes to its slot); see the case below.
# stop: Webcam Mode off (unpinned, back where it was), then Krisp alone back in its slot (it widens itself when a call ends).
#   Log: .state/director.log (start lines include the probe).
# Env for tests: DIRECTOR_SETTLE=<s> (layout watch, default 120: late windows such as BetterWispr's panel), DIRECTOR_QUIET=1 (no notification), DIRECTOR_DRY=1 (no moves).
# Tests: DIRECTOR_FAKE=<file> replaces live window titles with lines "Process|window title" ("CptHost" = in a Zoom meeting,
#   "MIC|<bundle or process>" = that process records from the mic, "MICNONE" = mic list known and empty; no MIC lines = unknown).
D="${SHORTCUT_KEEPER_HOME:-$(cd "$(dirname "$0")" && pwd)}"; ST="${DIRECTOR_STATE_DIR:-$D/.state}"; LOG="$ST/director.log"; STATE="$ST/director.state"   # DIRECTOR_STATE_DIR: tests only
mkdir -p "$ST"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { [ -n "${DIRECTOR_FAKE:-}${DIRECTOR_QUIET:-}" ] && return; /usr/bin/osascript -e "display notification \"$1\" with title \"Meeting Director\"" >/dev/null 2>&1; }
enc() { /usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
# One System Events call reads every call app's window titles ("Process|title" lines); wins() greps it.
# (One call per app took 15 to 40 s under load on 2026-10-21, too slow for the start of a call.) The names are copied into a list
# first: looping straight over "name of every window of process X" kept references that sometimes would not turn into
# text, and the try swallowed it, so every app looked windowless (seen 2026-10-22 during a Meet call).
CALLAPPS="zoom.us|Comet|Google Chrome|Safari|Arc|MSTeams|Microsoft Teams|Webex|Slack|WhatsApp|FaceTime|Phone"
LIVE="$ST/live-snap.txt"   # v105: Key Deck's snapshot (every 0.5 s): mic users and call window titles, used while under 2 s old
live_fresh() { [ -z "${DIRECTOR_FAKE:-}" ] && [ -s "$LIVE" ] && [ $(( $(date +%s) - $(head -1 "$LIVE" 2>/dev/null || echo 0) )) -le 2 ]; }
mic_list() { if live_fresh; then grep '^MIC|' "$LIVE" | cut -d'|' -f2-; else "$D/bin/micusers" 2>/dev/null; fi; }   # v106d: who is on the mic (snapshot, else Core Audio: 0.3 to 3 s)
snap() {
  if [ -n "${DIRECTOR_FAKE:-}" ]; then SNAP="$(cat "$DIRECTOR_FAKE")"; return; fi
  if live_fresh; then SNAP="$(tail -n +2 "$LIVE" | grep -vE '^(MIC|SCREEN)\|')"; return; fi   # v105: milliseconds instead of 1.2 s
  local list="" n OLDIFS="$IFS"; IFS='|'
  for n in $CALLAPPS; do pgrep -xq "$n" && list="$list${list:+, }\"$n\""; done   # pgrep is instant; asking System Events for its process list took 6 s
  IFS="$OLDIFS"; SNAP=""; [ -n "$list" ] || return
  SNAP="$(/usr/bin/osascript -e "set out to \"\"
tell application \"System Events\"
repeat with n in {$list}
try
set ns to (get name of every window of process (n as text))
repeat with i from 1 to (count of ns)
try
set out to out & (n as text) & \"|\" & ((item i of ns) as text) & linefeed
end try
end repeat
end try
end repeat
end tell
return out" 2>/dev/null | tr -d '\r')"
}
wins() { echo "$SNAP" | grep "^$1|" | cut -d'|' -f2-; }
has_win() { echo "$SNAP" | grep -q "^$1|"; }   # true even when the window has no title
zoom_meeting() { if [ -n "${DIRECTOR_FAKE:-}" ]; then grep -qx CptHost "$DIRECTOR_FAKE"; else pgrep -x CptHost >/dev/null 2>&1; fi; }

# processes recording from a mic: "pid|bundle|name|in|out" lines. MICKNOWN=0 when the tool is missing (then no audio gate)
mics() {
  MICS=""; MICKNOWN=0
  if [ -n "${DIRECTOR_FAKE:-}" ]; then
    grep -q '^MIC' "$DIRECTOR_FAKE" && { MICKNOWN=1; MICS="$(grep '^MIC|' "$DIRECTOR_FAKE" | cut -d'|' -f2-)"; }; return
  fi
  if live_fresh; then MICS="$(grep '^MIC|' "$LIVE" | cut -d'|' -f2-)"; MICKNOWN=1; return; fi   # v105
  [ -x "$D/bin/micusers" ] && MICS="$("$D/bin/micusers" 2>/dev/null)" && MICKNOWN=1
}
mic_has() { [ "$MICKNOWN" = 0 ] || echo "$MICS" | grep -qiE "$1"; }   # unknown = do not block
APPLE_CALL='avconference|callservices|TelephonyUtilities|mobilephone|FaceTime|CallKit|InCall'
browser_mic() { case "$1" in   # the browser's audio runs in a helper whose bundle id starts with the browser's
  com.apple.Safari) echo 'com\.apple\.(Safari|WebKit)';; *) echo "$(echo "$1" | sed 's/\./\\./g')";; esac; }
found() { KIND="$1"; APP="$2"; TITLE="$3"; WHAT="$4"; STRICT="$5"; }
detect() {
  KIND=""; APP=""; TITLE=""; WHAT=""; STRICT=1; snap; mics
  # 1. Zoom app: CptHost only runs inside a meeting
  if zoom_meeting; then
    t="$(wins zoom.us | grep -iE 'Zoom Meeting|Zoom Webinar|Meeting|Webinar' | head -1)"; found video us.zoom.xos "${t:-Zoom Meeting}" Zoom 1; return   # webinars too (missed 2026-10-25)
  fi
  # 2. browser tabs (a window's title is its front tab): Meet with a code, Teams or Webex meeting pages
  local OLDIFS="$IFS"; IFS=$'\n'
  for b in Comet:ai.perplexity.comet "Google Chrome:com.google.Chrome" Safari:com.apple.Safari Arc:company.thebrowser.Browser; do
    name="${b%%:*}"; bid="${b##*:}"; t="$(wins "$name")"; [ -n "$t" ] || continue
    code="$(echo "$t" | grep -iE 'Meet' | grep -oiE '[a-z]{3}-[a-z]{4}-[a-z]{3}' | head -1)"
    [ -n "$code" ] && { IFS="$OLDIFS"; found video "$bid" "$code" "Google Meet" 1; return; }
    # A calendar meeting's tab is titled "Meet - <meeting name>", not the code (missed twice on 2026-10-22: both
    # tabs carried the calendar event's name). Counts when that browser records from the mic or Chromium marks the tab
    # "Camera and microphone recording" / "Microphone recording". The idle landing tab is "Google Meet" and never matches.
    m="$(echo "$t" | grep -E '^Meet - ' | head -1)"
    if [ -n "$m" ] && { echo "$m" | grep -qiE '(camera and )?microphone recording' || { [ "$MICKNOWN" = 1 ] && mic_has "$(browser_mic "$bid")"; }; }; then
      w="${m%% - $name}"
      for cut in " - Camera and microphone recording" " - Camera recording" " - Microphone recording" " - High memory usage" " - Audio playing" " - Sharing"; do w="${w%%$cut*}"; done
      IFS="$OLDIFS"; found video "$bid" "$w" "Google Meet" 1; return
    fi
    m="$(echo "$t" | grep -iE 'Microsoft Teams' | grep -iE 'meeting|call' | head -1)"
    [ -n "$m" ] && { IFS="$OLDIFS"; found video "$bid" "${m%% - $name*}" "Teams (browser)" 1; return; }
    m="$(echo "$t" | grep -iE 'webex' | grep -iE 'meeting' | head -1)"
    [ -n "$m" ] && { IFS="$OLDIFS"; found video "$bid" "${m%% - $name*}" "Webex (browser)" 1; return; }
    m="$(echo "$t" | grep -E '^Zoom (Meeting|Webinar)' | head -1)"   # Zoom's web client (app.zoom.us/wc), added 2026-10-27
    [ -n "$m" ] && { IFS="$OLDIFS"; found video "$bid" "${m%% - $name*}" "Zoom (browser)" 1; return; }
  done
  IFS="$OLDIFS"
  # 3. native meeting apps with a separate call window
  for tp in MSTeams "Microsoft Teams"; do   # new Teams runs as MSTeams (com.microsoft.teams2), classic as Microsoft Teams
    m="$(wins "$tp" | grep -iE 'meeting|call' | head -1)"
    [ -n "$m" ] && { b=com.microsoft.teams2; [ "$tp" = "Microsoft Teams" ] && b=com.microsoft.teams; found video "$b" "$m" "Teams" 1; return; }
  done
  m="$(wins Webex | grep -iE 'meeting' | head -1)"; [ -n "$m" ] && { found video Cisco-Systems.Spark "$m" "Webex" 1; return; }
  m="$(wins Slack | grep -iE 'huddle' | head -1)"; [ -n "$m" ] && { found video com.tinyspeck.slackmacgap "$m" "Slack huddle" 1; return; }
  # v104 (2026-10-30, a real huddle): a huddle popped out into its own window is titled "<person or
  # channel> - <workspace> - Slack" (the title bar says "Huddle with ...", the window list does not): Slack on the mic plus a
  # Slack window that is not the main one ([Main]) and not a channel, DM or thread window = a huddle. While it loads its
  # title is "- <workspace> - Slack" (no name yet): skipped until the name shows, so the pin never matches the main window.
  if [ "$MICKNOWN" = 1 ] && echo "$MICS" | grep -qi 'slackmacgap'; then
    m="$(wins Slack | grep -vE '\[Main\]|\((Channel|DM|Thread|Canvas|List)\)' | grep -E '^[^- ].* - Slack$' | head -1)"
    [ -n "$m" ] && { found video com.tinyspeck.slackmacgap "$m" "Slack huddle" 1; return; }
  fi
  m="$(wins WhatsApp | grep -iE 'call' | head -1)"
  if [ -n "$m" ]; then k=audio; echo "$m" | grep -qi video && k=video; found "$k" net.whatsapp.WhatsApp "$m" "WhatsApp call" 1; return; fi
  # 4. Google Voice tab, only while that browser records from the mic (the tab often stays open all day)
  IFS=$'\n'
  for b in Comet:ai.perplexity.comet "Google Chrome:com.google.Chrome" Safari:com.apple.Safari Arc:company.thebrowser.Browser; do
    name="${b%%:*}"; bid="${b##*:}"
    m="$(wins "$name" | grep -E "^(\([0-9]+\) )?(Google )?Voice( - [A-Za-z ]+)? - $name\$" | head -1)"
    [ -n "$m" ] && mic_has "$(browser_mic "$bid")" && { IFS="$OLDIFS"; found audio "$bid" "${m%% - $name}" "Google Voice" 1; return; }
  done
  IFS="$OLDIFS"
  # 5. Phone and FaceTime: their own window is the call window, but it stays open between calls, so call audio must be
  #    live. Both share Apple's call processes, so Phone wins unless the audio names FaceTime or Phone has no window.
  mic_has "$APPLE_CALL" || return
  ft="$(wins FaceTime | head -1)"
  if has_win FaceTime && { ! has_win Phone || { [ "$MICKNOWN" = 1 ] && echo "$MICS" | grep -qi facetime; }; }; then
    w=0; [ -z "${DIRECTOR_FAKE:-}" ] && w="$(/usr/bin/osascript -e 'tell application "System Events" to tell process "FaceTime" to get item 1 of (get size of window 1)' 2>/dev/null)"
    k=audio; [ "${w:-0}" -gt 420 ] 2>/dev/null && k=video; echo "$ft" | grep -qi video && k=video
    found "$k" com.apple.FaceTime "" "FaceTime $k" 0; return
  fi
  has_win Phone && { found audio com.apple.mobilephone "" "Phone" 0; return; }
  # Apple call audio with no Phone or FaceTime window (a call answered on the iPhone side, 2026-10-25): still a phone call,
  # so the Phone call layout; Key Deck finds no window to pin and pins nothing
  [ "$MICKNOWN" = 1 ] && { found audio com.apple.mobilephone "" "Phone call (no call window)" 0; return; }   # only on real call audio
  IFS="$OLDIFS"
}

place() {
  [ -n "${DIRECTOR_PLACE:-}" ] && { echo "$DIRECTOR_PLACE"; return; }
  if live_fresh && grep -q '^SCREEN|' "$LIVE"; then   # v105: Key Deck's display list, instead of system_profiler's 1.4 s
    awk -F'|' '/^SCREEN\|/ { if ($3 > 0 && $2 / $3 > 2.0) d=1 } END { print (d ? "desk" : "laptop") }' "$LIVE"; return
  fi
  system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution:/ { w=$2; h=$4; if (h > 0 && w / h > 2.0) d=1 } END { print (d ? "desk" : "laptop") }'
}

plan() {   # sets LID, LAYOUT from APP and WHERE
  if [ "$APP" = com.apple.mobilephone ] || [ "$APP" = com.apple.FaceTime ]; then LAYOUT="Phone call"; LID=layout-call
  else LAYOUT="Video call"; LID=layout-transcripts; fi
  if [ "$WHERE" = desk ]; then LID="$LID-desk"; [ "$LAYOUT" = "Phone call" ] && LAYOUT="Desk phone call" || LAYOUT="Desk video call"; fi
}

probe_line() {
  local o=""
  for p in Phone FaceTime zoom.us MSTeams "Microsoft Teams" Webex Slack WhatsApp; do w="$(wins "$p" | tr '\n' ';')"; [ -n "$w" ] && o="$o $p=[$w]"; done
  for b in Comet "Google Chrome" Safari; do w="$(wins "$b" | grep -iE 'meet|teams|webex|voice|zoom|huddle' | tr '\n' ';')"; [ -n "$w" ] && o="$o $b=[$w]"; done
  if [ -z "${DIRECTOR_FAKE:-}" ]; then   # Krisp's windows and sizes: its call widget and live transcript window (learning their titles)
    kw="$(/usr/bin/osascript -e 'tell application "System Events" to if exists process "krisp" then get {name, size} of every window of process "krisp"' 2>/dev/null | tr -d '\r')"
    [ -n "$kw" ] && o="$o krisp=[$kw]"
  fi
  [ "$MICKNOWN" = 1 ] && o="$o mic=[$(echo "$MICS" | cut -d'|' -f2,3 | grep . | tr '\n' ';')]" || o="$o mic=unknown"
  echo "$o"
}

# BetterWispr's notetaker with every meeting (the Wispr deprecation test). BetterWispr 0.1.5 only
# offers its notetaker when it detects a call and reads no calendar, so the Director starts it from BetterWispr's menu bar menu
# ("Start Meeting Notes"; no focus or clicks needed) and names the note after the calendar meeting that Krisp matched (Krisp
# reads all of the user's calendars; its folder name is that meeting's title). No match = BetterWispr's own new note. The Director
# stops only a notetaker it started (.state/bw-auto holds that call's start time). DIRECTOR_NO_BW=1 (on-screen tests) skips it.
BWAUTO="$ST/bw-auto"
# v106b: Key Deck chooses BetterWispr's menu item natively (a fraction of a second; System Events took 3 to 4 s). Its answer in
# .state/menu-result is final; AppleScript only when Key Deck does not answer within 2 s.
bw_menu() {   # bw_menu "<item>": choose that item in BetterWispr's menu bar menu; prints "chose <item>" or why not
  if [ -z "${DIRECTOR_FAKE:-}" ] && pgrep -xq KeyDeck; then
    local r="$D/.state/menu-result" i=0; rm -f "$r"
    open -g "keydeck://menu?bundle=org.betterwispr.app&item=$(enc "$1")"
    while [ "$i" -lt 40 ] && [ ! -s "$r" ]; do sleep 0.05; i=$((i + 1)); done
    if [ -s "$r" ]; then grep -q '^chose' "$r" && echo "chose $1" || echo "menu: no \"$1\" (Key Deck)"; return; fi
  fi
  bw_menu_as "$1"
}
bw_menu_as() {   # the same through System Events
  /usr/bin/osascript - "$1" <<'APPLESCRIPT' 2>/dev/null
on run argv
	set want to item 1 of argv
	tell application "System Events"
		if not (exists process "BetterWispr") then return "not running"
		tell process "BetterWispr"
			set si to menu bar item 1 of menu bar 2
			perform action "AXPress" of si
			delay 0.4
			set names to {}
			repeat with mi in menu items of menu 1 of si
				try
					set n to name of mi
					if n is not missing value then
						set end of names to n
						if n is want then
							perform action "AXPress" of mi
							return "chose " & n
						end if
					end if
				end try
			end repeat
			perform action "AXCancel" of menu 1 of si
		end tell
	end tell
	set AppleScript's text item delimiters to " | "
	return "menu: " & (names as text)
end run
APPLESCRIPT
}
bw_recording() { mic_list | grep -q 'org.betterwispr.app'; }
pinned_now() {   # is the call window under a Floaty pin? By frame only, never by title: Floaty keeps the title from pin time
  # (2026-10-28), and the Director runs inside the KrispWatch applet, which cannot read window titles at all (no
  # Screen Recording there): every Zoom call on 2026-10-28 logged "not pinned" three times while the pin was in place.
  # Pinned = a Floaty pin window whose frame matches a normal window that is not Krisp's (Floaty pinned Krisp by mistake
  # on 2026-10-27). $1 (the call window's title) is not needed any more.
  local W; W="$("$D/bin/wins" --all)"
  printf '%s\n' "$W" | awk -F'\t' '$4=="Floaty" && $2=="L3" {f[$6]=1} $4!="Floaty" && $4!="krisp" && $2=="L0" {w[$6]=1}
    END {for (k in f) if (k in w) {print "pinned"; exit}}' | grep -q pinned
}
# v106: Key Deck writes .state/pin-result ("pinned", "not pinned", "unpinned", "still pinned" and the ms it took) when a pin
# or unpin request is done; the waits end the moment it does (file checks every 0.05 s). The frame check stays as the fallback.
PINRES="$D/.state/pin-result"
pin_wait() {   # v84: wait for Key Deck's pin instead of a fixed 4 s; BetterWispr's menu opens right after
  local i=0; while [ "$i" -lt 80 ] && [ ! -s "$PINRES" ]; do sleep 0.05; i=$((i + 1)); done
  grep -q '^pinned' "$PINRES" 2>/dev/null && return 0
  i=0; while [ "$i" -lt 16 ] && ! pinned_now; do sleep 0.25; i=$((i + 1)); done
}
unpin_req() { rm -f "$PINRES"; UNPIN_ASKED=1; open -g "keydeck://webcam-off"; }
unpin_wait() {
  local i=0
  if [ -n "${UNPIN_ASKED:-}" ]; then
    while [ "$i" -lt 60 ] && [ ! -s "$PINRES" ]; do sleep 0.05; i=$((i + 1)); done
    grep -q '^unpinned' "$PINRES" 2>/dev/null && return 0
  fi
  i=0; while [ "$i" -lt 16 ] && pinned_now; do sleep 0.25; i=$((i + 1)); done
}
screen_locked() { ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; }
bw_start() {   # $1 = this call's start time
  [ -n "${DIRECTOR_DRY:-}${DIRECTOR_FAKE:-}${DIRECTOR_NO_BW:-}" ] && return
  pgrep -xq BetterWispr || return
  bw_recording && { log "start: BetterWispr already taking notes, left as is"; return; }
  if bw_menu "Start Meeting Notes" | grep -q '^chose'; then
    # v108: BetterWispr can take ~6 s to open the mic, and right after a call it may ignore the first Start (seen in v108)
    local i=0; while [ "$i" -lt 16 ] && ! bw_recording; do sleep 0.5; i=$((i + 1)); done
    if ! bw_recording; then bw_menu "Start Meeting Notes" >/dev/null; sleep 4
      bw_recording && log "start: BetterWispr's notetaker started on the second try" || log "start: BetterWispr did not start recording (menu chosen twice)"; fi
    echo "$1" > "$BWAUTO"; log "start: BetterWispr's notetaker started"
  else log "start: BetterWispr's notetaker did not start (its menu has no \"Start Meeting Notes\")"; fi
}
krisp_meeting() {   # the calendar meeting Krisp matched for the call that started at $1; empty when Krisp used a generic name
  # Krisp's folder for a call: "<meeting> - October 27, 2026 5-34-00 PM", created when it starts recording. Its own names when
  # no calendar event matched: "<app> meeting" ("Comet meeting", "Granola meeting") or Zoom's default instant-meeting topic.
  /usr/bin/python3 - "$1" <<'PY' 2>/dev/null
import os, re, sys
t0 = int(sys.argv[1]); d = os.environ.get('KRISP_MEETINGS_DIR') or os.path.expanduser('~/Meetings/Krisp/Krisp Meetings')   # override: tests
try:
    c = [(os.stat(os.path.join(d, n)).st_birthtime, n) for n in os.listdir(d) if os.path.isdir(os.path.join(d, n))]
except OSError:
    sys.exit()
c = [x for x in c if x[0] >= t0 - 120]
if not c:
    sys.exit()
name = re.sub(r' - [A-Z][a-z]+ \d{1,2}, \d{4} \d{1,2}-\d{2}-\d{2} [AP]M$', '', max(c)[1]).strip()
generic = re.compile(r"^((google )?chrome|comet|safari|arc|zoom|granola|slack|whatsapp|(microsoft )?teams|webex|facetime|phone|"
                     r"wispr flow|betterwispr|krisp|unknown|in-person) meeting$|'s (zoom|personal) meeting( room)?$", re.I)
if name and not generic.search(name):
    print(name)
PY
}
call_meeting() {   # the meeting name a call window's title carries ($1 = title), empty for a bare code or a generic name
  # Google Meet titles its tab "Meet - <calendar event name>" when joined from the calendar (2026-10-28: "Meet - <event name>"
  # while Krisp, which Granola's mic beat to it, named its folder "Granola meeting"); Teams web
  # "<meeting> | Microsoft Teams". A bare Meet code (abc-defg-hij), "Zoom Meeting" and the like carry no name.
  local t="$1"
  t="$(printf '%s' "$t" | sed -E 's/^Meet - //; s/ \| Microsoft Teams$//; s/ - (Camera and microphone recording|Camera recording|Microphone recording|Audio playing|High memory usage).*$//; s/ ?🔊$//')"
  printf '%s' "$t" | grep -qiE '^[a-z]{3}-[a-z]{4}-[a-z]{3}$|^(zoom meeting|google meet|meet|microsoft teams|webex meeting|teams)$|whatsapp|huddle' && return
  [ -n "$t" ] && printf '%s\n' "$t"
}
bw_title() {   # name BetterWispr's note once per call ($1 = start time, $2 = call window title): Krisp's calendar match, else the
  # meeting name in the call window's title
  [ -f "$BWAUTO" ] && [ "$(cat "$BWAUTO" 2>/dev/null)" = "$1" ] || return
  [ -f "$BWAUTO.titled" ] && [ "$(cat "$BWAUTO.titled")" = "$1" ] && return
  local m src="Krisp's calendar match"; m="$(krisp_meeting "$1")"
  [ -n "$m" ] || { m="$(call_meeting "$2")"; src="the call window's title"; }
  [ -n "$m" ] || return
  if "$D/bin/bwtitle" "$m" >/dev/null 2>&1; then echo "$1" > "$BWAUTO.titled"; log "recheck: BetterWispr's note named \"$m\" ($src)"; fi
}
bw_stop() {   # after the call: stop the notetaker the Director started
  [ -f "$BWAUTO" ] || return
  rm -f "$BWAUTO" "$BWAUTO.titled"
  bw_recording || return
  bw_menu "Stop Meeting" | grep -q '^chose' && log "stop: BetterWispr's notetaker stopped (the note stays in BetterWispr)"
}
# Wispr Flow's notetaker with every meeting too,
# alongside BetterWispr's. Same pattern as BetterWispr: the Director starts it from Wispr's own Notetaker
# menu ("Start Notetaker"; the menu works with Wispr in the background, no focus or keys) and, after the call, stops only a
# notetaker it started (.state/wispr-auto) with the Meeting Recorder's "Stop listening" button (bin/wisprnote.js: the menu
# never shows a stop item). The note stays in Wispr. Its Meeting Recorder window opens docked on the right edge (617 x full
# height) and the layout puts it top left (600 pt tall at the least). DIRECTOR_NO_BW=1 (on-screen tests) skips it too.
WSAUTO="$ST/wispr-auto"
wispr_menu() {   # wispr_menu "<item>" (or "<prefix>*"): choose it in Wispr's Notetaker menu; prints "chose <item>" or "menu: <items>"
  /usr/bin/osascript - "$1" <<'APPLESCRIPT' 2>/dev/null
on run argv
	set want to item 1 of argv
	set pre to (want ends with "*")
	if pre then set want to text 1 thru -2 of want
	tell application "System Events"
		if not (exists process "Wispr Flow") then return "not running"
		tell process "Wispr Flow"
			set names to {}
			repeat with mi in menu items of menu 1 of menu bar item "Notetaker" of menu bar 1
				try
					set n to name of mi
					if n is not missing value then
						set end of names to n
						if (n is want) or (pre and n starts with want) then
							perform action "AXPress" of mi
							return "chose " & n
						end if
					end if
				end try
			end repeat
		end tell
	end tell
	set AppleScript's text item delimiters to " | "
	return "menu: " & (names as text)
end run
APPLESCRIPT
}
wnote() {   # wnote state|stop|close [limit s, 25]: bin/wisprnote.js with a time limit. It reads Wispr's window through System Events, which
  # queues behind any long Accessibility read (2026-10-28: a Krisp transcript read held it for minutes); prints
  # "timeout" then
  local f; f="$(mktemp -t wnote)"; /usr/bin/osascript -l JavaScript "$D/bin/wisprnote.js" "$1" > "$f" 2>/dev/null & local p=$! i=0
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt "${2:-25}" ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; echo timeout; else cat "$f"; fi; rm -f "$f"
}
# recording = its Meeting Recorder shows "Stop listening"; when that read times out, Wispr's helper on the mic counts
wispr_recording() { local s; s="$(wnote state)"; [ "$s" = recording ] || { [ "$s" = timeout ] && mic_list | grep -q 'com.electron.wispr-flow'; }; }
wispr_start() {   # $1 = this call's start time
  [ -n "${DIRECTOR_DRY:-}${DIRECTOR_FAKE:-}${DIRECTOR_NO_BW:-}" ] && return
  pgrep -xq "Wispr Flow" || return
  # fast check (no Accessibility, so the layout is not held up): Wispr's helper already on the mic = Wispr started its
  # notetaker by itself (it does for meetings it detects)
  mic_list | grep -q 'com.electron.wispr-flow' && { log "start: Wispr's notetaker already running, left as is"; return; }
  if wispr_menu "Start Notetaker" | grep -q '^chose'; then
    echo "$1" > "$WSAUTO"; log "start: Wispr's notetaker started"
  else log "start: Wispr's notetaker did not start (its Notetaker menu has no \"Start Notetaker\")"; fi
}
wispr_stop() {   # after the call: Wispr's notetaker off and its Meeting Recorder closed (the note stays in Wispr)
  # v87 (Wispr's notetaker must stop with the call, like the others): Wispr usually
  # stops itself when the meeting ends; the Director then found it idle, wrote nothing and left the recorder open behind
  # Krisp, which looked like it kept going. Now: still listening = stop it (15 s at most, Thursday's took 49 s); stopped by
  # Wispr = say so; then the Meeting Recorder closes like BetterWispr's panel. Runs alongside bw_stop.
  [ -n "${DIRECTOR_DRY:-}${DIRECTOR_FAKE:-}${DIRECTOR_NO_BW:-}" ] && return
  rm -f "$WSAUTO"
  pgrep -xq "Wispr Flow" || return
  local r i
  # v103: Key Deck stops and closes it natively (milliseconds); the JXA path timed out at 15 to 25 s on three calls on Oct 30
  rm -f "$ST/wispr-result"; open -g "keydeck://wispr?do=stop"
  for i in $(seq 1 16); do [ -s "$ST/wispr-result" ] && break; sleep 0.25; done
  r="$(cat "$ST/wispr-result" 2>/dev/null)"
  case "$r" in
    stopped*) log "stop: Wispr's notetaker stopped (the note stays in Wispr)"; [ "$r" = "stopped+closed" ] && log "stop: Wispr's Meeting Recorder closed (the note stays in Wispr)"; return ;;
    idle+closed) log "stop: Wispr's notetaker already stopped by Wispr"; log "stop: Wispr's Meeting Recorder closed (the note stays in Wispr)"; return ;;
    none) return ;;
  esac
  if mic_list | grep -q 'com.electron.wispr-flow'; then   # v88: the mic list decides (0.3 s)
    r="$(wnote stop 15)"
    if [ "$r" = stopped ]; then log "stop: Wispr's notetaker stopped (the note stays in Wispr)"
    else log "stop: Wispr's notetaker did not stop ($r); it may still be running"; return; fi
  else log "stop: Wispr's notetaker already stopped by Wispr"; fi
  r="$(wnote shut 8)"
  [ "$r" = closed ] && log "stop: Wispr's Meeting Recorder closed (the note stays in Wispr)"
}
tidy_panel() {   # after a call: close BetterWispr's floating notes panel (nothing should float over the user's work after a
  # call). The note stays in BetterWispr. Skipped while BetterWispr still records from the mic (v88: waits up to 3 s for it to
  # let go after its Stop, instead of bw_stop's fixed 2 s)
  local i=0; while [ "$i" -lt 12 ] && mic_list | grep -q 'org.betterwispr.app'; do sleep 0.25; i=$((i + 1)); done
  mic_list | grep -q 'org.betterwispr.app' && return
  /usr/bin/osascript -e 'tell application "System Events"
	if not (exists process "BetterWispr") then return ""
	tell process "BetterWispr"
		repeat with w in windows
			if name of w is "Notetaker" and subrole of w is not "AXStandardWindow" then
				repeat with b in buttons of w
					if subrole of b is "AXCloseButton" then
						perform action "AXPress" of b
						return "closed"
					end if
				end repeat
			end if
		end repeat
	end tell
end tell
return ""' 2>/dev/null | grep -q closed && log "stop: BetterWispr's notes panel closed (the note stays in BetterWispr)"
}
pin_call() {   # Webcam Mode on the detected call window (Key Deck leaves an already pinned window alone, and swaps an old one)
  [ -z "${DIRECTOR_DRY:-}" ] && { rm -f "$PINRES"; open -g "keydeck://webcam?bundle=$APP&title=$(enc "$TITLE")&strict=$STRICT"; }
}
watcher() {   # start the background recheck for this call session (not in fake-window tests)
  [ -n "${DIRECTOR_FAKE:-}" ] && return
  (nohup /bin/bash "$D/director.sh" watch-call "$1" >/dev/null 2>&1 &)
}

case "${1:-}" in
  start)
    if [ -f "$STATE" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$STATE") ))
      # v87 (2026-10-30: a 0-min incognito Meet; its start finished 12 s after its stop and rewrote the state file,
      # which would have ignored every call for 4 hours): a state file counts only while it is fresh (2 min) or its
      # recheck loop still runs
      t_old="$(cut -d'|' -f4 "$STATE")"
      if [ "$age" -lt 14400 ] && { [ "$age" -lt 120 ] || pgrep -f "director.sh watch-call $t_old" >/dev/null; }; then
        log "start ignored: already handling $(cat "$STATE")"; exit 0
      fi
      log "start: an old state file with nothing running behind it, replaced ($(cat "$STATE"))"
      rm -f "$STATE"
    fi
    # v88 (low latency): the watcher's own detection from the last 5 s is reused, no delay, no second detect
    CACHED=""
    if [ -z "${DIRECTOR_FAKE:-}" ] && [ -f "$ST/detect.cache" ] && IFS='|' read -r c_t c_k c_a c_w c_s c_p c_title < "$ST/detect.cache" \
       && [ $(( $(date +%s) - ${c_t:-0} )) -le 5 ] && [ -n "$c_k" ]; then
      KIND="$c_k"; APP="$c_a"; WHAT="$c_w"; STRICT="$c_s"; WHERE="$c_p"; TITLE="$c_title"; CACHED=1
    else
      [ -z "${DIRECTOR_FAKE:-}" ] && sleep "${DIRECTOR_START_DELAY:-0}"
      detect; WHERE="$(place)"
    fi
    rm -f "$ST/detect.cache" "$D/.state/front-pick"; T0="$(date +%s)"   # v107: each call starts with Krisp on top
    if [ -z "$KIND" ]; then
      log "start: Krisp is recording but no call window found (Granola or Wispr mic, or in person): layout only, nothing pinned yet"
      # no notetakers here (2026-10-28 test): Krisp starts its own "Granola meeting" recording whenever Granola is still
      # transcribing after a call ends, and that restarted the Director, which started BetterWispr and Wispr again with no
      # meeting. They start when a call window shows up (watch-call), or the user starts them for an in-person meeting.
      log "probe:$(probe_line)"
      echo "none||none|$T0|" > "$STATE"
      APP=""; plan; [ -z "${DIRECTOR_DRY:-}" ] && (/usr/bin/python3 "$D/layout.py" "$LID" --quiet --settle "${DIRECTOR_SETTLE:-120}" &)
      watcher "$T0"; exit 0
    fi
    plan
    # v86: the state file goes down now, not after the notetakers (about 8 s later): a second start in that window (the
    # watcher seeing the notetakers this start just opened, 2026-10-29) must read "already handling" and leave
    echo "$KIND|$APP|$WHAT|$T0|$TITLE" > "$STATE"
    # pin first, then lay out: pinning activates the call's app (a browser brings ALL its windows forward), and the layout's
    # first passes raise the meeting windows above them in order (2026-10-27 test: Comet windows covered the layout)
    # v88: Key Deck places the windows natively (a fraction of a second; layout.py's AppleScript pass took up to 15 s), then
    # pins; once pinned, the meeting windows are raised again over the browser windows the pin brought forward
    [ -z "${DIRECTOR_DRY:-}" ] && open -g "keydeck://place?id=$LID"
    pin_call
    if [ -z "${DIRECTOR_DRY:-}" ]; then
      pin_wait; open -g "keydeck://place?id=$LID&raise=1"
      bw_start "$T0" & wispr_start "$T0" & wait   # v88: side by side (BetterWispr's status menu, Wispr's app menu)
      (/usr/bin/python3 "$D/layout.py" "$LID" --quiet --settle "${DIRECTOR_SETTLE:-120}" &)
    fi
    if [ -n "${DIRECTOR_FAKE:-}" ]; then log "probe:$(probe_line)"
    else ( { [ -n "$CACHED" ] && { snap; mics; }; log "probe:$(probe_line)"; } & ); fi   # v88: after the pin, off the critical path
    if [ ! -f "$STATE" ] || [ "$(cut -d'|' -f4 "$STATE")" != "$T0" ]; then
      log "start: the call ended while this start ran (the stop came first): undoing what it started"
      [ -z "${DIRECTOR_DRY:-}${DIRECTOR_FAKE:-}" ] && { unpin_req; unpin_wait; bw_stop & wispr_stop & wait; tidy_panel; }
      exit 0
    fi
    notify "$WHAT: $LAYOUT layout, call window under the camera and pinned. Caps W undoes it."
    echo "$KIND|$APP|$WHAT|$T0|$TITLE" > "$STATE"
    log "start: $KIND call, $WHAT, window \"$TITLE\", $WHERE, layout $LAYOUT, pinned"
    watcher "$T0"
    ;;
  watch-call)
    # Runs in the background for one Krisp recording (back-to-back calls in one recording were never pinned before it).
    # Every minute: nothing pinned yet and a call window appears = pin it; a different call window shows up twice in a row
    # (the next call in a new window) = move the pin there. It never unpins mid-recording (switching tabs must not drop the
    # pin) and never re-runs the layout. Ends when the call session ends (state removed or replaced) or after 4 hours.
    # v84: the pin and call checks every 10 s (was 60); the window steps (undock, Krisp and Wispr back, the note name) still every 60 s
    every="${DIRECTOR_RECHECK_EVERY:-10}"; heavy=$(( ${DIRECTOR_RECHECK_LAYOUT:-60} / every )); [ "$heavy" -lt 1 ] && heavy=1
    t0="${2:-}"; seen=""; n=0; WHERE="$(place)"
    while [ "$n" -lt $(( 14400 / every )) ]; do
      sleep "$every"; n=$((n + 1))
      [ -f "$STATE" ] || exit 0
      IFS='|' read -r K0 A0 W0 T00 TI0 < "$STATE"
      [ "$T00" = "$t0" ] || exit 0
      # Wispr's Meeting Recorder and BetterWispr's notes panel open themselves docked on the right edge, often after the
      # layout's 2 minutes (2026-10-27): put them in their slots; windows the user moved elsewhere are left alone
      if [ -z "${DIRECTOR_DRY:-}${DIRECTOR_FAKE:-}" ] && [ $(( n % heavy )) -eq 0 ]; then
        APP="$A0"; plan; /usr/bin/python3 "$D/layout.py" "$LID" --only "BetterWispr notes,Wispr,Krisp widget,Granola nub,BetterWispr pill" --undock --quiet
        # Krisp widens itself mid-call (its Voice AI side panel, 2026-10-28 4 PM: it slid under BetterWispr's panel and over
        # Wispr) and Wispr grows once it records: put both back in their slots every minute (a window already in place is left alone)
        /usr/bin/python3 "$D/layout.py" "$LID" --only "Krisp,Wispr" --keep-order --quiet   # v107: no raise, the user's pick stays on top
        bw_title "$t0" "$TI0"   # BetterWispr's note gets the meeting's name (Krisp's calendar match, else the call window's title)
      fi
      detect
      # the pin did not take (the call window was a background tab, or would not take focus): pin it again, three tries,
      # only while that same call is still detected (2026-10-27: the Zoom meeting had just ended and its window was
      # closing when the recheck tried to pin it again)
      if [ "$K0" != none ] && [ -n "$TI0" ] && [ -z "${DIRECTOR_FAKE:-}" ] && [ "${repin:-0}" -lt 6 ] && \
         [ -n "$KIND" ] && [ "$APP|$TITLE" = "$A0|$TI0" ] && \
         ! pinned_now "$TI0"; then
        repin=$(( ${repin:-0} + 1 )); STRICT=1
        pin_call; log "recheck: the call window \"$TI0\" was not pinned, pinned again (try $repin)"
        sleep 3; plan; [ -z "${DIRECTOR_DRY:-}" ] && /usr/bin/python3 "$D/layout.py" "$LID" --raise --quiet
      fi
      [ -n "$KIND" ] || { seen=""; continue; }
      if [ "$K0" = none ]; then
        pin_call; echo "$KIND|$APP|$WHAT|$t0|$TITLE" > "$STATE"
        log "recheck: $KIND call found after the start, $WHAT, window \"$TITLE\", pinned"; seen=""; repin=0
        [ -z "${DIRECTOR_DRY:-}" ] && { pin_wait; bw_start "$t0"; sleep 0.5; wispr_start "$t0"; }
        sleep 3; plan; [ -z "${DIRECTOR_DRY:-}" ] && /usr/bin/python3 "$D/layout.py" "$LID" --raise --quiet
      elif [ "$APP|$TITLE" != "$A0|$TI0" ]; then
        if [ "$seen" = "$APP|$TITLE" ]; then
          pin_call; echo "$KIND|$APP|$WHAT|$t0|$TITLE" > "$STATE"
          log "recheck: next call, $WHAT, window \"$TITLE\", pin moved there"; seen=""; repin=0
          sleep 3; plan; [ -z "${DIRECTOR_DRY:-}" ] && /usr/bin/python3 "$D/layout.py" "$LID" --raise --quiet
        else seen="$APP|$TITLE"; fi
      else seen=""; fi
    done
    ;;
  stop)
    [ -f "$STATE" ] || exit 0
    IFS='|' read -r KIND APP WHAT T0 TITLE < "$STATE"
    rm -f "$STATE"
    log "stop: $KIND call, $WHAT, $(( ($(date +%s) - ${T0:-0}) / 60 )) min"; TS=$(date +%s)
    # After the call: unpin the call window and put it back; stop the BetterWispr and Wispr notetakers the Director started; Krisp alone
    # back in its slot (it widens itself to the full screen width when a call ends, 2026-10-27: 2056 pt from x 656);
    # BetterWispr's pill back home at the bottom center; BetterWispr's floating notes panel closed. Nothing else moves.
    WHERE="$(place)"; plan
    [ -n "${DIRECTOR_DRY:-}${DIRECTOR_FAKE:-}" ] && exit 0
    after_call() {
      [ "$KIND" != none ] && unpin_req
      wispr_stop & unpin_wait; bw_stop; wait   # v89: Wispr's stop (a button in its window) starts with the unpin; BetterWispr's
      # menu waits for the unpin (Floaty's menu); v87: side by side (Thursday 7 PM: one after the other took 53 s)
      tidy_panel; log "stop: unpinned, notetakers off, panels closed $(( $(date +%s) - TS )) s after the stop"
      /usr/bin/python3 "$D/layout.py" "$LID" --pill-home --quiet
      /usr/bin/python3 "$D/layout.py" "$LID" --only Krisp --quiet --settle 30
      /usr/bin/python3 "$D/layout.py" "$LID" --pill-home --quiet   # v109: again, the pill can still be changing right after the stop
      # self-check after every call (read only, no screenshot): .state/e2e-live.txt, one summary line in this log
      if E2E_NO_SHOT=1 /bin/bash "$D/tests/macos/e2e-live-check.sh" "auto-$(date +%m%d-%H%M)" after >/dev/null 2>&1; then
        log "after-call check: PASS (nothing pinned, Krisp back, BetterWispr's panel closed, Wispr's notetaker stopped, no stuck keys)"
      else log "after-call check: see .state/e2e-live.txt"; fi
    }
    # A locked screen hides every window from Accessibility (2026-10-27: the unpin and the tidy-up found no windows),
    # so the window steps wait for the user to unlock (up to 12 hours). BetterWispr's menu still works: its notetaker stops now.
    if screen_locked; then
      bw_stop & wispr_stop & wait
      log "stop: screen locked, the window clean-up waits until it unlocks"
      ( { n=0; while screen_locked && [ "$n" -lt 4320 ]; do sleep 10; n=$((n + 1)); done; sleep 3; after_call
          log "stop: window clean-up done after the unlock"; } >/dev/null 2>&1 & )
      exit 0
    fi
    ( after_call >/dev/null 2>&1 & )
    ;;
  test)
    detect; WHERE="$(place)"; plan
    # v88: the watcher runs this right before "start": the start reuses it (saves a second 1.3 s detect)
    [ -n "$KIND" ] && echo "$(date +%s)|$KIND|$APP|$WHAT|$STRICT|$WHERE|$TITLE" > "$ST/detect.cache"
    echo "kind=${KIND:-none} what=${WHAT:-none} app=${APP:-} window=\"${TITLE:-}\" strict=${STRICT} place=$WHERE layout=${LAYOUT}"
    ;;
  probe)
    detect; echo "detect: kind=${KIND:-none} what=${WHAT:-} window=\"${TITLE:-}\" place=$(place)"; echo "windows:$(probe_line)"
    [ -n "${SHORTCUT_KEEPER_CALL_HOOK:-}" ] && /bin/bash -c "$SHORTCUT_KEEPER_CALL_HOOK" 2>&1 | head -1   # optional: your recorder's status line
    ;;
  *) echo "usage: director.sh start|stop|test|probe|watch-call <session>" ;;
esac
