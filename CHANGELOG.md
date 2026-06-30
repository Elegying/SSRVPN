# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
