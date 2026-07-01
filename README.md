# SSRVPN

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)

SSRVPN is the main monorepo for the Android, macOS, and Windows Flutter clients. It keeps platform-specific UI and native integration in separate app folders while moving shared business logic into one tested package.

## Platforms

- `SSRVPN_Android`: Android VPN client. Release artifact: `SSRVPN.apk`.
- `SSRVPN_MacOS`: macOS desktop client. Release artifact: `SSRVPN.dmg`.
- `SSRVPN_Windows`: Windows portable client. Release artifact: `SSRVPN.zip`.

Older platform-only repositories are kept for history. Active development now happens in this monorepo.

## Repository Structure

- `packages/ssrvpn_shared`: shared models, services, policies, and tests.
- `SSRVPN_Android`: Android UI, VPN service integration, packaging, and update flow.
- `SSRVPN_MacOS`: macOS UI, system proxy/TUN integration, asset installation, and DMG packaging.
- `SSRVPN_Windows`: Windows UI, system proxy/TUN integration, portable packaging, and startup diagnostics.
- `.github/workflows`: monorepo CI and release automation.

## Requirements

- Flutter `3.44.1` stable, also recorded in `.fvmrc`.
- Dart SDK compatible with the selected Flutter release.
- Android SDK/NDK for Android builds.
- Xcode command-line tools and `hdiutil` for macOS builds.
- Visual Studio 2022 with C++ desktop workload for Windows builds.

## Local Verification

Shared package:

```bash
cd packages/ssrvpn_shared
dart pub get
dart analyze
dart test
```

Each platform app:

```bash
flutter pub get
flutter analyze
flutter test
```

Analyzer warnings, infos, and errors should stay fixed before merging.

## Project Health

- `docs/OWNER_GUIDE.zh-CN.md`: owner-friendly Chinese guide for daily sync, feature requests, verification, and releases.
- `docs/PROJECT_MANAGEMENT.md`: branch model, artifact policy, local workflow, and release policy.
- `docs/PROJECT_HEALTH.md`: current completeness, maintainability, release-readiness, and risk scorecard.
- `docs/MAINTENANCE.md`: weekly maintenance, PR, release, and online/offline consistency checklist.
- `docs/ROADMAP.md`: completed work plus near-term, medium-term, and long-term technical roadmap.
- `docs/RELEASE_SIGNING.md`: Android, macOS, and Windows signing/notarization checklist.
- `MIGRATION.md`: migration notes for the historical platform-only repositories.

## Maintainer Shortcuts

Common local operations are wrapped in root-level `make` commands:

```bash
make status
make sync
make feature name=my-change
make verify
```

`dist/` is reserved for local deliverables and is intentionally ignored by Git. Release artifacts should be published through GitHub Releases.

## Release Builds

Android:

```bash
cd SSRVPN_Android
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk SSRVPN.apk
sha256sum SSRVPN.apk > SSRVPN.apk.sha256
```

Windows portable ZIP:

```powershell
cd SSRVPN_Windows
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tool\package_windows.ps1
```

macOS drag-install DMG:

```bash
cd SSRVPN_MacOS
bash tool/package_macos.sh
shasum -a 256 SSRVPN.dmg > SSRVPN.dmg.sha256
```

Tagged pushes matching `v*` run the GitHub release workflow and upload all three platform artifacts plus SHA256 checksums.

## Security

Do not log raw subscription URLs, API secrets, bearer tokens, proxy passwords, or credentials. See `SECURITY.md` for the supported security model and reporting process.
