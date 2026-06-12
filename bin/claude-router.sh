#!/bin/bash
# claude-router.sh — the main entry point for cc-imessage-control.
#
# Called by:
#   - macOS: Shortcuts "Run Shell Script" action when an incoming iMessage
#     from you matches the keyword filter. Shortcuts passes the message
#     body as $1.
#   - Linux: bin/cc_imessage_listen.py HTTP listener when it receives a
#     POST /trigger with the message body. Listener invokes this script
#     with the body as $1.
#
# Flow (both platforms):
#   1. Load config (~/.claude/.cc-remote-env, falling back to legacy
#      .cc-imessage-env, falling back to repo-local .env).
#   2. Drop messages that start with our reply prefix (loop avoidance —
#      only matters on macOS where we send a reply iMessage back).
#   3. Strip the leading "Claude" / "claude" keyword off the body.
#   4. Ask infer_project.sh which project slug the remaining phrase
#      points to.
#   5. Open a new terminal window: cd <project> && claude --remote-control.
#      macOS uses Terminal.app via AppleScript. Linux tries
#      gnome-terminal / konsole / xterm / kitty / alacritty / tilix /
#      x-terminal-emulator in order, falling back to a detached tmux
#      session when no display is available.
#   6. On macOS only, send a confirmation iMessage back. Linux skips
#      the reply step (per design — the iOS Claude app shows the new
#      session as feedback).

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Logs live in the user's Claude config dir so they survive plugin updates.
# Override with CC_REMOTE_LOG_DIR (legacy CC_IMESSAGE_LOG_DIR) if you want
# them somewhere else.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG_DIR="${CC_REMOTE_LOG_DIR:-${CC_IMESSAGE_LOG_DIR:-$CLAUDE_DIR/.cc-remote-logs}}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$PROJECT_DIR/logs" && mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/router.log"

# Non-interactive shells (Shortcuts on macOS, systemd on Linux) don't load
# the user's .zshrc/.bashrc. Make sure `claude` and friends are findable.
export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Load config. Search order:
#   1. $CC_REMOTE_ENV (explicit override)
#   2. $CC_IMESSAGE_ENV (legacy explicit override)
#   3. $CLAUDE_CONFIG_DIR/.cc-remote-env (preferred — survives plugin updates)
#   4. $CLAUDE_CONFIG_DIR/.cc-imessage-env (legacy location, pre-v0.4.0)
#   5. $PROJECT_DIR/.env (dev fallback — repo-local)
load_env() {
  local f="$1"
  [ -f "$f" ] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  log "loaded config: $f"
  return 0
}

if [ -n "${CC_REMOTE_ENV:-}" ] && load_env "$CC_REMOTE_ENV"; then
  :
elif [ -n "${CC_IMESSAGE_ENV:-}" ] && load_env "$CC_IMESSAGE_ENV"; then
  :
elif load_env "$CLAUDE_DIR/.cc-remote-env"; then
  :
elif load_env "$CLAUDE_DIR/.cc-imessage-env"; then
  :
elif load_env "$PROJECT_DIR/.env"; then
  :
else
  log "WARN: no config file found — using defaults"
fi

SEND="$PROJECT_DIR/bin/imessage_send.sh"
INFER="$PROJECT_DIR/bin/infer_project.sh"
LIST="$PROJECT_DIR/bin/build_project_list.sh"
PREFIX="${REPLY_PREFIX:-${IMESSAGE_PREFIX:-[cc-rc]}}"
PLATFORM="$(uname)"

# Model + reasoning effort for every remote-spawned session. Opus 4.8 at
# "medium" effort by default. Override by setting CC_LAUNCH_FLAGS
# in ~/.claude/.cc-remote-env. These flags are word-split into the launch
# command string below — they MUST be baked into the command, not exported,
# because the new Terminal/tmux shell does not inherit this process's env.
CC_LAUNCH_FLAGS="${CC_LAUNCH_FLAGS:-"--model claude-opus-4-8 --effort medium"}"

