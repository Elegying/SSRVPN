# Roadmap

## Completed

- Consolidated Android, macOS, Windows, and shared package into one monorepo.
- Migrated historical platform repositories to migration notices.
- Added monorepo CI and release workflows.
- Added shared models for proxy nodes, proxy groups, and subscriptions.
- Added shared policies for log redaction, private-node latency, and force-proxy site validation.
- Added shared subscription parser and wired it into all three platforms.
- Added shared force-proxy rule generation and wired it into all three platforms.
- Added GitHub issue templates, PR template, CODEOWNERS, Dependabot, security policy, and migration docs.
- Cleared the Android analyzer info backlog and restored strict platform analyzer checks.
- Added release signing documentation and pinned macOS CI/release jobs to a stable runner image.

## Near Term

1. Extract more `ClashService` configuration assembly into `packages/ssrvpn_shared`.
2. Keep platform dependency updates current through grouped Dependabot PRs.
3. Wire signing and notarization secrets into the release workflow.
4. Create the first monorepo release tag and verify artifacts from GitHub Actions.

## Medium Term

1. Introduce platform adapters for settings persistence and native process/system proxy behavior.
2. Align `AppSettings` around a shared core model with platform-specific extension fields.
3. Add integration smoke tests for generated Clash config and API group switching.
4. Improve release notes generation from `CHANGELOG.md`.

## Long Term

1. Move reusable UI components into shared packages where platform UX permits.
2. Add signed and notarized production release pipelines.
3. Add crash-safe diagnostics bundles with automatic secret redaction.
4. Track coverage and regression metrics in CI.
