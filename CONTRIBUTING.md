# Contributing to SSRVPN

SSRVPN is organized as a multi-platform Flutter workspace:

- `packages/ssrvpn_shared` contains platform-neutral models, policies, and services.
- `SSRVPN_Android`, `SSRVPN_MacOS`, and `SSRVPN_Windows` contain platform-specific UI and native integration.

## Development Rules

- Keep `main` stable and use `feature/*`, `fix/*`, or `chore/*` branches for new work.
- Put reusable business logic in `packages/ssrvpn_shared` first.
- Keep platform code focused on UI, native services, packaging, and OS-specific behavior.
- Do not log raw subscription URLs, API secrets, passwords, bearer tokens, or proxy credentials.
- Keep Android, macOS, and Windows behavior aligned unless a platform capability requires a difference.
- Do not commit local deliverables from `dist/`, APK/DMG/ZIP files, signing keys, or generated build caches.

## Verification

Run shared package checks:

```bash
cd packages/ssrvpn_shared
dart test
dart analyze
```

Run app checks from each app directory:

```bash
flutter pub get
flutter analyze
flutter test
```

Keep `flutter analyze` clean before opening or merging a PR.

## Issues

Use the GitHub issue templates for bugs, feature requests, and maintenance tasks. Security reports should follow `SECURITY.md` and should not be filed as public issues.

## Pull Requests

Each PR should include:

- A short summary of user-visible behavior changes.
- The platforms affected: Android, macOS, Windows, shared.
- Verification commands run locally.
- Screenshots or recordings for UI changes.
- Notes for release or migration risks.

See `docs/MAINTENANCE.md` for the weekly maintenance rhythm, release checklist, and online/offline consistency rules.
See `docs/PROJECT_MANAGEMENT.md` for the branch model and artifact policy.
