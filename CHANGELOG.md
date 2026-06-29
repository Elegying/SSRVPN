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

### Changed
- Improved project structure with monorepo approach
- Enhanced CI/CD configuration with matrix builds
- Updated documentation with contributing guidelines and security policy

### Fixed
- Unified error messages across platforms
- Standardized logging with `LogRedactor`
- Consistent force proxy site policy

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
