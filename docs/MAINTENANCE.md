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
| `SSRVPN_MacOS/lib/app.dart`, `SSRVPN_Windows/lib/app.dart` | Platform startup, shutdown, window state, and OS-specific failure policy |
| `SSRVPN_MacOS/lib/app_runtime_actions_part.dart`, `SSRVPN_Windows/lib/app_runtime_actions_part.dart` | Platform tray connection workflow, runtime notices, and user-facing recovery actions |
| `packages/ssrvpn_shared/lib/services/desktop_connection_coordinator.dart` | Revision- and intent-guarded desktop config preparation, start, preferred-node switch, and owned rollback transaction |
| `packages/ssrvpn_shared/lib/desktop_ui/desktop_app_shell_part.dart` | Shared responsive navigation shell, page stack, side rail, and startup banners |
| `desktop_home_screen_part.dart` | Shared desktop home state, lifecycle, connection entrypoint, and page composition |
| `desktop_home_background_tasks_part.dart` | Initial runtime synchronization, status listeners, latency flushing, and update scheduling |
| `desktop_home_runtime_actions_part.dart` | Shared desktop reload, node selection, latency, update, and runtime actions |
| `desktop_home_public_ip_part.dart` | Shared desktop public-IP refresh state |
| `desktop_home_dashboard_part.dart` | Desktop dashboard composition, top bar, and status-panel layout |
| `desktop_home_status_widgets_part.dart` | Connection summary, mode/IP status, and connection errors |
| `desktop_home_connection_options_part.dart` | Proxy mode, proxy method, and forced-proxy entry controls |
| `SSRVPN_Android/lib/screens/home_screen.dart` | Android home state ownership, lifecycle, update scheduling, and page composition |
| `home_connection_actions_part.dart` | Android connect, reload, proxy mode, and forced-proxy actions |
| `home_node_actions_part.dart` | Android node selection, editing, persistence, and latency actions |
| `home_public_ip_part.dart` | Android public-IP refresh state |

The existing log entry opens the shared diagnostics center. Keep stable failure
codes and report redaction in `models/app_diagnostics.dart`; keep shared checks
in `clash_service_diagnostics.dart`; platform services may add only native
checks and safe repairs. A repair must require SSRVPN ownership and must not
silently disconnect an active session.

## Service Responsibility Map

| Scope | Responsibility |
| --- | --- |
| `subscription_service_base.dart` | Refresh orchestration, source merge, persistence, and public subscription API |
| `subscription_node_codec.dart` | Node URI decoding/encoding, JSON cleanup, and normalized node editing |
| `clash_service_base.dart` | Shared lifecycle facade and platform contract |
| `clash_service_diagnostics.dart` | Bounded diagnostic collection, stable failure mapping, and redacted reports |
| `SSRVPN_MacOS/lib/services/settings_service.dart` | Settings migration and serialized persistence orchestration |
| `macos_private_file_store.dart` | Atomic private-file writes, permissions, verification, and temporary-file cleanup |

The boundary guard enforces these delegations and practical line limits. A new
part must own a coherent behavior and have characterization tests; line count
alone is not a reason to split.

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

4. Verify the free Android self-signed keystore secrets are available. Desktop
   releases always use the documented free path: macOS ad-hoc without
   notarization and Windows without Authenticode. Do not add Apple/Microsoft
   certificate secrets or paid-signing branches. See `docs/RELEASE_SIGNING.md`.
5. Create and push a version tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

6. Watch the `Release` workflow.
7. Download artifacts, verify checksums, and optionally run `scripts/check-release-assets.sh vX.Y.Z`.
8. Confirm the Windows build log includes the real `SSRVPN_Setup.exe` install/uninstall smoke test, not only packaging and static checks.
9. Smoke test at least one install/run path per platform before announcing.

## Online/Offline Consistency

- Local `main` should track `origin/main`.
- Do not maintain platform-only repositories as active development roots.
- Historical platform repositories have been deleted; keep all maintenance work in this monorepo.
- Any direct GitHub edit must be pulled locally before further local commits.
