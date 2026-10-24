# 门禁全表：改之前先看会不会撞墙

> **核心警告：多个文件接近上限。** 当前 `desktop_connection_coordinator.dart` 188/188、`stop_ssrvpn_processes.ps1` 1350/1350 均无余量；订阅持久化 195/196、订阅事务 179/180、来源缓存 159/160、代理模型 129/130 各余 1 行。Windows 生命周期为 1485/1690（余 205），系统代理为 1307/1320（余 13）。
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

**「当前」列是实测快照（2026-10-24）；实时数值以 `bash scripts/check-clash-service-boundaries.sh` 输出为准，会随代码变动——动手前自己 `wc -l` 复核。**

| 文件 | 当前 | 上限 | 余量 | 必须的 part |
|---|---|---|---|---|
| `SSRVPN_Android/lib/services/clash_service.dart` | 841 | **850** | 9 ⚠️ | `clash_service_native_bridge.dart`、`clash_service_snapshot_cleanup.dart`、`clash_service_config.dart`、`clash_service_country.dart`、`clash_service_data_plane.dart` |
| `packages/ssrvpn_shared/lib/services/clash_service_base.dart` | 725 | **760** | 35 | `clash_service_config_support.dart`、`clash_service_diagnostics.dart`、`clash_service_runtime_support.dart`、`clash_service_health_monitor.dart`、`clash_service_rule_provider_support.dart`、`clash_service_data_plane_support.dart`、`clash_service_latency_support.dart` |
| `SSRVPN_MacOS/lib/services/clash_service.dart` | 419 | **550** | 131 | `clash_service_config.dart`、`clash_service_lifecycle.dart` |
| `SSRVPN_Windows/lib/services/clash_service.dart` | 222 | **550** | 328 | `clash_service_config.dart`、`clash_service_lifecycle.dart`、`clash_service_process_support.dart`、`clash_service_config_validation.dart` |
| `SSRVPN_Windows/lib/services/clash_service_config_validation.dart` | 59 | **80** | 21 | （宿主声明 part） |
| `SSRVPN_Windows/lib/services/clash_service_process_support.dart` | 28 | **35** | 7 ⚠️ | （宿主声明 part） |
| `SSRVPN_Windows/lib/services/clash_service_lifecycle.dart` | 1485 | **1690** | 205 | （无，遗留热点） |
| `packages/ssrvpn_shared/lib/services/clash_service_data_plane_support.dart` | 597 | 600 | 3 ⚠️ | （宿主声明 part） |
| `packages/ssrvpn_shared/lib/services/clash_service_latency_support.dart` | 78 | 120 | 42 | （宿主声明 part） |

> `ClashServiceBase` 挂载的 7 个 mixin part 均由守卫检查存在与声明；数据面与测速 part 另有限制：600 行与 120 行。

### update 服务

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `update_service.dart`（facade） | 552 | 650 | 98 |
| `update_service_download.dart` | 258 | 360 | 102 |
| `update_service_publication.dart` | 802 | 900 | 98 |

facade 里**不得出现**这些符号（属已下沉职责）：`_recoverInterruptedPublicationLocked`、`_acquirePublicationLock`、`_cancellableStream`

### subscription 服务

`subscription_service_base.dart`（编排）**≤ 800**，必须委托给 `subscription_node_codec.dart` 与 `subscription_header_name_parser.dart`；编排里**不得出现**：`_cleanJsonMap`、`_cleanSubscriptionHeaderName`。

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `subscription_service_base.dart` | 751 | 800 | 49 |
| `subscription_service_persistence.dart` | 195 | 196 | 1 ⚠️ |
| `subscription_service_transaction.dart` | 179 | 180 | 1 ⚠️ |
| `subscription_source_cache.dart` | 159 | 160 | 1 ⚠️ |
| `subscription_node_editor.dart` | 114 | 140 | 26 |
| `node_preference_transaction.dart` | 122 | 160 | 38 |
| `subscription_undo_record.dart` | 47 | 100 | 53 |

🚨 = **加几行就 fail**。碰这几个文件前先想清楚能不能把逻辑下沉到别的 part。

### macOS settings

- `SSRVPN_MacOS/lib/services/settings_service.dart`：当前 **650** / 上限 **703**，余 53
- 必须声明 part `macos_private_file_store.dart`

### 系统代理调用位置

macOS 与 Windows：`setSystemProxy` / `clearSystemProxy` **只能**出现在 `clash_service_lifecycle.dart`，出现在 `clash_service.dart` 主文件里即失败。

## 3. `check-desktop-startup-guards.sh` —— 桌面 UI 部件行数

### desktop home 部件（`packages/ssrvpn_shared/lib/desktop_ui/screens/`）

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `desktop_home_screen_part.dart` | 744 | **900** | 156 |
| `desktop_home_runtime_actions_part.dart` | 383 | **600** | 217 |
| `desktop_home_background_tasks_part.dart` | 224 | **300** | 76 |
| `desktop_home_initial_subscription_part.dart` | 274 | **300** | 26 |
| `desktop_home_public_ip_part.dart` | 91 | **600** | 509 |
| `desktop_subscription_screen_part.dart` | 359 | 450 | 91 |

⚠️ **三部件合计（home + runtime_actions + background_tasks）≤ 1410**，当前 **1351，余 59**。
单项上限宽松但**合计卡得死**，往这三个文件里塞东西前先算总账。

