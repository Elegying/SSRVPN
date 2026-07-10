# Project Health

Last reviewed: 2026-07-10

## Current Status

SSRVPN is a single Flutter monorepo for Android, macOS, Windows, and `ssrvpn_shared`. The released baseline is `v2.4.5`; the comprehensive audit is implemented on `fix/comprehensive-audit-v2.4.5` and has not yet been pushed or validated by remote three-platform CI.

| Area | Status | Notes |
|---|---|---|
| Repository shape | Good | One workspace, one release pipeline, shared services and policies. |
| Local verification | Healthy | `make verify` passes, including analyzers, 329 Flutter tests, coverage gates, native guards, and Android JUnit. |
| Shared package | Healthy | 182 tests, 59.30% line coverage; parsing, transactions, bounds, downloads, crashes, and controllers are covered. |
| Android | Needs device QA | 83 Flutter tests plus native APK identity tests pass; live VPN/update flows still need arm64 hardware. |
| macOS | Proxy mode healthy | 34 tests, 32.21% coverage, Debug build passes. TUN intentionally fails closed until a safe privileged architecture exists. |
| Windows | Needs Windows CI | 30 tests pass on macOS; native launcher, mitigations, and portable packaging require Windows CI/VM. |
| Release automation | Hardened | Source must be on `main`; checksums, versions, core assets, signing prerequisites, and artifact shape are checked. |
| GitHub branch state | Needs cleanup | Remote `main` is still at `v2.4.3`, behind released `v2.4.5` and this audit branch. |

## Current Coverage Gates

| Target | Verified | Gate |
|---|---:|---:|
| `ssrvpn_shared` | 59.30% | 50% |
| Android | 45.49% | 40% |
| macOS | 32.21% | 10% |
| Windows | 14.05% | 12% |

The macOS and Windows gates remain deliberately conservative. Raising them should follow new behavior-focused tests, not exclude more source files from coverage.

## Remaining Risks

- macOS TUN is unavailable; re-enabling the former setuid root model is prohibited.
- Native lifecycle behavior still needs repeatable device/VM smoke tests before release.
- macOS and Windows are distributed without paid platform signing/notarization.
- Desktop settings and subscription data remain in local app/portable storage by product choice.
- Android's current Kotlin plugin works but Flutter reports that a future release will require Built-in Kotlin migration.
- The audit branch has many reviewed commits but no remote PR/CI result yet.

## Recommended Scorecard

| Dimension | Score | Rationale |
|---|---:|---|
| Correctness and recovery | 8/10 | Startup, proxy ownership, update, and subscription rollback paths are substantially stronger. |
| Security | 8/10 | Unsafe macOS/Windows privilege mechanisms were removed and external data is bounded; signing remains incomplete. |
| Maintainability | 8/10 | Shared boundaries, guards, transactional services, and focused tests are good; several platform files remain large. |
| Automated verification | 8/10 | Local full gate is green; Windows native and real-device coverage are still missing. |
| Release readiness | 6/10 | Code is ready for PR/CI, not for an immediate public tag because TUN behavior and native smoke tests need release planning. |

## Next Milestones

1. Merge released history and audit changes back into `main` through a reviewed PR.
2. Pass GitHub CI on Ubuntu, macOS, and Windows, then perform the documented device/VM matrix.
3. Decide and document the macOS TUN architecture before implementation.
4. Cut a `2.5.0` prerelease with explicit TUN and upgrade notes.
5. Migrate Android to Built-in Kotlin before the next Flutter toolchain upgrade.
