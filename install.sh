#!/usr/bin/env bash
#
# cc-imessage-control installer — local clone path.
#
# Default: registers the marketplace + installs the plugin via Claude Code's
#          plugin manager, then prints the next-step pointer to
#          /cc-imessage-control setup so the user wires up the trigger
#          interactively (macOS Shortcuts or the Linux systemd listener).
#
# Flags:
#   --plugin-only   Plugin install only (skip the next-step nudge).
#   --dry-run       Print planned actions; write nothing.
#   --force         Re-run even if the plugin reports already installed.
#   --help|-h       Print this help and exit.
#
# Requires:
#   - claude CLI on PATH (Claude Code installs this at ~/.local/bin/claude or similar)
#   - git (claude plugin marketplace add clones the repo)
#
set -euo pipefail

REPO="nathan-hekman/cc-imessage-control"
MARKETPLACE_NAME="cc-imessage-control"
PLUGIN_NAME="cc-imessage-control"

PLUGIN_ONLY=0
DRY=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-only) PLUGIN_ONLY=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//;/^set -e/d'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: 'claude' CLI not found on PATH. Install Claude Code first." >&2
  echo "       https://claude.com/claude-code" >&2
  exit 1
fi

run() {
  if [[ $DRY -eq 1 ]]; then
    echo "+ $*"
  else
    echo "+ $*"
    eval "$@"
  fi
}

echo "cc-imessage-control → install"
echo ""

# 1. Add the marketplace (idempotent — claude handles "already added" gracefully).
run "claude plugin marketplace add $REPO" || true

# 2. Install the plugin.
if [[ $FORCE -eq 1 ]]; then
  run "claude plugin install --force $PLUGIN_NAME@$MARKETPLACE_NAME"
else
  run "claude plugin install $PLUGIN_NAME@$MARKETPLACE_NAME"
fi

echo ""
echo "Plugin installed."

if [[ $PLUGIN_ONLY -eq 1 ]]; then
  exit 0
fi

cat <<'EOF'

Next step — wire up the trigger:

  1. Restart Claude Code (or open a new session).
  2. Run:  /cc-imessage-control setup
  3. The wizard detects your platform (macOS or Linux), collects your
     config, and walks you through Shortcuts.app (macOS) or the systemd
     listener + iPhone Personal Automation (Linux).

Or read the docs first: https://github.com/nathan-hekman/cc-imessage-control
EOF
