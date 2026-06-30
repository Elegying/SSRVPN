# Project Health

Last reviewed: 2026-06-30

## Current Status

SSRVPN is now maintained from the `Elegying/SSRVPN` monorepo. The historical platform-only repositories remain available for release history and point contributors back to this repository.

| Area | Status | Notes |
|------|--------|-------|
| Repository shape | Healthy | Single monorepo with Android, macOS, Windows, and `ssrvpn_shared`. |
| Online CI | Healthy | Main monorepo CI is green on `main`. |
| Shared package | Healthy | Shared models, parser, force-proxy policy, log redaction, latency policy, unlock tests, and config helpers are covered by tests. |
| Android | Functional | Analyze/test pass with strict analyzer settings. |
| macOS | Functional | Analyze/test pass; Flutter warns that CocoaPods integration can be migrated to Swift Package Manager. |
| Windows | Functional | Analyze/test pass; Mihomo integration test is skipped when the binary is unavailable in the test environment. |
| Release automation | Good | Tag-driven release workflow builds all platforms and publishes checksums. |

## Remaining Risks

- `ClashService` remains large on all three platforms. Platform-native behavior is still mixed with config assembly and API orchestration.
- Platform `AppSettings` models are still separate because each app has different persisted fields.
- macOS still carries CocoaPods project files even though Flutter reports plugins are available as Swift Packages.
- Release signing and notarization are not fully automated. Android signing, Windows code signing, and macOS notarization should be handled with repository secrets before public production releases.

## Recommended Scorecard

| Dimension | Score | Direction |
|-----------|-------|-----------|
| Project completeness | 8/10 | Core app, docs, CI, release workflow, and migration story exist. |
| Maintainability | 7/10 | Shared logic is improving, but service classes remain large. |
| Professional GitHub presence | 8/10 | Templates, CI, Dependabot, security policy, migration docs, and old repo pointers are in place. |
| Runtime reliability | 7/10 | Tests cover key parsing/config paths; platform integration and signing need more release validation. |
| Release readiness | 7/10 | Artifacts build via workflow, but signing/notarization and first monorepo tag/release are still pending. |

## Next Audit Focus

1. Extract a platform-neutral config assembly layer from `ClashService`.
2. Keep strict analyzer checks green as dependencies and lints evolve.
3. Migrate macOS away from CocoaPods if package compatibility remains stable.
4. Add signed release documentation and repository secrets checklist.
5. Create the first monorepo tag and verify release artifacts end-to-end.