### 共享 widgets（`packages/ssrvpn_shared/lib/widgets/`）

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `ssrvpn_app_surface.dart` | 350 | 400 | 50 |
| `ssrvpn_home_overview.dart` | 322 | 600 | 278 |
| `ssrvpn_home_overview_header.dart` | 165 | 200 | 35 |
| `ssrvpn_subscription_view.dart` | 577 | 600 | 23 |
| `ssrvpn_subscription_header.dart` | 75 | 100 | 25 |
| `ssrvpn_subscription_error_dialog.dart` | 142 | 200 | 58 |
| `ssrvpn_version_update_footer.dart` | 84 | 120 | 36 |
| `ssrvpn_power_button.dart` | 113 | 120 | 7 ⚠️ |
| `ssrvpn_node_selection_page.dart` | 348 | 360 | 12 |
| `ssrvpn_node_selection_latency.dart` | 120 | 160 | 40 |
| `ssrvpn_node_selection_controls.dart` | 277 | 400 | 123 |
| `ssrvpn_node_selection_support_controls.dart` | 120 | 200 | 80 |
| `ssrvpn_node_selection_subscription_filter.dart` | 212 | 220 | 8 ⚠️ |
| `ssrvpn_node_selection_node_card.dart` | 231 | 250 | 19 |

### 其他（含原生/安装器/应用入口的紧余量）

| 文件 | 当前 | 上限 | 余量 |
|---|---|---|---|
| `desktop_connection_coordinator.dart` | 188 | 188 | 0 🚨零余量 |
| Windows `system_proxy_service.dart` | 1307 | 1320 | 13 |
| Windows `system_proxy_recovery_journal.dart` | 140 | 155 | 15 |
| `system_proxy_models.dart` | 129 | 130 | 1 ⚠️ |
| `CoreProcessSupport.swift` | 238 | 240 | 2 ⚠️ |
| `stop_ssrvpn_processes.ps1` | 1350 | 1350 | 0 🚨零余量 |
| `launcher_main.cpp` | 1473 | 1500 | 27 |
| `AppDelegate.swift` | 2009 | 2020 | 11 |
| macOS `app_runtime_actions_part.dart` | 312 | 320 | 8 ⚠️ |
| `program_files_transaction.ps1` | 1490 | 1600 | 110 |
| macOS `system_proxy_service.dart` | 1062 | 1100 | 38 |

- macOS/Windows 的 `screens/home_screen.dart` 必须引用全部 4 个 desktop home part（runtime_actions / initial_subscription / background_tasks / public_ip）
- Windows 自定义标题栏必须同时包裹 startup shell 与 main shell

## 4. 覆盖率门槛（`check_coverage_thresholds.py`）

### 包级总覆盖率

| 目标 | 门槛 |
|---|---|
| `packages/ssrvpn_shared` | **90.0%** |
| `SSRVPN_Android` | **70.0%** |
| `SSRVPN_MacOS` | **75.0%** |
| `SSRVPN_Windows` | **68.0%** |

### 关键文件地板（**提高需全量覆盖率证据，降低需显式审查**）

| 目标 | 文件 | 门槛 |
|---|---|---|
| packages/ssrvpn_shared | `lib/services/subscription_service_transaction.dart` | 95.0% |
| packages/ssrvpn_shared | `lib/services/subscription_service_persistence.dart` | 95.0% |
| packages/ssrvpn_shared | `lib/services/subscription_source_cache.dart` | 95.0% |
| packages/ssrvpn_shared | `lib/services/update_service_download.dart` | 90.0% |
| packages/ssrvpn_shared | `lib/services/update_service_publication.dart` | 80.0% |
| packages/ssrvpn_shared | `lib/services/clash_service_health_monitor.dart` | 95.0% |
| packages/ssrvpn_shared | `lib/services/clash_service_data_plane_support.dart` | 88.0% |
| SSRVPN_Android | `lib/services/clash_service_native_bridge.dart` | 85.0% |
| SSRVPN_MacOS | `lib/services/clash_service_lifecycle.dart` | 75.0% |
| SSRVPN_MacOS | `lib/services/system_proxy_service.dart` | 85.0% |
| SSRVPN_MacOS | `lib/services/system_proxy_snapshot.dart` | 90.0% |
| SSRVPN_MacOS | `lib/services/macos_start_transaction.dart` | 95.0% |
| SSRVPN_Windows | `lib/services/clash_service_lifecycle.dart` | 58.0% |
| SSRVPN_Windows | `lib/services/clash_service_process_support.dart` | 90.0% |
| SSRVPN_Windows | `lib/services/clash_service_config_validation.dart` | 90.0% |
| SSRVPN_Windows | `lib/services/windows_start_transaction.dart` | 95.0% |

共享事务、更新发布与健康检查单独设地板，不能被高覆盖的 UI 或其他文件抵消。
包级门槛保留跨宿主余量；Windows 包在 Mac 上的原生测试跳过会影响实测值，故统一总门槛取 68%，生命周期仍保留 58%。Windows 原生全套仍须单独通过，不能用跨宿主报告代替。

覆盖率仅从 `<pkg>/coverage/lcov.info` 读取；shared 也必须提供完整 LCOV，缺失时门禁失败，不再回退 Dart VM coverage。

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
