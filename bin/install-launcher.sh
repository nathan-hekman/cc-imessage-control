#!/usr/bin/env bash
# install-launcher.sh — write a stable launcher + a router-path pin so the
# iOS Shortcut shell-action can call a path that survives plugin version
# bumps AND dev-clone renames.
#
# Why this exists: macOS Shortcuts store the LITERAL absolute path to the
# shell-script they run. Pinning the path to
# `$CLAUDE_PLUGIN_ROOT/bin/claude-router.sh` means every plugin update
# (cache dir = .../<plugin>/<plugin>/<version>/...) silently breaks the
# Shortcut. Pinning to a dev-clone path (e.g. ~/Documents/Other
# Projects/cc-imessage-control/bin/claude-router.sh) means every dir rename
# silently breaks it. We've now been bitten by both. The fix: pin the
# Shortcut at a STABLE path under $HOME/.claude/ that this script writes,
# then refresh-on-SessionStart so the indirection always resolves to the
# current install.
#
# Called by:
#   - SessionStart hook (every Claude Code session) — fire-and-forget.
#   - Manual repair: `bash <plugin_root>/bin/install-launcher.sh`.
#
# Writes:
#   $CLAUDE_CONFIG_DIR/.cc-remote-router-path         pin (one line: abs path to claude-router.sh)
#   $CLAUDE_CONFIG_DIR/cc-imessage-control-launcher.sh  shim Shortcuts point at

set -uo pipefail

# Resolve the plugin root. When called from the SessionStart hook,
# $CLAUDE_PLUGIN_ROOT is the canonical answer. When called manually,
# fall back to this script's parent dir.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
# Strip any trailing slash so the resulting router path is clean
# ("<root>/bin/...", not "<root>//bin/..."). Shortcuts execs either form
# fine, but the double slash shows up in logs + Pushover messages.
PLUGIN_ROOT="${PLUGIN_ROOT%/}"

ROUTER="$PLUGIN_ROOT/bin/claude-router.sh"
if [ ! -x "$ROUTER" ]; then
  echo "install-launcher: router not executable at $ROUTER" >&2
  exit 1
fi

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PIN="$CLAUDE_DIR/.cc-remote-router-path"
LAUNCHER="$CLAUDE_DIR/cc-imessage-control-launcher.sh"

mkdir -p "$CLAUDE_DIR"

# Write the pin atomically so a concurrent launcher read never sees half a
# path. mv across the same filesystem is atomic on macOS / Linux.
tmp=$(mktemp "$CLAUDE_DIR/.cc-remote-router-path.XXXXXX")
printf '%s\n' "$ROUTER" > "$tmp"
mv "$tmp" "$PIN"

# Write the launcher itself. Idempotent — overwrite every session so any
# downstream content fix lands automatically.
cat > "$LAUNCHER" <<'LAUNCHER_SH'
#!/usr/bin/env bash
# cc-imessage-control launcher — stable indirection between iOS Shortcuts
# and the active claude-router.sh install.
#
# AUTO-GENERATED — regenerated on every Claude Code session by
# bin/install-launcher.sh. Do not edit by hand; changes will be overwritten.
#
# Resolution order:
#   1. $CC_REMOTE_ROUTER_OVERRIDE — explicit override for debugging.
#   2. $CLAUDE_CONFIG_DIR/.cc-remote-router-path — the pin file written at
#      install / SessionStart. Single line: absolute path to claude-router.sh.
#   3. Scan plugin caches under ~/.claude/plugins/cache/ — pick the newest
#      (sort -V) cc-imessage-control router; fall back to the legacy
#      claude-imessage-router cache for users who never reinstalled.
#   4. Hard fail: write to ~/.claude/.cc-remote-logs/launcher-error.log AND
#      try a Pushover ping so the user gets a chip on their phone instead of
#      total silence (the failure mode that triggered shipping this fix).
#
# Detach behavior (v0.9.1):
#   The router can take 8–15s (Haiku inference call + Terminal launch +
#   iMessage reply). macOS Shortcuts blocks the iMessage Personal
#   Automation on this script's stdout exit — long script runs presented
#   as "shortcut hangs, session never opens." So once we've located the
#   router we daemonize it (nohup + & + disown) and exit 0 immediately.
#   Shortcuts sees a sub-second action; the actual work runs detached
#   under launchd. Any router failure surfaces via the router's own
#   iMessage reply + Pushover paths, not via this launcher's exit code.

set -u

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PIN="$CLAUDE_DIR/.cc-remote-router-path"
LOG_DIR="${CC_REMOTE_LOG_DIR:-$CLAUDE_DIR/.cc-remote-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
OVERRIDE="${CC_REMOTE_ROUTER_OVERRIDE:-}"

# detach <router_abs_path> <args...>
#   Spawn the router in a fully detached subshell, redirect all std{in,out,err}
#   so Shortcuts doesn't hold the pipe, and exit. nohup blocks SIGHUP when the
#   parent shell ends; the background & ensures we don't block on it; the
#   subshell + disown breaks the job-control association so Shortcuts can't
#   reap the child either. Tested on macOS 14 + bash 3.2.
detach() {
  local router="$1"
  shift
  (
    nohup "$router" "$@" </dev/null >>"$LOG_DIR/launcher.log" 2>&1 &
    disown 2>/dev/null || true
  )
  exit 0
}

if [ -n "$OVERRIDE" ] && [ -x "$OVERRIDE" ]; then
  detach "$OVERRIDE" "$@"
fi

if [ -f "$PIN" ]; then
  # read -r preserves spaces inside the path (Nathan's clone lives under
  # "Other Projects/"). Only strip a trailing CR for cross-platform safety;
  # head | tr would eat the literal spaces and break exec.
  router=""
  IFS= read -r router < "$PIN" || true
  router="${router%$'\r'}"
  if [ -n "$router" ] && [ -x "$router" ]; then
    detach "$router" "$@"
  fi
fi

shopt -s nullglob
candidates=()
for d in "$HOME/.claude/plugins/cache/cc-imessage-control/cc-imessage-control"/*/bin/claude-router.sh \
         "$HOME/.claude/plugins/cache/claude-imessage-router/claude-imessage-router"/*/bin/claude-router.sh; do
  [ -x "$d" ] && candidates+=("$d")
done
if [ "${#candidates[@]}" -gt 0 ]; then
  newest=$(printf '%s\n' "${candidates[@]}" | sort -V | tail -n1)
  detach "$newest" "$@"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] launcher: NO router found. Pin=$PIN Input=$*" \
  >> "$LOG_DIR/launcher-error.log"
helper="$HOME/Documents/scrape-collection/scripts/orchestrator/pushover.py"
if [ -f "$helper" ]; then
  python3 "$helper" \
    --title "cc-imessage-control: launcher broken" \
    --message "Shortcut fired but no router on this Mac. Open Claude Code once to self-heal, or re-run /cc-imessage-control setup." \
    --priority 1 >/dev/null 2>&1 || true
fi
exit 1
LAUNCHER_SH

chmod 755 "$LAUNCHER"
chmod 644 "$PIN"
echo "install-launcher: launcher=$LAUNCHER pin=$ROUTER"
