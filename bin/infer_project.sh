#!/bin/bash
# Map a short phrase to a project slug.
# Usage: infer_project.sh "<phrase>"
# Stdout: one slug, or "NONE".
#
# Strategy (v0.9.1):
#   1. Deterministic prefilter — walks the slug list and scores each one
#      by how many phrase tokens appear inside it. Unambiguous winners
#      bypass the model entirely. This is fast (<10ms) AND fixes a class
#      of bugs where Haiku punted to NONE on ambiguous phrases like
#      "Dinosaur" (matches Dinosaur-iOS + Dinosaur-AppleTV) or
#      "cert lookup" (matches both PSA cert extensions).
#   2. Tiebreak — among slugs that match the same number of tokens, the
#      shortest slug wins. "hydra" → hydra (not hydra-poc-claude).
#      "Dinosaur" → Dinosaur-iOS (12 chars < 16).
#   3. Fallback to claude -p Haiku — for novel phrases the prefilter
#      can't score (e.g. semantic match: "courtyard" → cy-scraper-new).
#      The Haiku output is parsed leniently: scan the response for ANY
#      valid slug substring, not strict equality. Stops the "Haiku
#      replied with a sentence so we returned NONE" failure mode.

set -uo pipefail

phrase="${1:-}"
if [ -z "$phrase" ]; then
  echo "NONE"
  exit 0
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIST_SCRIPT="$PROJECT_DIR/bin/build_project_list.sh"
MODEL="${ROUTER_MODEL:-claude-haiku-4-5-20251001}"

# Materialize the slug list once; pipefail-safe with set -u.
slug_blob="$("$LIST_SCRIPT" 2>/dev/null | cut -d'|' -f1 | sort -u)"
if [ -z "$slug_blob" ]; then
  echo "NONE"
  exit 0
fi

# ---------------------------------------------------------------- prefilter
#
# Build a normalized phrase: lowercase, collapse whitespace, trim.
phrase_lower=$(printf '%s' "$phrase" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -s '[:space:]' ' ' \
  | sed -E 's/^ +//; s/ +$//')

best_slug=""
best_score=0
best_len=0

# Walk each slug. For each:
#   - tokenized slug = slug with '-' and '_' replaced by spaces, lowercased
#   - count phrase tokens that appear either (a) as a whole word in the
#     tokenized slug or (b) as a substring of the original slug
#   - score = matched_tokens; only consider slugs that match ALL tokens
#   - if equal to current best score, prefer the shorter slug
while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  slug_lower=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  slug_dashed=" $(printf '%s' "$slug_lower" | sed 's/[-_]/ /g') "

  # Exact-name short-circuit (case-insensitive).
  if [ "$phrase_lower" = "$slug_lower" ]; then
    echo "$slug"
    exit 0
  fi

  total=0
  matched=0
  for word in $phrase_lower; do
    total=$((total + 1))
    # 1-char tokens contribute too little signal; skip them but don't fail.
    if [ ${#word} -lt 2 ]; then
      total=$((total - 1))
      continue
    fi
    case "$slug_dashed" in
      *" $word "*)
        matched=$((matched + 1))
        continue
        ;;
    esac
    case "$slug_lower" in
      *"$word"*)
        matched=$((matched + 1))
        ;;
    esac
  done

  if [ "$total" -gt 0 ] && [ "$matched" -eq "$total" ]; then
    len=${#slug}
    if [ "$matched" -gt "$best_score" ]; then
      best_score=$matched
      best_slug=$slug
      best_len=$len
    elif [ "$matched" -eq "$best_score" ] && [ -n "$best_slug" ] && [ "$len" -lt "$best_len" ]; then
      # Tiebreak: shortest slug wins. Closer to a literal match, avoids
      # n8-sidescroller-game when phrase is "sidescroller", etc.
      best_slug=$slug
      best_len=$len
    fi
  fi
done <<EOF
$slug_blob
EOF

if [ -n "$best_slug" ]; then
  echo "$best_slug"
  exit 0
fi

# ------------------------------------------------------------ Haiku fallback
#
# Slow-path ack: prefilter missed, so we're about to spend 6–10s on a
# Haiku call. Fire an "[cc-rc] looking up '<phrase>'..." iMessage now so
# the user sees acknowledgment instead of dead silence between the text
# they sent and the eventual "Session started" reply. Gated by the
# CC_REMOTE_SLOW_ACK_MSG env var set by claude-router.sh — keeps this
# script reusable in contexts where Messages.app isn't available
# (Linux, CI smoke tests, --dry-run callers).
if [ -n "${CC_REMOTE_SLOW_ACK_MSG:-}" ]; then
  ACK_SENDER="$PROJECT_DIR/bin/imessage_send.sh"
  if [ -x "$ACK_SENDER" ]; then
    "$ACK_SENDER" "$CC_REMOTE_SLOW_ACK_MSG" >/dev/null 2>&1 || true
  fi
fi

# Non-interactive `claude -p` needs the long-lived headless OAuth token
# (set up once with `claude setup-token`). When this script is invoked
# from inside another Claude Code session the parent injects
# ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL pointing at the session's
# managed proxy — those creds aren't valid for normal CLI use, so wipe
# them and let the headless token take over.
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
HEADLESS_TOKEN_FILE="$HOME/.claude-headless-token"
if [ -f "$HEADLESS_TOKEN_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$HEADLESS_TOKEN_FILE"
  set +a
fi

slug_csv=$(printf '%s' "$slug_blob" | paste -sd, -)

read -r -d '' prompt <<EOF || true
You map a short user phrase to ONE project slug from a fixed list, or "NONE" if nothing fits.

Valid slugs: $slug_csv

Phrase: "$phrase"

Hints:
- "ebay" / "ebay-scrape" / "scrape" → ebay-scrape-new
- "cy" / "courtyard" / "cy-scraper" → cy-scraper-new
- "server" / "scrape-server" / "hub" → scrape-server
- "ios" / "safari extension" / "ios extension" → ios-psa-cert-lookup-extension
- "chrome" / "chrome extension" → psa-cert-lookup-chrome-extension
- "psa-shared" / "shared" → psa-shared

Reply with exactly one slug from the list (or the literal word NONE).
No quotes, no punctuation, no explanation, no other text.
EOF

raw=$(claude -p --model "$MODEL" "$prompt" 2>/dev/null)
if [ -z "$raw" ]; then
  echo "NONE"
  exit 0
fi

# Lenient parse: first try the strict tokenized response (the model usually
# does what it's told). If that fails to match a valid slug, scan the raw
# response for any valid slug as a whole-word substring — handles the case
# where Haiku adds prose despite the instruction.
strict=$(printf '%s' "$raw" | tr -d '"' | tr -d "'" | tr -d '[:space:]')
if printf '%s\n' "$slug_blob" | grep -Fxq "$strict"; then
  echo "$strict"
  exit 0
fi

while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  case " $raw " in
    *" $slug "*|*$'\n'"$slug "*|*" $slug"$'\n'*|*$'\n'"$slug"$'\n'*)
      echo "$slug"
      exit 0
      ;;
  esac
done <<EOF
$slug_blob
EOF

echo "NONE"
