# Security model, cc-imessage-control

## What this bridge does in security terms

`cc-imessage-control` accepts a single text trigger on your Mac (iMessage Shortcut) or your Linux box (authenticated HTTP POST), matches it against a sender/auth filter, then spawns a terminal running `claude --remote-control` in one of your project directories. It is **not** a remote shell. It does **not** parse the message body as code. It maps the body to one of a fixed list of project slugs (your own folder names) via a Claude Haiku classification.

## Threat model — macOS

| Threat | Mitigated by | Status |
|--------|--------------|--------|
| Someone else triggers your Mac by texting it "claude" | macOS Shortcuts automation filter: `Sender = <your contact>`. Messages from anyone else are ignored before the shell ever runs. | Mitigated |
| Attacker injects shell metacharacters via the message body | The message body is **not** executed. It is passed as `$1` to a shell that uses it only as a prompt to Claude Haiku. Haiku is then constrained to return one slug from a fixed list of your folder names, anything else returns `NONE`. | Mitigated |
| Attacker tricks Haiku into returning a path outside your projects | `infer_project.sh` validates Haiku's response against the slug list built from `build_project_list.sh` (a strict directory enumeration). Hallucinated slugs return `NONE`. | Mitigated |
| Reply iMessage loop (Mac iMessages itself triggering the automation again) | (a) Personal Automation on macOS doesn't fire on Mac-originated messages. (b) Belt-and-suspenders: every reply is prefixed with `REPLY_PREFIX` (default `[cc-rc]`), and incoming messages starting with that prefix are dropped before infer runs. | Mitigated |
| Phone number leaked via plugin install | Config (`.cc-remote-env`) lives in `$CLAUDE_CONFIG_DIR`, **not** in the plugin cache. It is `chmod 600` after the setup wizard writes it. It is never sent over the network. | Mitigated |
| Full iMessage history exfiltration | The router has access to one message at a time, the body of the matched message, passed as `$1`. It never reads `chat.db` or any other Messages storage. | Mitigated |

## Threat model — Linux

| Threat | Mitigated by | Status |
|--------|--------------|--------|
| Random internet host POSTs `/trigger` and runs code on your box | Bearer-token auth: `CC_REMOTE_SECRET` (64-char hex by default) must match a `Authorization: Bearer <secret>` header. `secrets.compare_digest` is used to dodge timing side channels. | Mitigated by token strength |
| Listener exposed to the public internet | Default bind is `127.0.0.1`. Tailscale tailnet IP / hostname is the recommended deployment, which makes the port unreachable to non-tailnet hosts. | Mitigated by default config |
| Replayed POST after token leaks | None at the transport layer. Rotate `CC_REMOTE_SECRET` and restart the service if you suspect token leak. | Not mitigated — rotate-on-suspicion |
| Attacker on your LAN sniffs the bearer token | If you bind to `0.0.0.0` with no TLS, the token is sent in cleartext. Use Tailscale (WireGuard-encrypted), or front the listener with a TLS tunnel (Cloudflare Tunnel, Caddy reverse proxy, ngrok). | Operator-dependent |
| Shell metacharacter injection via POST body | Same protection as macOS — body is passed to the router as `$1`, never `eval`'d. Haiku slug validation applies. | Mitigated |
| Token leak via plugin install | `CC_REMOTE_SECRET` is in `~/.claude/.cc-remote-env` (mode 600), **not** in the plugin cache. Never sent over the network except in the `Authorization` header on inbound POSTs. | Mitigated |

## Cross-platform

| Threat | Mitigated by | Status |
|--------|--------------|--------|
| Compromised plugin update ships malicious code | Plugins install from a git repo via `claude plugin install`. Pin a specific commit by editing `installed_plugins.json`. Audit the diff with `git log` in the marketplace cache. | Partial, relies on trusting this repo |

## Limits, what this does NOT protect against

- A malicious actor with physical access to the Mac or Linux box. Plugin code is on disk, the OAuth token is on disk, the bearer token is on disk.
- A compromised Anthropic Claude Code install. If `claude` itself is malicious, the bridge is the least of your concerns.
- A jailbroken iPhone where someone else can read your iMessages or your Shortcut secrets.
- On Linux, anyone who can read your home directory can read `CC_REMOTE_SECRET`. Trust the box's other users accordingly.

## Reporting issues

If you find a security issue, please **do not** open a public GitHub issue. Open a [private GitHub Security Advisory](https://github.com/nathan-hekman/cc-imessage-control/security/advisories/new) instead, that's the preferred channel. As a fallback you can reach the author at the email listed on [github.com/nathan-hekman](https://github.com/nathan-hekman).

## Auth / credentials reference

| Credential | Where stored | Who can read it |
|-----------|--------------|------------------|
| Claude Code OAuth (headless) | `~/.claude-headless-token` | Your OS user account |
| Phone number (`REPLY_TARGET`) | `~/.claude/.cc-remote-env` (mode 600) | Your OS user account |
| Messages.app automation permission (macOS) | macOS Privacy & Security → Automation | Granted once via TCC prompt |
| Listener bearer token (`CC_REMOTE_SECRET`) | `~/.claude/.cc-remote-env` (mode 600) | Your OS user account, plus anyone who can read your iPhone Shortcut |
