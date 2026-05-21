#!/bin/bash
# Send an iMessage to $REPLY_TARGET (or legacy $IMESSAGE_TARGET), prefixed with
# $REPLY_PREFIX (or legacy $IMESSAGE_PREFIX). Mac-only: uses AppleScript to
# drive Messages.app. On Linux the router skips the reply step entirely.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 \"<message>\"" >&2
  exit 1
fi

target="${REPLY_TARGET:-${IMESSAGE_TARGET:-}}"
if [ -z "$target" ]; then
  echo "REPLY_TARGET (or legacy IMESSAGE_TARGET) env var required" >&2
  exit 1
fi
prefix="${REPLY_PREFIX:-${IMESSAGE_PREFIX:-[cc-rc]}}"
body="$1"
full="${prefix} ${body}"

escaped=$(printf '%s' "$full" | sed 's/\\/\\\\/g; s/"/\\"/g')

osascript <<EOF
tell application "Messages"
    set targetService to 1st service whose service type = iMessage
    set targetBuddy to buddy "${target}" of targetService
    send "${escaped}" to targetBuddy
end tell
EOF
