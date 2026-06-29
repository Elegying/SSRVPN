---
version: "1.0"
name: SSRVPN-design-analysis
description: |
  A dark-first desktop VPN dashboard built around deep near-black surfaces
  (#040405 → #0D0D10), refined violet accent (#8B5CF6), and precision glass-morphism
  effects. The connection button is the single hero element — a glowing, breathing
  orb that carries the entire emotional weight of the app. Cards use subtractive
  glass treatment (BackdropFilter blur over near-black) rather than additive
  lifts. Typography is Segoe UI at 700–800 weight for headlines, 400–600 for body,
  with tight negative letter-spacing. The system is engineered for a single
  window at 1100×760 px, optimized for system-tray residency.

colors:
  # ── Brand ──
  primary: "#8B5CF6"
  primary-hover: "#A78BFA"
  primary-muted: "#6D28D9"
  accent: "#06B6D4"

  # ── Surfaces (dark-first) ──
  bg: "#040405"
  surface: "#08080A"
  card: "#0D0D10"
  card-hover: "#141417"
  border: "#1C1C21"
  border-light: "#26262B"

  # ── Text ──
  text-primary: "#EDEDEF"
  text-secondary: "#8E8E93"
  text-tertiary: "#636369"

  # ── Semantic ──
  success: "#22C55E"
  success-muted: "#16A34A"
  warning: "#F59E0B"
  error: "#EF4444"

  # ── Light mode (secondary) ──
  light-bg: "#F5F5F5"
  light-surface: "#FFFFFF"
  light-card: "#FFFFFF"
  light-border: "#E5E5E5"
  light-text-primary: "#1A1A1A"
  light-text-secondary: "#6B6B6B"

  # ── Glass ──
  glass-alpha-dark: "0.04"
  glass-alpha-light: "0.40"
  glass-border-alpha-dark: "0.06"
  glass-border-alpha-light: "0.40"
  glass-blur: "24"

typography:
  font-family: "Segoe UI, system-ui, -apple-system, sans-serif"
  # ── Display ──
  hero-status:
    fontSize: 24px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: -0.5px
  section-title:
    fontSize: 15px
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: -0.2px
  # ── Body ──
  body:
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: -0.1px
  body-strong:
    fontSize: 14px
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: -0.1px
  body-sm:
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: 0
  body-sm-strong:
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.35
    letterSpacing: 0
  caption:
    fontSize: 10px
    fontWeight: 500
    lineHeight: 1.3
    letterSpacing: 0
  # ── Special ──
  brand-name:
    fontSize: 18px
    fontWeight: 800
    lineHeight: 1.2
    letterSpacing: 1.0px
  button-label:
    fontSize: 13px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: 3.0px
  pill-label:
    fontSize: 10px
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: 0
  badge:
    fontSize: 8px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: 1.2px

rounded:
  xs: 4px
  sm: 6px
  md: 10px
  lg: 14px
  xl: 20px
  xxl: 24px
  pill: 9999px

spacing:
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 20px
  xl: 24px
  xxl: 28px
  xxxl: 32px
  section: 48px

components:
  # ── Navigation ──
  top-bar:
    backgroundColor: transparent
    textColor: "{colors.text-primary}"
    typography: "{typography.brand-name}"
    height: 48px
    padding: 16px 32px 4px 32px

  bottom-nav:
    backgroundColor: transparent
    textColor: "{colors.text-tertiary}"
    activeTextColor: "{colors.primary}"
    rounded: "{rounded.pill}"
    padding: 8px
    margin: 0px 12px 10px 12px

  # ── Hero: Connection Card ──
  connection-card:
    backgroundColor: transparent
    rounded: "{rounded.xxl}"
    padding: 32px 28px
    shadow-connected: "{colors.success} at 36px blur + 4px spread"

  connection-button:
    width: 140px
    height: 140px
    gradient-disconnected: "{colors.primary} → {colors.primary-muted}"
    gradient-connected: "{colors.success} → {colors.success-muted}"
    pulse-rings: 4
    ring-speed: 4s
    breathe-speed: 3.5s
    typography: "{typography.button-label}"

  status-text:
    typography: "{typography.hero-status}"
    color-disconnected: "{colors.text-primary}"
    color-connected: "{colors.success}"

  # ── Mode Selector ──
  proxy-mode-card:
    backgroundColor: "{colors.card}"
    rounded: "{rounded.md}"
    padding: 18px 16px
    border: 0.5px "{colors.border}"

  segmented-control:
    backgroundColor: transparent
    selectedColor: "{colors.primary}"
    unselectedColor: "{colors.text-secondary}"
    rounded: "{rounded.md}"

  mode-choice:
    backgroundColor-selected: "{colors.primary} with alpha 0.08"
    border-selected: "{colors.primary} with alpha 0.2"
    backgroundColor-default: transparent
    border-default: "{colors.border}"
    rounded: "{rounded.md}"
    padding: 12px 10px
    typography: "{typography.body-sm-strong}"

  # ── Node List ──
  node-list-header:
    padding: 12px 32px 10px 32px
    indicator: 3px × 16px pill "{colors.primary}"
    typography: "{typography.section-title}"

  node-count-badge:
    backgroundColor: "{colors.primary} with alpha 0.08"
    border: "{colors.primary} with alpha 0.15"
    typography: "{typography.pill-label}"

  node-card:
    backgroundColor: transparent
    rounded: "{rounded.md}"
    padding: 12px 14px
    gap: 6px
    border-default: "{colors.border}"
    border-selected: "{colors.success} at 80% alpha, 1.5px"
    background-selected: "{colors.success} at 10% alpha"
    typography-node-name: "{typography.body-strong}"
    typography-latency: "{typography.body-sm}"
    status-icon-size: 32px

  # ── Cards (generic) ──
  card-default:
    backgroundColor: "{colors.card}"
    rounded: "{rounded.lg}"
    border: 0.5px "{colors.text-primary} at 6% alpha"
    padding: 16px
    shadow: 0px 8px 20px rgba(0,0,0,0.4)

  card-glass:
    backgroundColor: "{colors.card} → {colors.surface} gradient"
    rounded: "{rounded.lg}"
    border: 0.5px white at 6% alpha
    blur: 24px
    shadow: 0px 8px 20px rgba(0,0,0,0.4)

  # ── Buttons ──
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: white
    rounded: "{rounded.md}"
    padding: 12px 20px
    typography: "{typography.body-strong}"

  button-secondary:
    backgroundColor: "{colors.card}"
    textColor: "{colors.text-secondary}"
    rounded: "{rounded.sm}"
    border: 0.5px "{colors.border}"
    padding: 6px 10px
    typography: "{typography.body-sm}"

  button-icon:
    backgroundColor: "{colors.primary} at 10% alpha"
    textColor: "{colors.primary}"
    rounded: "{rounded.pill}"
    width: 30px
    height: 30px

  # ── Pills & Badges ──
  pill-status:
    backgroundColor: color at 10% alpha
    textColor: color
    rounded: "{rounded.sm}"
    padding: 4px 9px
    typography: "{typography.pill-label}"

  badge-platform:
    backgroundColor: "{colors.primary} at 10% alpha"
    textColor: "{colors.primary}"
    rounded: "{rounded.xs}"
    padding: 2px 6px
    typography: "{typography.badge}"

  # ── Forms ──
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-primary}"
    placeholderColor: "{colors.text-tertiary}"
    rounded: "{rounded.md}"
    border-default: "{colors.border}"
    border-focus: "{colors.primary} at 1.5px"
    padding: 12px 14px
    typography: "{typography.body}"

  # ── Dialogs ──
  dialog:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.xl}"
    padding: 24px

  # ── Banners ──
  startup-banner:
    backgroundColor: color at 14% alpha
    textColor: color
    padding: 10px 18px
    typography: "{typography.body-sm}"

  # ── Snackbar ──
  snackbar:
    backgroundColor: "{colors.card}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    margin: 16px
    typography: "{typography.body}"

  # ── Tray ──
  system-tray:
    visibleWhen: window_manager initialized and NOT safe-mode
    menu-items: "Show/Hide, Connect/Disconnect, Quit"
    icon: system-tray-plugin

  # ── Unlock Test ──
  unlock-category-tab:
    backgroundColor-default: "{colors.card}"
    backgroundColor-active: "{colors.primary} at 12% alpha"
    textColor-default: "{colors.text-secondary}"
    textColor-active: "{colors.primary}"
    rounded: "{rounded.md}"
    padding: 8px 14px
    border-active: "{colors.primary} at 30% alpha"
    typography: "{typography.body-sm}"

  unlock-card:
    backgroundColor: white at 4% alpha
    rounded: "{rounded.lg}"
    padding: 14px
    border-default: status-color at 25% alpha
    border-result: status-color at 50% alpha, 1px
    typography-name: "{typography.body-strong}"

  unlock-summary-chip:
    backgroundColor: color at 10% alpha
    textColor: color
    rounded: "{rounded.sm}"
    padding: 3px 8px
    typography: "{typography.pill-label}"

