# Maintenance Guide

This guide keeps local development, GitHub automation, and releases aligned.

## Weekly Maintenance

0. Start from a clean and synced local `main`:

   ```bash
   make status
   make sync
   ```

1. Check Dependabot PRs and CI status.
2. Check dependency drift once a month, not on release day:

   ```bash
   make deps
   ```

3. Run shared package verification:

   ```bash
   cd packages/ssrvpn_shared
   dart pub get
   flutter analyze
   flutter test --coverage
   ```

4. Run touched platform checks:

   ```bash
   cd SSRVPN_Android
   flutter pub get
   flutter analyze
   flutter test --coverage
   ```

5. Repeat for `SSRVPN_MacOS` and `SSRVPN_Windows` when shared behavior or common models change.
6. Keep `CHANGELOG.md` updated under `Unreleased`.

## Pull Request Rules

- Work from `feature/*`, `fix/*`, or `chore/*` branches; keep `main` stable.
- Put reusable business logic in `packages/ssrvpn_shared` before duplicating platform code.
- Keep platform services focused on native integration, process management, and OS-specific behavior.
- Redact credentials and subscription data in logs.
- Update tests when changing parsing, config generation, persistence, or release behavior.
- Include the verification commands in the PR template.
- Do not include local `dist/` files, signing material, or generated build caches.

## UI Responsibility Map

Use these boundaries before adding or removing home-screen behavior:

| Scope | Responsibility |
| --- | --- |
| `SSRVPN_MacOS/lib/app.dart`, `SSRVPN_Windows/lib/app.dart` | Platform startup, tray callbacks, shutdown, window state, and OS-specific failure policy |
| `packages/ssrvpn_shared/lib/desktop_ui/desktop_app_shell_part.dart` | Shared responsive navigation shell, page stack, side rail, and startup banners |
| `desktop_home_screen_part.dart` | Shared desktop home state, lifecycle, connection entrypoint, and page composition |
| `desktop_home_runtime_actions_part.dart` | Shared desktop reload, node selection, latency, update, and runtime actions |
| `desktop_home_public_ip_part.dart` | Shared desktop public-IP refresh state |
| `desktop_home_dashboard_part.dart` | Desktop dashboard composition, top bar, and status-panel layout |
| `desktop_home_status_widgets_part.dart` | Connection summary, mode/IP status, and connection errors |
| `desktop_home_connection_options_part.dart` | Proxy mode, proxy method, and forced-proxy entry controls |
| `SSRVPN_Android/lib/screens/home_screen.dart` | Android home state ownership, lifecycle, update scheduling, and page composition |
| `home_connection_actions_part.dart` | Android connect, reload, proxy mode, and forced-proxy actions |
| `home_node_actions_part.dart` | Android node selection, editing, persistence, and latency actions |
| `home_public_ip_part.dart` | Android public-IP refresh state |

Keep a new behavior in the narrowest matching file. Add a new part only when it
creates a distinct responsibility; do not split a short cohesive implementation
only to reduce line count. When moving code, update the matching boundary guard
and run both platform suites for shared desktop changes.

## Release Checklist

1. Confirm `main` CI is green.
2. Review `CHANGELOG.md` and move relevant entries from `Unreleased` to the target version.
3. Verify bundled core assets:

   ```bash
   scripts/verify-core-assets.sh
   ```

4. Verify the free Android self-signed keystore secrets are available. macOS notarization and Windows code signing are intentionally not required for the current personal release posture.
   See `docs/RELEASE_SIGNING.md` for expected secret names and workflow steps.
5. Create and push a version tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

6. Watch the `Release` workflow.
7. Download artifacts, verify checksums, and optionally run `scripts/check-release-assets.sh vX.Y.Z`.
8. Smoke test at least one install/run path per platform before announcing.

## Online/Offline Consistency

- Local `main` should track `origin/main`.
- Do not maintain platform-only repositories as active development roots.
- Historical platform repositories have been deleted; keep all maintenance work in this monorepo.
- Any direct GitHub edit must be pulled locally before further local commits.
