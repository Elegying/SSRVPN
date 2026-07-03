# Project Health

Last reviewed: 2026-07-03

## Current Status

SSRVPN is maintained from the `Elegying/SSRVPN` monorepo. The historical platform-only repositories have been deleted, so this repository is now the single source for code, issues, releases, and app update checks.

| Area | Status | Notes |
|------|--------|-------|
| Repository shape | Healthy | Single monorepo with Android, macOS, Windows, and `ssrvpn_shared`. |
| Online CI | Healthy | Main monorepo CI is green on `main`. |
| Shared package | Healthy | Shared models, parser, force-proxy policy, log redaction, latency policy, unlock tests, and config helpers are covered by tests. |
| Android | Functional | Analyze/test pass with strict analyzer settings. |
| macOS | Functional | Analyze/test pass; Flutter Swift Package Manager integration is enabled and CocoaPods project files have been removed. |
| Windows | Functional | Analyze/test pass; Mihomo integration test is skipped when the binary is unavailable in the test environment. |
| Release automation | Good | Tag-driven release workflow builds all platforms, verifies bundled core assets, publishes checksums, and supports free Android self-signed release signing. |

## Remaining Risks

- `ClashService` remains large on all three platforms. Platform-native behavior is still mixed with config assembly and API orchestration.
- Platform `AppSettings` models are still separate because each app has different persisted fields.
- macOS and Windows are intentionally distributed without paid platform certificates for now. Users may see Gatekeeper or SmartScreen warnings.
- Desktop settings, subscription URLs, and caches intentionally stay in the app-local profile/config area so uninstalling or deleting the portable folder removes the app data.
- Native integration paths still need manual smoke testing on real devices before each public release.

## Recommended Scorecard

| Dimension | Score | Direction |
|-----------|-------|-----------|
| Project completeness | 8/10 | Core app, docs, CI, release workflow, and migration story exist. |
| Maintainability | 7/10 | Shared logic is improving, but service classes remain large. |
| Professional GitHub presence | 8/10 | Templates, CI, Dependabot, security policy, migration docs, and a single canonical repository are in place. |
| Runtime reliability | 7/10 | Tests cover key parsing/config paths; platform integration needs more real-device release validation. |
| Release readiness | 8/10 | Artifacts build via workflow, core assets and release assets are verifiable, and Android can be self-signed for free. |

## Next Audit Focus

1. Extract a platform-neutral config assembly layer from `ClashService`.
2. Keep strict analyzer checks green as dependencies and lints evolve.
3. Continue reducing platform-specific duplication in update, subscription, and settings code.
4. Keep the free-only release posture documented and visible to users.
5. Verify release artifacts end-to-end after every tag.
