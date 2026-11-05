#!/bin/bash
# Unit tests for director.sh call detection, with fake window lists (no windows are touched).
#   tests/director-test.sh            prints each case and PASS/FAIL, exit 1 on any failure
# Fake list lines: "Process|window title", "CptHost" (in a Zoom meeting), "MIC|<bundle>" (records from the mic), "MICNONE".
D="$(cd "$(dirname "$0")/.." && pwd)"; F="$(mktemp)"; fail=0
t() {   # name, fake list, expected "kind what layout strict", [place]
  printf '%s\n' "$2" > "$F"
  r="$(DIRECTOR_FAKE="$F" DIRECTOR_PLACE="${4:-laptop}" /bin/bash "$D/director.sh" test)"
  got="$(echo "$r" | sed -E 's/.*kind=([a-z]+) what=(.*) app=.* strict=([01]) place=[a-z]+ layout=(.*)/\1|\2|\4|\3/')"
  if [ "$got" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected $3, got $got"; fail=1; fi
}
PLAIN='Comet|Example Project - Script Editor - Comet'
t "Zoom meeting"                $'CptHost\nzoom.us|Zoom Workplace\nzoom.us|Zoom Meeting'          "video|Zoom|Video call|1"
t "Zoom open, no meeting"       $'zoom.us|Zoom Workplace\n'"$PLAIN"                              "none|none|Video call|1"
t "Meet in a call"              $'Comet|Inbox (12) - Gmail - Comet\nComet|Meet - abc-defg-hij - Comet\nPhone|Phone' "video|Google Meet|Video call|1"
t "Meet idle tab + phone call"  $'Comet|Google Meet - Comet\n'"$PLAIN"$'\nPhone|Phone\nMIC|com.apple.TelephonyUtilities' "audio|Phone|Phone call|0"
t "Meet idle tab, no call"      $'Comet|Google Meet - Comet\n'"$PLAIN"$'\nPhone|Phone\nMICNONE'  "none|none|Video call|1"
t "Teams web meeting"           $'Comet|Meeting with Alex | Microsoft Teams - Comet'            "video|Teams (browser)|Video call|1"
t "Teams app meeting"           $'MSTeams|Chat | Microsoft Teams\nMSTeams|Meeting compact view | Microsoft Teams' "video|Teams|Video call|1"
t "Webex web meeting"           $'Google Chrome|Webex Meeting - Google Chrome'                   "video|Webex (browser)|Video call|1"
t "Zoom web meeting"            $'Google Chrome|Zoom Meeting - Google Chrome'                    "video|Zoom (browser)|Video call|1"
t "Zoom invite tab, no call"    $'Comet|Your Zoom Meeting invite - Gmail - Comet'                "none|none|Video call|1"
t "Slack huddle"                $'Slack|general (Channel) - Slack\nSlack|Huddle: #general - Slack' "video|Slack huddle|Video call|1"
t "Slack huddle pop-out"        $'Slack|Sam Rivera (DM) - Example Co - 1 new item - Slack [Main]\nSlack|Sam Rivera - Example Co - Slack\nMIC|com.tinyspeck.slackmacgap.helper' "video|Slack huddle|Video call|1"
t "Slack huddle still loading"  $'Slack|Sam Rivera (DM) - Example Co - Slack [Main]\nSlack|- Example Co - Slack\nMIC|com.tinyspeck.slackmacgap.helper' "none|none|Video call|1"
t "Slack pop-out, mic idle"     $'Slack|Sam Rivera - Example Co - Slack\nMICNONE'           "none|none|Video call|1"
t "Slack huddle in main window" $'Slack|Sam Rivera (DM) - Example Co - Slack\nMIC|com.tinyspeck.slackmacgap.helper' "none|none|Video call|1"
t "Slack, no huddle"            $'Slack|design-review (Channel) - Example Co - 3 new items - Slack' "none|none|Video call|1"
t "WhatsApp video call"         $'WhatsApp|WhatsApp\nWhatsApp|Video call'                         "video|WhatsApp call|Video call|1"
t "WhatsApp voice call"         $'WhatsApp|WhatsApp\nWhatsApp|Voice call'                         "audio|WhatsApp call|Video call|1"
t "WhatsApp, no call"           $'WhatsApp|WhatsApp'                                              "none|none|Video call|1"
t "FaceTime call"               $'FaceTime|FaceTime\nMIC|com.apple.avconferenced'                 "audio|FaceTime audio|Phone call|0"
t "FaceTime open, no call"      $'FaceTime|FaceTime\nMIC|com.granola.app.helper'                  "none|none|Video call|1"
t "FaceTime + Phone, phone call" $'FaceTime|FaceTime\nPhone|Phone\nMIC|com.apple.TelephonyUtilities' "audio|Phone|Phone call|0"
t "FaceTime + Phone, FaceTime"  $'FaceTime|FaceTime\nPhone|Phone\nMIC|com.apple.FaceTime'         "audio|FaceTime audio|Phone call|0"
t "Phone call"                  $'Phone|Phone\nMIC|com.apple.avconferenced'                       "audio|Phone|Phone call|0"
t "Phone open, no call"         $'Phone|Phone\nMIC|com.electron.wispr-flow.helper'                "none|none|Video call|1"
t "Phone window with no title" $'Phone|\nMIC|com.apple.avconferenced'                            "audio|Phone|Phone call|0"
t "Phone call at the desk"      $'Phone|Phone\nMIC|com.apple.avconferenced'                       "audio|Phone|Desk phone call|0" desk
t "Google Voice call"           $'Comet|Voice - Calls - Comet\nPhone|Phone\nMIC|ai.perplexity.comet.helper' "audio|Google Voice|Video call|1"
t "Google Voice tab, no call"   $'Comet|Voice - Calls - Comet\nMICNONE'                           "none|none|Video call|1"
t "Doc with Voice in its name"  $'Comet|Brand Voice guide - Google Docs - Comet\nMIC|ai.perplexity.comet.helper' "none|none|Video call|1"
t "Meet by name, mic live"      $'Comet|Meet - Planning session with Jordan - Camera and microphone recording - Comet\nMIC|ai.perplexity.comet.helper' "video|Google Meet|Video call|1"
t "Meet by name, high memory"   $'Comet|Meet - Riley / Sam - Camera and microphone recording - High memory usage - 952 MB - Comet\nMICNONE' "video|Google Meet|Video call|1"
t "Meet by name, call left"     $'Comet|Meet - Weekly sync - Comet\nMICNONE'                       "none|none|Video call|1"
t "Meet by name + phone audio"  $'Comet|Meet - Weekly sync - Comet\nPhone|Phone\nMIC|com.apple.TelephonyUtilities' "audio|Phone|Phone call|0"
t "Zoom webinar"                $'CptHost\nzoom.us|Zoom Workplace\nzoom.us|Zoom Webinar'          "video|Zoom|Video call|1"
t "Apple call audio, no window" $'zoom.us|ZM_HUD_TOAST_WINDOW\nMIC|com.apple.avconferenced'     "audio|Phone call (no call window)|Phone call|0"
t "Meet at the desk"            $'Comet|Meet - abc-defg-hij - Comet'                               "video|Google Meet|Desk video call|1" desk
t "Script editor window only"   "$PLAIN"$'\nMIC|ai.perplexity.comet.helper'                        "none|none|Video call|1"
rm -f "$F"; [ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
