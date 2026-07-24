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

# CC_LAUNCH_FLAGS is built dynamically after token extraction (below).
# Set CC_LAUNCH_FLAGS in ~/.claude/.cc-remote-env to override all per-message
# parsing and force a fleet-wide model+effort for every launched session.
# Default: --model opus --effort low (overridable per-message via tokens).
# These flags are word-split into the launch command — baked in, not exported,
# because the new Terminal/tmux shell does not inherit this process's env.

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

# List command: `list` (case-insensitive, optional "skill"/"claude" filler)
# prints the tap-menu the iOS "Card Skill" Shortcut shows when run empty —
# every runnable skill, then every project (prefixed "project: "). One entry
# per line on stdout, nothing launched. Answered even when the kill-switch is
# on, so the menu still populates; the actual launch is re-checked below.
case "$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')" in
  list|"skill list"|"claude list"|"list skills"|"list all")
    log "list command → emitting grouped menu"
    # The iOS "Card Skill" Shortcut shows this when the free-text box is left
    # blank. Clean, spaced skill names GROUPED under category headers, then a
    # short whitelist of real projects — no raw slugs, no junk dirs. Every line
    # is sent back prefixed "pick " by the Shortcut, and `pick` (below) resolves
    # skill-first then project, so the labels need no skill:/project: tag. A
    # tapped "──  Header  ──" line simply resolves to nothing (harmless).
    #
    # cat_of <skill-slug> → its category bucket. Unmapped/new skills fall to
    # "Other" so a brand-new skill still appears (just ungrouped) until sorted.
    cat_of() {
      case "$1" in
        daily-collection-summary|collection-expert|collection-advisor|accept-offers|cardhunt|collector-nerd|stack-health|skill-retro|scrape-retro) echo "Collection" ;;
        ebay|ebay-lookup|purchase-ebay|make-offer|ebay-payment-fix|morning-deals-headline) echo "eBay" ;;
        cy-vault-ship|cy-marketplace-search) echo "Courtyard" ;;
        market-price|market-news|pricecharting) echo "Market" ;;
        update-financials) echo "Money" ;;
        *) echo "Other" ;;
      esac
    }
    _skills="$("$PROJECT_DIR/bin/skill-router.sh" --list 2>/dev/null)"
    for _grp in Collection eBay Courtyard Market Money Other; do
      _printed=0
      while IFS= read -r _s; do
        [ -n "$_s" ] || continue
        [ "$(cat_of "$_s")" = "$_grp" ] || continue
        if [ "$_printed" -eq 0 ]; then echo "──  $_grp  ──"; _printed=1; fi
        echo "$_s" | tr '-' ' '
      done <<EOF_SKILLS
$_skills
EOF_SKILLS
    done
    # Projects: curated whitelist only (override with CC_MENU_PROJECTS, a
    # comma-separated slug list). Keeps ~/Documents junk out of the menu.
    _projects="${CC_MENU_PROJECTS:-scrape-server,ebay-scrape-new,cy-scraper-new,scrape-collection,cc-imessage-control}"
    echo "──  Projects  ──"
    _oldifs="$IFS"; IFS=','
    for _p in $_projects; do
      _p="$(printf '%s' "$_p" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [ -n "$_p" ] && echo "$_p"
    done
    IFS="$_oldifs"
    exit 0
    ;;
esac

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

# `pick <phrase>` — the verb the Card Skill Shortcut sends for BOTH a typed
# free-text answer and a tapped menu label. Resolve skill-FIRST (silent
# --match probe), else fall through to project inference. This keeps the menu
# labels clean (no skill:/project: tags) while staying unambiguous: a real
# skill name runs the skill; anything else (a project name, a header line) is
# handled as a project phrase below. Only bare "pick" gets this treatment, so
# the explicit "Claude <project>" and "skill <name>" keywords are untouched.
case "$msg" in
  [Pp]ick|[Pp]ick\ *|[Pp]ick,*|[Pp]ick:*|[Pp]ick.*)
    _pick="$(printf '%s' "$msg" | sed -E 's/^[Pp]ick[[:space:],:.]*//; s/[[:space:]]+$//')"
    if [ -n "$_pick" ] && "$PROJECT_DIR/bin/skill-router.sh" --match "skill $_pick" >/dev/null 2>&1; then
      log "pick → skill match for '$_pick' → skill-router"
      exec "$PROJECT_DIR/bin/skill-router.sh" "skill $_pick"
    fi
    msg="Claude $_pick"
    log "pick → no skill match; treating as project phrase '$_pick'"
    ;;
esac

