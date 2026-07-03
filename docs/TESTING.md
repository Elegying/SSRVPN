# Testing Strategy

SSRVPN uses layered tests so platform-specific behavior can be validated without
requiring every native integration in every unit test.

## CI Coverage

The `SSRVPN CI` workflow runs:

- `scripts/verify-core-assets.sh` to reject missing Git LFS binaries, pointer
  files, or unexpected core/geo database hashes
- `dart test --coverage=coverage` for `packages/ssrvpn_shared`
- `flutter test --coverage` for Android, macOS, and Windows

Coverage output is uploaded as GitHub Actions artifacts. No minimum threshold is
enforced for the shared package yet because `dart test --coverage` stores VM
JSON snapshots instead of `lcov.info` here. Android, macOS, and Windows enforce
conservative line coverage floors through `scripts/check-coverage-thresholds.sh`
so obvious regressions fail quickly without pretending the current coverage is
complete.

## Platform Dependencies

- Shared package tests avoid OS process and UI dependencies.
- Android tests cover config generation, subscription parsing, update logic, and
  model behavior; native MethodChannel/VPN behavior is still integration-level.
- macOS tests cover config generation and shared subscription behavior without
  invoking root/TUN or system proxy changes.
- Windows tests include HTTP server mocks for Clash API calls and a Mihomo
  integration smoke test. The integration test runs on Windows when the Git LFS
  `assets/mihomo.exe` binary is available; otherwise it is skipped with an
  explicit reason.

## Local Commands

```bash
scripts/check-shared-barrel-imports.sh
scripts/verify-core-assets.sh
scripts/check-secrets.sh

cd packages/ssrvpn_shared
dart test --coverage=coverage

cd ../../SSRVPN_Android
flutter test --coverage
../scripts/check-coverage-thresholds.sh SSRVPN_Android

cd ../SSRVPN_MacOS
flutter test --coverage
../scripts/check-coverage-thresholds.sh SSRVPN_MacOS

cd ../SSRVPN_Windows
flutter test --coverage
../scripts/check-coverage-thresholds.sh SSRVPN_Windows
```

From the repository root, release and performance smoke checks are:

```bash
scripts/check-release-assets.sh vX.Y.Z
scripts/smoke-release-artifacts.sh --allow-missing
scripts/performance-baseline.sh
```

When changing process management, system proxy, TUN, MethodChannel, or packaging
behavior, run the relevant platform build/package script in addition to tests.
`scripts/check-release-assets.sh` is a post-release smoke check for GitHub
Release assets and requires network access.
`scripts/smoke-release-artifacts.sh` validates local APK/DMG/ZIP structure when
those artifacts exist. `scripts/performance-baseline.sh` records source hotspots,
targeted parser/controller timings, and optional adb startup/memory samples; use
it to compare releases before optimizing for low-end devices.
