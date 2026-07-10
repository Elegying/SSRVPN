# Project Health

Last reviewed: 2026-07-11

## Current Status

SSRVPN is a single Flutter monorepo for Android, macOS, Windows, and `ssrvpn_shared`. The `v3.0.1` release candidate combines the package-guide, Windows flag, conservative unlock, Android startup, and Clash responsibility-boundary work, plus a Windows PowerShell 5.1 UTF-8 guide-title fix discovered by downloading and inspecting the published `v3.0.0` artifacts. It passed the full local gate, Android debug packaging, macOS Release/DMG packaging, macOS UI startup, and native lifecycle tests; remote three-platform CI remains mandatory before tagging.

| Area | Status | Notes |
|---|---|---|
| Repository shape | Good | One workspace, one release pipeline, shared services and policies. |
| Local verification | Healthy | `scripts/verify-all.sh` passes, including analyzers, 352 Flutter tests, four coverage gates, native guards, package-guide checks, and Android JUnit. |
| Shared package | Healthy | 199 tests, 63.02% line coverage; parsing, transactions, bounds, downloads, crashes, controllers, and conservative unlock classification are covered. |
| Android | Healthy | 86 Flutter tests and native APK identity tests pass; debug APK metadata is `3.0.0+300`, and prior arm64 hardware tests covered VPN, notification, background, disconnect, and cleanup flows. |
| macOS | Proxy mode healthy | 34 tests, 32.33% coverage, arm64 Release/DMG packaging, strict ad-hoc validation, UI startup, and Dock lifecycle tests pass. TUN intentionally fails closed until a safe privileged architecture exists. |
| Windows | CI healthy | 33 tests pass and Windows CI validates SVG flags, the native launcher, mitigations, and portable ZIP; final real-device smoke testing remains a release follow-up. |
| Release automation | Hardened | Source must be on `main`; checksums, versions, core assets, signing prerequisites, and artifact shape are checked. |
| Git branch state | Ready for CI | The local refactor branch is ahead of `main`; it must be pushed and pass remote CI before merge or release. |

## Current Coverage Gates

| Target | Verified | Gate |
|---|---:|---:|
| `ssrvpn_shared` | 63.02% | 50% |
| Android | 45.83% | 40% |
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
| Automated verification | 9/10 | The local full gate is green across shared, Android, macOS, Windows, Kotlin/JUnit, packaging, and native macOS lifecycle tests; Windows real-device coverage remains manual. |
| Release readiness | 8/10 | The branch is locally ready for CI, not yet for release; unsigned desktop distribution and intentionally unavailable macOS TUN remain documented limitations. |

## Next Milestones

1. Push the verified `v3.0.1` correction, require all remote CI jobs, then complete the documented Windows real-device smoke matrix.
2. Add Developer ID/notarization and Windows Authenticode signing for trusted desktop distribution.
3. Decide and document the macOS TUN architecture before implementation.
4. Migrate Android to Built-in Kotlin before the next Flutter toolchain upgrade.
5. Split the remaining desktop Home/app UI hotspots by screen sections and raise platform coverage gates with behavior-focused tests.
