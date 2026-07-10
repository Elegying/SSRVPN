# Project Health

Last reviewed: 2026-07-10

## Current Status

SSRVPN is a single Flutter monorepo for Android, macOS, Windows, and `ssrvpn_shared`. The `v2.5.0` release candidate contains the comprehensive audit and has passed local verification, real-device Android and macOS smoke tests, and remote three-platform CI.

| Area | Status | Notes |
|---|---|---|
| Repository shape | Good | One workspace, one release pipeline, shared services and policies. |
| Local verification | Healthy | `make verify` passes, including analyzers, 344 Flutter tests, four coverage gates, native guards, package-guide checks, and Android JUnit. |
| Shared package | Healthy | 194 tests, 62.77% line coverage; parsing, transactions, bounds, downloads, crashes, controllers, and unlock classification are covered. |
| Android | Healthy | 83 Flutter tests and native APK identity tests pass; live VPN, notification, background, disconnect, and cleanup flows were verified on arm64 hardware. |
| macOS | Proxy mode healthy | 34 tests, 32.21% coverage, Debug build passes. TUN intentionally fails closed until a safe privileged architecture exists. |
| Windows | CI healthy | 33 tests pass and Windows CI validates SVG flags, the native launcher, mitigations, and portable ZIP; final real-device smoke testing remains a release follow-up. |
| Release automation | Hardened | Source must be on `main`; checksums, versions, core assets, signing prerequisites, and artifact shape are checked. |
| GitHub branch state | Ready to release | PR #21 is mergeable and its Android, macOS, Windows, workspace, and core-asset jobs are green. |

## Current Coverage Gates

| Target | Verified | Gate |
|---|---:|---:|
| `ssrvpn_shared` | 62.77% | 50% |
| Android | 45.49% | 40% |
| macOS | 32.21% | 10% |
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
| Maintainability | 8/10 | Shared boundaries, guards, transactional services, and focused tests are good; several platform files remain large. |
| Automated verification | 8/10 | Local full gate and remote three-platform CI are green; Windows real-device coverage remains manual. |
| Release readiness | 8/10 | Code and online builds are ready for `v2.5.0`; unsigned desktop distribution and intentionally unavailable macOS TUN are documented limitations. |

## Next Milestones

1. Monitor the `v2.5.0` release and complete the documented Windows real-device smoke matrix.
2. Add Developer ID/notarization and Windows Authenticode signing for trusted desktop distribution.
3. Decide and document the macOS TUN architecture before implementation.
4. Migrate Android to Built-in Kotlin before the next Flutter toolchain upgrade.
5. Raise platform coverage gates with behavior-focused tests.
