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
enforced yet; add one only after the baseline is stable.

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

cd packages/ssrvpn_shared
dart test --coverage=coverage

cd ../../SSRVPN_Android
flutter test --coverage

cd ../SSRVPN_MacOS
flutter test --coverage

cd ../SSRVPN_Windows
flutter test --coverage

scripts/check-release-assets.sh vX.Y.Z
```

When changing process management, system proxy, TUN, MethodChannel, or packaging
behavior, run the relevant platform build/package script in addition to tests.
`scripts/check-release-assets.sh` is a post-release smoke check for GitHub
Release assets and requires network access.
