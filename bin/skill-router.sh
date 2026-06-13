#!/bin/bash
# skill-router.sh — "skill <phrase>" iMessage entry point for cc-imessage-control.
#
# Companion to claude-router.sh, but resolves the inbound phrase to a SLASH
# COMMAND (not a project dir). Opens a new Terminal.app window cwd'd at the
# owning plugin's project dir, running `claude --remote-control <slug>
# "/<command>"` so the new session shows up in the iOS Claude app instantly
# and is doing real work on open.
#
# Called by:
#   - macOS: Shortcuts "Run Shell Script" action when an incoming iMessage
#     starts with "skill". Either:
#       (a) directly, with $1 = the message body, OR
#       (b) via claude-router.sh's keyword dispatcher (claude-router.sh
#           detects the "skill" prefix and exec's this script).
#   - Linux: bin/cc_imessage_listen.py HTTP listener (same dispatch path).
#
# Why a separate script: claude-router.sh resolves to a PROJECT
# (build_project_list.sh / infer_project.sh) and starts a generic Claude
# session there. This router resolves to a SLASH COMMAND from an installed
# plugin's commands/ directory and bakes the slash-command invocation
# into the launch line.
#
# Compatibility: written for /bin/bash 3.2 (macOS default — Shortcuts uses
# this shell). No associative arrays.
#
# Flags:
#   --dry-run   Resolve and print the launch command; do NOT open Terminal
#               and do NOT send confirmation. For offline testing.
#
# Extending: edit CMD_NAMES + CMD_DIRS + alias_to_cmd() below to add commands
# from other plugins. A future version may scan
# ~/.claude/plugins/cache/*/*/commands/*.md and ~/.claude/settings.json's
# extraKnownMarketplaces for source paths automatically.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG_DIR="${CC_REMOTE_LOG_DIR:-${CC_IMESSAGE_LOG_DIR:-$CLAUDE_DIR/.cc-remote-logs}}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$PROJECT_DIR/logs" && mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/skill-router.log"

# Non-interactive shells (Shortcuts on macOS, systemd on Linux) don't load
# the user's .zshrc/.bashrc. Make `claude` findable.
export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Load config (same precedence as claude-router.sh).
load_env() {
  local f="$1"
  [ -f "$f" ] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  return 0
}
if [ -n "${CC_REMOTE_ENV:-}" ] && load_env "$CC_REMOTE_ENV"; then :
elif [ -n "${CC_IMESSAGE_ENV:-}" ] && load_env "$CC_IMESSAGE_ENV"; then :
elif load_env "$CLAUDE_DIR/.cc-remote-env"; then :
elif load_env "$CLAUDE_DIR/.cc-imessage-env"; then :
elif load_env "$PROJECT_DIR/.env"; then :
fi

PREFIX="${REPLY_PREFIX:-${IMESSAGE_PREFIX:-[cc-rc]}}"
SEND="$PROJECT_DIR/bin/imessage_send.sh"
PLATFORM="$(uname)"

# Model + reasoning effort for every remote-spawned session. Opus 4.8 at
# "extra high" (xhigh) effort by default. Override by setting CC_LAUNCH_FLAGS
# in ~/.claude/.cc-remote-env. These flags are word-split into the launch
# command string below — they MUST be baked into the command, not exported,
# because the new Terminal/tmux shell does not inherit this process's env.
CC_LAUNCH_FLAGS="${CC_LAUNCH_FLAGS:-"--model claude-opus-4-8 --effort xhigh"}"

# reply <msg> — send an iMessage back on macOS; no-op elsewhere.
#
# When invoked from the launchd HTTP listener (CC_REMOTE_FROM_LISTENER=1),
# we skip the iMessage reply entirely. macOS TCC blocks AppleEvents
# (osascript -> Messages.app) from a launchd-spawned process, so the call
# hangs for ~60s and then silently fails — burning latency for no user
# benefit. Pushover delivers the same confirmation reliably from any
# context, so it is the canonical reply channel when running headless.
reply() {
  if [ "$PLATFORM" != "Darwin" ] || [ ! -x "$SEND" ]; then
    log "reply (skipped, non-Darwin or no sender): $1"
    return 0
  fi
  if [ "${CC_REMOTE_FROM_LISTENER:-0}" = "1" ]; then
    log "reply (launchd context, skipped — pushover handles it): $1"
    return 0
  fi
  "$SEND" "$1" >>"$LOG_FILE" 2>&1 || true
}

# pushover_notify <title> <message> [priority] [deep_link]
#   Send a Pushover ping IF a Pushover helper is configured. Set
#   CC_PUSHOVER_HELPER in ~/.claude/.cc-remote-env to the absolute path
#   of a script that accepts --title/--message/--priority/--url/--url-title.
#   Used for failure + success surfaces so the user sees something on
#   their phone even when iMessage reply is silent or filtered.
#   `deep_link` defaults to claude://code/ — tap opens the iOS Claude
#   Code tab. Pass an empty string to suppress the tap target.
#   Silent no-op if CC_PUSHOVER_HELPER is unset or the file is missing.
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

