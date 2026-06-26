---
name: cc-imessage-control-setup
description: Interactive setup wizard for cc-imessage-control. Detects macOS vs Linux and branches: on macOS, walks through writing config + the Shortcuts Run-Shell-Script line + one automation + a self-test. On Linux, the default path is SSH over Tailscale — detects host/user, ensures sshd + the launcher, helps paste the iPhone's SSH public key, and points to the ready-made CC Remote SSH shortcut; an HTTP-listener path (Python service + systemd unit + bearer token) remains as a fallback. Trigger when the user runs /cc-imessage-control setup, says "set up cc-remote", "configure cc-imessage-control", or asks how to wire a text trigger into Claude Code.
---

# cc-imessage-control — setup wizard

Drive this wizard interactively. Each step has a clear ask, a wait
point, and a verification. Do not run all steps in one shot. Do not
assume any answer.

## Pre-flight (silent — do this before talking to the user)

1. Detect platform:
   ```bash
   PLATFORM="$(uname)"   # Darwin or Linux
   ```
   Branch the rest of the wizard on this.
2. Resolve the absolute install path:
   ```bash
   echo "${CLAUDE_PLUGIN_ROOT}"
   ```
   Save as `INSTALL_PATH`. Shortcuts (macOS) and systemd (Linux) both
   need this exact path.
3. Resolve the config file path:
   - `CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`
   - `CONFIG_FILE="$CONFIG_DIR/.cc-remote-env"`
   - Legacy fallback (pre-v0.4.0): `$CONFIG_DIR/.cc-imessage-env`
4. If `CONFIG_FILE` (or the legacy one) already exists, treat this as
   a re-run and offer to update rather than overwrite. If only the
   legacy file exists, offer to migrate it to the new path.
5. Check that the `claude` CLI is on PATH (`command -v claude`). If
   missing, stop and tell the user to install Claude Code first.
6. On Linux only: check for `python3` (`command -v python3`). The
   HTTP listener needs it. If missing, stop and ask the user to
   install python3 via their package manager.

## Step 1 — Collect shared config (both platforms)

Ask the user three things plainly:

**Q1 — projects root (where to fuzzy-search).** "Where do your code
projects live? When you text 'Claude foo', the router fuzzy-matches
'foo' against folder names one level deep inside this directory.
Default is `$HOME/Documents`. Press enter to accept, or paste a
different path." Validate the path exists (`[ -d "$path" ]`).

**Q2 — extra search dirs (optional).** "Do you keep projects in
*additional* directories? Common case: `~/Documents/Other Projects/`
or `~/code/`. Paste a comma-separated list, or press enter to skip.
Each dir is scanned one level deep, same as the main root." Validate
each path.

**Q3 — exclude list (optional).** "Any folders to *skip* during
fuzzy-match? Useful for things like `node_modules`, `Zoom`, archive
dirs. Paste a comma-separated list of basenames, or press enter to
skip. Dotfiles are always skipped automatically."

**Claude launch mode is not configurable.** The router always runs
`claude --remote-control "<slug>"` — that's the whole point of the
plugin (drive the session from the iOS Claude app). Don't ask the
user about this.

## Step 2A — Collect macOS-specific config

