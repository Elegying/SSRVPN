# Migration From Platform Repositories

Active development has moved to the `Elegying/SSRVPN` monorepo.

Historical repositories:

- `Elegying/SSRVPN_Android`
- `Elegying/SSRVPN_MacOS`
- `Elegying/SSRVPN_Windows`

The platform apps now depend on `packages/ssrvpn_shared` by path, so the supported development layout is this monorepo. Keeping the platform repositories as independent source roots requires vendoring the shared package, using a submodule, or publishing `ssrvpn_shared` separately.

## What Changed

- Shared models, policies, subscription parsing, and config helpers live in `packages/ssrvpn_shared`.
- Android, macOS, and Windows remain in their own app directories.
- CI runs the shared package first, then analyzes and tests all three platform apps.
- Releases are produced from one tagged monorepo workflow.

## Recommended Contributor Flow

```bash
git clone https://github.com/Elegying/SSRVPN.git
cd SSRVPN

cd packages/ssrvpn_shared
dart pub get
dart analyze
dart test

cd ../../SSRVPN_Android
flutter pub get
flutter analyze
flutter test
```

Repeat the app commands for `SSRVPN_MacOS` and `SSRVPN_Windows` when touching shared behavior.