# -------------------------------------------------------------------- registry
#
# CMD_NAMES + CMD_DIRS: parallel arrays mapping each slash command Nathan
# has wired up here to the directory `claude` should cwd to when it fires.
#
# To add a new command from another plugin:
#   1. Append its canonical kebab-case name to CMD_NAMES.
#   2. Append the matching project dir (where you want `claude` to cwd) to
#      CMD_DIRS at the same index.
#   3. Add aliases in alias_to_cmd() below.

CMD_NAMES=(
  "update-financials"
  "daily-collection-summary"
  "morning-deals-headline"
  "cy-vault-ship"
  "heb-curbside-order"
)
CMD_DIRS=(
  "$HOME/Documents/scrape-collection"
  "$HOME/Documents/scrape-collection"
  "$HOME/Documents/scrape-collection"
  "$HOME/Documents/scrape-collection"
  "$HOME/Documents/Other Projects/heb-shopping-skill"
)

# Pure-function alias map. Returns canonical command name or empty string.
alias_to_cmd() {
  case "$1" in
    "financials"|"update financials"|"update fin"|"fin"|"do financials"|"run financials")
      echo "update-financials" ;;
    "collection"|"daily"|"daily collection"|"daily summary"|"collection summary"|"daily collection summary"|"review collection"|"review my collection")
      echo "daily-collection-summary" ;;
    "morning"|"morning deals"|"morning report"|"morning headline"|"deals headline"|"morning deals headline")
      echo "morning-deals-headline" ;;
    "cy"|"vault"|"cy vault"|"cy ship"|"vault ship"|"cy vault ship"|"courtyard"|"courtyard ship"|"courtyard vault"|"ship cy")
      echo "cy-vault-ship" ;;
    "heb"|"heb order"|"heb curbside"|"curbside"|"curbside order"|"groceries"|"grocery"|"grocery order"|"grocery shopping"|"weekly groceries"|"shopping"|"heb shopping"|"order groceries")
      echo "heb-curbside-order" ;;
    *)
      echo "" ;;
  esac
}

cmd_index() {
  local needle="$1"
  local i=0
  for cmd in "${CMD_NAMES[@]}"; do
    if [ "$cmd" = "$needle" ]; then
      echo "$i"
      return 0
    fi
    i=$((i + 1))
  done
  echo "-1"
}

# -------------------------------------------------------------------- input
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

raw_input="${1:-}"
# Fall back to stdin if the caller piped input.
if [ -z "$raw_input" ] && [ ! -t 0 ]; then
  raw_input="$(cat)"
fi
log "Received: '$raw_input' (dry_run=$DRY_RUN)"

if [ -z "$raw_input" ]; then
  log "ERROR: no input"
  reply "skill router: no input from Shortcut."
  exit 1
fi

# Master kill-switch. `/cc-imessage-control off` creates this file; `on`
# removes it. Skip processing when present. (Skip the check in dry-run
# so testing still resolves matches.)
DISABLE_FLAG="$CLAUDE_DIR/.cc-remote-disabled"
if [ "$DRY_RUN" -eq 0 ] && [ -f "$DISABLE_FLAG" ]; then
  log "ignored: cc-imessage-control is OFF (flag at $DISABLE_FLAG)"
  reply "cc-imessage-control is OFF — run /cc-imessage-control on to re-enable"
  pushover_notify "cc-imessage-control OFF — text ignored" "Got: '$raw_input'. Run /cc-imessage-control on to re-enable." 0
  exit 0
fi

# Loop avoidance: ignore replies that came from us.
case "$raw_input" in
  "$PREFIX"*)
    log "ignored: matches reply prefix"
    exit 0
    ;;
esac

# Strip leading "skill" keyword (case-insensitive), tolerating punctuation.
phrase="$(echo "$raw_input" | sed -E 's/^[[:space:]]*[Ss][Kk][Ii][Ll][Ll][[:space:],:.-]+//')"
phrase_norm="$(echo "$phrase" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"
log "Phrase after strip: '$phrase_norm'"

if [ -z "$phrase_norm" ]; then
  available="$(printf '%s, ' "${CMD_NAMES[@]}" | sed 's/, $//')"
  reply "skill router: nothing followed 'skill'. Try: $available"
  exit 1
fi

# -------------------------------------------------------------------- match
match=""

alias_hit="$(alias_to_cmd "$phrase_norm")"
if [ -n "$alias_hit" ]; then
  match="$alias_hit"
  log "Alias hit: '$phrase_norm' -> '$match'"
fi

if [ -z "$match" ]; then
  for cmd in "${CMD_NAMES[@]}"; do
    cmd_words="$(echo "$cmd" | tr '-' ' ')"
    if [ "$phrase_norm" = "$cmd" ] || [ "$phrase_norm" = "$cmd_words" ]; then
      match="$cmd"
      log "Exact-name hit: '$phrase_norm' -> '$match'"
      break
    fi
  done
fi

