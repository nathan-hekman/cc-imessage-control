#!/bin/bash
# Marks a project directory as trusted in ~/.claude.json before a remote-launched
# session opens there.
#
# Why this exists: Claude Code asks "Is this a project you created or one you
# trust?" the first time it runs in a directory, and blocks on that prompt
# before the session boots. --dangerously-skip-permissions does not cover it.
# A session launched from an iMessage trigger has nobody at the keyboard, so it
# sits on the prompt forever: the process is alive, the Terminal window is open,
# and the session never registers with Remote Control — so from the phone it
# looks like nothing launched at all. That is exactly what happened to
# fanatics-scraper on 2026-08-17 (two sessions stuck 80+ minutes).
#
# Scope: a path is only trusted if build_project_list.sh already emits it, i.e.
# it is one of Nathan's own project dirs under PROJECTS_ROOT /
# PROJECTS_ROOT_EXTRA. Anything else is left alone and the prompt still fires.
# The router can only ever launch into a path from that list, so this grants
# nothing the router could not already open — it just answers, up front, the
# question no one is there to answer.
#
# Usage: pretrust_project.sh <abs-path>
# Exit 0 when the path ends up trusted (including "already was"), 1 otherwise.
# Never fatal to the caller: a failure here means the old stuck-prompt
# behaviour, not a failed launch.

set -uo pipefail

target="${1:-}"
[ -n "$target" ] || { echo "pretrust: no path given" >&2; exit 1; }

# Normalise: strip any trailing slash so it matches the project-list form.
target="${target%/}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only ever trust a directory the project list already knows about.
if ! "$here/build_project_list.sh" 2>/dev/null \
     | cut -d'|' -f2- | grep -qxF "$target"; then
  echo "pretrust: $target is not in the project list; leaving it untrusted" >&2
  exit 1
fi

CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
[ -f "$CLAUDE_JSON" ] || { echo "pretrust: no $CLAUDE_JSON" >&2; exit 1; }

python3 - "$CLAUDE_JSON" "$target" <<'PY'
import json, os, sys, tempfile

path, target = sys.argv[1], sys.argv[2]

with open(path) as fh:
    data = json.load(fh)

projects = data.setdefault("projects", {})
entry = projects.setdefault(target, {})

if entry.get("hasTrustDialogAccepted") is True:
    print("pretrust: already trusted")
    sys.exit(0)

entry["hasTrustDialogAccepted"] = True

# Every live Claude session rewrites this file, so write a temp file in the
# same directory and rename it into place — a reader never sees a half-written
# config, and a concurrent writer loses at most this one flag rather than
# corrupting the file.
directory = os.path.dirname(path) or "."
with tempfile.NamedTemporaryFile("w", dir=directory, delete=False) as tmp:
    json.dump(data, tmp, indent=2)
    tmp_path = tmp.name
os.replace(tmp_path, path)
print(f"pretrust: trusted {target}")
PY
