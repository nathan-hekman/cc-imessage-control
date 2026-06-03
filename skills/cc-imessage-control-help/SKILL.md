---
name: cc-imessage-control-help
description: Quick-reference card for cc-imessage-control — what it does, how to install on macOS or Linux, the slash commands, where files live, FAQ. One-shot display, not a persistent mode. Trigger when user asks "/cc-imessage-control help", "what does cc-imessage-control do", "how do I use cc-imessage-control", "claude remote router help".
---

# cc-imessage-control — help

Display this reference. One-shot — do NOT change state, write config, or
persist anything. Plain prose so the card reads as a reference.

## What it does

**Start Claude on your Mac or Linux box from a text.**

Text yourself `Claude api` (or any project name) from your iPhone — a
native iOS/macOS Shortcut catches the keyword and launches
`claude --remote-control "<slug>"` in a fresh terminal on the target
box. You open the iOS Claude app → Code tab → tap the new session
entry → drive the box from anywhere with cell signal. Claude never
sees a message it wasn't explicitly addressed in — no `chat.db`
reading.

## Why this is novel

The Claude iOS app has Remote Control — drive a session on a remote
box from your phone. But you still had to physically be at the box to
*start* the session. This bridge removes that step. **You can spin up
a Claude Code session from the couch, the airport, the trail.**

## Install

```bash
claude plugin marketplace add nathan-hekman/cc-imessage-control
claude plugin install cc-imessage-control@cc-imessage-control
```

Restart Claude Code. Then run `/cc-imessage-control setup` to wire it
into Shortcuts (macOS) or systemd (Linux).

Full docs: https://github.com/nathan-hekman/cc-imessage-control

## Two trigger paths

**macOS (Tier 1, batteries included):** macOS Shortcuts watches your
own iMessage thread for the keyword, runs `claude-router.sh` directly.
No network exposure, no listener, no secret.

**Linux (Tier 2, HTTP over Tailscale):** A tiny Python HTTP listener
on the box accepts `POST /trigger` with a bearer-token header. iPhone
Personal Automation does the same Message → "Get Contents of URL"
shortcut, hitting the listener. Tailscale (or LAN, or a tunnel) keeps
it off the public internet.

## Slash commands

| Command | What |
|---------|------|
| `/cc-imessage-control setup` | Interactive setup wizard. Detects platform, writes config, walks through the trigger surface, runs a self-test. |
| `/cc-imessage-control status` | Shows config, project list, last 5 log lines. Phone number / secret masked. |
| `/cc-imessage-control test` | Runs the router locally with a test phrase (`Claude`) to verify wiring without spawning a session. |
| `/cc-imessage-control tail` | Last 20 lines of `router.log`. |
| `/cc-imessage-control help` | This card. |

## Where files live

- **Plugin install (macOS):** `~/.claude/plugins/cache/cc-imessage-control/cc-imessage-control/<commit>/`
- **Plugin install (Linux):** same path, under the user's home
- **Config:** `~/.claude/.cc-remote-env` (survives plugin updates;
  legacy `~/.claude/.cc-imessage-env` still read for backwards compat)
- **Logs:** `~/.claude/.cc-remote-logs/router.log`
- **systemd unit (Linux):** `~/.config/systemd/user/cc-imessage-control.service`
- **Source:** `bin/claude-router.sh` is the entry point on both
  platforms. `bin/cc_imessage_listen.py` is the Linux HTTP receiver.

## FAQ

**Tailscale / same Wi-Fi?** macOS: no — iMessage uses Apple's push
network. Linux: yes — the iPhone needs to be able to reach the
listener URL. Tailscale is the easiest answer; LAN works if you're
home; a tunnel works if you want public access.

**Does this give Claude access to my whole iMessage history?** No.
macOS: the Shortcuts filter (`Sender = you` + `Message contains
"claude"`) gates triggering. Linux: the listener only receives the
specific message body the iPhone Shortcut posts. No `chat.db`
reading anywhere.

**Can someone else text my Mac/Linux box "claude" and run code?**
macOS: no — Shortcuts filters on your contact card. Linux: no —
the listener requires a `Bearer <secret>` header, and you should
bind it to Tailscale or localhost.

**What does it cost per trigger?** One Claude Haiku 4.5 call (~few
hundred tokens). Well under $0.001 per text. The session itself uses
your normal Claude Code plan.

## Troubleshooting one-liners

- macOS — reply iMessage doesn't arrive → run `bash "${CLAUDE_PLUGIN_ROOT}/bin/imessage_send.sh" "test"` manually. macOS will prompt for Messages automation permission the first time.
- macOS — automation fires but Terminal doesn't open → check `~/.claude/.cc-remote-logs/router.log`. Most common: `claude: command not found` because Shortcuts runs without `.zshrc`. Edit the `export PATH=...` line in `claude-router.sh`.
- macOS — trigger doesn't fire → Shortcuts.app → Automation → confirm the automation is toggled **on** at top-right. macOS sometimes disables them after permission prompts.
- Linux — listener won't start → `systemctl --user status cc-imessage-control.service` and `journalctl --user -u cc-imessage-control.service -n 50`. Most common: `CC_REMOTE_SECRET` unset, or the `ExecStart=` path still references `HEAD` instead of the real install commit dir.
- Linux — POST returns 401 → bearer token mismatch between iPhone Shortcut and `CC_REMOTE_SECRET` in the config file. Copy fresh.
- `infer_project.sh` returns `NONE` every time → run `claude setup-token` to mint a headless OAuth token.
