# Maintenance Guide

This guide keeps local development, GitHub automation, and releases aligned.

## Weekly Maintenance

0. Start from a clean and synced local `main`:

   ```bash
   make status
   make sync
   ```

1. Check Dependabot PRs, Dependency Review results, vulnerability alerts, and CI status. The GitHub Dependency Graph is the canonical source for exporting an SPDX SBOM when an audit needs one.
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
- Keep all tracked Dart source formatted and all tracked shell scripts clean under ShellCheck; do not suppress diagnostics without a narrow reason next to the affected code.
- Keep strict casts, inference, and raw types enabled in the shared package and all platform apps.
- Include the verification commands in the PR template.
- Do not include local `dist/` files, signing material, or generated build caches.

## GitHub Actions Rules

- Keep pull-request and branch checks in `ci.yml`.
- Keep tag-triggered publishing in `release.yml`.
- Add manual operator tasks to `maintenance.yml`; prefer a new task over another
  workflow file. `prepare-release.yml` is intentionally separate because it owns
  the write permissions, global concurrency lock, exact-main verification, tag
  creation, and handoff to `release.yml`. GeoIP must not regain a `schedule`
  trigger; `Maintenance > geoip-refresh` remains only a manual recovery path.
- Split a workflow only when it needs an incompatible trigger, permission boundary,
  or concurrency lock.
- Pin every third-party action to a full commit SHA. Dependency Review on pull requests
  blocks new moderate-or-higher known vulnerabilities; Dependabot, vulnerability alerts,
  and the Dependency Graph remain the recurring maintenance layer.

## UI Responsibility Map

Use these boundaries before adding or removing home-screen behavior:

| Scope | Responsibility |
| --- | --- |
| `SSRVPN_MacOS/lib/app.dart`, `SSRVPN_Windows/lib/app.dart` | Platform startup, shutdown, window state, and OS-specific failure policy |
| `SSRVPN_MacOS/lib/app_runtime_actions_part.dart`, `SSRVPN_Windows/lib/app_runtime_actions_part.dart` | Platform tray connection workflow, runtime notices, and user-facing recovery actions |
| `packages/ssrvpn_shared/lib/services/desktop_connection_coordinator.dart` | Revision- and intent-guarded desktop config preparation, start, preferred-node switch, and owned rollback transaction |
| `SSRVPN_Android/lib/app.dart`, `packages/ssrvpn_shared/lib/desktop_ui/desktop_app_shell_part.dart` | Two-page Home/Subscription composition, shared bottom navigation, synchronized version, and platform startup banners |
| `packages/ssrvpn_shared/lib/widgets/ssrvpn_app_surface.dart` | Shared visual tokens, backdrop, cards, and exactly two bottom-navigation destinations |
| `packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview.dart` | Shared home header, connection action, selected-node summary, About, diagnostics, tutorial, and log entry points |
| `packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_page.dart` and its local parts | Shared node browsing, offline preselection, latency actions, proxy mode, and optional desktop TUN controls |
| `packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_view.dart` | Shared subscription add, list, refresh, delete, and empty-state presentation |
| `desktop_home_screen_part.dart` | Shared desktop home state, lifecycle, connection entrypoint, and adapters for the shared Home/Node Selection surfaces |
| `desktop_home_background_tasks_part.dart` | Initial runtime synchronization, status listeners, latency flushing, and update scheduling |
| `desktop_home_runtime_actions_part.dart` | Shared desktop reload, node selection, latency, update, and runtime actions |
| `desktop_home_public_ip_part.dart` | Shared desktop public-IP refresh state |
| `desktop_subscription_screen_part.dart` | Shared desktop subscription state, dialogs, and adapter for `SsrvpnSubscriptionView` |
| `SSRVPN_Android/lib/screens/home_screen.dart` | Android home state ownership, lifecycle, update scheduling, and adapters for the shared Home/Node Selection surfaces |
| `SSRVPN_Android/lib/screens/subscription_screen.dart` | Android subscription state, dialogs, and adapter for `SsrvpnSubscriptionView` |
| `home_connection_actions_part.dart` | Android connect, reload, proxy mode, and forced-proxy actions |
| `home_node_actions_part.dart` | Android node selection, editing, persistence, and latency actions |
| `home_public_ip_part.dart` | Android public-IP refresh state |

Primary navigation is intentionally limited to Home and Subscription. About is
a Home-only utility and must not appear in Subscription or become a navigation
destination. While disconnected, the remembered/default node remains selectable
and is shown as the pending connection choice; connected node switching
continues to follow the latency and runtime safety policies.