# reply <msg> — only sends on macOS; no-op on Linux.
#
# When invoked from the launchd HTTP listener (CC_REMOTE_FROM_LISTENER=1),
# we skip the iMessage reply entirely. macOS TCC blocks AppleEvents
# (osascript -> Messages.app) from a launchd-spawned process, so the call
# hangs for ~60s and then silently fails — burning latency for no user
# benefit. Pushover delivers the same confirmation reliably from any
# context, so it is the canonical reply channel when running headless.
reply() {
  if [ "$PLATFORM" != "Darwin" ]; then
    log "reply (linux, skipped): $1"
    return 0
  fi
  if [ "${CC_REMOTE_FROM_LISTENER:-0}" = "1" ]; then
    log "reply (launchd context, skipped — pushover handles it): $1"
    return 0
  fi
  "$SEND" "$1" || true
}

# pushover_notify <title> <message> [priority] [deep_link]
#   Send a Pushover ping IF a Pushover helper is configured. Set
#   CC_PUSHOVER_HELPER in ~/.claude/.cc-remote-env to the absolute path
#   of a script accepting --title/--message/--priority/--url/--url-title.
#   Used for failure + success surfaces. `deep_link` defaults to
#   claude://code/ which makes the notification's tap target jump
#   straight into the Claude iOS app's Code tab. Pass an empty string
#   to suppress the tap target. Silent no-op if CC_PUSHOVER_HELPER is
#   unset or the file is missing.
pushover_notify() {
  local title="$1" message="$2" priority="${3:-0}" deep_link="${4:-claude://code/}"
  local helper="${CC_PUSHOVER_HELPER:-}"
  if [ -f "$helper" ]; then
    if [ -n "$deep_link" ]; then
      python3 "$helper" --title "$title" --message "$message" --priority "$priority" --url "$deep_link" --url-title "Open Claude iOS" >>"$LOG_FILE" 2>&1 || true
    else
      python3 "$helper" --title "$title" --message "$message" --priority "$priority" >>"$LOG_FILE" 2>&1 || true
    fi
  fi
}

msg="${1:-}"
# Fall back to stdin if the caller piped input rather than passing argv.
if [ -z "$msg" ] && [ ! -t 0 ]; then
  msg="$(cat)"
fi
log "received: $msg"

# Normalize JSON-wrapped payloads. iOS Shortcuts' "Get Contents of URL"
# action commonly POSTs a JSON body like {"phrase":"Claude eBay"} rather
# than raw text. Both the HTTP listener and the macOS Run Shell Script
# action hand us the body verbatim, so a JSON wrapper would otherwise
# become the literal phrase, sail past the "Claude" keyword strip, and
# never match a project — a silent no-op the user experiences as flakiness.
# Unwrap the inner string from the first known text field. Plain-text input
# and non-matching JSON pass through untouched.
case "$msg" in
  '{'*'}')
    if command -v python3 >/dev/null 2>&1; then
      _unwrapped=$(printf '%s' "$msg" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if isinstance(d, dict):
    for k in ("phrase", "text", "message", "body", "msg"):
        v = d.get(k)
        if isinstance(v, str) and v.strip():
            print(v)
            sys.exit(0)
sys.exit(1)
' 2>/dev/null) && [ -n "$_unwrapped" ] && { msg="$_unwrapped"; log "unwrapped JSON payload → $msg"; }
    fi
    ;;
esac

if [ -z "$msg" ]; then
  log "empty message; nothing to do"
  exit 0
fi

# Master kill-switch. `/cc-imessage-control off` creates this file; `on`
# removes it. Skip ALL processing when present so neither claude-router
# nor skill-router fire.
DISABLE_FLAG="$CLAUDE_DIR/.cc-remote-disabled"
if [ -f "$DISABLE_FLAG" ]; then
  log "ignored: cc-imessage-control is OFF (flag at $DISABLE_FLAG)"
  reply "cc-imessage-control is OFF — run /cc-imessage-control on to re-enable"
  pushover_notify "cc-imessage-control OFF — text ignored" "Got: '$msg'. Run /cc-imessage-control on to re-enable." 0
  exit 0
fi

# Loop avoidance: ignore any message that starts with our reply prefix.
case "$msg" in
  "$PREFIX"*)
    log "ignored: matches reply prefix"
    exit 0
    ;;
