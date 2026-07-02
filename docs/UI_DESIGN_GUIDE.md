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