Keep the shared Home concise: it does not permanently show the local runtime
proxy port. If Windows moves a conflicting port, the runtime notice and tray
status must both disclose the actual port. Preserve those assertions in
`scripts/test_windows_proxy_shutdown_recovery.py` when changing the Home layout.

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
| `update_service.dart` | Stable shared update facade, metadata validation, and public update API |
| `update_service_download.dart` | Bounded download, cancellation, redirect, and temporary-file handling |
| `update_service_publication.dart` | Verified publication, recovery, replacement locks, and atomic cleanup |
| `clash_service_base.dart` | Shared lifecycle facade and platform contract |
| `clash_service_diagnostics.dart` | Bounded diagnostic collection, stable failure mapping, and redacted reports |
| `SSRVPN_MacOS/lib/services/settings_service.dart` | Settings migration and serialized persistence orchestration |
| `macos_private_file_store.dart` | Atomic private-file writes, permissions, verification, and temporary-file cleanup |
| `SSRVPN_MacOS/macos/Runner/AppDelegate.swift` | Native application, core-process, proxy-lifecycle, and termination transaction orchestration |
| `CoreProcessSupport.swift` | Native core identity, PID records, bounded output, and owned-process value types |
| `ApplicationLifecycleSupport.swift` | Secure single-instance lease and window reveal support |
| `SSRVPN_Windows/lib/services/system_proxy_service.dart` | Windows proxy lock, acquisition, recovery, and PowerShell transaction ordering |
| `system_proxy_models.dart` | Private snapshot, cancellation, journal, and recovery action models in the same Dart library |

The boundary guard enforces these delegations and practical line limits. A new
part must own a coherent behavior and have characterization tests; line count
alone is not a reason to split.

For security-sensitive lifecycle code, follow
[ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md): move one
mechanically comparable responsibility at a time, keep transaction ordering in
its existing orchestrator, and stop when the next split would need new callbacks,
loading behavior, or a wider interface without stronger target-platform evidence.

Keep a new behavior in the narrowest matching file. Add a new part only when it
creates a distinct responsibility; do not split a short cohesive implementation
only to reduce line count. When moving code, update the matching boundary guard
and run both platform suites for shared desktop changes.

## Release Checklist

1. Update the application version on `main`. Review `CHANGELOG.md` and move
   relevant entries from `Unreleased` to the target version.
2. Verify the pinned assets and prove that GeoIP still matches upstream `latest`:

   ```bash
   make assets
   scripts/verify-core-assets.sh
   python3 scripts/sync-geoip-metadb.py --check
   ```

   The check re-reads the upstream Release and asset identity after verifying the
   downloaded content. A `latest` rollover during verification is a failure, not
   permission to accept either snapshot.

3. Verify the free Android self-signed keystore secrets are available. Desktop
   releases always use the documented free path: macOS ad-hoc without
   notarization and Windows without Authenticode. Do not add Apple/Microsoft
   certificate secrets or paid-signing branches. See `docs/RELEASE_SIGNING.md`.
4. Start GitHub Actions `Prepare Release` with the matching new `vX.Y.Z` tag. It
   automatically refreshes GeoIP, verifies the temporary branch, creates and
   rebase-merges the source-record PR, reruns CI on the exact merged `main`,
   creates the annotated tag, and dispatches `Release`. Do not create the tag
   manually first.
5. Confirm both preparation CI runs are green and watch the automatic handoff
   to the `Release` workflow. The protected branch requires the exact nine
   GitHub Actions checks recorded in `.github/main-branch-protection.json`; the
   orchestrator verifies that policy twice and does not bypass or impersonate it.
   If automated preparation is unavailable, use `Maintenance > geoip-refresh` as
   the manual fallback, merge its PR, wait for `main` CI, and only then create the
   application tag.
6. New releases fail before platform builds if the
   reviewed GeoIP pointer is no longer current; the workflow never rewrites a tag.
   An existing-release retry bypasses this live check only after the exact tag,
   completed asset states, IDs, digests, commit, and provenance all validate.
   The publish job must then find the same Release ID and canonical asset identity;
   it cannot delete or replace an authorized retry if the Release changes mid-run.
   Finalization, polling, and post-publication validation stay bound to that numeric
   ID while allowing only the expected draft-to-public state transition. The asset
   identity is rechecked after OSS promotion and after the public-state poll before
   the recovery backup is discarded.
7. Download artifacts, verify checksums, and optionally run `scripts/check-release-assets.sh vX.Y.Z`.
8. Confirm the Windows build log includes the native registry-sandbox proxy recovery test and the real `SSRVPN_Setup.exe` install/uninstall smoke test, not only packaging and static checks.
9. Smoke test at least one install/run path per platform before announcing.

## Online/Offline Consistency

- Local `main` should track `origin/main`.
- Do not maintain platform-only repositories as active development roots.
- Historical platform repositories have been deleted; keep all maintenance work in this monorepo.
- Any direct GitHub edit must be pulled locally before further local commits.