esac

# Keyword dispatch: if the message starts with "skill" (case-insensitive),
# hand off to skill-router.sh, which resolves slash commands instead of
# project dirs. This lets a single Siri Shortcut handle both keywords —
# filter for "claude OR skill" and point its shell-script action here.
case "$msg" in
  [Ss][Kk][Ii][Ll][Ll]\ *|[Ss][Kk][Ii][Ll][Ll],*|[Ss][Kk][Ii][Ll][Ll]:*|[Ss][Kk][Ii][Ll][Ll].*|[Ss][Kk][Ii][Ll][Ll]-*)
    log "keyword 'skill' detected → dispatching to skill-router.sh"
    exec "$PROJECT_DIR/bin/skill-router.sh" "$msg"
    ;;
esac

# Strip leading "Claude" / "claude" (case-insensitive) plus trailing
# punctuation/whitespace.
phrase=$(printf '%s' "$msg" \
  | sed -E 's/^[[:space:]]*[Cc][Ll][Aa][Uu][Dd][Ee][[:space:][:punct:]]*//' \
  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
log "phrase: '$phrase'"

if [ -z "$phrase" ]; then
  available=$("$LIST" | cut -d'|' -f1 | head -10 | paste -sd, -)
  reply "Which project? Try one of: $available"
  log "empty phrase; sent menu"
  exit 0
fi

# Slow-path ack: tell infer_project.sh to send an "[cc-rc] looking up..."
# iMessage IF it has to fall back to the Haiku call (prefilter miss). Only
# wire this on macOS — the iMessage sender is no-op elsewhere. The fast
# path stays silent so deterministic matches don't double up on the
# eventual "Session started" reply.
if [ "$PLATFORM" = "Darwin" ]; then
  export CC_REMOTE_SLOW_ACK_MSG="looking up '$phrase'..."
fi
match=$("$INFER" "$phrase" 2>>"$LOG_FILE")
unset CC_REMOTE_SLOW_ACK_MSG
log "infer → $match"

if [ -z "$match" ] || [ "$match" = "NONE" ]; then
  available=$("$LIST" | cut -d'|' -f1 | head -10 | paste -sd, -)
  reply "Couldn't match '$phrase'. Try: $available"
  pushover_notify "Claude router: no project match" "Got '$phrase'. Tried: $available" 0
  exit 0
fi

path=$("$LIST" | awk -F'|' -v s="$match" '$1==s {print $2; exit}')
if [ -z "$path" ]; then
  reply "Matched '$match' but no path found. Check build_project_list.sh."
  log "ERROR: no path for slug $match"
  pushover_notify "Claude router: slug-to-path failed" "Matched '$match' but build_project_list.sh did not return a path." 0
  exit 1
fi

# Make the remote-control slug unique per launch so each Claude session
# gets its own cloud-registry key (mirrors skill-router behavior). Without
# the timestamp, repeated "Claude <project>" texts all register the same
# slug and the iOS app collapses them to a single (often stale) row.
slug="${match}-$(date +%Y%m%d-%H%M%S)"

# Launch a new Terminal window running `claude --remote-control "<slug>"`.
#
# IMPLEMENTATION NOTE: we deliberately do NOT use `osascript tell Terminal
# do script ...`. That AppleEvents path is blocked by macOS TCC when the
# router is invoked from a launchd-spawned process (the HTTP listener) —
# the osascript call silently hangs for ~60s then "succeeds" without
# opening any window, which is exactly the flakiness Nathan kept hitting.
#
# Instead we write a one-shot `.command` file and hand it to LaunchServices
# via `open -a Terminal`. LaunchServices does not require AppleEvents
# permission and works identically from foreground shells, launchd agents,
# and cron. The `.command` filename also doubles as the Terminal tab
# title, so we get a readable "Claude-<slug>.command" in the title bar
# without a second AppleScript call.
#
# Launch scripts go under ~/.claude/.cc-remote-launches/. A small reaper
# at the end of this function prunes files older than 24h so the dir
# does not grow unbounded.
launch_macos() {
  local launches_dir="$CLAUDE_DIR/.cc-remote-launches"
  mkdir -p "$launches_dir"
  local cmd_file="$launches_dir/Claude-${slug}.command"
  # Quote $path as a single-quoted bash literal so spaces / unicode
  # survive. Embedded single quotes are escaped via the standard
  # '\'' close-open trick.
  local quoted_path
  quoted_path=$(printf "'%s'" "$(printf '%s' "$path" | sed "s/'/'\\\\''/g")")
  cat > "$cmd_file" <<COMMAND_EOF
#!/bin/bash
# Auto-generated by claude-router.sh — safe to delete.
cd $quoted_path || exit 1
exec claude $CC_LAUNCH_FLAGS --remote-control "$slug"
COMMAND_EOF
  chmod +x "$cmd_file"

  /usr/bin/open -a Terminal "$cmd_file"
  local rc=$?

  # Reap launch scripts older than 24h. Best-effort, never fatal.
  find "$launches_dir" -name '*.command' -type f -mtime +1 -delete 2>/dev/null || true

  return $rc
}

launch_linux() {
  local cmd="cd \"$path\" && claude $CC_LAUNCH_FLAGS --remote-control \"$slug\"; exec \${SHELL:-bash}"

  # Headless box (no display server) — drop into a detached tmux session.
  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    if command -v tmux >/dev/null 2>&1; then
      tmux new-session -d -s "$slug" -c "$path" "claude $CC_LAUNCH_FLAGS --remote-control \"$slug\""
      log "launched (tmux): session $slug"
      return 0
    fi
    log "ERROR: no display and no tmux available"
    return 1
  fi

  # Desktop: try common terminals in preference order.
  for term in x-terminal-emulator gnome-terminal konsole tilix kitty alacritty xterm; do
    if command -v "$term" >/dev/null 2>&1; then
      case "$term" in
        gnome-terminal)
          # gnome-terminal swallows `-e` in recent versions; `--` is the
          # forward-compat form.
          "$term" -- bash -c "$cmd" >/dev/null 2>&1 &
          ;;
        konsole|tilix)
          "$term" -e bash -c "$cmd" >/dev/null 2>&1 &
          ;;
        kitty|alacritty)
          "$term" -e bash -c "$cmd" >/dev/null 2>&1 &
          ;;
        xterm|x-terminal-emulator)
          "$term" -e "bash -c '$cmd'" >/dev/null 2>&1 &
          ;;
      esac
      log "launched ($term): $slug at $path"
      return 0
    fi
  done

  log "ERROR: no terminal emulator found (tried gnome-terminal, konsole, etc.)"
  return 1
}

case "$PLATFORM" in
  Darwin)
    launch_macos
    ;;
  Linux)
    if ! launch_linux; then
      log "FAILED to launch terminal for $slug"
      exit 1
    fi
    ;;
  *)
    log "ERROR: unsupported platform $PLATFORM"
    exit 1
    ;;
esac

reply "Session started in $slug. Open Claude iOS: claude://code/"
pushover_notify "Claude session: $slug" "Started in $path. Tap below to open Claude iOS." 0 "claude://code/"
log "launched: $slug at $path"
