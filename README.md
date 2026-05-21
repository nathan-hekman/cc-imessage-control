<p align="center">
  <img src="docs/assets/cc.png" alt="cc-remote-control logo" width="140">
</p>

<h1 align="center">cc-remote-control</h1>

<p align="center"><strong>Start Claude on your Mac or Linux box from a text.</strong></p>

<p align="center">
  <img src="docs/assets/hero-flow-v2.png" alt="Text 'claude ice cream'; the matching machine opens Claude Code in the project; iOS Claude app shows the live session." width="980">
</p>

---

Claude Code only starts at the keyboard. This plugin lets you text
**"Claude &lt;project&gt;"** to yourself and have your Mac (iMessage)
or Linux box (HTTP over Tailscale) spin up a `/remote-control` session
in that folder — couch, airport, trail, anywhere.

No `chat.db` reading. No third-party messaging service. Sender filter
(macOS) or bearer-token auth (Linux). The router never sees a message
you didn't text yourself.

## Install

```bash
claude plugin marketplace add nathan-hekman/cc-remote-control
claude plugin install cc-remote-control@cc-remote-control
```

Restart Claude Code, then:

```
/cc-remote-control setup
```

5-minute wizard. Detects whether you're on macOS or Linux and walks
the right path.

## Two trigger paths

**macOS — native Shortcuts.** Shortcuts.app watches your own iMessage
thread for the keyword and runs the router directly. No listener, no
secret, no network exposure. ~5 min to set up.

**Linux — HTTP over Tailscale.** A tiny Python HTTP listener accepts
`POST /trigger` with a bearer-token header. iPhone Personal
Automation does the same Message → URL-POST flow, hitting the
listener over your tailnet. Same UX, different transport. ~10 min to
set up.

## Day-to-day

Two keywords. One Shortcut.

**`Claude <project>`** — opens a fresh Claude Code session in that
project dir.

| You text          | Machine opens                      |
|-------------------|------------------------------------|
| `Claude eBay`     | `~/Documents/ebay-scrape-new`      |
| `Claude scraper`  | `~/Documents/cy-scraper-new`       |
| `Claude` (alone)  | macOS texts a project menu; Linux logs a menu |

**`skill <phrase>`** — opens a fresh session AND fires a plugin slash
command in that plugin's project dir. The session is doing real work
the instant it opens.

| You text                | Session opens                                                  |
|-------------------------|----------------------------------------------------------------|
| `skill update fin`      | `~/Documents/scrape-collection`, runs `/update-financials`     |
| `skill courtyard`       | `~/Documents/scrape-collection`, runs `/cy-vault-ship`         |
| `skill morning`         | `~/Documents/scrape-collection`, runs `/morning-deals-headline`|
| `skill daily summary`   | `~/Documents/scrape-collection`, runs `/daily-collection-summary` |

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
| `/cc-remote-control setup`    | Interactive setup wizard                 |
| `/cc-remote-control status`   | Config + project list + recent logs      |
| `/cc-remote-control test`     | Run the router locally, no network       |
| `/cc-remote-control tail`     | Last 20 log lines                        |
| `/cc-remote-control help`     | Reference card                           |

## More

- [INSTALL.md](INSTALL.md) — install reference, per-platform notes,
  dry-run, uninstall
- [SECURITY.md](SECURITY.md) — threat model, what's not protected
- [`.env.example`](.env.example) — config template

## License

[MIT](LICENSE)
