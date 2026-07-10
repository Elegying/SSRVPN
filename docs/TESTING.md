# Testing Strategy

SSRVPN uses layered tests so platform-specific behavior can be validated without
requiring every native integration in every unit test.

## CI Coverage

The `SSRVPN CI` workflow runs:

- `scripts/check-core-asset-bootstrap.sh` to reject tracked binaries or a
  reintroduced Git LFS dependency
- `scripts/bootstrap-core-assets.sh` and `scripts/verify-core-assets.sh` to
  obtain immutable release assets and reject unexpected core/GeoIP hashes
- `flutter test --coverage` for `packages/ssrvpn_shared`
- `flutter test --coverage` for Android, macOS, and Windows
- `scripts/test-android-native.sh` for Kotlin/JUnit update-install identity tests

Coverage output is uploaded as GitHub Actions artifacts. Conservative line
coverage floors are enforced through `scripts/check-coverage-thresholds.sh`:
shared 50%, Android 40%, macOS 10%, and Windows 12%. These thresholds catch
obvious regressions without pretending the current coverage is complete.

Normal CI validates the GeoIP database against the hashes committed in
`docs/GEOIP_SOURCE.txt`, keeping pull-request checks deterministic. The separate
`GeoIP Freshness` scheduled/manual workflow runs
`scripts/sync-geoip-metadb.py --check` daily to report upstream updates without
making unrelated pull requests fail. Release builds still synchronize the
latest verified upstream database before packaging.

## Platform Dependencies

- Shared package tests avoid OS process and UI dependencies.
- Android tests cover config generation, subscription parsing, secure settings,
  update logic, APK identity validation, and model behavior; live VPN behavior
  is still integration-level.
- macOS tests cover config generation and shared subscription behavior without
  changing system proxy state. They also verify that TUN fails closed and that
  legacy privileged/symlinked cores cannot cross the file boundary.
- Windows tests include HTTP server mocks for Clash API calls and a Mihomo
  integration smoke test. CI bootstraps the verified `assets/mihomo.exe`
  binary before the Windows job, so the integration test runs there.

## Local Commands

```bash
make verify
make assets

scripts/check-shared-barrel-imports.sh
scripts/verify-core-assets.sh
scripts/check-secrets.sh

cd packages/ssrvpn_shared
flutter test --coverage
../../scripts/check-coverage-thresholds.sh packages/ssrvpn_shared

cd ../../SSRVPN_Android
flutter test --coverage
../scripts/check-coverage-thresholds.sh SSRVPN_Android
../scripts/test-android-native.sh

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
