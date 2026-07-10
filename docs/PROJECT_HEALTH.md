# Project Health

Last reviewed: 2026-07-10

## Current Status

SSRVPN is a single Flutter monorepo for Android, macOS, Windows, and `ssrvpn_shared`. The `v2.5.0` release candidate contains the comprehensive audit and passed real-device Android and macOS smoke tests plus remote three-platform CI. The follow-up Clash boundary refactor has passed the full local gate and a macOS Release build; it still needs remote CI before merge or release.

| Area | Status | Notes |
|---|---|---|
| Repository shape | Good | One workspace, one release pipeline, shared services and policies. |
| Local verification | Healthy | `make verify` passes, including analyzers, 347 Flutter tests, four coverage gates, native guards, package-guide checks, and Android JUnit. |
| Shared package | Healthy | 197 tests, 62.96% line coverage; parsing, transactions, bounds, downloads, crashes, controllers, and unlock classification are covered. |
| Android | Healthy | 83 Flutter tests and native APK identity tests pass; live VPN, notification, background, disconnect, and cleanup flows were verified on arm64 hardware. |
| macOS | Proxy mode healthy | 34 tests, 32.33% coverage, Release build passes. TUN intentionally fails closed until a safe privileged architecture exists. |
| Windows | CI healthy | 33 tests pass and Windows CI validates SVG flags, the native launcher, mitigations, and portable ZIP; final real-device smoke testing remains a release follow-up. |
| Release automation | Hardened | Source must be on `main`; checksums, versions, core assets, signing prerequisites, and artifact shape are checked. |
| Git branch state | Ready for CI | The local refactor branch is ahead of `main`; it must be pushed and pass remote CI before merge or release. |

## Current Coverage Gates

| Target | Verified | Gate |
|---|---:|---:|
| `ssrvpn_shared` | 62.96% | 50% |
| Android | 45.49% | 40% |
| macOS | 32.33% | 10% |
| Windows | 14.05% | 12% |

The macOS and Windows gates remain deliberately conservative. Raising them should follow new behavior-focused tests, not exclude more source files from coverage.

## Remaining Risks

- macOS TUN is unavailable; re-enabling the former setuid root model is prohibited.
- Windows native lifecycle behavior still needs repeatable real-device or VM smoke tests after the online release build.
- macOS and Windows are distributed without paid platform signing/notarization.
- Desktop settings and subscription data remain in local app/portable storage by product choice.
- Android's current Kotlin plugin works but Flutter reports that a future release will require Built-in Kotlin migration.

## Recommended Scorecard

| Dimension | Score | Rationale |
|---|---:|---|
| Correctness and recovery | 8/10 | Startup, proxy ownership, update, and subscription rollback paths are substantially stronger. |
| Security | 8/10 | Unsafe macOS/Windows privilege mechanisms were removed and external data is bounded; signing remains incomplete. |
| Maintainability | 9/10 | Shared config, platform config, and core lifecycle/proxy coordination now have enforced private boundaries; the remaining 900-line hotspots are UI composition files. |
| Automated verification | 8/10 | The local full gate is green; the follow-up refactor still needs remote three-platform CI and Windows real-device coverage remains manual. |
| Release readiness | 8/10 | The branch is locally ready for CI, not yet for release; unsigned desktop distribution and intentionally unavailable macOS TUN remain documented limitations. |

## Next Milestones

1. Push the verified refactor branch, require all remote CI jobs, then complete the documented Windows real-device smoke matrix.
2. Add Developer ID/notarization and Windows Authenticode signing for trusted desktop distribution.
3. Decide and document the macOS TUN architecture before implementation.
4. Migrate Android to Built-in Kotlin before the next Flutter toolchain upgrade.
5. Split the remaining desktop Home/app UI hotspots by screen sections and raise platform coverage gates with behavior-focused tests.
