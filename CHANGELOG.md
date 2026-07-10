# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.1] - 2026-07-11

### 修复

- 修复 Windows 便携 ZIP 中文教程标题在 Windows PowerShell 5.1 下被错误代码页解码而显示乱码的问题。
- 让 ZIP 产物冒烟检查兼容 Windows 路径分隔符，并校验教程标题和版本格式，防止同类编码回归。

## [3.0.0] - 2026-07-11

### 新增

- macOS DMG 内加入中文安装和首次使用说明，Windows 便携 ZIP 内加入中文解压、启动、导入和连接说明。
- Windows 节点列表改用与 Android、macOS 一致的国旗资源，并为未知地区保留明确的安全回退图标。

### 修复

- 解锁检测改为证据优先：Netflix 和 YouTube Premium 只有在官方域名、明确页面证据同时成立时才显示“支持”；页面变化、模糊响应或跨域跳转统一显示“无法判断”。
- Android 初始化超时后的重试复用仍在执行的初始化任务，避免两套核心服务并发启动；手动重试会正确重置重试状态。
- 将 macOS 和 Windows 的核心进程生命周期、系统代理协调与配置生成职责拆分，保持启动失败回滚和代理清理顺序可验证。

### 变更

- 解锁检测统一使用本地代理、HTTPS 重定向限制、响应大小上限和并发上限，区分“支持”“可访问”“不支持”“无法判断”和“检测失败”。
- CI 和正式发布工作流增加 Clash 服务职责边界检查，三端构建继续执行分析、测试、核心资源校验和安装包冒烟检查。
- 完善三端正式发布审查文档、项目健康记录和安装包内容检查。

## [2.5.0] - 2026-07-10

### Security

- Removed the macOS setuid-root Mihomo model. macOS TUN now fails closed until a
  Network Extension or audited privileged helper is available; system proxy
  mode continues to work with an unprivileged, SHA256-verified core, and the
  macOS UI marks TUN as unavailable instead of requesting administrator access.
- Removed the invalid Windows PE header patch that marked the portable launcher
  as AppContainer instead of CET-compatible, and now use the supported MSVC
  linker flags.
- Added a reliable one-time cleanup path and upgrade guidance for Windows
  mitigation exceptions created by older SSRVPN releases.
- Android update installation now verifies package name, version code, and the
  installed signing certificate or valid signing lineage immediately before
  invoking the system installer.
- Update downloads now require exact HTTPS GitHub assets, bounded streaming,
  matching SHA256 checksums, and a secure final redirect URL on all platforms.
- Subscription redirects reject HTTPS downgrades; response headers, bodies,
  chunk metadata, read duration, and Android gzip expansion are bounded.
- Android API secrets now fail safely on Keystore errors and remove legacy
  copies only after secure persistence succeeds.
- Disabled Android application backups so subscription credentials and
  Keystore-backed storage artifacts are not copied outside the app sandbox.

### Fixed

- Serialized settings, subscription, desktop core, and system-proxy startup so
  concurrent callers cannot observe partially initialized or conflicting state.
- Invalidated stale Android VPN permission callbacks and made native bridge
  health checks fail closed.
- Restored desktop proxy settings only while the exact SSRVPN-owned endpoint is
  still active, preserving later user or third-party changes.
- Made subscription refresh transactional with rollback and bounded hostile
  input, fixed proxy-node double escaping, and reduced duplicate-name merging
  from quadratic behavior.
- Bounded timed process cleanup, startup logs, log redaction, crash-report
  storage, and Windows dump retention.
- Fixed shared Flutter coverage generation and workspace barrel-import checks.
- Android now requests notification permission once after the first successful
  VPN connection so the ongoing status and disconnect action remain visible.

### Changed

- Replaced Git LFS build inputs with ignored, reproducibly bootstrapped core
  assets from immutable GitHub Releases, verified before extraction by SHA256.
- Release tags and manual release commits must already belong to `main`; Actions
  are pinned to immutable commits and asset checks use authenticated GitHub API
  requests.
- CI now runs Android Kotlin/JUnit update identity tests and validates macOS core
  privilege and Windows launcher security invariants.
- Dependabot and dependency checks now operate once at the Flutter workspace
  root, and GeoIP freshness is separated from deterministic pull-request checks.
- Android debug builds now install beside release builds under a distinct
  package name and `SSRVPN Debug` label, preserving release app data.

## [2.4.5] - 2026-07-07

### 修复
- 修复桌面端三栏布局下连接状态文字被右侧操作区挤压，导致“已连接”显示不全的问题。

### 变更
- 发布说明和检查更新弹窗中的固定更新日志文案改为中文。

## [2.4.4] - 2026-07-07

### Changed
- Aligned the desktop Home proxy mode selector with the proxy method card layout on Windows and macOS.

## [2.4.3] - 2026-07-07

### Fixed
- Suppressed misleading Windows native crash dumps during normal shutdown.
- Fixed Windows diagnostic and CET helper scripts for UTF-8 output and Windows PowerShell 5.1 compatibility.
- Stopped showing full subscription and proxy node URLs in desktop subscription cards.
- Updated Windows portable support text to avoid publicly sharing `.dmp` files.

