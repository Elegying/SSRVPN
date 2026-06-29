# SSRVPN

SSRVPN is a three-platform Flutter VPN client workspace built around a shared core package.

## Repository Structure

- `packages/ssrvpn_shared`: shared models, services, utilities, and constants
  - `models/`: data structures for proxy nodes, groups, subscriptions, and settings
  - `services/`: core business logic for subscription parsing and Clash config generation
  - `utils/`: utility classes for logging, proxy policies, and latency handling
  - `constants/`: application-wide constants and configuration values
- `SSRVPN_Android`: Android VPN client. Release artifact: `SSRVPN_Android/SSRVPN.apk`.
- `SSRVPN_MacOS`: macOS desktop client. Release artifact: `SSRVPN_MacOS/SSRVPN.dmg`.
- `SSRVPN_Windows`: Windows portable client. Release artifact: `SSRVPN_Windows/SSRVPN.zip`.
- `LICENSE`: MIT License
- `CHANGELOG.md`: project update history
- `CONTRIBUTING.md`: contribution guidelines
- `SECURITY.md`: security policy

## Repository Layout

The recommended GitHub layout is a single monorepo rooted at this directory. The platform apps depend on `../packages/ssrvpn_shared`, so publishing each platform as a standalone repository requires either vendoring the shared package, using a Git submodule, or publishing `ssrvpn_shared` as a private package.

## Local Verification

Shared package:

```bash
cd packages/ssrvpn_shared
dart test
dart analyze
```

Each platform app:

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

Android currently has a UI-level lint backlog made mostly of `prefer_const_*` info diagnostics. Warnings and errors should remain fixed.

## Release Builds

Android:

```powershell
cd SSRVPN_Android
flutter build apk --release
Copy-Item .\build\app\outputs\flutter-apk\app-release.apk .\SSRVPN.apk -Force
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
```

macOS builds require a macOS machine with Xcode command-line tools and `hdiutil`.
