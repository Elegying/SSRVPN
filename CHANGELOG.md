# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.3.3] - 2026-07-14

### 变更

- Windows 安装版改为每次全新覆盖：安装前清空固定安装目录、LocalAppData 回退配置、窗口状态和旧安装恢复状态，不再搜索、备份或恢复旧订阅与设置；升级后需要重新导入订阅。
- Windows 安装版继续使用 `%LOCALAPPDATA%\Programs\SSRVPN` 与当前用户桌面/开始菜单，不写入 `Program Files`，安装和系统代理模式均无需管理员权限。

### 修复

- 删除会因旧数据备份或恢复失败而中止安装的辅助流程；进程和自有系统代理清理仍在覆盖前执行，即使清理脚本返回错误也不主动阻断安装。

## [3.3.2] - 2026-07-14

### 修复

- Windows 安装器不再让旧安装残留的不完整恢复状态永久阻断健康、可写的原地升级；只有确实重建安装目录时才在安装完成后恢复已校验数据，陈旧恢复证据继续保留以便排查。
- Windows Flutter 主进程正常退出、崩溃或被结束后，外层启动器会使用现有的所有权快照恢复系统代理；第二实例只唤醒主窗口，不会误清理仍在使用的代理。
- Windows 原生代理完整恢复失败时，至少关闭仍能确认属于 SSRVPN 的不可达本地代理端点，避免用户第二天需要手工修复 IE/系统代理才能联网。

## [3.3.1] - 2026-07-14

### 修复

- macOS 断开连接时先恢复系统代理，再终止本地 Mihomo；代理恢复失败会保留核心和状态监控供用户重试，避免应用流量被留在不可达的本地代理上。
- 移除共享服务中未被调用的明文 HTTP 出口地区查询及 Android 未接入界面的旧地理服务，不再保留 `ip-api.com` 非加密备用入口。

### 维护

- 将 macOS 与 Windows 重复的窗口状态持久化和启动日志轮转提取到共享包，平台层只保留路径、控制台和 Windows 故障报告差异；连接生命周期继续独立维护。
- 共享包启用 Flutter 推荐 lint，补齐直接依赖并清理全部现存 lint；新增窗口状态、日志轮转和脱敏回归测试。

## [3.3.0] - 2026-07-14

### 新增

- 新增统一的中文用户指南、按症状组织的故障排查、当前文档索引和桌面 API secret 存储决策记录，平台指南只保留各自安装、权限与行为差异。

### 变更

- Android 核心启动健康检查改为访问带 Bearer 认证的 Mihomo `/version`，只有在同一个绝对 20 秒截止时间内返回受限大小且结构有效的 HTTP 200 JSON 才进入已连接状态；裸 TCP 端口或慢速滴流响应不会再被误判为就绪。
- 将共享、Android、macOS、Windows 的最低行覆盖率门槛从 `50/40/10/12` 收紧到 `65/50/30/30`，并把当前文档一致性纳入仓库验证。
- 重写项目首页、安全策略、测试策略、健康评分、产品行为要求与路线图，消除 `2.x`、macOS TUN 不可用和桌面密钥明文长期保存等陈旧结论。

### 安全

- macOS 与 Windows 的长期 Mihomo API secret 不再写入设置 JSON：macOS 使用 `0700` 数据目录内的 `0600` 专用文件、目录同步及崩溃临时文件清理，Windows 使用当前用户 DPAPI 及同目录原子替换；验证失败会回滚旧值，重置/更新共享同一串行队列，损坏旧设置的诊断备份不会重新保留明文 secret。
- macOS 在新设置与专用 secret 文件验证成功后清理旧 `SharedPreferences app_settings` 明文副本；当前 ad-hoc 包不启用跨升级身份不稳定的 file-based Keychain。
- 桌面端重置与设置更新统一串行执行；无法删除的残留数据会明确报错，不再把部分重置显示为成功。
- macOS 运行时 `config.yaml` 在原子替换前设置为 `0600`；文档明确说明 Mihomo 运行期间仍需短期明文以及同用户进程残余风险。

