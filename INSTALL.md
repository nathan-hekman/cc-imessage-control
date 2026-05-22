# cc-imessage-control, install reference

Works on macOS (iMessage Shortcuts trigger) and Linux (HTTP listener
behind Tailscale or LAN). The plugin install is identical on both
platforms — the wizard branches by `uname` when you run `setup`.

## Pure Claude Code commands (recommended)

```bash
claude plugin marketplace add nathan-hekman/cc-imessage-control
claude plugin install cc-imessage-control@cc-imessage-control
```

That clones the marketplace into `$CLAUDE_CONFIG_DIR/plugins/marketplaces/cc-imessage-control/`, installs the plugin into `$CLAUDE_CONFIG_DIR/plugins/cache/cc-imessage-control/cc-imessage-control/<commit>/`, and registers it so it shows up in `/plugin list` and in the Claude Code desktop UI.

Restart Claude Code, then:

```
/cc-imessage-control setup
```

The setup wizard detects your platform and walks the right path. ~5
min on macOS, ~10 min on Linux (mostly because of the systemd unit and
the iPhone Shortcut config).

## One-line install (curl | bash)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nathan-hekman/cc-imessage-control/main/install-claude-code.sh)
```

Clones the repo to a temp dir and runs `install.sh --force`. Same end state as the two `claude plugin` commands above. Idempotent, safe to re-run.

## Local clone install

```bash
git clone https://github.com/nathan-hekman/cc-imessage-control.git
cd cc-imessage-control
./install.sh                  # plugin install + next-step pointer
./install.sh --plugin-only    # plugin only, skip the nudge
./install.sh --dry-run        # preview, write nothing
./install.sh --force          # re-run even if already installed
```

## Prerequisites — macOS

| Thing | Why | How to get it |
|------|-----|---------------|
| **macOS 14 (Sonoma) or newer** | Shortcuts Personal Automations + AppleScript Messages support | Already on your Mac if recent |
| **iPhone signed into same iCloud as Mac** | "Sender = me" filter matches; Mac can iMessage you back | Settings → [your name] → iCloud |
| **iMessage active on both devices** | Trigger + reply channel | Messages → Settings → iMessage tab |
| **Claude Code (Pro or Max plan)** | Remote Control is a Pro/Max feature | [claude.com/claude-code](https://claude.com/claude-code) |
| **Claude Code headless OAuth token** | Lets the router call `claude -p` non-interactively from a Shortcut | Run `claude setup-token` once |
| **Your phone number in E.164 format** | Reply target (e.g. `+15551234567`) | You already know it |

## Prerequisites — Linux

| Thing | Why | How to get it |
|------|-----|---------------|
| **Any Linux with systemd + python3** | Listener service + stdlib HTTP server | Already on most distros |
| **A reachable network path from iPhone → box** | Phone Shortcut posts the trigger | Tailscale (recommended), LAN, Cloudflare Tunnel, or ngrok |
| **`openssl` for secret generation** | Wizard generates the bearer token | `apt install openssl` / `dnf install openssl` |
| **Claude Code (Pro or Max plan)** | Remote Control is a Pro/Max feature | [claude.com/claude-code](https://claude.com/claude-code) |
| **Claude Code headless OAuth token** | Lets the router call `claude -p` non-interactively from systemd | Run `claude setup-token` once |
| **A terminal emulator OR tmux** | Where the Claude session lands. Wizard tries `gnome-terminal`, `konsole`, `xterm`, `kitty`, `alacritty`, `tilix`, `x-terminal-emulator`. No `$DISPLAY` → falls back to detached `tmux`. | Distro default usually fine |

## What gets installed where

| Path | Purpose |
|------|---------|
| `$CLAUDE_CONFIG_DIR/plugins/cache/cc-imessage-control/cc-imessage-control/<commit>/` | Plugin install (scripts, hooks, skills, commands) |
| `$CLAUDE_CONFIG_DIR/.cc-remote-env` | Your config (phone, prefix, model, project roots, listener settings) |
| `$CLAUDE_CONFIG_DIR/.cc-remote-logs/router.log` | Append-only run log |
| `$CLAUDE_CONFIG_DIR/.cc-remote-update-available` | Sentinel, written by update-check hook when a newer release exists |
| `~/.config/systemd/user/cc-imessage-control.service` (Linux only) | User-mode systemd unit running the HTTP listener |

`$CLAUDE_CONFIG_DIR` defaults to `~/.claude`. Legacy paths
(`.cc-imessage-env`, `.cc-imessage-logs`) from pre-v0.4.0 installs are
still read for backwards compat.

## Updating

```bash
claude plugin update cc-imessage-control@cc-imessage-control
```

Your config (`.cc-remote-env`) and logs live outside the plugin cache, so they survive updates automatically. On Linux, after a plugin update the systemd unit's `ExecStart=` path will reference the previous commit dir — re-run `/cc-imessage-control setup` so the wizard patches the unit, or `systemctl --user edit cc-imessage-control.service` manually.

## Uninstalling

```bash
claude plugin uninstall cc-imessage-control@cc-imessage-control
```

That removes the plugin from `$CLAUDE_CONFIG_DIR/plugins/cache/`. To fully clean up:

```bash
rm -f ~/.claude/.cc-remote-env ~/.claude/.cc-remote-update-* ~/.claude/.cc-remote-active
rm -rf ~/.claude/.cc-remote-logs

# Linux extras:
systemctl --user disable --now cc-imessage-control.service 2>/dev/null
rm -f ~/.config/systemd/user/cc-imessage-control.service
systemctl --user daemon-reload
```

Then:
- **macOS:** open Shortcuts.app and delete the **Run claude launcher** shortcut and the **Message → claude** automation.
- **Linux:** delete the iPhone Personal Automation pointing at your listener URL.