# Keyword dispatch: if the message starts with "skill" (case-insensitive),
# hand off to skill-router.sh, which resolves slash commands instead of
# project dirs. This lets a single Siri Shortcut handle both keywords —
# filter for "claude OR skill" and point its shell-script action here.
case "$msg" in
  [Ss][Kk][Ii][Ll][Ll]|[Ss][Kk][Ii][Ll][Ll]\ *|[Ss][Kk][Ii][Ll][Ll],*|[Ss][Kk][Ii][Ll][Ll]:*|[Ss][Kk][Ii][Ll][Ll].*|[Ss][Kk][Ii][Ll][Ll]-*)
    log "keyword 'skill' detected → dispatching to skill-router.sh"
    exec "$PROJECT_DIR/bin/skill-router.sh" "$msg"
    ;;
esac

# Strip leading "Claude" / "claude" (case-insensitive) plus trailing
# punctuation/whitespace.
phrase=$(printf '%s' "$msg" \
  | sed -E 's/^[[:space:]]*[Cc][Ll][Aa][Uu][Dd][Ee][[:space:][:punct:]]*//' \
  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

# Strip optional "code" / "Code" sub-keyword used by the "Claude code <project>"
# Shortcut variant (e.g. "Claude code scrape server sonnet max"). Only strip
# when followed by more content — "Claude code" alone falls through to the menu.
case "$phrase" in
  [Cc][Oo][Dd][Ee]\ ?*)
    phrase="${phrase#* }"
    phrase=$(printf '%s' "$phrase" | sed -E 's/^[[:space:]]+//')
    ;;
esac

# After stripping the "Claude"/"code" trigger prefix, the remaining phrase may
# itself begin with the "skill" keyword (e.g. "Claude code skill update
# financials"). The bare-"skill" dispatch near the top only fires when the raw
# message STARTS with "skill", which on macOS needs a SEPARATE Messages
# automation. Re-checking here lets a single "claude"-filtered automation launch
# skills too — so a follow-up like "Claude code skill update financials" works.
case "$phrase" in
  [Ss][Kk][Ii][Ll][Ll]|[Ss][Kk][Ii][Ll][Ll]\ *|[Ss][Kk][Ii][Ll][Ll],*|[Ss][Kk][Ii][Ll][Ll]:*|[Ss][Kk][Ii][Ll][Ll].*|[Ss][Kk][Ii][Ll][Ll]-*)
    log "keyword 'skill' detected after prefix strip → dispatching to skill-router.sh"
    exec "$PROJECT_DIR/bin/skill-router.sh" "$phrase"
    ;;
esac

log "phrase: '$phrase'"

if [ -z "$phrase" ]; then
  available=$("$LIST" | cut -d'|' -f1 | head -10 | paste -sd, -)
  reply "Which project? Try one of: $available"
  log "empty phrase; sent menu"
  exit 0
fi

# Token extraction: scan each word for optional model, effort, and machine
# tokens. The remaining words form the project phrase for infer_project.sh.
#
# Supported tokens (case-insensitive), with fuzzy synonyms so a natural
# sentence works, not only exact keywords:
#   Model:   opus sonnet haiku fable   (+ fast→haiku, smart/best→opus)  default opus
#   Effort:  max high low normal                                        default high
#   Machine: n8server (+ n8s prod production)  → run on n8server
#            n8bot    (+ bot andi andrea)      → run on n8bot
#
# Routing is SYMMETRIC: whichever Mac receives the message, a machine token
# naming the OTHER Mac forwards the launch there over SSH (passwordless both
# ways). With no machine token the default is CC_DEFAULT_HOST (n8server), so a
# bare phrase opens on the always-on Mac. The project itself is still resolved
# by infer_project.sh (Haiku) from arbitrary phrasing; only the closed sets
# (2 Macs, 4 models) use the synonym table.
#
# NOTE: the bare word "server" is deliberately NOT a machine token — it would
# collide with the scrape-server project. Only the tokens listed above route.
#
# Examples:
#   "scrape server"              → project=scrape-server, opus/high, on n8server (default)
#   "scrape server n8bot"        → project=scrape-server, opus/high, on n8bot
#   "documents n8bot"            → ~/Documents, on n8bot
#   "courtyard on the bot fast"  → cy-scraper-new, haiku, on n8bot
#   "ebay sonnet"                → project=ebay-scrape-new, sonnet, on n8server
_model="${CC_LAUNCH_MODEL:-opus}"
_effort="${CC_LAUNCH_EFFORT:-low}"

_self_host=$(printf '%s' "${CC_MACHINE_PREFIX:-$(hostname -s)}" | tr '[:upper:]' '[:lower:]')
# Default target Mac when no machine token is present. n8server is the
# always-on production runtime, so bare phrases land there.
_target="${CC_DEFAULT_HOST:-n8server}"
_project_phrase=""  # non-semantic words → fed to infer_project.sh