### 修复

- Windows 安装目录需要重建时，恢复状态会记录订阅、设置与 DPAPI 密钥等白名单文件的 SHA256 清单；备份缺失、被篡改或目标内容冲突时会保留状态、备份和旧应用副本并阻止自动启动，不再把不完整恢复显示为成功。
- Windows 无法用当前账户解密既有 DPAPI 密钥时，启动页显示可复制的实际路径并保留原密文；用户指南新增跨账户/跨设备移动和重命名留证恢复步骤。
- 桌面订阅 HTTP 请求到达绝对截止时间时会先取消响应流再关闭客户端，避免网络关闭竞态把可重试的超时误报为其他 HTTP 错误或造成 CI 偶发失败。

## [3.2.2] - 2026-07-13

### Fixed

- 修复 Windows 安装器脚本在 Inno Setup 线上编译时将续行数组误判为节标签、导致安装包构建失败的问题。

## [3.2.1] - 2026-07-13

### 修复

- Windows 安装版固定使用 `%LOCALAPPDATA%\Programs\SSRVPN`，不再扫描或选择桌面、下载目录中的便携副本，因此多个旧目录不会阻止安装。
- Windows 安装前清理改为尽力执行且永不主动中止安装；只结束 SSRVPN 进程和路径精确属于当前安装目录的 Mihomo，同名的其他软件核心保持不动。
- 当前安装目录损坏或不可写时，会先对订阅与设置白名单文件做 SHA256 校验备份，再重建目录并在安装后恢复；仍被占用的程序文件交给安装器在重启时替换。

## [3.2.0] - 2026-07-13

### 新增

- Android、macOS、Windows 配置与订阅链路升级为 IPv4/IPv6 双栈，支持 IPv6 节点、AAAA 解析、IPv6 TUN 路由与 IPv6 代理流量；无可用 IPv6 时自然回退 IPv4。
- macOS TUN 改为连接时请求管理员密码，使用按次暂存、摘要校验、超时清理的 root runner 启动 Mihomo；断开或客户端退出会清理特权进程、路由和暂存文件。
- 解锁检测新增 ChatGPT：仅凭 OpenAI 官方 API 的严格认证响应显示“可访问”，明确地区拒绝显示“不支持”，其余响应均保守显示“无法判断”。

### 修复

- Windows 上次异常退出留下系统代理恢复记录时，第一次点击连接即完成恢复并继续连接；恢复失败会显示主窗口和明确原因，不再表现为“点击没反应”。
- Windows 托盘退出先隐藏窗口，再恢复系统代理和停止自有 Mihomo；代理恢复失败时保持客户端和核心存活供重试，正常退出不再等待约 5 秒才消失。
- Windows 安装版无条件创建当前用户桌面快捷方式，并保留开始菜单入口。
- 连接成功状态会在核心、API 与代理就绪后立即显示；联网验证改为多次保守探测，单次 HTTP 502 不再过早提示切换节点。
- Android 自动重载、通知线路切换和原生启动代际增加过期结果保护；空订阅刷新不再让仍在运行的 VPN 与 UI 状态不一致。
- 双栈订阅下载交替尝试 IPv4/IPv6 地址并执行总超时；所有节点入口拒绝区域标识或括号歧义的 IPv6 地址。
- 首页公网 IP 改用 IPv4 专用端点，备用响应也强制校验地址族，不再因双栈出口显示 IPv6。

### 维护

- 将桌面主页公网 IP 行为拆为独立模块，继续保持主状态、运行时动作和 UI 组件边界，且未修改“私家车”延迟显示逻辑。
- macOS 未配置 Developer ID/notarization 时仍属于用户显式密码授权模型，系统无法验证发布者身份；正式签名和最小特权 helper/Network Extension 仍列为后续安全升级。

## [3.1.2] - 2026-07-13

### 修复