if [ -z "$match" ]; then
  best_score=0
  best_cmd=""
  for cmd in "${CMD_NAMES[@]}"; do
    cmd_words="$(echo "$cmd" | tr '-' ' ')"
    score=0
    for word in $phrase_norm; do
      if [ ${#word} -lt 3 ]; then continue; fi
      if echo " $cmd_words " | grep -qi " $word "; then
        score=$((score + 1))
      fi
    done
    if [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best_cmd=$cmd
    fi
  done
  if [ -n "$best_cmd" ] && [ "$best_score" -gt 0 ]; then
    match="$best_cmd"
    log "Fuzzy hit (score=$best_score): '$phrase_norm' -> '$match'"
  fi
fi

if [ -z "$match" ]; then
  log "ERROR: no command matched '$phrase_norm'"
  available="$(printf '%s, ' "${CMD_NAMES[@]}" | sed 's/, $//')"
  reply "skill router: no command matched '$phrase'. Available: $available"
  pushover_notify "skill router: no match" "Got 'skill $phrase'. Tried these: $available" 0
  exit 1
fi

# -------------------------------------------------------------------- launch
idx="$(cmd_index "$match")"
project_dir="${CMD_DIRS[$idx]}"

if [ ! -d "$project_dir" ]; then
  log "ERROR: project dir missing for $match: $project_dir"
  reply "skill router: project dir not found for /$match — $project_dir"
  pushover_notify "skill router: project dir missing" "/$match needs $project_dir but it doesn't exist." 0
  exit 1
fi

_machine="${CC_MACHINE_PREFIX:-$(hostname -s)}"
slug="${_machine}-${match}-$(date +%Y%m%d-%H%M%S)"
launch_cmd="cd \"$project_dir\" && claude $CC_LAUNCH_FLAGS --remote-control \"$slug\" \"/$match\""

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would launch: $launch_cmd"
  echo "would-launch: $launch_cmd"
  exit 0
fi

log "Launching: $launch_cmd"

launch_macos() {
  # See claude-router.sh launch_macos for the long-form rationale —
  # short version: AppleEvents to Terminal.app are blocked from the
  # launchd listener context by macOS TCC, so we route through
  # LaunchServices via a `.command` file instead.
  local launches_dir="$CLAUDE_DIR/.cc-remote-launches"
  mkdir -p "$launches_dir"
  local cmd_file="$launches_dir/skill-${slug}.command"
  local quoted_dir
  quoted_dir=$(printf "'%s'" "$(printf '%s' "$project_dir" | sed "s/'/'\\\\''/g")")
  cat > "$cmd_file" <<COMMAND_EOF
#!/bin/bash
# Auto-generated by skill-router.sh — safe to delete.
cd $quoted_dir || exit 1
exec claude $CC_LAUNCH_FLAGS --remote-control "$slug" "/$match"
COMMAND_EOF
  chmod +x "$cmd_file"

  /usr/bin/open -a Terminal "$cmd_file"
  local rc=$?

  find "$launches_dir" -name '*.command' -type f -mtime +1 -delete 2>/dev/null || true
  return $rc
}

launch_linux() {
  local cmd="$launch_cmd; exec \${SHELL:-bash}"
  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    if command -v tmux >/dev/null 2>&1; then
      tmux new-session -d -s "$slug" -c "$project_dir" "claude $CC_LAUNCH_FLAGS --remote-control \"$slug\" \"/$match\""
      return 0
    fi
    return 1
  fi
  for term in x-terminal-emulator gnome-terminal konsole tilix kitty alacritty xterm; do
    if command -v "$term" >/dev/null 2>&1; then
      case "$term" in
        gnome-terminal)   "$term" -- bash -c "$cmd" >/dev/null 2>&1 & ;;
        konsole|tilix)    "$term" -e bash -c "$cmd" >/dev/null 2>&1 & ;;
        kitty|alacritty)  "$term" -e bash -c "$cmd" >/dev/null 2>&1 & ;;
        xterm|x-terminal-emulator) "$term" -e "bash -c '$cmd'" >/dev/null 2>&1 & ;;
      esac
      return 0
    fi
  done
  return 1
}

case "$PLATFORM" in
  Darwin) launch_macos ;;
  Linux)
    if ! launch_linux; then
      log "ERROR: linux launch failed"
      reply "skill router: terminal launch failed"
      pushover_notify "skill router: terminal launch failed" "/$match couldn't open a terminal on this Linux box." 0
      exit 1
    fi
    ;;
  *)
    log "ERROR: unsupported platform $PLATFORM"
    reply "skill router: unsupported platform"
    pushover_notify "skill router: unsupported platform" "Got platform '$PLATFORM' — only macOS + Linux supported." 0
    exit 1
    ;;
esac

reply "skill /$match firing. Session: $slug. Open Claude on iOS: claude://code/"
pushover_notify "skill /$match firing" "Session: $slug. Tap below to open Claude iOS." 0 "claude://code/"
log "Launched OK: slug=$slug match=$match"
