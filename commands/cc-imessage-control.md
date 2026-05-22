---
description: "cc-imessage-control controls — setup wizard, status, on/off toggle, test ping, log tail. Usage: /cc-imessage-control setup | status | on | off | test | tail | help."
argument-hint: "setup | status | on | off | test [phrase] | tail | help"
---

Interpret `$ARGUMENTS` as follows. Match exactly — do not be creative.

If `$ARGUMENTS` is empty or `help`:
- Print a one-line summary of all sub-commands and stop. Do not invoke any skill.
  ```
  /cc-imessage-control setup   → interactive setup wizard
  /cc-imessage-control status  → show config, on/off state, log path, last few log lines
  /cc-imessage-control on      → re-enable iMessage routing (delete the disable flag)
  /cc-imessage-control off     → disable iMessage routing (create ~/.claude/.cc-remote-disabled)
  /cc-imessage-control test    → run the router locally with a test phrase
  /cc-imessage-control tail    → tail the live router log
  ```

If `$ARGUMENTS` is `setup`:
- Invoke the `cc-imessage-control-setup` skill and follow it. On macOS it
  walks the user through writing `~/.claude/.cc-remote-env`, the
  Shortcuts shell-script line, opening Shortcuts.app, and a self-test.
  On Linux it walks through writing the same config, generating an
  HTTP listener secret, installing the systemd user service, and the
  iPhone Personal Automation that POSTs to the box.

If `$ARGUMENTS` is `status`:
- Run `bash "${CLAUDE_PLUGIN_ROOT}/bin/build_project_list.sh"` and show
  the user a clean table of slug → path so they can see which projects
  are reachable. Also show:
  - **enabled state**: report whether `~/.claude/.cc-remote-disabled`
    exists. If present, "DISABLED — routers exit silently". If absent,
    "ENABLED — routers active".
  - whether `~/.claude/.cc-remote-env` exists (and its `REPLY_TARGET` /
    `REPLY_PREFIX` / `ROUTER_MODEL` values, with the phone number
    masked except the last 4 digits). On Linux, also surface
    `CC_REMOTE_BIND` / `CC_REMOTE_PORT` and whether
    `CC_REMOTE_SECRET` is set (don't echo it).
  - last 5 lines of `~/.claude/.cc-remote-logs/router.log` if it exists
  - the absolute path of `claude-router.sh` (i.e. the line on macOS
    Shortcuts, or the ExecStart= path on Linux systemd)

If `$ARGUMENTS` is `off`:
- Create the disable flag:
  ```bash
  touch ~/.claude/.cc-remote-disabled
  echo "Disabled at $(date)" > ~/.claude/.cc-remote-disabled
  ```
- Both `claude-router.sh` and `skill-router.sh` check for this file
  early and exit silently with a "[cc-rc] cc-imessage-control is OFF —
  run /cc-imessage-control on to re-enable" reply iMessage.
- Confirm to the user: "cc-imessage-control is now OFF. Incoming
  `Claude <project>` and `skill <phrase>` texts will be ignored."

If `$ARGUMENTS` is `on`:
- Remove the disable flag:
  ```bash
  rm -f ~/.claude/.cc-remote-disabled
  ```
- Confirm to the user: "cc-imessage-control is now ON. Texting
  `Claude <project>` or `skill <phrase>` will fire normally."

If `$ARGUMENTS` is `test` or `test <phrase>`:
- Default phrase if missing: `Claude help`.
- Run `bash "${CLAUDE_PLUGIN_ROOT}/bin/claude-router.sh" "<phrase>"` in
  a Bash tool call and report what happened. Surface the log delta
  produced by this run (`tail -5 ~/.claude/.cc-remote-logs/router.log`).
- For testing the `skill` path: use `bash
  "${CLAUDE_PLUGIN_ROOT}/bin/skill-router.sh" --dry-run "<phrase>"` so
  no real Terminal session spawns.
- Do not generate a TLDR or HTML one-pager for status/test/tail output
  — these are operational commands.

If `$ARGUMENTS` is `tail`:
- Run `tail -20 ~/.claude/.cc-remote-logs/router.log` and show the
  output verbatim. Then suggest the user run `tail -f` in a real
  terminal if they want a live feed.

Always end with a single-line pointer to the docs: `Full reference: https://github.com/nathan-hekman/cc-imessage-control`.
