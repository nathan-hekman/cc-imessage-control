# Releasing cc-imessage-control

The release process and the format every GitHub Release notes page follows.

## Release notes, format

Same shape every time, top to bottom:

1. **Hero image at the very top.** A screenshot or stamped graphic, **attached as a release asset** (NOT committed to the repo), embedded via the release-download URL.
2. **TLDR block**, three short, plain-English bullets. Twelve words max each. No jargon.
3. **What's new**, three to five short bullets, plain English, "you can now…" voice. Upbeat.
4. **How to update**, one shell snippet.
5. **Compare link** at the very bottom, single line.

## Asset hosting, release assets, NOT the repo

**Never commit hero PNGs to `main`.** Binaries in git history bloat clones forever, slow plugin installs, and punish every fork. Instead, attach them as **release assets** on the GitHub Release.

Asset URL pattern:

```
https://github.com/nathan-hekman/cc-imessage-control/releases/download/cc-imessage-control--v<X.Y.Z>/v<X.Y.Z>.png
```

## Voice

- Upbeat but calm. "Yeah, this one's nice." Not the rocket-and-confetti SaaS holler.
- ELI8. A twelve-year-old should grok the bullets.
- No exclamation marks anywhere.
- No emoji.
- One sentence per bullet. One idea per sentence.

## Release flow

1. Update `version` in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`. They must match.
2. Stage a hero PNG locally (don't commit it, attach to the release).
3. Commit + push the code changes to `main`. **Do not commit the PNG.**
4. Tag:
   ```bash
   git tag cc-imessage-control--vX.Y.Z
   git push origin cc-imessage-control--vX.Y.Z
   ```
5. Create the GitHub Release:
   ```bash
   gh release create cc-imessage-control--vX.Y.Z \
     --title "cc-imessage-control vX.Y.Z, <short tagline>" \
     --notes "$(cat release-notes.md)"
   ```
6. Upload the hero PNG as a release asset:
   ```bash
   gh release upload cc-imessage-control--vX.Y.Z /tmp/vX.Y.Z.png --clobber
   ```
   Rename the file `vX.Y.Z.png` first so the asset URL is predictable.
7. Verify the hero image renders on the release page. Refresh once; GitHub caches eagerly.

## Release notes template

```markdown
![vX.Y.Z hero](https://github.com/nathan-hekman/cc-imessage-control/releases/download/cc-imessage-control--vX.Y.Z/vX.Y.Z.png)

---

**TLDR**

- short plain bullet
- another short plain bullet
- one more (optional, max three)

---

**What's new**

- you can now …
- the bridge is …
- and one bonus …

**How to update**

\`\`\`bash
claude plugin update cc-imessage-control@cc-imessage-control
\`\`\`

[Full diff](https://github.com/nathan-hekman/cc-imessage-control/compare/cc-imessage-control--v<PREV>...cc-imessage-control--v<THIS>)
```
