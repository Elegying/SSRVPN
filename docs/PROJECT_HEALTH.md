# Project Health

Last reviewed: 2026-07-13

## Current Status

SSRVPN is a single Flutter monorepo for Android, macOS, Windows, and `ssrvpn_shared`. The current reviewed worktree builds on the published `v3.1.1` baseline with an upgrade-friendly Windows installer, Android notification correctness and wakeup limiting, OSS-first updates with an exact GitHub fallback, and stricter release recovery. The full local gate, randomized test-order pass, Android native tests, macOS native lifecycle tests, arm64 DMG build/mount validation, and public download checks pass. Windows-native runtime validation remains a CI and real-Windows responsibility.

| Area | Status | Notes |
|---|---|---|
| Repository shape | Good | One workspace, one release pipeline, shared services and policies. |
| Local verification | Healthy | `scripts/verify-all.sh` passes, including zero analyzer findings, 412 passing Flutter tests, one expected Windows-only integration skip on macOS, four coverage gates, 47 release-tool tests, native guards, package-guide checks, and Android JUnit. |
| Shared package | Healthy | 234 tests, 68.29% line coverage; parsing, transactions, bounds, canonical update assets, downloads, crashes, controllers, and conservative unlock classification are covered. |
| Android | Healthy | 96 Flutter tests and Android native tests pass; the public APK is `com.ssrvpn.android` `3.1.1+311`, arm64, and retains the established release certificate. Lifecycle coalescing, start cancellation, public IPv4 routes, notification selection updates, screen-aware refresh limiting, update cleanup, and Quick Tile state have explicit regression coverage. |
| macOS | Proxy mode healthy | 44 Flutter tests, 33.89% coverage, four native lifecycle tests, arm64 Release/DMG packaging, strict ad-hoc validation, UI startup, and Dock lifecycle tests pass. TUN intentionally fails closed until a safe privileged architecture exists. |
| Windows | CI healthy | 38 Flutter tests pass locally and one Windows-binary integration test skips on macOS. Windows CI validates SVG flags, the native launcher, mitigations, portable-data migration, the per-user Inno installer, and the portable ZIP. Final installer lifecycle testing on a real Windows machine remains a release follow-up. |
| Release automation | Hardened | Source must be on `main`; checksums, versions, core assets, signing prerequisites, canonical asset names, provenance, and artifact shape are checked. A stale-source retry is limited to an already-public, complete stable release. The workflow publishes immutable OSS version paths and replaces `latest.json` only after all files verify. |
| Release baseline | Published | The immutable `v3.1.1` tag points at reviewed commit `aac2cce`; GitHub marks it as the latest non-draft, non-prerelease release, and its three canonical backup download URLs resolve successfully. |

## Current Coverage Gates

| Target | Verified | Gate |
|---|---:|---:|
| `ssrvpn_shared` | 68.29% | 50% |
| Android | 58.33% | 40% |
| macOS | 33.89% | 10% |
| Windows | 15.99% | 12% |

The macOS and Windows gates remain deliberately conservative. Raising them should follow new behavior-focused tests, not exclude more source files from coverage.

## Remaining Risks

- macOS TUN is unavailable; re-enabling the former setuid root model is prohibited.
- Windows installer lifecycle, process-closing, portable-data migration, and upgrade behavior still need the documented real-device or clean-VM smoke matrix; CI can build and inspect the EXE but this Mac cannot execute it.
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
| Release readiness | 9/10 | The four user-facing packages are published to OSS and GitHub and independently rechecked; unsigned desktop distribution, Windows real-device coverage, and intentionally unavailable macOS TUN remain documented limitations. |

## Next Milestones

1. Complete the documented Windows 11 real-device or clean-VM smoke matrix for first launch, connection, exit, and proxy restoration.
2. Add Developer ID/notarization and Windows Authenticode signing for trusted desktop distribution.
3. Decide and document the macOS TUN architecture before implementation.
4. Migrate Android to Built-in Kotlin before the next Flutter toolchain upgrade.
5. Split the remaining desktop Home/app UI hotspots by screen sections and raise platform coverage gates with behavior-focused tests.