- 加固三端连接生命周期：重复启动/停止会合并执行，取消连接可终止仍在进行的启动，核心异常退出时会清理 VPN 或系统代理，避免残留半连接状态。
- 修复 Android 公网 IPv4 路由覆盖缺口，并让连接中按钮可以立即取消；通知线路、快捷磁贴和 Flutter 状态只接受当前有效连接结果。
- 修复 Windows 和 macOS 在崩溃、强制退出或安装升级后的系统代理恢复，只恢复 SSRVPN 能证明拥有的端点，不覆盖用户或其他软件后续修改。
- 修复正常退出的命令被后代进程继承输出管道时可能继续等待的问题，并修复 UTF-8 多字节日志截断突破磁盘/内存上限的问题。
- 损坏或注入式 TUN stack 设置现在只会回退到安全的 `gvisor`，不会逃逸生成的 Mihomo YAML。

### 变更

- 三端更新下载统一要求 HTTPS、大小上限和 SHA256 校验；Android 会清理旧 APK 缓存，桌面端支持取消下载及 OSS 失败后切换 GitHub 备用源。
- 解锁探针继续采用保守证据规则：官方页面或响应结构变化时返回“无法判断”，不根据普通 HTTP 200 或模糊关键词显示“支持”。

### 安全

- 发布流程新增来源清单、旧提交重试约束、不可变 OSS 版本目录、公开固定地址事务式更新和可验证回滚，拒绝草稿、预发行、错误哈希或来源不一致的资产进入稳定渠道。
- Windows 安装器只结束当前会话中的 SSRVPN 进程，并仅依据记录 PID 与精确可执行路径处理自有 Mihomo，避免按进程名误杀其他软件。

## [3.1.1] - 2026-07-12

### 修复

- Windows 安装或升级会按当前用户会话结束 SSRVPN 主程序及其子进程树，并按完整路径清理自有 Mihomo；如果仍有 SSRVPN 进程残留则中止安装，避免旧、新核心并存，同时不影响其他软件的 Mihomo。
- 正式发布会自动刷新 OSS 固定下载地址并重新下载比对，网站以后无需随版本号修改链接；GitHub 备用下载统一使用 `releases/latest/download` 固定地址。

## [3.1.0] - 2026-07-12

### 新增

- Windows 新增无需管理员权限的每用户安装版，同时继续发布绿色便携 ZIP；安装或升级会自动结束 SSRVPN 专属进程并启动新版本。
- 安装器会在结束正在运行的旧便携版之前迁移已有设置、订阅和本地数据库，首次切换到安装版不需要重新导入节点。
- 三端更新检测改为阿里云 OSS 主源、GitHub Releases 备用源，正式发布自动上传不可变版本目录并最后更新 `latest.json`。

### 修复

- Android 在 VPN 已连接时手动切换节点，会立即同步通知栏线路名称，不再停留在连接时读取的旧节点。
- Windows 便携启动器缺少内部主程序时，改为明确提示必须完整解压 ZIP，避免用户只复制顶层 EXE 后无法启动。
- 修复 Release 工具测试受工作目录影响、GitHub Windows Runner 缺少额外 Inno 语言文件时安装器构建失败的问题。

### 变更

- Android 流量通知最多每 60 秒刷新一次，熄屏期间停止数字刷新，亮屏后立即恢复；状态和线路变化仍即时更新。
- Windows 客户端更新入口默认选择 `SSRVPN_Setup.exe`，便携 ZIP 继续作为独立下载选项。
- CI 和 Release workflow 同时构建、校验并上传 Windows 安装版与便携版，发布说明和 OSS 运维文档同步覆盖双包流程。

### 安全

- OSS 和 GitHub 更新资产改为精确文件名匹配，并强制校验固定 host、仓库、tag 版本目录、SHA256 文件和下载文件的一致性，拒绝同扩展名的非标准资产。
- Windows 便携数据迁移只复制固定白名单内的数据文件，不覆盖安装目录中已存在的数据，也不会按名称结束其他程序的 `mihomo.exe`。

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
