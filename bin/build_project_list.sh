#!/bin/bash
# Emits "slug|abs_path" one per line for every candidate Claude Code project.
#
# Sources:
#   PROJECTS_ROOT          — primary dir, scanned one level deep.
#                            Default: $HOME/Documents
#   PROJECTS_ROOT_EXTRA    — optional comma-separated extra dirs, each scanned
#                            one level deep. Useful if you keep some projects
#                            in a nested folder (e.g. "$HOME/Documents/Other Projects").
#   PROJECTS_EXCLUDE       — optional comma-separated subdir names to skip
#                            (matches basename, exact). Dotfiles always skipped.

set -uo pipefail

PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Documents}"
PROJECTS_ROOT_EXTRA="${PROJECTS_ROOT_EXTRA:-}"
PROJECTS_EXCLUDE="${PROJECTS_EXCLUDE:-}"

excluded() {
  local name="$1"
  case "$name" in .*) return 0 ;; esac
  [ -z "$PROJECTS_EXCLUDE" ] && return 1
  local IFS=','
  for skip in $PROJECTS_EXCLUDE; do
    # Trim surrounding whitespace.
    skip="${skip## }"; skip="${skip%% }"
    [ "$name" = "$skip" ] && return 0
  done
  return 1
}

emit_dir() {
  local d="$1"
  [ -d "$d" ] || return 0
  local name
  name="$(basename "$d")"
  excluded "$name" && return 0
  echo "${name}|${d%/}"
}

scan_root() {
  local root="$1"
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    emit_dir "$d"
  done
}

{
  scan_root "$PROJECTS_ROOT"
  # Also expose the primary root itself as a selectable target (slug = its
  # basename, e.g. "Documents"), so "Claude Documents" opens a session at the
  # Documents root instead of failing to match any subproject.
  emit_dir "$PROJECTS_ROOT"

  if [ -n "$PROJECTS_ROOT_EXTRA" ]; then
    IFS=',' read -r -a extras <<< "$PROJECTS_ROOT_EXTRA"
    for extra in "${extras[@]}"; do
      # Trim and expand ~ / $HOME if user put literal "~/..." in .env.
      extra="${extra## }"; extra="${extra%% }"
      extra="${extra/#\~/$HOME}"
      scan_root "$extra"
    done
  fi
} | awk -F'|' '!seen[$1]++'
# Dedupe by slug (first occurrence wins). Without this, having the same
# folder name under two scanned roots (e.g. `image-blaster-test` both at
# the top of $HOME/Documents AND inside `$HOME/Documents/Other Projects`)
# emits the slug twice. infer_project.sh resolves the first row, but the
# duplicate is still visible in the router's "Available:" reply menu.
