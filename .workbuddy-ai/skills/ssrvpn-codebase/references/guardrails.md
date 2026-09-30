# 门禁全表：改之前先看会不会撞墙

> **核心警告：上限卡得很死。** 实测零余量/紧余量不止一处：`Windows/clash_service_lifecycle.dart` 1683/1690（余7）、`subscription_service_persistence.dart` 196/196、`desktop_connection_coordinator.dart` 188/188（零余量）；`system_proxy_models.dart` 129/130、Windows `system_proxy_service.dart` 1314/1320、`CoreProcessSupport.swift` 238/240（余量见下表）。**加几行就 fail 是常态，不是意外。**
> 守卫脚本用 `raise SystemExit`，**遇错即停**：修好一处才暴露下一处。
> 验证时一次性算完所有数值，别打地鼠。

## 1. Flutter / 格式 / 工具链

| 要求 | 说明 |
|---|---|
| Flutter **3.44.1** | `.fvmrc` 钉死，版本不符 `check-flutter-version.sh` 直接退出 1。装了 mise 用 `mise exec flutter@3.44.1 -- <cmd>`；否则用 fvm / 官方 SDK / asdf 任一方式切到 3.44.1 即可 |
| `dart format` | `check-quality-hygiene.sh` 对**全部已跟踪 `.dart`** 跑 `dart format --output=none --set-exit-if-changed`。**`flutter analyze` 不查格式**——只跑 analyze 就提交会挂 CI |
| 典型翻车 | `static const` 字段后**直接跟文档注释、缺空行** → 格式检查失败 |
| `shellcheck` | `check-quality-hygiene.sh` 需要已安装 |
| lockfile | `flutter pub get --enforce-lockfile` |

## 2. `check-clash-service-boundaries.sh` —— 核心服务边界

### 宿主文件行数上限 + 必须声明的 part

**「当前」列是实测快照（2026-09-27），会随代码变动——动手前自己 `wc -l` 复核。**

| 文件 | 当前 | 上限 | 余量 | 必须的 part |
|---|---|---|---|---|
| `SSRVPN_Android/lib/services/clash_service.dart` | 838 | **850** | 12 ⚠️ | `clash_service_native_bridge.dart`、`clash_service_snapshot_cleanup.dart`、`clash_service_config.dart`、`clash_service_country.dart`、`clash_service_data_plane.dart` |
| `packages/ssrvpn_shared/lib/services/clash_service_base.dart` | 759 | **760** | 1 ⚠️ | `clash_service_config_support.dart`、`clash_service_diagnostics.dart`、`clash_service_runtime_support.dart`、`clash_service_health_monitor.dart`、`clash_service_rule_provider_support.dart` |
| `SSRVPN_MacOS/lib/services/clash_service.dart` | 419 | **550** | 131 | `clash_service_config.dart`、`clash_service_lifecycle.dart` |
| `SSRVPN_Windows/lib/services/clash_service.dart` | 219 | **550** | 331 | `clash_service_config.dart`、`clash_service_lifecycle.dart`、`clash_service_config_validation.dart` |
| `SSRVPN_Windows/lib/services/clash_service_config_validation.dart` | 59 | **80** | 21 | （宿主声明 part） |
| `SSRVPN_Windows/lib/services/clash_service_process_support.dart` | 28 | **35** | 7 ⚠️ | （宿主声明 part） |
| `SSRVPN_Windows/lib/services/clash_service_lifecycle.dart` | **1683** | **1690** | **7** ⚠️ | （无，遗留热点） |

> 注：`ClashServiceBase` 实际挂 **7 个 mixin**（另有 `_ClashDataPlaneSupport`、`_ClashLatencySupport`，来自 `clash_service_data_plane_support.dart` 与 `clash_service_latency_support.dart`），但守卫脚本**只校验上面 5 个 part 的存在与声明**。删掉后两个文件守卫不会报，但编译会挂。

### update 服务

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `update_service.dart`（facade） | 525 | 650 | 125 |
| `update_service_download.dart` | 264 | 360 | 96 |
| `update_service_publication.dart` | 779 | 900 | 121 |

facade 里**不得出现**这些符号（属已下沉职责）：`_recoverInterruptedPublicationLocked`、`_acquirePublicationLock`、`_cancellableStream`