for _word in $phrase; do
  _word_l=$(printf '%s' "$_word" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:punct:]]+$//')
  case "$_word_l" in
    opus|sonnet|haiku|fable)      _model="$_word_l" ;;
    fast)                         _model="haiku" ;;
    smart|best)                   _model="opus" ;;
    max)                          _effort="max" ;;
    high|low|normal)              _effort="$_word_l" ;;
    n8server|n8s|prod|production) _target="n8server" ;;
    n8bot|bot|andi|andrea)        _target="n8bot" ;;
    *) _project_phrase="$_project_phrase $_word" ;;
  esac
done

_project_phrase=$(printf '%s' "$_project_phrase" | sed -E 's/^ +//; s/ +$//')
_target=$(printf '%s' "$_target" | tr '[:upper:]' '[:lower:]')

# Build launch flags from extracted (or default) model and effort.
# A CC_LAUNCH_FLAGS value already in env (from .cc-remote-env) overrides all
# per-message tokens — useful for enforcing a fleet-wide setting.
if [ -n "${CC_LAUNCH_FLAGS:-}" ]; then
  log "using CC_LAUNCH_FLAGS override: $CC_LAUNCH_FLAGS"
else
  CC_LAUNCH_FLAGS="--model $_model --effort $_effort --dangerously-skip-permissions"
fi

log "tokens: model=$_model effort=$_effort target=$_target project='$_project_phrase'"

if [ -z "$_project_phrase" ]; then
  available=$("$LIST" | cut -d'|' -f1 | head -10 | paste -sd, -)
  reply "Which project? (model=$_model effort=$_effort) Try: $available"
  log "empty project phrase after token extraction; sent menu"
  exit 0
fi

# Machine routing (SYMMETRIC). If the resolved target Mac isn't THIS machine,
# forward the launch to it over the peer's HTTP listener (the same
# cc_imessage_listen.py service both Macs already run for the iMessage/Shortcut
# path) and exit. This needs NO ssh-agent and NO extra keys — it reuses the
# shared CC_REMOTE_SECRET. The listener returns 202 immediately and runs the
# launch in its own launchd context, so this call is sub-second.
#
# Per-target listener URLs come from ~/.claude/.cc-remote-env:
#   CC_N8SERVER_URL  (e.g. http://<n8server-tailscale-ip>:8923)
#   CC_N8BOT_URL     (e.g. http://<n8bot-tailscale-ip>:8923)
#
# The forwarded phrase carries an explicit machine token for the target so the
# remote pins to itself and never bounces the launch back here (loop guard).
if [ "$_target" != "$_self_host" ]; then
  _fwd_phrase=$(printf '%s' "$_project_phrase $_model $_effort $_target" \
    | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
  case "$_target" in
    n8server) _fwd_url="${CC_N8SERVER_URL:-}" ;;
    n8bot)    _fwd_url="${CC_N8BOT_URL:-}" ;;
    *)        _fwd_url="" ;;
  esac
  if [ -z "$_fwd_url" ]; then
    _url_var="CC_$(printf '%s' "$_target" | tr '[:lower:]' '[:upper:]')_URL"
    log "ERROR: no forward URL for $_target (set $_url_var in ~/.claude/.cc-remote-env)"
    reply "Can't reach $_target — no listener URL configured ($_url_var)."
    pushover_notify "Claude router: $_target not configured" "Set $_url_var in ~/.claude/.cc-remote-env to forward to $_target." 0
    exit 0
  fi
  log "routing to $_target via $_fwd_url: 'claude $_fwd_phrase'"
  _http_code=$(curl -sf -o /dev/null -w '%{http_code}' -X POST "$_fwd_url/trigger" \
    -H "Authorization: Bearer ${CC_REMOTE_SECRET:-}" \
    --data "claude $_fwd_phrase" --max-time 12 2>>"$LOG_FILE")
  if [ "$_http_code" = "202" ]; then
    log "forwarded to $_target OK (http $_http_code)"
    reply "Routing to $_target: claude $_fwd_phrase ($_model/$_effort)"
    pushover_notify "Claude -> $_target" "claude $_fwd_phrase ($_model/$_effort) on $_target" 0 "claude://code/"
  else
    log "ERROR: forward to $_target failed (HTTP $_http_code)"
    reply "ERROR: forward to $_target failed (HTTP $_http_code)"
    pushover_notify "Claude router: $_target forward failed" "HTTP $_http_code forwarding 'claude $_fwd_phrase' to $_target" 0
  fi
  exit 0
fi