(Skip this step on Linux — Linux replies aren't sent.)

**AskUserQuestion (multi-select=false, two options):**
- "What phone number should I reply to?" — option A: "Same number I'll
  text *from* (typical case)", option B: "A different number".
- If A, ask plainly for the number. If B, ask for both the *trigger*
  number (sender filter) and the *reply* number separately.

Store as `REPLY_TARGET` (E.164 format, e.g. `+15551234567`).

## Step 2B — Linux transport choice + SSH config

(Skip this step on macOS.)

The **default and recommended** Linux transport is **SSH over
Tailscale**: the iPhone runs a native "Run Script over SSH" action
that calls the router on the box. No service, no open port, no custom
code — just `sshd`, which the box already has.

**AskUserQuestion (multi-select=false):** "How should your iPhone
reach this box?"
- Option A (default): **SSH over Tailscale (recommended)** — native
  iOS action, nothing running on the box but `sshd`.
- Option B: **HTTP listener (legacy fallback)** — a small Python
  service + systemd unit behind a bearer token. More moving parts;
  only pick this if SSH is blocked.

If they pick **B**, jump to the listener flow in the appendix at the
bottom of this skill ("Appendix: HTTP listener path") and skip the
rest of the SSH steps.

For **A (SSH)**, gather the three values the phone Shortcut needs.
Detect them — don't make the user guess:

```bash
# Username the phone will log in as:
SSH_USER="$(whoami)"

# Tailnet hostname (preferred) or IP. Try Tailscale first:
SSH_HOST="$(tailscale status --json 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["Self"]["DNSName"].rstrip("."))' 2>/dev/null)"
[ -z "$SSH_HOST" ] && SSH_HOST="$(tailscale ip -4 2>/dev/null | head -1)"
[ -z "$SSH_HOST" ] && SSH_HOST="$(hostname)"

SSH_PORT=22
```

Pre-flight checks, fix inline:
1. **sshd running?**
   ```bash
   systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null
   ```
   If inactive, tell the user the exact enable command for their
   distro (`sudo systemctl enable --now ssh` on Debian/Ubuntu,
   `sshd` on Fedora/Arch) and wait for them to run it.
2. **Tailscale up?**
   ```bash
   tailscale status >/dev/null 2>&1 && echo up || echo down
   ```
   If down or not installed, point them to https://tailscale.com/download
   and have them `tailscale up`, then re-detect `SSH_HOST`.

Show the user the resolved trio and confirm:
"Phone will connect as **`$SSH_USER`@`$SSH_HOST`:`$SSH_PORT`**. Good?"

## Step 3 — Write the config file

Write the values to `$CONFIG_FILE` with proper quoting:

```bash
cat > "$CONFIG_FILE" <<EOF
# cc-imessage-control config
# Generated by /cc-imessage-control setup on $(date -Iseconds)
REPLY_TARGET="<phone-or-empty-on-linux>"
REPLY_PREFIX="[cc-rc]"
ROUTER_MODEL="claude-haiku-4-5-20251001"
PROJECTS_ROOT="<projects-root>"
PROJECTS_ROOT_EXTRA="<extra-or-empty>"
PROJECTS_EXCLUDE="<exclude-or-empty>"
# Linux HTTP-listener fallback only — unused by the SSH path and
# ignored on macOS. Leave empty unless you chose Option B in Step 2B.
CC_REMOTE_BIND="<bind-or-empty>"
CC_REMOTE_PORT="<port-or-empty>"
CC_REMOTE_SECRET="<generated-or-empty>"
EOF
chmod 600 "$CONFIG_FILE"
```

Confirm to the user: "Wrote config to `~/.claude/.cc-remote-env`.
Phone (macOS): `+1 *** *** ####`. SSH (Linux): `$SSH_USER@$SSH_HOST`."

## Step 4 — Sanity-check the project list

Run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/build_project_list.sh"
```

Show the user the first 15 lines. Ask: "Do you see the projects you
want? Anything missing, or anything that shouldn't be there?"

If they want to exclude something, edit `$CONFIG_FILE` to add a
`PROJECTS_EXCLUDE` entry and re-run.

## Step 5A — macOS: print the Shortcuts shell-script line

First, ensure the stable launcher exists (the SessionStart hook writes
it automatically, but a manual run from the wizard is safe and idempotent):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/install-launcher.sh"
```

That creates `$HOME/.claude/cc-imessage-control-launcher.sh`, which is
the stable indirection Shortcuts will pin. The launcher resolves the
actual router via the pin file at `$HOME/.claude/.cc-remote-router-path`,
refreshed every Claude Code session start. This survives plugin version
bumps AND dev-clone renames — historically the #1 source of silent
trigger failures.

Print this to the chat verbatim with a clear "copy this exact line"
instruction:

```
"$HOME/.claude/cc-imessage-control-launcher.sh" "$1"
```

(Use `$HOME` literally — Shortcuts.app's shell expands it correctly.
Don't substitute the absolute path; keeping `$HOME` lets the same line
work if Nathan ever migrates Macs.)

Tell the user: "In a moment we'll open Shortcuts.app. You'll create
one shortcut + one automation. The shortcut needs that exact line
above as its `Run Shell Script` action. Pass Input must be set to
**'as arguments'** — that's the part that makes `$1` work. Because
this points at the stable launcher (not the version-pinned plugin path),
you only have to set it once — future updates won't break it."

## Step 5B — Linux (SSH path): prepare the box side

No service to install — the SSH path reuses `sshd`. Three things:

1. **Ensure the stable launcher exists.** This is the command the
   phone will run over SSH. The SessionStart hook writes it, but run
   it now so it's guaranteed present even before the next session:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/install-launcher.sh"
   test -f "$HOME/.claude/cc-imessage-control-launcher.sh" && echo "launcher OK"
   ```
   The launcher resolves the real router via the pin file at
   `$HOME/.claude/.cc-remote-router-path`, refreshed every Claude Code
   session start. It survives plugin version bumps and dev-clone
   renames — historically the #1 source of silent trigger failures.

2. **Make sure `~/.ssh/authorized_keys` exists** so the public-key
   paste in the next step has somewhere to land:
   ```bash
   mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
   touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
   ```

3. **Print the exact phone-Shortcut config** the user will paste in
   Step 6B. Echo the resolved trio plainly:
   ```
   SSH_HOST = <resolved $SSH_HOST>
   SSH_USER = <resolved $SSH_USER>
   SSH_PORT = <resolved $SSH_PORT>
   Script   = bash ~/.claude/cc-imessage-control-launcher.sh "<PHRASE>"
   ```
   Tell the user these three values go into the three Text fields at
   the top of the **CC Remote SSH** shortcut.

## Step 6A — macOS: open Shortcuts.app and walk through the flow

Ask: "Ready to open Shortcuts.app? (yes / not yet)"

If yes, run:
```bash
osascript -e 'tell application "Shortcuts" to activate'
```

Walk them through, in order:

1. **All Shortcuts** sidebar → **+** → create new shortcut.
2. Drag in a **Run Shell Script** action (search the actions panel).
3. Shell: `zsh` (or `/bin/bash`).
4. Pass Input: **as arguments** (NOT "to stdin").
5. Run as Administrator: **off**.
6. Script: paste the exact line printed in Step 5A.
7. Rename the shortcut to **"Run claude launcher"**.
8. `⌘W` to close.
9. Switch to the **Automation** tab in the sidebar.
10. **+** → New Automation → pick the **Message** trigger.
11. Sender: themselves (their own contact card — this is the safety
    gate that stops anyone else triggering it).
12. Message Contains: `claude` (lowercase — case-insensitive).
13. **Run Immediately** selected.
14. Next → delete any default actions → add **Run Shortcut** →
    `Run claude launcher` → make sure Pass Input is **Shortcut Input**.
15. Done.

**Skills via a bare `skill` message (optional second automation).** The
single `claude` automation above already launches skills when the user
prefixes the trigger — e.g. `Claude code skill update financials` (the
router re-checks for the `skill` keyword after stripping `Claude`/`code`).
To also fire on a bare `skill update financials` with NO `claude` prefix,
add a SECOND Message automation identical to steps 10-15 but with **Message
Contains: `skill`**. A Shortcuts automation allows only one Contains string,
so the two keywords need two automations — both pointing at the same
`Run claude launcher` shortcut. Skip this if always prefixing with `claude`
is fine.

Reference screenshots are in the repo at `docs/screenshots/01-*.jpeg`
through `03-*.jpeg` — link them inline as you walk through.

## Step 6B — Linux (SSH path): the iPhone Shortcut + automation

The iPhone is the trigger source. The user needs (a) the **CC Remote
SSH** shortcut on their phone, (b) the phone's SSH public key added to
the box, and (c) a Message automation that calls the shortcut.

**6B.1 — Get the shortcut onto the phone.** Offer both, recommend the
import:

- **Import (recommended).** The signed shortcut ships in the repo at
  `${CLAUDE_PLUGIN_ROOT}/ios/CC Remote SSH.shortcut`. The user opens it
  on the iPhone — easiest is the raw GitHub link in mobile Safari:
  `https://github.com/nathan-hekman/cc-imessage-control/raw/main/ios/CC%20Remote%20SSH.shortcut`
  Then they tap to add it. After import they edit the three Text
  fields at the top with the trio from Step 5B.
- **Build by hand (5 actions).** If they'd rather not import a file,
  point them at the "Linux setup (SSH over Tailscale)" section of the
  README, which lists the five actions (three Text/Set-Variable
  config rows, an If/Ask-for-Input phrase capture, then **Run Script
  over SSH** + **Show Notification**). The SSH action's Script field
  must be `bash ~/.claude/cc-imessage-control-launcher.sh "<PHRASE>"`
  with the PHRASE variable inserted.

**6B.2 — Authorize the phone's key.** In the shortcut's **Run Script
over SSH** action, the user taps the **SSH Key** field to reveal the
Shortcuts-generated **public key**. Have them copy it and paste it
back to you; append it to the box:
```bash
echo "<pasted-public-key>" >> "$HOME/.ssh/authorized_keys"
```
(Or tell them to run an equivalent `echo >>` themselves.) Confirm the
line landed: `tail -1 "$HOME/.ssh/authorized_keys"`.

**6B.3 — Wire the Message automation (manual, four taps).** Tell the
user, exactly:
1. iPhone → **Shortcuts** → **Automation** tab → **+** → **New
   Automation** → **Message** trigger.
2. Sender: **yourself**. Message Contains: `claude` (lowercase). This
   is the safety gate — only your own texts fire it.
3. **Run Immediately** selected (turn off "Ask Before Running" for
   hands-free).
4. Next → delete default actions → **Run Shortcut** → **CC Remote
   SSH**, Pass Input = **Shortcut Input** (the message text).

An Automation can't be shipped as a file, so this step is always by
hand — but it's just these four taps.

## Step 7 — Self-test

Run the router with a non-matching phrase so we exercise the
infer + reply path without spawning a Terminal/tmux:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/claude-router.sh" "Claude" 2>&1 | tail -5
```

This should produce a router log entry and (on macOS only) send an
iMessage that looks like `[cc-rc] Which project? Try one of: <list>`.

On macOS: ask the user "Did you receive an iMessage from your Mac
(prefixed `[cc-rc]`)?"
On Linux: ask the user "Did the router log show a `phrase: ''` entry
followed by a menu log line? `tail -5 ~/.claude/.cc-remote-logs/router.log`"

- **Yes** → setup is done. Tell them to text "Claude <project>" from
  iPhone next.
- **No** → diagnose:
  - Check `tail -20 ~/.claude/.cc-remote-logs/router.log` for the
    last run's errors.
  - macOS: if a Messages.app permission popup appeared, accept it.
    If `REPLY_TARGET` looks wrong, edit `$CONFIG_FILE`.
  - macOS: if the Automation permission for Shortcuts → Messages
    isn't granted, point them to System Settings → Privacy &
    Security → Automation.
  - Linux (SSH path): confirm the launcher exists
    (`ls -l ~/.claude/cc-imessage-control-launcher.sh`). From the
    phone, the first SSH run will prompt to trust the host — accept
    it. If the SSH action errors, verify the public key is in
    `~/.ssh/authorized_keys`, that `sshd` is active, and that
    Tailscale is up on both phone and box (`tailscale status`).
  - Linux (HTTP fallback): `systemctl --user status cc-imessage-control.service`
    and `journalctl --user -u cc-imessage-control.service -n 50`.

## Step 8 — Wrap up

Print these one-liners they should bookmark:

- `/cc-imessage-control status` — see config + project list + recent logs
- `/cc-imessage-control test` — run the router locally
- `/cc-imessage-control tail` — last 20 log lines

Plus the repo URL: https://github.com/nathan-hekman/cc-imessage-control

## Style

- One step at a time. Wait for the user between steps.
- Surface the actual paths and values you resolved — don't be vague.
- If something errors, show the user the exact line from the log, not
  a paraphrase.
- Don't auto-overwrite an existing config without asking.
- Mask the phone number when echoing config back to the chat
  (`+1 *** *** ####`).
- Never echo the listener secret a second time after generating it.

## Appendix: HTTP listener path (Linux Option B fallback)

Only use this if the user picked **Option B** in Step 2B (SSH is
blocked or unwanted). It runs a small Python service behind a bearer
token instead of using `sshd`. More moving parts and an open inbound
port — that's why SSH is the default.

**A1 — config.** Ask bind/port, generate a secret:
- **Bind address.** `127.0.0.1` (front with a tunnel), the tailnet IP
  / hostname (recommended), or `0.0.0.0` (all interfaces — warn about
  exposure, suggest a firewall rule).
- **Port.** Default `8923`.
- **Secret.** Generate, don't ask: `SECRET=$(openssl rand -hex 32)`.
  Tell the user they'll paste it into the phone automation once and it
  won't be echoed again.

Write `CC_REMOTE_BIND` / `CC_REMOTE_PORT` / `CC_REMOTE_SECRET` into
`$CONFIG_FILE` (Step 3 template already has the keys).

**A2 — systemd user service.**
```bash
mkdir -p "$HOME/.config/systemd/user"
sed "s|/cc-imessage-control/HEAD/|/cc-imessage-control/$(basename "$INSTALL_PATH")/|" \
  "$INSTALL_PATH/systemd/cc-imessage-control.service" \
  > "$HOME/.config/systemd/user/cc-imessage-control.service"
systemctl --user daemon-reload
systemctl --user enable --now cc-imessage-control.service
systemctl --user status cc-imessage-control.service --no-pager
curl -s "http://$CC_REMOTE_BIND:$CC_REMOTE_PORT/healthz"   # → ok
```
For reboot survival without an active login: `sudo loginctl enable-linger "$USER"`.

**A3 — iPhone automation (POST instead of SSH).** Same Message trigger
as 6B.3, but the action is **Get Contents of URL**:
- URL `http://<host>:<port>/trigger`, Method **POST**.
- Headers: `Authorization` = `Bearer <secret>`, `Content-Type` = `text/plain`.
- Request Body **Text** = the **Shortcut Input** magic variable.

Print the listener URL and secret once, then continue to Step 7.