### subscription 服务

`subscription_service_base.dart`（编排）**≤ 800**，必须委托给 `subscription_node_codec.dart` 与 `subscription_header_name_parser.dart`；编排里**不得出现**：`_cleanJsonMap`、`_cleanSubscriptionHeaderName`。

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `subscription_service_base.dart` | 797 | 800 | **3** 🚨 |
| `subscription_service_persistence.dart` | **196** | 196 | **0** 🚨零余量 |
| `subscription_service_transaction.dart` | 175 | 180 | **5** 🚨 |
| `subscription_source_cache.dart` | 117 | 160 | 43 |
| `subscription_node_editor.dart` | 114 | 140 | 26 |
| `node_preference_transaction.dart` | 122 | 160 | 38 |
| `subscription_undo_record.dart` | 47 | 100 | 53 |

🚨 = **加几行就 fail**。碰这几个文件前先想清楚能不能把逻辑下沉到别的 part。

### macOS settings

- `SSRVPN_MacOS/lib/services/settings_service.dart`：当前 **665** / 上限 **703**，余 38
- 必须声明 part `macos_private_file_store.dart`

### 系统代理调用位置

macOS 与 Windows：`setSystemProxy` / `clearSystemProxy` **只能**出现在 `clash_service_lifecycle.dart`，出现在 `clash_service.dart` 主文件里即失败。

## 3. `check-desktop-startup-guards.sh` —— 桌面 UI 部件行数

### desktop home 部件（`packages/ssrvpn_shared/lib/desktop_ui/screens/`）

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `desktop_home_screen_part.dart` | 779 | **900** | 121 |
| `desktop_home_runtime_actions_part.dart` | 384 | **600** | 216 |
| `desktop_home_background_tasks_part.dart` | 234 | **300** | 66 |
| `desktop_home_initial_subscription_part.dart` | 273 | **300** | **27** ⚠️ |
| `desktop_home_public_ip_part.dart` | 66 | **600** | 534 |
| `desktop_subscription_screen_part.dart` | 349 | 450 | 101 |

⚠️ **三部件合计（home + runtime_actions + background_tasks）≤ 1410**，当前 **1397，余 13**。
单项上限宽松但**合计卡得死**，往这三个文件里塞东西前先算总账。

### 共享 widgets（`packages/ssrvpn_shared/lib/widgets/`）

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `ssrvpn_app_surface.dart` | 376 | 400 | 24 |
| `ssrvpn_home_overview.dart` | 551 | 600 | 49 |
| `ssrvpn_home_overview_header.dart` | 134 | 200 | 66 |
| `ssrvpn_subscription_view.dart` | **591** | 600 | **9** ⚠️ |
| `ssrvpn_subscription_header.dart` | 93 | 100 | **7** ⚠️ |
| `ssrvpn_subscription_error_dialog.dart` | 138 | 200 | 62 |
| `ssrvpn_version_update_footer.dart` | 84 | 120 | 36 |
| `ssrvpn_power_button.dart` | 100 | 120 | 20 |
| `ssrvpn_node_selection_page.dart` | **350** | 360 | **10** ⚠️ |
| `ssrvpn_node_selection_latency.dart` | 104 | 160 | 56 |
| `ssrvpn_node_selection_controls.dart` | 366 | 400 | 34 |
| `ssrvpn_node_selection_support_controls.dart` | 120 | 200 | 80 |
| `ssrvpn_node_selection_subscription_filter.dart` | 170 | 220 | 50 |
| `ssrvpn_node_selection_node_card.dart` | 209 | 250 | 41 |

### 其他（含原生/安装器/应用入口的紧余量）

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `desktop_connection_coordinator.dart` | **188** | 188 | **0** 🚨 |
| Windows `system_proxy_service.dart` | **1314** | 1320 | **6** ⚠️ |
| Windows `system_proxy_recovery_journal.dart` | 140 | 155 | 15 |
| `system_proxy_models.dart` | **129** | 130 | **1** 🚨 |
| `CoreProcessSupport.swift` | **238** | 240 | **2** 🚨 |
| `stop_ssrvpn_processes.ps1` | 1333 | 1350 | **17** ⚠️ |
| `launcher_main.cpp` | 1473 | 1500 | **27** ⚠️ |
| `AppDelegate.swift` | 2002 | 2020 | **18** ⚠️ |
| macOS `app_runtime_actions_part.dart` | 311 | 320 | **9** ⚠️ |
| `program_files_transaction.ps1` | 1477 | 1600 | 123 |
| macOS `system_proxy_service.dart` | 1062 | 1100 | 38 |

