#!/bin/bash
# Example notifier for keeper.py. keeper runs it only when something was fixed, adopted, added or removed, or needs you:
#   SHORTCUT_KEEPER_NOTIFY=examples/notify-example.sh python3 keeper.py --fix
#   $1 = one-line summary, $2 = path of today's report
# Swap the body for your own channel (a chat bot, email, a webhook). This one appends to a log file when
# SHORTCUT_KEEPER_NOTIFY_LOG is set, else shows a macOS notification, else prints.
msg="[shortcut-keeper] $1 (report: $2)"
if [ -n "${SHORTCUT_KEEPER_NOTIFY_LOG:-}" ]; then printf '%s\n' "$msg" >> "$SHORTCUT_KEEPER_NOTIFY_LOG"
elif command -v osascript >/dev/null 2>&1; then osascript -e "display notification \"${1//\"/}\" with title \"Shortcut Keeper\"" >/dev/null 2>&1
else printf '%s\n' "$msg"; fi
