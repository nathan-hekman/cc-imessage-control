# cc-imessage-control, install reference

Works on macOS (iMessage Shortcuts trigger) and Linux (SSH over
Tailscale by default; HTTP listener as a fallback). The plugin install
is identical on both platforms — the wizard branches by `uname` when
you run `setup`.

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

## Prerequisites — Linux (default: SSH over Tailscale)

| Thing | Why | How to get it |
|------|-----|---------------|
| **`sshd` running** | The iPhone's native "Run Script over SSH" action logs in and runs the router | `sudo systemctl enable --now ssh` (Debian/Ubuntu) or `sshd` (Fedora/Arch) |
| **Tailscale on phone + box, same tailnet** | Private wire so the phone can reach the box anywhere | [tailscale.com/download](https://tailscale.com/download), then `tailscale up` |
| **An iPhone** | Runs the **CC Remote SSH** shortcut + the Message automation. No paid app — the SSH action is built into iOS Shortcuts | — |
| **Claude Code (Pro or Max plan)** | Remote Control is a Pro/Max feature | [claude.com/claude-code](https://claude.com/claude-code) |
| **Claude Code headless OAuth token** | Lets the router call `claude -p` non-interactively over SSH | Run `claude setup-token` once |
| **A terminal emulator OR tmux** | Where the Claude session lands. Wizard tries `gnome-terminal`, `konsole`, `xterm`, `kitty`, `alacritty`, `tilix`, `x-terminal-emulator`. No `$DISPLAY` → falls back to detached `tmux`. | Distro default usually fine |

**Fallback (HTTP listener) extras** — only if you decline SSH in the
wizard: `systemd` + `python3` (for the listener service) and `openssl`
(to generate the bearer token). See the wizard's "Appendix: HTTP
listener path".

## What gets installed where

| Path | Purpose |
|------|---------|
| `$CLAUDE_CONFIG_DIR/plugins/cache/cc-imessage-control/cc-imessage-control/<commit>/` | Plugin install (scripts, hooks, skills, commands) |
| `$CLAUDE_CONFIG_DIR/.cc-remote-env` | Your config (phone, prefix, model, project roots, listener settings) |
| `$CLAUDE_CONFIG_DIR/.cc-remote-logs/router.log` | Append-only run log |
| `$CLAUDE_CONFIG_DIR/.cc-remote-update-available` | Sentinel, written by update-check hook when a newer release exists |
| `~/.claude/cc-imessage-control-launcher.sh` | Stable launcher the SSH path (and macOS Shortcut) calls |
| `~/.config/systemd/user/cc-imessage-control.service` (Linux, HTTP fallback only) | User-mode systemd unit running the HTTP listener |

`$CLAUDE_CONFIG_DIR` defaults to `~/.claude`. Legacy paths
(`.cc-imessage-env`, `.cc-imessage-logs`) from pre-v0.4.0 installs are
still read for backwards compat.

## Updating

```bash
claude plugin update cc-imessage-control@cc-imessage-control
```

Your config (`.cc-remote-env`) and logs live outside the plugin cache, so they survive updates automatically. The SSH path is update-proof: the phone calls the stable `~/.claude/cc-imessage-control-launcher.sh`, which re-resolves the router on every Claude Code session start. (HTTP-fallback users only: after an update the systemd unit's `ExecStart=` path references the previous commit dir — re-run `/cc-imessage-control setup` so the wizard patches the unit, or `systemctl --user edit cc-imessage-control.service` manually.)

## Uninstalling

```bash
claude plugin uninstall cc-imessage-control@cc-imessage-control
```

That removes the plugin from `$CLAUDE_CONFIG_DIR/plugins/cache/`. To fully clean up:

```bash
rm -f ~/.claude/.cc-remote-env ~/.claude/.cc-remote-update-* ~/.claude/.cc-remote-active
rm -rf ~/.claude/.cc-remote-logs

# Linux SSH path: remove the phone's public key line from authorized_keys
#   (edit ~/.ssh/authorized_keys and delete the line you pasted in).
# Linux HTTP fallback only:
systemctl --user disable --now cc-imessage-control.service 2>/dev/null
rm -f ~/.config/systemd/user/cc-imessage-control.service
systemctl --user daemon-reload
```

Then:
- **macOS:** open Shortcuts.app and delete the **Run claude launcher** shortcut and the **Message → claude** automation.
- **Linux:** on the iPhone, delete the **CC Remote SSH** shortcut and the Message automation that calls it (HTTP-fallback users: the automation that POSTs to your listener URL).
