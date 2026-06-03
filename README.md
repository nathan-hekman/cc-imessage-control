<p align="center">
  <img src="docs/assets/cc.png" alt="cc-imessage-control logo" width="140">
</p>

<h1 align="center">cc-imessage-control</h1>

<p align="center"><strong>Start Claude on your Mac or Linux box from a text.</strong></p>

<p align="center">
  <img src="docs/assets/hero-flow-v2.png" alt="Text 'claude ice cream'; the matching machine opens Claude Code in the project; iOS Claude app shows the live session." width="980">
</p>

---

Claude Code only starts at the keyboard. This plugin lets you text
**"Claude &lt;project&gt;"** to yourself and have your Mac (iMessage)
or Linux box (SSH over Tailscale) spin up a `/remote-control` session
in that folder — couch, airport, trail, anywhere.

No `chat.db` reading. No third-party messaging service. Sender filter
(macOS) or SSH key over your private tailnet (Linux). The router never
sees a message you didn't text yourself.

## Install

```bash
claude plugin marketplace add nathan-hekman/cc-imessage-control
claude plugin install cc-imessage-control@cc-imessage-control
```

Restart Claude Code, then:

```
/cc-imessage-control setup
```

5-minute wizard. Detects whether you're on macOS or Linux and walks
the right path.

## Two trigger paths

**macOS — native Shortcuts.** Shortcuts.app watches your own iMessage
thread for the keyword and runs the router directly. No listener, no
secret, no network exposure. ~5 min to set up.

**Linux — SSH over Tailscale.** An iPhone Personal Automation runs a
native **Run Script over SSH** action that calls the router on your
box over your private tailnet. No service to run, no open inbound
port, no custom code — just `sshd`, which your distro already ships.
The setup wizard does the box side for you. ~10 min, mostly the
one-time SSH key paste. See **[Linux setup (SSH over Tailscale)](#linux-setup-ssh-over-tailscale)** below.

## Linux setup (SSH over Tailscale)

The iPhone is the trigger source on Linux. A Personal Automation fires
when you text yourself `Claude <project>`, and runs a small Shortcut
that SSHes into your box and starts the session. The whole box side is
handled by `/cc-imessage-control setup` — this section is the map.

**1. Install + run setup on the Linux box.**

```bash
claude plugin install cc-imessage-control@cc-imessage-control
/cc-imessage-control setup        # detects Linux, runs the SSH path
```

The wizard ensures `sshd` is running, confirms Tailscale is up, writes
your config + project list, and prints the exact three values you'll
paste into the phone Shortcut (host, user, port) plus the SSH-key
instructions.

**2. Get the Shortcut onto your iPhone.** Two ways:

- **Import the ready-made one** — open
  [`ios/CC Remote SSH.shortcut`](ios/CC%20Remote%20SSH.shortcut) on
  the iPhone (AirDrop it, or open the raw GitHub link on the phone).
  Edit the three Text fields at the top (`SSH_HOST`, `SSH_USER`,
  `SSH_PORT`) with the values the wizard printed.
- **Build it by hand** (5 actions) if you'd rather not import a file:

  1. **Text** → your tailnet host (e.g. `my-box.tailnet.ts.net`) →
     *Set Variable* `SSH_HOST`.
  2. **Text** → your username → *Set Variable* `SSH_USER`.
  3. **Text** → `22` → *Set Variable* `SSH_PORT`.
  4. **If** *Shortcut Input* has any value → use it; *Otherwise* **Ask
     for Input** (Text, prompt "Phrase (e.g. claude api)"). *Set
     Variable* `PHRASE`.
  5. **Run Script over SSH** — Host `SSH_HOST`, User `SSH_USER`, Port
     `SSH_PORT`, Authentication **SSH Key**, Script:
     `bash ~/.claude/cc-imessage-control-launcher.sh "<PHRASE>"`
     (insert the `PHRASE` variable). Then **Show Notification**
     "Sent to Claude box: <PHRASE>".

**3. Authorize the key.** Open the SSH action, tap the key field to
reveal the Shortcuts-generated **public key**, and add it to
`~/.ssh/authorized_keys` on the box (the wizard offers to paste it in
for you).

**4. Wire the trigger.** On the iPhone: **Shortcuts → Automation → +
→ Message** trigger, sender = yourself, contains `claude`, **Run
Immediately**, then **Run Shortcut → CC Remote SSH** passing the
message text. (An Automation can't be shipped as a file — this step is
always by hand, but it's four taps.)

**5. Test.** Text yourself `Claude <project>`. The box launches
`claude --remote-control` in a terminal (or detached `tmux` on a
headless box); drive it from the Claude mobile app.

> **Prefer no SSH at all?** An HTTP-listener path (a tiny Python
> service behind a bearer token) still ships in `bin/cc_imessage_listen.py`
> + `systemd/`. It's the older approach — more moving parts, an open
> port — kept as a fallback. The wizard offers it if you decline SSH.

## Day-to-day

Two keywords. One Shortcut.

**`Claude <project>`** — opens a fresh Claude Code session in that
project dir.

| You text          | Machine opens                      |
|-------------------|------------------------------------|
| `Claude api`      | `~/Documents/my-api`               |
| `Claude web`      | `~/Documents/web-app`              |
| `Claude` (alone)  | macOS texts a project menu; Linux logs a menu |

**`skill <phrase>`** — opens a fresh session AND fires a plugin slash
command in that plugin's project dir. The session is doing real work
the instant it opens.

| You text             | Session opens                                          |
|----------------------|--------------------------------------------------------|
| `skill deploy`       | `~/Documents/my-plugin`, runs `/deploy`                |
| `skill report`       | `~/Documents/my-plugin`, runs `/daily-report`          |

(Examples are illustrative — map the keywords to your own projects and
plugin commands in `bin/skill-router.sh`.)

Both keywords route through the same `bin/claude-router.sh`, which
dispatches `skill` → `bin/skill-router.sh`. Use ONE Shortcut whose
iMessage filter matches "Claude" OR "skill" — point its shell-script
step at `bin/claude-router.sh "$1"` and you're done.

To add a `skill` keyword for your own plugin's command, edit
`CMD_NAMES`, `CMD_DIRS`, and `alias_to_cmd()` in
[`bin/skill-router.sh`](bin/skill-router.sh).

New project? Just `mkdir` it under your projects root. No config change.

## Slash commands

| Command                       | What                                     |
|-------------------------------|------------------------------------------|
| `/cc-imessage-control setup`    | Interactive setup wizard                 |
| `/cc-imessage-control status`   | Config + project list + recent logs      |
| `/cc-imessage-control test`     | Run the router locally, no network       |
| `/cc-imessage-control tail`     | Last 20 log lines                        |
| `/cc-imessage-control help`     | Reference card                           |

## More

- [INSTALL.md](INSTALL.md) — install reference, per-platform notes,
  dry-run, uninstall
- [SECURITY.md](SECURITY.md) — threat model, what's not protected
- [`.env.example`](.env.example) — config template

## License

[MIT](LICENSE)