## [2.4.2] - 2026-07-07

### Fixed
- Fixed the Windows portable package so the root launcher includes the Visual C++ runtime DLLs it needs on clean Windows machines.
- Improved the Windows Home connection module at 1280x720 and compact window sizes by using a denser connection panel and responsive power button sizing.

### Changed
- Added online CI validation and artifact upload for the Windows portable ZIP so release packaging regressions are caught before publishing.

## [2.4.1] - 2026-07-07

### Fixed
- Restored macOS Dock reopen behavior after closing the main window to the menu bar, so clicking the Dock icon brings SSRVPN back without requiring the menu bar icon.
- Updated the macOS XCTest host/product reference from the old `ssrvpn_client.app` name to `SSRVPN.app` so native lifecycle tests run against the current app bundle.

## [2.4.0] - 2026-07-07

### Added
- Added Android in-app updates that download the release APK inside SSRVPN, verify its SHA256 checksum, and then launch the Android system installer.
- Android now resumes the APK installation automatically after the user grants "install unknown apps" permission for SSRVPN.

## [2.3.2] - 2026-07-07

### Fixed
- Fixed macOS and Windows Home node selection so the selected node is confirmed from Mihomo's runtime selector state instead of trusting the expected node after startup or switching.
- Fixed proxy switching to report success only after Mihomo's `PROXY` and `GLOBAL` groups reflect the requested node, preventing the UI from showing a node that is not actually active.

## [2.3.1] - 2026-07-07

### Fixed
- Improved the Home connection module public IP layout on small screens so the country code remains visible on Android, macOS, and Windows.

## [2.3.0] - 2026-07-06

### Added
- Show the current public IP address and country code in the Home connection module after connecting, with a manual refresh action.

### Changed
- Public IP, connectivity, unlock, and exit-country checks now require the local proxy path instead of falling back to direct network access.
- Home and startup node selection now ignore non-runnable subscription info rows when choosing or counting nodes.

### Fixed
- Prevent subscription info pseudo nodes from entering runtime proxy groups, and stop desktop exit-country resolution from switching the active proxy node in the background.

## [2.2.0] - 2026-07-06

### Changed
- Unlock tests now use a compact list view with trailing support status text and clickable official-site links.

## [2.1.0] - 2026-07-06

### Changed
- Removed the obsolete settings screen and stopped persisting startup, theme, tray, and automatic subscription-update software preferences.
- Shared Clash configuration generation caching through the common Clash service base.
- Release workflow now generates GitHub release notes from `CHANGELOG.md`.
- CI now prints and enforces shared and platform coverage thresholds aligned to
  the current automated test baseline.
- Release builds now fetch and SHA256-verify the latest `geoip.metadb` from
  `MetaCubeX/meta-rules-dat`, then sync one deterministic gzip copy into all
  three platform assets.
- Generated Mihomo configs now use CN domain/IP rule providers and trigger one
  silent provider update 10 minutes after the Mihomo core starts.

### Fixed
- Expanded log redaction for URL query credentials, URL userinfo, JSON credential fields, and non-Bearer authorization formats.

## [2.0.13] - 2026-07-04

### Fixed
- Fixed HTTP subscription imports so Android, macOS, and Windows use the subscription profile title from response headers instead of defaulting to the URL host.

## [2.0.12] - 2026-07-04

### Added
- Added mainstream URI subscription parsing for VLESS, Hysteria, Hysteria2, TUIC, Snell, SOCKS5, HTTP, and HTTPS proxy nodes.
- Added subscription-source grouping on the home screen, with standalone imported nodes pinned above collapsible multi-subscription groups.

### Changed
- Subscription imports now use the subscription host or single-node name by default instead of forcing the `SSRVPN.VIP` name.
- Node edits are normalized before writing cached YAML so common proxy types keep required fields and app-only metadata stays out of Mihomo config files.

### Fixed
- Fixed node editing for newer protocol types so password, UUID, and SNI fields are preserved where required.
- Fixed force-proxy site rule normalization for full URLs, wildcard domains, duplicate hosts, and IPv4 addresses.

## [2.0.11] - 2026-07-04

### Added
- Added local secret scanning, conservative coverage gates, release artifact smoke checks, and a low-end-device performance baseline script.
- Added a shared timed process runner with tests for bounded desktop process execution.

### Changed
- Shared the remaining duplicate macOS/Windows desktop screens through the shared package.
- Unified common runtime logging behind a redacted shared logger.
- Upgraded Android release tooling to Gradle 8.14.3, Android Gradle Plugin 8.11.1, and Kotlin Gradle Plugin 2.2.20.
- Enhanced Lite crash reporting so copied reports include the GitHub issue submission entry.

## [2.0.10] - 2026-07-04

### Fixed
- Implemented Android startup `syncSettings` on the native channel and added a release guard for the startup MethodChannel.

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
