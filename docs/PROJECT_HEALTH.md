# Project Health

Last reviewed: 2026-07-12

## Current Status

SSRVPN is a single Flutter monorepo for Android, macOS, Windows, and `ssrvpn_shared`. The published `v3.1.0` release adds an upgrade-friendly Windows installer, Android notification correctness and wakeup limiting, and OSS-first updates with an exact GitHub fallback. It passed three independent review passes covering behavior and lifecycle, security and update supply chain, and maintainability and release operations. The full local gate, untagged three-platform validation build, tag-driven release build, Android hardware upgrade test, macOS DMG mount test, and public OSS/GitHub artifact comparison all passed.

| Area | Status | Notes |
|---|---|---|
| Repository shape | Good | One workspace, one release pipeline, shared services and policies. |
| Local verification | Healthy | `scripts/verify-all.sh` passes, including analyzers, 361 Flutter tests, four coverage gates, native guards, release-tool tests, package-guide checks, and Android JUnit. |
| Shared package | Healthy | 207 tests, 63.68% line coverage; parsing, transactions, bounds, canonical update assets, downloads, crashes, controllers, and conservative unlock classification are covered. |
| Android | Healthy | 87 Flutter tests and Android native tests pass; the public APK is `com.ssrvpn.android` `3.1.0+310`, arm64, and retains the established release certificate. A real arm64 device upgraded from `3.0.1` without data loss, connected successfully, updated the notification immediately from Hong Kong to Singapore, stopped numeric refresh while dozing, and resumed it after wake. |
| macOS | Proxy mode healthy | 34 tests, 32.33% coverage, arm64 Release/DMG packaging, strict ad-hoc validation, UI startup, and Dock lifecycle tests pass. TUN intentionally fails closed until a safe privileged architecture exists. |
| Windows | CI healthy | 33 tests pass and Windows CI validates SVG flags, the native launcher, mitigations, portable-data migration, the per-user Inno installer, and the portable ZIP. The public EXE and ZIP passed checksum and artifact checks; final installer lifecycle testing on a real Windows machine remains a release follow-up. |
| Release automation | Hardened | Source must be on `main`; checksums, versions, core assets, signing prerequisites, canonical asset names, and artifact shape are checked. The workflow publishes immutable OSS version paths and replaces `latest.json` only after all files verify. |
| Release baseline | Published | The immutable `v3.1.0` tag points at reviewed commit `0f29a06`; GitHub marks it as the latest non-draft, non-prerelease release, and public OSS and GitHub downloads are byte-identical. |

## Current Coverage Gates

| Target | Verified | Gate |
|---|---:|---:|
| `ssrvpn_shared` | 63.68% | 50% |
| Android | 46.82% | 40% |
| macOS | 32.33% | 10% |
| Windows | 14.05% | 12% |

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
