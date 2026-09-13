# UI Design Guide

This is the public design baseline for Android, macOS, and Windows. Platform
layouts can differ, but color, typography, spacing, and component behavior
should stay aligned unless a platform convention requires otherwise.

## Source Of Truth

- Shared product surfaces: `packages/ssrvpn_shared/lib/widgets/ssrvpn_app_surface.dart`
  (`SsrvpnUiTokens`), `ssrvpn_liquid_glass.dart`, and `ssrvpn_typography.dart`.
- Platform `AppTheme` files retain base Material styles and compatibility names;
  they do not override every shared glass surface.
- Detailed desktop reference: `SSRVPN_Windows/DESIGN.md`.

## Current Shared Dark Surface Tokens

All three app entrypoints currently select the dark theme. Light Material styles
remain in code for compatibility; they are not a user-selectable theme.

| Role | Value |
| --- | --- |
| Background | `#0A1020` |
| Surface | `#242641` |
| Strong surface | `#2C2E4B` |
| Border | `#33FFFFFF` |
| Primary | `#8A84FF` |
| Accent | `#20C8B4` |
| Success | `#29C978` |
| Warning | `#F3B83F` |
| Error | `#E35D6A` |

## Stable Glass and Wallpaper

The current working-tree update selects a stable device tier at startup:
normal hardware uses premium; conservatively identified low-end hardware uses
minimal glass and shared 60 FPS pacing.
Runtime frame spikes must not silently change its thickness, blur or capture
pipeline. Platform shader capability and accessibility fallbacks still apply.
Diagnostic quality rollback switches have been retired; the selected device tier
stays fixed while accessibility and renderer capability fallbacks remain.

The accepted wallpaper is `network-glass-deep.png`. Retired wallpaper assets
and build-time rollback switches were removed after user acceptance. Asset
loading errors retain a lightweight procedural background for readability.
The wallpaper traverses a continuous 18-second cosine cycle, with 1.16 overscan
and fractional horizontal/vertical travel of .11/.08. Pause it while inactive,
obscured, during route transitions, or when reduced motion is requested; do not
reduce normal-tier capture resolution. Resume wallpaper drift after transitions.

Android keeps its PageView height constant during horizontal transitions. Home
content reserves navigation space locally; subscriptions scroll behind the bar
and reserve the same inset at the list tail. Status labels use natural CJK font
metrics with evenly distributed leading, not a forced Latin strut height.

## Typography

- Use system fonts: Segoe UI on Windows, SF Pro/system on macOS, Roboto/system
  on Android.
- Brand/title: 18-24px, weight 700-800.
- Section title: 15-16px, weight 600-700.
- Body: 13-14px, weight 400-600.
- Caption/badge: 10-12px, weight 500-700.
- Keep letter spacing at zero unless a platform-specific logo/badge treatment
  already uses explicit spacing.

## Components

- Connection button is the primary status control and should remain the visual
  focus of the home screen.
- Proxy mode uses segmented or card-like choices with clear selected state.
- Node rows/cards must show name, latency/status, and selection affordance.
- Dialogs use the same rounded radius and semantic colors as app surfaces.
- SnackBars and bottom sheets must avoid bottom navigation or system insets.

## Consistency Checklist

- Theme token changes are reflected in all platform `AppTheme` files.
- New shared UI copy is checked against Android and desktop layouts.
- First-run and tutorial flows are data-driven where practical.
- Large UI files should move repeated widgets or static content into focused
  widgets/data constants before adding more logic.

## Home node position

In the tall vertical home layout (overview height at least 610 logical pixels
after the top safe inset, before its 4px padding), the node card itself is
centered in the full home viewport, including bottom navigation but excluding
system/titlebar safe insets. Header, status and connection button share the
remaining upper space. Statistics remain anchored above navigation, and node
to public-IP spacing is at least 12px. Three/five cards and connection changes
do not move the node midpoint. Existing constrained-height and compact side-by-side
layouts remain unchanged; no minimum-window increase or scrolling is introduced.

## Account quota card

The account card keeps its label, then a complete `125GB/250GB` amount/limit
line and a single `已用50% 每月1日重置` line. Each amount selects its own binary-progressing unit.
Nonzero percentages below 0.1% use two decimal places, without an inequality sign.
The five-card panel uses three-plus-two rows, giving the account card 62% of the
second row. In very short landscape space (less than 100px), the full home has
a 380px panel and all five cards share a row, with more width for the complete
account reminder. Local padding and text fitting keep all content visible.
The narrowest portrait quota card uses 3px horizontal padding; outer card edges
stay aligned with navigation. Local text fitting retains a 10px minimum and
full accessibility counters. Existing connection/node geometry is unchanged.