# Home-directory shortcut: the project list only covers ~/Documents (+ Other
# Projects via PROJECTS_ROOT_EXTRA), so "home"/"nathanhekman"/"~" never infer.
# Honor them as a direct launch at $HOME, bypassing inference entirely.
match=""
path=""
case "$(printf '%s' "$_project_phrase" | tr '[:upper:]' '[:lower:]')" in
  home|home\ dir|home\ directory|"~"|"$(id -un)")
    match="$(id -un)"
    path="$HOME"
    log "home-dir shortcut → launching at $path"
    ;;
esac

if [ -z "$match" ]; then
  # Slow-path ack: tell infer_project.sh to send an "[cc-rc] looking up..."
  # iMessage IF it has to fall back to the Haiku call (prefilter miss). Only
  # wire this on macOS — the iMessage sender is no-op elsewhere. The fast
  # path stays silent so deterministic matches don't double up on the
  # eventual "Session started" reply.
  if [ "$PLATFORM" = "Darwin" ]; then
    export CC_REMOTE_SLOW_ACK_MSG="looking up '$_project_phrase'..."
  fi
  match=$("$INFER" "$_project_phrase" 2>>"$LOG_FILE")
  unset CC_REMOTE_SLOW_ACK_MSG
  log "infer → $match"

  _fallback_path="${PROJECTS_ROOT:-$HOME/Documents}"
  if [ -z "$match" ] || [ "$match" = "NONE" ]; then
    log "no project match for '$_project_phrase'; falling back to $_fallback_path"
    match="$(basename "$_fallback_path")"
    path="$_fallback_path"
    reply "No match for '$_project_phrase' — opening $_fallback_path ($_model/$_effort)"
    pushover_notify "Claude router: fallback to Documents" "No match for '$_project_phrase'. Opening $_fallback_path." 0 "claude://code/"
  else
    path=$("$LIST" | awk -F'|' -v s="$match" '$1==s {print $2; exit}')
    if [ -z "$path" ]; then
      log "slug '$match' matched but no path; falling back to $_fallback_path"
      match="$(basename "$_fallback_path")"
      path="$_fallback_path"
      reply "Matched '$match' but path missing — opening $_fallback_path ($_model/$_effort)"
      pushover_notify "Claude router: fallback to Documents" "Slug '$match' had no path. Opening $_fallback_path." 0 "claude://code/"
    fi
  fi
fi

# Make the remote-control slug unique per launch so each Claude session
# gets its own cloud-registry key (mirrors skill-router behavior). Without
# the timestamp, repeated "Claude <project>" texts all register the same
# slug and the iOS app collapses them to a single (often stale) row.
_machine="${CC_MACHINE_PREFIX:-$(hostname -s)}"
slug="${_machine}-${match}-$(date +%Y%m%d-%H%M%S)"

# Launch the Claude session in a native Terminal.app window.
#
# WHY: every iMessage-triggered session opens as a normal Terminal.app window
# on the Mac desktop — one visible window per session, nothing hidden inside a
# multiplexer. (The old behavior launched into a shared "claude" tmux session
# so a phone "tmuxy" web GUI could mirror it; that indirection was confusing
# and was removed. The iOS Claude app's --remote-control path is unaffected —
# it registers via the cloud slug, independent of how the terminal is hosted.)
launch_macos() {
  # Resolve the claude binary explicitly so the new Terminal shell can find it
  # even when ~/.local/bin is not on the default (non-login) PATH.
  local _claude_bin
  _claude_bin=$(command -v claude 2>/dev/null || true)
  if [ -z "$_claude_bin" ]; then
    log "ERROR: claude binary not found in PATH after router PATH export"
    return 1
  fi
  # Build the shell command and hand it to osascript via argv so paths with
  # spaces don't need AppleScript-string escaping.
  local cmd="cd \"$path\" && \"$_claude_bin\" $CC_LAUNCH_FLAGS --remote-control \"$slug\""
  osascript - "$cmd" <<'APPLESCRIPT'
on run argv
  tell application "Terminal"
    activate
    do script (item 1 of argv)
  end tell
end run
APPLESCRIPT
  local _rc=$?
  if [ "$_rc" -ne 0 ]; then
    log "ERROR: Terminal.app launch failed (osascript rc=$_rc)"
    return 1
  fi
  log "launched (Terminal.app): slug=$slug claude=$_claude_bin"
  return 0
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

reply "Session started: $slug ($_model/$_effort). Open Claude iOS: claude://code/"
pushover_notify "Claude session: $slug" "Started in $path with $_model/$_effort. Tap below to open Claude iOS." 0 "claude://code/"
log "launched: $slug at $path with model=$_model effort=$_effort"
