#!/usr/bin/env node
// cc-imessage-update-check.js — standalone update probe.
//
// Hits GitHub's "latest release" API for nathan-hekman/cc-imessage-control,
// parses the version from the tag (`cc-imessage-control--vX.Y.Z` → `X.Y.Z`),
// compares to the installed plugin.json version, and writes:
//
//   $CLAUDE_CONFIG_DIR/.cc-remote-update-available   contains "X.Y.Z" if newer
//   $CLAUDE_CONFIG_DIR/.cc-remote-update-check       touched on every run (TTL)
//
// Designed to be fire-and-forget from the SessionStart hook so the network
// call never blocks Claude's startup. Quiet-fails on every error.

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24h
const HTTP_TIMEOUT_MS = 4000;
const REPO = 'nathan-hekman/cc-imessage-control';
const TAG_PREFIX = 'cc-imessage-control--v';

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const flagPath = path.join(claudeDir, '.cc-remote-update-available');
const checkPath = path.join(claudeDir, '.cc-remote-update-check');

// Skip if we checked within the TTL window.
try {
  const stat = fs.statSync(checkPath);
  if (Date.now() - stat.mtimeMs < CACHE_TTL_MS) {
    process.exit(0);
  }
} catch (e) { /* no prior check — proceed */ }

let installed;
try {
  const plugin = JSON.parse(
    fs.readFileSync(path.join(__dirname, '..', '.claude-plugin', 'plugin.json'), 'utf8')
  );
  installed = plugin.version || '0.0.0';
} catch (e) {
  process.exit(0);
}

function cmpSemver(a, b) {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (x !== y) return x - y;
  }
  return 0;
}

const req = https.request({
  hostname: 'api.github.com',
  path: `/repos/${REPO}/releases/latest`,
  method: 'GET',
  headers: {
    'User-Agent': 'cc-imessage-control-update-check',
    'Accept': 'application/vnd.github+json',
  },
  timeout: HTTP_TIMEOUT_MS,
}, (res) => {
  let body = '';
  res.on('data', (chunk) => { body += chunk; });
  res.on('end', () => {
    try {
      // Always touch the check file so we honor the TTL even on parse errors.
      fs.writeFileSync(checkPath, String(Date.now()));
      if (res.statusCode !== 200) return;
      const release = JSON.parse(body);
      const tag = release.tag_name || '';
      if (!tag.startsWith(TAG_PREFIX)) return;
      const latest = tag.slice(TAG_PREFIX.length);
      if (!/^\d+\.\d+\.\d+/.test(latest)) return;
      if (cmpSemver(latest, installed) > 0) {
        fs.writeFileSync(flagPath, latest);
      } else {
        try { fs.unlinkSync(flagPath); } catch (e) { /* ignore */ }
      }
    } catch (e) { /* quiet */ }
  });
});

req.on('error', () => { /* offline — silent */ });
req.on('timeout', () => { req.destroy(); });
req.end();
