# Roadmap

## Completed

- Consolidated Android, macOS, Windows, and shared package into one monorepo.
- Deleted historical platform repositories after moving all development and updates to the monorepo.
- Added monorepo CI and release workflows.
- Added shared models for proxy nodes, proxy groups, and subscriptions.
- Added shared policies for log redaction, private-node latency, and force-proxy site validation.
- Added shared subscription parser and wired it into all three platforms.
- Added shared force-proxy rule generation and wired it into all three platforms.
- Added GitHub issue templates, PR template, CODEOWNERS, Dependabot, security policy, and migration docs.
- Cleared the Android analyzer info backlog and restored strict platform analyzer checks.
- Added release signing documentation and pinned macOS CI/release jobs to a stable runner image.
- Migrated macOS from CocoaPods project files to Flutter Swift Package Manager integration.
- Centralized app version and GitHub release update checks in `packages/ssrvpn_shared`.
- Added deterministic verification for bundled core binaries and geo databases.
- Added Android first-run apiSecret generation backed by encrypted storage.
- Added a free Android release-keystore helper for personal distribution.
- Kept the Android VPN notification synchronized with live node switching and limited traffic refreshes to once per minute while the screen is on.
- Added a per-user Windows installer with running-process handoff while retaining the portable ZIP.

## Near Term

1. Extract more `ClashService` configuration assembly into `packages/ssrvpn_shared`.
2. Keep platform dependency updates current through grouped Dependabot PRs.
3. Keep release artifacts verified after each tag-driven GitHub Actions release.
4. Document any user-facing macOS Gatekeeper and Windows SmartScreen prompts in release notes.

## Medium Term

1. Introduce platform adapters for settings persistence and native process/system proxy behavior.
2. Align `AppSettings` around a shared core model with platform-specific extension fields.
3. Add integration smoke tests for generated Clash config and API group switching.
4. Improve release notes generation from `CHANGELOG.md`.

## Long Term

1. Move reusable UI components into shared packages where platform UX permits.
2. Revisit paid macOS notarization and Windows code signing only if the project needs broader public distribution.
3. Add crash-safe diagnostics bundles with automatic secret redaction.
4. Track coverage and regression metrics in CI.