---

## Overview

SSRVPN is a **dark-first desktop VPN dashboard** built with Flutter for Windows. It operates as a single-window application with system-tray integration — the user connects, minimizes to tray, and the app lives in the background. The UI is designed to be calm, precise, and visually reassuring — the connection button is the single hero element, a breathing orb that communicates VPN state instantly.

The surface is built on a three-level near-black ladder: `{colors.bg}` (#040405, the page background), `{colors.surface}` (#08080A, inset regions), and `{colors.card}` (#0D0D10, lifted containers). Glass-morphism is the core material language — cards use `BackdropFilter` blur over the dark background rather than additive lifts. The effect is subtractive: glass hushes the background behind it rather than popping forward.

The single chromatic accent is **violet** `{colors.primary}` (#8B5CF6) — used on the connection orb, focus rings, navigation indicators, and section markers. Green `{colors.success}` (#22C55E) appears only when the VPN is connected, transforming the connection orb to signal the state change. No other saturated colors appear in the UI chrome.

**Key Characteristics:**
- **Dark-first.** No light-mode primary — light is a secondary theme shipped for accessibility, not the brand default.
- **Single hero element.** The connection button (140×140 px glowing orb) is the emotional center of the app.
- **Glass-morphism as material.** Cards use `BackdropFilter(blur: 24)` with `0.06` alpha white borders — subtractive, not additive.
- **Calm typography.** Segoe UI at weights 400–800, with tight negative letter-spacing on brand and display.
- **Tray-first workflow.** The app is designed to disappear to the system tray; the window is a dashboard you visit, not a workspace you inhabit.
- **Startup resilience.** Safe mode, crash dumps, and graceful degradation are part of the design system.

## Colors

### Brand
- **Violet** `{colors.primary}` (#8B5CF6): The app's signature accent. Used on the connection orb (disconnected state), navigation active indicator, focus rings, link emphasis, and section markers. A lighter hover (`{colors.primary-hover}` #A78BFA) appears on hover states; a deeper focus variant (`{colors.primary-muted}` #6D28D9) anchors gradient stops.
- **Cyan** `{colors.accent}` (#06B6D4): A secondary accent reserved for dual-gradient moments (app icon, a few splash elements). Never used as a standalone UI color.

### Surfaces
- **Bg** `{colors.bg}` (#040405): The page background — near-pure black with the faintest warmth.
- **Surface** `{colors.surface}` (#08080A): One step above bg — used for inset regions, empty states, dialog backgrounds.
- **Card** `{colors.card}` (#0D0D10): The lifted card surface. Used for the connection card, node cards, and glass containers.
- **Card Hover** `{colors.card-hover}` (#141417): Hover / pressed state for interactive cards.
- **Border** `{colors.border}` (#1C1C21): 0.5–1px borders on cards and dividers.
- **Border Light** `{colors.border-light}` (#26262B): Stronger borders for focused states and active indicators.

### Text
- **Text Primary** `{colors.text-primary}` (#EDEDEF): All headlines and emphasized body.
- **Text Secondary** `{colors.text-secondary}` (#8E8E93): Body copy, metadata, node details.
- **Text Tertiary** `{colors.text-tertiary}` (#636369): Placeholders, captions, disabled text.

### Semantic
- **Success** `{colors.success}` (#22C55E): Connected state — transforms the connection orb, selected node indicator, success banners.
- **Warning** `{colors.warning}` (#F59E0B): Cautions, "safe mode" banner, originals-only unlock status.
- **Error** `{colors.error}` (#EF4444): Connection failures, blocked states, error banners.

### Glass
The glass system is subtractive — it uses `BackdropFilter.blur()` to soften the background behind containers:
- **Glass Alpha Dark:** `{colors.glass-alpha-dark}` (0.04) — dark mode glass fill opacity.
- **Glass Alpha Light:** `{colors.glass-alpha-light}` (0.40) — light mode glass fill opacity.
- **Glass Border Alpha Dark:** `{colors.glass-border-alpha-dark}` (0.06) — dark mode glass border opacity.
- **Glass Border Alpha Light:** `{colors.glass-border-alpha-light}` (0.40) — light mode glass border opacity.
- **Glass Blur:** `{colors.glass-blur}` (24px σ) — default blur radius for glass containers.

## Typography

### Font Family
**Segoe UI** is the primary face, shipped with Windows and tuned for on-screen reading. Fallback: `system-ui, -apple-system, sans-serif`.

### Hierarchy

| Token | Size | Weight | Line Height | Letter Spacing | Use |
|---|---|---|---|---|---|
| `{typography.hero-status}` | 24px | 700 | 1.2 | -0.5px | Connection status ("已连接" / "未连接") |
| `{typography.brand-name}` | 18px | 800 | 1.2 | 1.0px | Top bar app name "SSRVPN" |
| `{typography.section-title}` | 15px | 700 | 1.3 | -0.2px | Section headers ("全部节点") |
| `{typography.body-strong}` | 14px | 600 | 1.4 | -0.1px | Node names, emphasized body |
| `{typography.body}` | 14px | 400 | 1.4 | -0.1px | Default body, form text |
| `{typography.body-sm-strong}` | 12px | 600 | 1.35 | 0 | Mode choice labels, connection info |
| `{typography.body-sm}` | 12px | 400 | 1.35 | 0 | Metadata, latency, subtitle |
| `{typography.button-label}` | 13px | 700 | 1.2 | 3.0px | Connection button label ("连接" / "断开") |
| `{typography.pill-label}` | 10px | 600 | 1.2 | 0 | Status pill, node count badge |
| `{typography.badge}` | 8px | 700 | 1.2 | 1.2px | Platform badge ("WINDOWS") |
| `{typography.caption}` | 10px | 500 | 1.3 | 0 | Fine print, unlock test metadata |

### Principles
- **Weight 800 is reserved for the brand name** ("SSRVPN"). Everything else caps at 700.
- **Positive letter-spacing only on brand and button labels.** The badge uses 1.2px; the button label uses 3.0px. All body text is neutral or slightly negative.
- **No all-caps styling on body text.** Only the platform badge ("WINDOWS") uses uppercase, and it's purely cosmetic.
- **Chinese text inherits the same weight scale.** The 700 weight on Chinese characters achieves the same visual density as 600 on Latin.

## Layout

### Spacing System
- **Base unit:** 4px
- **Tokens:** `{spacing.xxs}` 4px · `{spacing.xs}` 8px · `{spacing.sm}` 12px · `{spacing.md}` 16px · `{spacing.lg}` 20px · `{spacing.xl}` 24px · `{spacing.xxl}` 28px · `{spacing.xxxl}` 32px · `{spacing.section}` 48px
- Horizontal page gutters: `{spacing.xxxl}` 32px on desktop, `{spacing.lg}` 20px on compact (< 430px).
- Card interior padding: `{spacing.xxxl}` 32px vertical × `{spacing.xxl}` 28px horizontal for the connection card.
- Inter-card gap: `{spacing.md}` 16px between node cards.

### Grid
- **Single-column layout.** The app is a narrow dashboard (default 1100×760 px). Content flows in one column: top bar → connection card → node list.
- **Responsive threshold at 430px** — below this, horizontal gutters tighten to 20px, and the top bar badge collapses.
- **Node list uses a ListView**, not a grid — nodes are listed vertically with 6px gaps.

### Whitespace Philosophy
The near-black background IS the whitespace. Sections separate by the surface lift of the glass card, not by explicit spacing. The connection card floats as a lifted glass panel over the bg; the node list sits flush below. Within a card, `{spacing.xl}` 24px gaps between content blocks.

## Elevation & Depth

| Level | Treatment | Use |
|---|---|---|
| 0 — Flat | No shadow, no border | Top bar, bottom nav, body text |
| 1 — Glass Lift | Glass card with blur + subtle shadow | Connection card, settings cards |
| 2 — Focus Glow | Colored box-shadow at 24–36px blur | Connected state glow around connection card |
| 3 — Button Glow | Colored blur at 28px + dark shadow | Connection orb hover/press |

SSRVPN uses **glass + glow** for depth, not the traditional shadow ladder. Cards blur the background behind them (glass) and emit colored light when active (glow). The connection card is the only element that uses glow — it radiates green light when connected, reinforcing the "alive" metaphor.

### Decorative Depth
- **Connection orb breathing:** A 3.5-second sine-wave scale animation (0.025× amplitude) gives the orb a subtle "alive" quality when connected.
- **Pulse rings:** 4 concentric rings expand and fade outward from the connection orb at varying speeds.
- **Rotating arc:** A 0.45π sweep gradient arc rotates around the orb over 4 seconds, giving a "data flowing" feel.

## Shapes

### Border Radius Scale

| Token | Value | Use |
|---|---|---|
| `{rounded.xs}` | 4px | Platform badge, section indicator |
| `{rounded.sm}` | 6px | Status pills, small buttons |
| `{rounded.md}` | 10px | Form inputs, buttons, mode cards, nav |
| `{rounded.lg}` | 14px | Node cards, unlock cards, generic cards |
| `{rounded.xl}` | 20px | Dialog modals |
| `{rounded.xxl}` | 24px | Connection card (highest prominence) |
| `{rounded.pill}` | 9999px | Nav indicators, refresh buttons |

The connection card uses `{rounded.xxl}` 24px — the largest radius — to signal its role as the visual anchor. Everything else uses `{rounded.md}` to `{rounded.lg}`.

## Components

### Navigation

**`top-bar`** — Minimal header with brand identity.
- Height 48px. Logo (28×28 px violet gradient square, 7px radius) + "SSRVPN" brand name + platform badge + tutorial button. Transparent background.

**`bottom-nav`** — Liquid-glass navigation bar.
- Three tabs: Home, Subscription, Unlock Test. Active tab gets violet text + icon. Uses `GlassContainer` with `{rounded.pill}` 32px. Sits in a `SafeArea` above the bottom edge.

### Hero: Connection Card

**`connection-card`** — The visual anchor of the app.
- A `GlassContainer` with `{rounded.xxl}` 24px, `{spacing.xxxl}` 32px vertical padding. Contains the `connection-button` + status text + proxy mode selector.
- When connected: emits a green box-shadow (36px blur, 4px spread) that breathes with a 3s sine-wave animation.

**`connection-button`** — 140×140 px custom-painted orb.
- **Disconnected:** Violet gradient (#8B5CF6 → #6D28D9) with subtle dark shadow.
- **Connected:** Green gradient (#22C55E → #16A34A) with breathing scale animation.
- **Connecting:** Shows a white CircularProgressIndicator.
- **Rings:** 4 pulse rings expand outward (2s cycle) when active. 2 rotating gradient arcs orbit the orb (4s cycle).
- **Label:** "连接" / "断开" in `{typography.button-label}` (13px, 700 weight, 3.0px letter-spacing).
- **Highlight:** White crescent reflection on the top half (12% opacity).

**`status-text`** — Connection state label.
- "已连接" / "正在连接..." / "未连接" in `{typography.hero-status}` (24px, 700 weight). Connected state uses `{colors.success}`; disconnected uses `{colors.text-primary}`. Animated with `AnimatedSwitcher` (250ms).

**`force-proxy-button`** — "添加强制代理网站" action.
- Violet tinted background at 8% alpha, violet border at 20% alpha, `{rounded.md}`.

### Proxy Mode Selector

**`proxy-mode-card`** — Tucked below the connection button.
- Subtle background (white at 3% alpha), `{rounded.md}` 12px, 0.5px border. Contains two controls side-by-side on desktop, stacked on compact:
  - **Left:** Proxy mode segmented control (Rule / Global). Uses Material `SegmentedButton<ProxyMode>`.
  - **Right:** Tunnel mode choice (System Proxy default / TUN mode). Uses custom `tunChoice` cards with radio icon.

**`segmented-control`** — Rule / Global toggle.
- Selected segment gets violet background at low alpha; unselected is dark card bg.

**`mode-choice`** — TUN / System Proxy selector.
- Two card-like tiles with icon + label + radio indicator. Selected tile gets violet tint + violet border.

### Node List

**`node-list-header`** — Section title row.
- 3px × 16px violet pill indicator + "全部节点" `{typography.section-title}` + node count badge + "测速" action button (when connected).

**`node-card`** — Individual proxy node entry.
- `{rounded.lg}` 14px. Full-width row: status icon (32px) → node name + latency → refresh button.
- **Default:** Transparent background, `{colors.border}` border.
- **Selected:** Green tinted background at 10% alpha, green border at 1.5px.
- **Timeout:** 45% opacity, non-interactive.
- **Latency display:** Colored by value (< 200ms = green, < 500ms = yellow, > 500ms = red).
- Right-click opens context menu (select / test latency / copy address).

### Buttons

**`button-primary`** — Violet CTA.
- Background `{colors.primary}`, white text, `{rounded.md}`, 12px × 20px padding, `{typography.body-strong}`.

**`button-secondary`** — Subtle action.
- Background `{colors.card}`, `{colors.text-secondary}` text, `{rounded.sm}`, 6px × 10px padding.

**`button-icon`** — Circular icon trigger.
- 30×30 px, `{colors.primary}` at 10% alpha background, violet icon. Used for refresh buttons on node cards.

### Pills & Badges

**`pill-status`** — Status indicator.
- Color at 10% alpha background, solid color text, `{rounded.sm}`, 4px × 9px padding. Used for "已连接" / "支持" / "不支持" labels.

**`badge-platform`** — Platform tag ("WINDOWS").
- Violet at 10% alpha background, `{typography.badge}` (8px, 700 weight, 1.2px spacing), `{rounded.xs}`.

### Unlock Test

**`unlock-category-tab`** — Category filter pill.
- Row of 4 tabs: 全部 / 流媒体 / AI 服务 / 其他. Active tab gets violet tint + violet border.

**`unlock-card`** — Service test result.
- White at 4% alpha background, `{rounded.lg}`, 14px padding. Status-colored border. Contains: icon + name + refresh button → status pills → detail text.

**`unlock-summary-chip`** — Summary stats.
- Row of 3 chips: 解锁N / 阻止N / 失败N. Each uses its status color at 10% alpha.

### Glass System

**`card-glass`** — The core container primitive.
- `BackdropFilter(blur: 24px)` over near-black bg. Gradient fill from `{colors.card}` to `{colors.surface}`. 0.5px white border at `{colors.glass-border-alpha-dark}` (6%). Stacked shadow.

**`card-default`** — Non-glass alternative (for performance).
- Solid `{colors.card}` fill. Same border + shadow as glass variant.

### System Tray

**`system-tray`** — Native Windows tray integration.
- Menu items: Show/Hide app, Connect/Disconnect, Quit.
- Disabled in safe mode.
- Uses `system_tray` Flutter plugin. Menu refreshes on connection state change.

## Page Layouts

### Home Screen
```
┌─────────────────────────────┐
│  🔷 SSRVPN  [WINDOWS]  [教程]│  ← top-bar
│                             │
│  ┌───────────────────────┐  │
│  │   ● (connection orb)  │  │  ← connection-card
│  │   "已连接" / "未连接"  │  │
│  │   ┌─Rule─┬─Global──┐  │  │
│  │   │ Sys  │  TUN    │  │  │  ← proxy-mode-card
│  │   └──────┴─────────┘  │  │
│  └───────────────────────┘  │
│                             │
│  ▎全部节点 [N]     [测速]   │  ← node-list-header
│  ┌─ ● Node 1 ── 45ms ──┐  │
│  ├─ ○ Node 2 ── 120ms ─┤  │  ← node-cards
│  ├─ ● Node 3 ── ∞ ─────┤  │
│  └──────────────────────┘  │
│                             │
│  [ 主页 | 订阅 | 解锁 ]      │  ← bottom-nav
└─────────────────────────────┘
```

### Subscription Screen
- Header + subscription URL list with status indicators.
- Each subscription shows: last update time, node count, update button.
- "添加订阅" button at bottom.

### Unlock Test Screen
- Header + connection info strip + category tabs + summary bar.
- Grid of unlock cards (27 services across streaming / AI / other categories).
- Each card: service icon + name + status pill + region (if detected) + detail.

## Animation

| Element | Trigger | Duration | Effect |
|---|---|---|---|
| Connection orb pulse | Connected/Connecting | 2s loop | 4 rings expand + fade |
| Connection orb ring | Connected | 4s loop | 2 gradient arcs rotate |
| Connection orb breathe | Connected | 3.5s loop | Sine-wave scale (±2.5%) |
| Status text swap | State change | 250ms | Fade transition |
| Card glow | Connected | 3s loop | Sine-wave box-shadow opacity |
| Node selection | Tap node | 200ms | AnimatedContainer border/color |
| Tab switch | Tap nav | 200ms | AnimatedContainer indicator |
| Scaling press | Tap card | 100ms | Scale 1.0 → 0.985 → 1.0 |
| Dialog enter | Open dialog | 200ms | Material default |
| Page transition | Nav tap | 300ms | IndexedStack crossfade |

**Principle:** Animations should feel like physics, not like UI. The connection orb's breathing is intentionally slow (3.5s) — it should read as "alive," not "busy." Press interactions are fast (100ms) for responsiveness.

## Do's and Don'ts

### Do
- Reserve `{colors.primary}` violet for brand elements only: connection orb, focus rings, nav active indicator, section markers.
- Use `{colors.success}` green ONLY for the connected state — it is the most powerful signal in the app.
- Apply glass `BackdropFilter` only to major cards (connection card, dialogs). Smaller elements use solid backgrounds.
- Keep the connection orb at 140×140 px — it is the hero; don't shrink it.
- Use the breathing animation ONLY when connected. Idle state should be still.
- Pair weight 800 with 1.0px letter-spacing for the brand name. This is the only place 800 is used.
- Use `AnimatedSwitcher` for state-driven text changes (status, error messages).
- Ensure all interactive elements have ≥100ms feedback (scale or color change).

### Don't
- Don't use violet as a background fill or section color. Violet is an accent, not a surface.
- Don't add a second saturated color. Green is reserved for connected state; violet for brand.
- Don't animate the idle state. Calm is the default.
- Don't use heavy drop shadows. Glass + glow is the depth system.
- Don't round the connection card below 20px — the xxl radius signals its importance.
- Don't shrink the connection orb below 120px on any viewport.
- Don't use uppercase on body text. Only the platform badge uses uppercase.
- Don't render the connection orb without the crescent highlight — it loses the "physical button" quality.

## Responsive Behavior

### Breakpoints

| Name | Width | Key Changes |
|---|---|---|
| Compact | < 430px | Gutters 32→20px. Platform badge hidden. "教程" label collapses. Mode selector stacks vertically. |
| Default | ≥ 430px | Full layout with all elements visible. Mode selector side-by-side. |

### Touch Targets
- Connection orb: 140×140 px — well above any tap target minimum.
- Node cards: full-width, ≥48px tall — comfortable for both mouse and touch.
- Bottom nav: 32px radius pill, generous tap area.
- Refresh buttons: 30×30 px circular, meets touch target minimum.

### Window Size
- **Default:** 1100×760 px, centered on primary display.
- **Minimum:** Enforced by `window_manager.setMinimumSize()`.
- **Restore:** Saves position on close/minimize; validates against screen bounds on next launch. If saved position is off-screen, reverts to default.
- **Safe mode:** Skips position restore, always uses default.

## Iteration Guide

1. Reference component tokens by their `components:` name, e.g. "use `connection-card` styling."
2. When adding a new card, decide: glass or solid? Glass only for top-level containers.
3. Default body text to `{typography.body}` (14px, 400 weight).
4. Treat violet as scarce: orb, focus, nav indicator, markers. Never decorative.
5. Green means connected. Don't use it for anything else.
6. Add new animation tokens to the Animation table above.
7. Test all states: disconnected, connecting, connected, error, safe mode.
