# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.9] - 2026-07-04

### Fixed
- Silenced Android notification MethodChannel fallback when the native foreground VPN service already owns the persistent notification.

## [2.0.8] - 2026-07-04

### Added
- Added a CI guard that verifies Android native bridge calls stay behind timeout-protected helpers.

### Fixed
- Moved Android Mihomo native start/init, stop, and running-state checks behind daemon workers with bounded waits to prevent UI-thread ANR during connect/disconnect cleanup.

## [2.0.6] - 2026-07-03

### Changed
- Bumped Android, macOS, and Windows client versions to `2.0.6+206`.
- Updated in-app project links to the canonical `Elegying/SSRVPN` monorepo.
- Refreshed repository cleanup and release checklist documentation after deleting historical platform repositories.

## [2.0.5] - 2026-07-02

### Changed
- Bumped Android, macOS, and Windows client versions to `2.0.5+205`.
- Desktop startup screens now show a clean progress bar instead of internal startup step identifiers or log paths.

## [2.0.4] - 2026-07-02

### Added
- CI now collects coverage artifacts for the shared package and all three Flutter apps.
- Added public UI design, testing strategy, and core binary source documentation.
- Release workflow now verifies the macOS drag-install DMG shape and Windows portable ZIP contents.

### Changed
- Bumped Android, macOS, and Windows client versions to `2.0.4+204`.
- Platform code and tests now import `ssrvpn_shared` through the package barrel.
- Android tutorial steps are data-driven instead of hardcoded directly in the dialog widget tree.

### Fixed
- Generated Clash configs now rebuild subscription proxies from parsed YAML to avoid user-controlled YAML escaping through node fields.
- Home screen config reload failures now surface an error instead of silently clearing connection state.
- Desktop first-run subscription dialog is consumed once per app run, preventing resize/rebuild repeats.

## [2.0.3] - 2026-07-02

### Fixed
- macOS DMG Finder layout is applied through the mounted folder so drag-to-Applications presentation is enforced during release builds.

## [2.0.2] - 2026-07-02

### Changed
- Bumped Android, macOS, and Windows client versions to `2.0.2+202`.
- macOS DMG packaging now uses a drag-to-Applications layout with an Applications shortcut.

## [2.0.1] - 2026-07-02

### Changed
- Bumped Android, macOS, and Windows client versions to `2.0.1+201`.

### Fixed
- Release workflow now requires Android release signing secrets and verifies APK signatures before publishing.

### Added
- Owner-friendly project management scripts: `make status`, `make sync`, `make feature`, and `make verify`.
- `docs/OWNER_GUIDE.zh-CN.md` and `docs/PROJECT_MANAGEMENT.md` for local/GitHub workflow, artifact policy, and release management.
- Shared package `ssrvpn_shared` with cross-platform models and services
- `SubscriptionParser` for YAML parsing and SSR link import
- `ClashConfigGenerator` for Clash configuration generation
- `AppSettings` model with JSON serialization
- `AppConstants` for magic numbers and configuration values
- Unit tests for shared package (5 test files)
- Barrel file `ssrvpn_shared.dart` for easy imports
- MIT License
- Changelog file
- Monorepo CI badge and `.fvmrc` pinned to Flutter 3.44.1
- Repository-level `.gitattributes` for stable line endings
- GitHub issue templates, pull request template, CODEOWNERS, and Dependabot configuration
- Project health, maintenance, and roadmap documentation
- Grouped Dependabot maintenance for GitHub Actions and platform Dart dependencies
- Release signing and notarization checklist for Android, macOS, and Windows

### Changed
- Improved project structure with monorepo approach
- Enhanced CI/CD configuration with matrix builds
- Updated documentation with contributing guidelines and security policy
- Platform READMEs now point to the monorepo workflow
- Android, macOS, and Windows subscription parsing now reuse shared parser logic
- Android, macOS, and Windows force-proxy rule generation now reuses shared logic
- Release workflow fetches complete tag history before generating release notes
- Shared package CI now uses the same pinned Flutter SDK as the platform apps
- Root audit notes were consolidated into maintained docs under `docs/`
- GitHub Actions and platform Dart dependencies were updated through grouped Dependabot PRs
- Platform analyzer checks now run in strict `flutter analyze` mode
- macOS CI and release jobs now pin a stable macOS runner image

### Fixed
- Unified error messages across platforms
- Standardized logging with `LogRedactor`
- Consistent force proxy site policy
- Android settings service syntax error that blocked `flutter analyze`
- Android dependency lockfile drift after adding encrypted secure storage
- Standard `ss://method:password@host:port` URI parsing
- YAML string ports in parsed subscriptions
- Unknown proxy-group entries being added as fake nodes
- API secret YAML quoting in generated Clash config
- IPv6 force-proxy rule leakage in shared config generation
- Android analyzer info backlog after Flutter lint and secure storage updates

## [1.0.0] - 2026-06-20

### Added
- Initial release
- Android, macOS, and Windows clients
- Shared models for proxy nodes, groups, and subscriptions
- Basic CI/CD configuration
- Contributing guidelines
- Security policy

## [0.9.0] - 2026-06-15

### Added
- Beta release
- Core VPN functionality
- Subscription management
- Proxy node testing
- System proxy configuration

## [0.8.0] - 2026-06-10

### Added
- Alpha release
- Basic UI framework
- Clash core integration
- Settings management

## [0.7.0] - 2026-06-05

### Added
- Pre-alpha release
- Project setup
- Architecture design
- Initial codebase
