#!/usr/bin/env python3
"""cc-imessage-control HTTP trigger listener (Linux).

Tiny stdlib HTTP server that turns iPhone Personal Automation iMessage
triggers into calls to claude-router.sh. Designed to run as a systemd
user service behind Tailscale (or a LAN-only bind, or a Cloudflare
Tunnel — your call).

Endpoint:
    POST /trigger      Body: raw text message (e.g. "claude ebay")
                       Header: Authorization: Bearer <secret>
                       Returns 202 Accepted on enqueue, 401 on bad auth,
                       400 on empty body, 404 on wrong path.

Configuration is read from environment (set by the systemd unit, which
sources ~/.claude/.cc-remote-env first):

    CC_REMOTE_BIND     interface to bind on (default: 127.0.0.1)
                       Set to your tailnet IP, 0.0.0.0, or hostname.
    CC_REMOTE_PORT     port (default: 8923)
    CC_REMOTE_SECRET   shared secret. If unset, the listener refuses to
                       start — there is no "no auth" mode by design.

The trigger body is handed verbatim to claude-router.sh as $1, exactly
as Shortcuts on macOS would. The router does its own keyword strip,
project inference, terminal launch.
"""

from __future__ import annotations

import http.server
import os
import secrets
import subprocess
import sys
from pathlib import Path

PORT = int(os.environ.get("CC_REMOTE_PORT", "8923"))
BIND = os.environ.get("CC_REMOTE_BIND", "127.0.0.1")
SECRET = os.environ.get("CC_REMOTE_SECRET", "")
ROUTER = Path(__file__).resolve().parent / "claude-router.sh"
MAX_BODY = 4096  # plenty for a phrase; reject anything huge


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path != "/trigger":
            return self.send_error(404, "unknown path")

        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {SECRET}"
        # Constant-time compare to avoid timing side channels on the token.
        if not secrets.compare_digest(auth, expected):
            return self.send_error(401, "bad token")

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.send_error(400, "bad content-length")
        if length <= 0 or length > MAX_BODY:
            return self.send_error(400, "empty or oversized body")

        body = self.rfile.read(length).decode("utf-8", errors="replace").strip()
        if not body:
            return self.send_error(400, "empty body")

        # Fire-and-forget. The router can take a few seconds (Haiku call,
        # Terminal launch) and we don't want to block the HTTP connection.
        try:
            subprocess.Popen(
                ["bash", str(ROUTER), body],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as e:
            sys.stderr.write(f"[cc-remote] router spawn failed: {e}\n")
            return self.send_error(500, "router spawn failed")

        self.send_response(202)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        self.send_error(404, "POST /trigger only")

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[cc-remote] " + (fmt % args) + "\n")


def main() -> int:
    if not SECRET:
        sys.stderr.write(
            "[cc-remote] CC_REMOTE_SECRET is required; refusing to start. "
            "Set it in ~/.claude/.cc-remote-env.\n"
        )
        return 2
    if not ROUTER.exists():
        sys.stderr.write(f"[cc-remote] router not found at {ROUTER}\n")
        return 2

    sys.stderr.write(f"[cc-remote] listening on {BIND}:{PORT} → {ROUTER}\n")
    http.server.ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
