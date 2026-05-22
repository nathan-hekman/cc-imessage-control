# cc-imessage-control — design system

## Palette

OKLCH-tuned with neutrals warmed toward the paper tone. No `#000`, no
`#fff`. Tinted neutrals.

### Light (default)

| Token | Value | Role |
|---|---|---|
| `--ink` | `#1a1a1a` | Primary text |
| `--ink-soft` | `#3a342e` | Body copy, lede |
| `--paper` | `#faf8f4` | Page background |
| `--paper-2` | `#f3eee4` | Alt section background, inline code bg |
| `--paper-3` | `#ece6d8` | Reserved for deeper section bands |
| `--rule` | `#e6e1d6` | Hairline borders |
| `--rule-strong` | `#c8c0b0` | Stronger borders, pill outlines |
| `--muted` | `#6b6258` | Captions, kicker, meta |
| `--accent` | `#0a84ff` | Brand blue. Links, marker highlight underlay. |
| `--accent-soft` | `#d9ebff` | Accent-tinted backgrounds |
| `--highlight` | `#fbe7a3` | Marker-pen highlight behind hero accent text |
| `--code-bg` | `#1d1d1f` | Code block background |
| `--code-ink` | `#e8e6e0` | Code block text |

### Dark (auto)

Same role names; pre-mirrored:

| Token | Value |
|---|---|
| `--ink` | `#f0eee8` |
| `--ink-soft` | `#d0cbc0` |
| `--paper` | `#1a1814` |
| `--paper-2` | `#221f1a` |
| `--paper-3` | `#2a2620` |
| `--rule` | `#3a352d` |
| `--rule-strong` | `#564e42` |
| `--muted` | `#a8a094` |
| `--accent` | `#4ca3ff` |
| `--accent-soft` | `#1f2f44` |
| `--highlight` | `#4a3f1d` |
| `--code-bg` | `#0e0d0b` |
| `--code-ink` | `#e8e6e0` |

### Brand accent letters

The "CC" logo letters use saturated, **not-tuned-for-theme** colors:

| Letter | Color | Notes |
|---|---|---|
| First C | `#e51e25` | Saturated red. TiVo-style. |
| Second C | `#0a84ff` | Brand blue. Matches `--accent`. |

The logo smile uses `currentColor`-style adaptation: dark on light, light
on dark, via `prefers-color-scheme` inside the SVG.

## Color strategy

**Restrained** — tinted paper neutrals dominate; accent blue ≤10% of
surface area (links, hero accent underline, primary CTA dot).
Marker-pen yellow highlight reserved exclusively for the *single* hero
accent phrase. The CC red is **only** allowed on the logo mark itself
and must not bleed into UI.

Do not promote any color above its current role. No "accent gradient"
hero background. No "color of the section" temptation.

## Typography

| Role | Family | Weight | Size (desktop) | Notes |
|---|---|---|---|---|
| Hero H1 | Georgia, "New York", serif | 500 | 56px | Letter-spacing −0.022em |
| Section H2 | Georgia, "New York", serif | 500 | 36px | Letter-spacing −0.01em |
| H3 | system sans | 700 | 18px | |
| Body / lede | system sans | 400 / 400 | 17-19px | Max 62-65ch line-length |
| Subhead | system sans | 400 | 19px | Max 52ch |
| Kicker | system sans | 700 | 11px | Letter-spacing 0.2em, uppercase, muted |
| Code | ui-monospace, SF Mono, Menlo | 400 | 13.5px (`pre`), 0.92em (inline) | |
| Button | system sans | 600 | 15px | |
| Brand wordmark | system sans | 700 | 18-20px | Letter-spacing −0.005em |

**Type scale** between H1 → H2 → H3 → body: 56 / 36 / 18 / 17 — ratios
≥1.25, contrast strong.

## Spacing rhythm

Don't use a single padding everywhere. Roles:

| Token | Value | Use |
|---|---|---|
| Section base | `56px 0` | Default top/bottom section padding |
| Section dense | `40px 0` | Mobile section padding |
| Wrap inner | `0 36px` | Desktop side gutter |
| Wrap inner mobile | `0 22px` | Mobile side gutter |
| Card | `26px` | Install cards |
| Diagram pad | `28px 18px 14px` | Hero diagram frame |
| Hero | `48px 0 28px` | After logo-mark addition |
| Vertical between hero elements | `18-22-26-28px` | Visual rhythm, vary |

Wrap max-width is **980px**. Inside, body-copy and lede have their own
narrower `max-width: 52-65ch` so reading lines never go wide.

## Components

### Top bar

- Brand: `<img class="mark">` (28×34px) + wordmark, gap 10px.
- GitHub pill link on the right: 1px border `--rule-strong`, hover →
  `--ink` border.

### Hero

- Logo mark, 120-130px tall, centered.
- Kicker (uppercase 11px, muted).
- H1 with one accent phrase wrapped in `<span class="accent">`. The
  accent gets a yellow `::after` highlight underlay rotated −0.6deg.
- Subhead, 52ch max.
- Two CTA pills: primary (`--ink` bg, `--paper` text) + secondary
  (transparent, `--rule-strong` border).

### Diagram

- Padding-framed card with `--rule` border + soft shadow.
- SVG flow diagram on desktop.
- At ≤760px, swap to ordered-list fallback with numbered accent
  badges.

### Comparison table

- Single internal card, no per-row dividers beyond a hairline `--rule`.
- "Us" column has `--ink` body weight; "them" column has `--muted`.
- Header `--paper-2` band; no zebra striping.

### FAQ accordion

- `<details>`/`<summary>` native. No JS.
- Plus/minus indicator via `::after`. Use proper minus (`−`) not
  hyphen-minus.
- Border-top + border-bottom hairlines only.

### Install card

- `--paper` card on `--paper` section (white-on-cream) — separated by
  `--rule` border + ~22px inner padding.
- Code block uses `--code-bg` / `--code-ink` regardless of theme.

## Motion

- Buttons: `transform: translateY(-1px)` on hover, `transition:
  transform 0.08s ease-out-quart`.
- FAQ accordion: native `<details>` toggle.
- Logo: no animation on the mark itself (the smile carries the
  warmth).
- **Never** animate layout properties (width, height, top, margin).
- No bounce, no elastic, no parallax.

## Mobile breakpoint

`@media (max-width: 760px)`:

- H1 → 38px
- H2 → 28px
- Section padding → 40px
- Wrap padding → 0 22px
- Hero padding → 36px 0 20px
- Diagram SVG hidden, ordered-list fallback shown
- Screenshot grid collapses to single column

## Anti-patterns

Banned in this project, on top of impeccable's universal absolute bans:

- **Big-number hero metric template.** No "50ms response time / 99%
  uptime" stat row. We have no metrics to show; don't fake any.
- **Identical 3-card / 4-card "Features" grid.** The differentiator
  table replaces this.
- **Pricing teaser table.** Free open-source. Don't dress it up.
- **Floating chat-widget cliché.** No chat bubble.
- **Newsletter sign-up modal.** No.
- **Carousel of testimonials.** Absolutely not.

## Naming the social card

`docs/assets/social-card.png` is **always** 1200×630. It is the
og:image for every page that links here.
