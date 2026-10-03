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

The shared `SsrvpnTheme` extension defines six palettes and materials. The table
below documents the default dark theme; Sakura, Cloud and Soft use light palettes.

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

The default theme uses premium glass with renderer-capability and accessibility
fallbacks. User-selectable quality tiers and background modes have been removed.
All backgrounds are static; only connected control decorations animate.
The default wallpaper is lossless `network-glass-deep.webp`, pixel-identical to
the former PNG. Theme artwork is shared across routes and compressed as WebP.
Aurora and Dusk rings are drawn concentrically in code. Soft uses raised cards
and inset selection surfaces; its power control is flat while disconnected.

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

The node card is centered in the usable home viewport. Public IP sits below it;
statistics sit above navigation. Every theme retains all actions on one screen.
Small viewports scale the complete home shell uniformly. Desktop windows use a
fixed 460×840 design size scaled to the available work area; resizing/maximizing
is disabled, but move/minimize/close remain available.

## Account quota card

Usage and device cards continue to use the trusted account-provider contract.
Quota is represented by a live circular progress indicator; unknown data must
not be replaced with fictional values. Upload/download/session totals use two
compact lines, with value and unit together. Theme changes never alter networking,
private-node latency policy, account identity checks, or persistence semantics.
