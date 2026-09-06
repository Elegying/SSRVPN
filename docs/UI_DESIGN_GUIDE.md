# UI Design Guide

This is the public design baseline for Android, macOS, and Windows. Platform
layouts can differ, but color, typography, spacing, and component behavior
should stay aligned unless a platform convention requires otherwise.

## Source Of Truth

- Android tokens: `SSRVPN_Android/lib/theme/app_theme.dart`
- Desktop tokens: `SSRVPN_MacOS/lib/theme/app_theme.dart` and `SSRVPN_Windows/lib/theme/app_theme.dart`
- Detailed desktop reference: `SSRVPN_Windows/DESIGN.md`

When changing a shared visual decision, update this guide and the relevant
`AppTheme` files in the same PR.

## Color Tokens

| Role | Dark | Light |
| --- | --- | --- |
| Background | `#040405` / `#08080A` | `#F5F5F5` |
| Card | `#0D0D10` | `#FFFFFF` |
| Border | `#1C1C21` | `#E5E5E5` |
| Primary | `#8B5CF6` | `#8B5CF6` |
| Accent | `#06B6D4` | `#06B6D4` |
| Success | `#22C55E` | `#22C55E` |
| Warning | `#F59E0B` | `#F59E0B` |
| Error | `#EF4444` | `#EF4444` |

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
line, a `50%` line and the reminder `每月1日重置`. Each amount selects its own binary-progressing unit.
The five-card panel uses three-plus-two rows except in very short landscape
space (less than 100px). There, a wider quota card breaks at the slash and
retains the percentage and reset reminder, with reduced local padding.
Only the very short landscape connection circle uses 120px instead of 124px
to make room; approved compact desktop and tall layouts keep their geometry. The narrowest
portrait quota card uses 3px horizontal padding; card edges stay aligned.
Local text fitting retains a 10px minimum and full accessibility counters.