- macOS/Windows 的 `screens/home_screen.dart` 必须引用全部 4 个 desktop home part（runtime_actions / initial_subscription / background_tasks / public_ip）
- Windows 自定义标题栏必须同时包裹 startup shell 与 main shell

## 4. 覆盖率门槛（`check_coverage_thresholds.py`）

### 包级总覆盖率

| 目标 | 门槛 |
|---|---|
| `packages/ssrvpn_shared` | **65.0%** |
| `SSRVPN_Android` | 30.0% |
| `SSRVPN_MacOS` | 30.0% |
| `SSRVPN_Windows` | 30.0% |

### 关键文件地板（**提高需全量覆盖率证据，降低需显式审查**）

| 端 | 文件 | 门槛 |
|---|---|---|
| macOS | `lib/services/clash_service_lifecycle.dart` | 60.0% |
| macOS | `lib/services/system_proxy_service.dart` | **80.0%** |
| macOS | `lib/services/system_proxy_snapshot.dart` | **80.0%** |
| Windows | `lib/services/clash_service_lifecycle.dart` | 51.0% |
| Windows | `lib/services/clash_service_process_support.dart` | **90.0%** |

覆盖率从 `<pkg>/coverage/lcov.info` 读取（shared 无 lcov 时回退 Dart VM coverage）。

## 5. 核心资产（**不可协商**）

`make assets` + `scripts/verify-core-assets.sh` **fail-closed** 校验随包内核 SHA-256。

- 三端内核必须是带 SSRVPN 流量统计扩展的**定制构建**（`native/proxy_traffic/` 补丁打进 mihomo/AtlasCore，版本号带 `-ssrvpn.1` 后缀）
- **不得用官方原版替代**：流量统计、首页与常驻通知代理用量、私家车流量、设备数全依赖 `GET /ssrvpn/traffic`，换成官方内核会**静默失效**
- 缺失 / 哈希不符 / 误用官方内核都会阻断发布
- **任何情况下不得为赶发版跳过或放宽此校验**

## 6. 其他守卫（脚本名以 `verify-all.sh` 为准，别凭印象写）

| 领域 | 脚本 |
|---|---|
| 版本号一致 | `check-version-sync.sh` |
| shared barrel 导出 | `check-shared-barrel-imports.sh` |
| 内置智能规则 | `verify-smart-rules.py` |
| 规则发布评审测试 | `python3 -m unittest discover -s rule-channel -p test_publish.py` |
| 包级指引 | `check-package-guides.sh` |
| 文档一致性 | `check-doc-consistency.sh` |
| 质量卫生（格式 + shellcheck） | `check-quality-hygiene.sh` |
| 核心资产 | `check-core-asset-bootstrap.sh` → `bootstrap-core-assets.sh` → `verify-core-assets.sh` |
| Android 原生桥 | `check-android-native-bridge-guards.sh` |
| Android 内置 Kotlin | `check-android-built-in-kotlin.sh` |
| 产品界面 | `check-product-surface-guards.sh` |
| 桌面安全存储 | `check-desktop-secure-storage.sh` |
| macOS 核心权限 | `check-macos-core-privileges.sh` |
| macOS TUN DNS 事务 | `test-macos-tun-dns-transaction.sh` |
| Windows 启动器安全 | `check-windows-launcher-security.sh` |
| 密钥泄露 | `check-secrets.sh` + `gitleaks git --config .gitleaks.toml --redact --log-opts=--all` |
| 发布工具测试 | `test-release-tooling.sh` |
| 性能冒烟 | `check-performance-baseline.sh` |
| 三端项目地址 | 必须都指向 `https://github.com/Elegying/SSRVPN` |

发版产物结构冒烟：`scripts/smoke-release-artifacts.sh --allow-missing`（**属发版清单，不在 verify-all 里**）。

完整步骤顺序与平台条件见 `verification.md`。
