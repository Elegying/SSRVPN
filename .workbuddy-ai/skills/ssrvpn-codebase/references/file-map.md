# 文件地图：改 X 找哪里

> 先查表，再 Grep。表里没有再扫仓库。

## 0. 顶层布局

```
SSRVPN/
├── pubspec.yaml              # workspace 定义（ssrvpn_workspace），dependency_overrides 指向 packages/liquid_glass_widgets
├── packages/
│   ├── ssrvpn_shared/        # 跨端共享层（绝大部分业务逻辑在这里）
│   └── liquid_glass_widgets/ # UI 组件库（独立包，被 override 引用）
├── SSRVPN_Android/           # Android 壳
├── SSRVPN_MacOS/             # macOS 壳
├── SSRVPN_Windows/           # Windows 壳
├── native/proxy_traffic/     # Go：定制内核补丁 + 流量统计扩展
├── rule-channel/             # 规则通道（签名、发布）
├── scripts/                  # 全部门禁脚本 + verify-all.sh
└── docs/                     # 文档树（有严格政策，见 SKILL.md 第 6 节）
```

`packages/ssrvpn_shared/lib/` 分五个子树：`services/`（业务与平台服务）、`models/`（纯数据模型，**刻意不依赖 `dart:io`**）、`controllers/`（页面级编排）、`widgets/` + `desktop_ui/`（UI）、`utils/` + `constants/`（策略与常量）。

## 1. 按「要改什么」查

| 要改的东西 | 优先看这些文件 |
|---|---|
| **Clash 核心的启动/停止/连接/健康** | `packages/ssrvpn_shared/lib/services/clash_service_base.dart`（宿主类 `ClashServiceBase`，7 个 mixin 挂在其上） |
| 连接配置生成（YAML 输出） | `shared/lib/services/clash_config_generator.dart` |
| 连接健康检查 / 恢复链 | `shared/lib/services/clash_service_health_monitor.dart` |
| 数据面外部探测 / 网络指纹 | `shared/lib/services/clash_service_data_plane_support.dart` |
| 运行时状态 / 流量 | `shared/lib/services/clash_service_runtime_support.dart`、`clash_service_traffic.dart` |
| 诊断信息采集 | `shared/lib/services/clash_service_diagnostics.dart` |
| **订阅**：解析 | `shared/lib/services/subscription_parser.dart` + `subscription_parser_*_part.dart`（base64 / yaml / uri / ss / ssr / naming） |
| **订阅**：合并多订阅 | `shared/lib/services/subscription_yaml_merger.dart` |
| **订阅**：编排 / 持久化 / 缓存 / 撤销 | `subscription_service_base.dart`、`subscription_service_persistence.dart`、`subscription_source_cache.dart`、`subscription_service_transaction.dart`、`subscription_undo_record.dart` |
| **订阅**：节点编辑 | `subscription_node_editor.dart`、`subscription_node_codec.dart` |
| 订阅刷新策略 / 失败诊断 | `subscription_fetch_policy.dart`、`subscription_refresh_control.dart`、`subscription_failure_diagnosis.dart` |
| **智能规则 / 签名通道** | `shared/lib/services/smart_rule_bundle.dart`、`smart_rule_signature.dart`、`smart_rule_recovery.dart` |
| 智能规则历史快照清理（仅初始化） | `smart_rule_snapshot_retention.dart`、`smart_rule_recovery.dart`；Android 原生 `NativeConnectionSession.ruleRetentionConfigPaths` |
| **更新检查 / 下载 / 发布** | `update_service.dart`（facade）、`update_service_download.dart`、`update_service_publication.dart`、`update_checker.dart`、`update_http_client.dart` |
| 账号用量 | `account_usage_client.dart`、`account_usage_provider.dart`、`shared/lib/controllers/account_usage_controller.dart` |
| 节点国家归属 | `node_country_lookup.dart`、`node_country_mmdb.dart`、`shared/lib/controllers/node_country_controller.dart` |
| 节点延迟测速 | `physical_tcp_latency.dart`、`node_latency_cache.dart`、`shared/lib/controllers/home_latency_controller.dart` |
| HTTP/1 解析 | `shared/lib/services/http1_response_decoder.dart` |
| 直连抓取 | `direct_fetcher.dart`、`shared/lib/utils/force_proxy_site_policy.dart` |
| 崩溃上报 | `shared/lib/services/crash_reporter.dart` |
| 公网 IP 显示 | `shared/lib/services/public_ip_info_service.dart`、`shared/lib/models/public_ip_info.dart` |
| **策略 / 校验规则** | `shared/lib/utils/*policy*.dart`（force_proxy_site / node_country / node_display / proxy_dependency / proxy_option / proxy_transport / subscription_url / runtime_config_name / runtime_port_conflict / statistics_visibility / private_node_latency） |
| 常量 | `shared/lib/constants/app_constants.dart`（**契约常量写这里，调用点显式传参**） |
| 连接阶段耗时 | `shared/lib/utils/connection_phase_trace.dart`、`clash_service_connection_progress.dart`；Android 原生 `NativeVpnStartTiming.kt` |
| 日志与脱敏 | `shared/lib/utils/app_logger.dart`、`log_redactor.dart`、`bounded_file_logger.dart` |
| 队列 / 并发原语 | `shared/lib/utils/recovering_serial_queue.dart`、`connection_transition_queue.dart`、`async_lazy.dart`、`best_effort_cleanup.dart` |

## 2. 按「哪个端」查

三端 `lib/` 结构一致：`main.dart` / `app.dart` / `services/` / `screens/` / `models/` / `widgets/` / `theme/` / `utils/` / `startup/`。

### Android（`SSRVPN_Android/`）
- 核心桥：`lib/services/clash_service_native_bridge.dart`（Kotlin ↔ Dart）
- `clash_service.dart` 是宿主，part：`_native_bridge` / `_snapshot_cleanup` / `_config` / `_country` / `_data_plane`
- 其他服务：`connection_orchestrator.dart`、`http_client_adapter.dart`、`qr_image_picker.dart`（仅用于二维码图片选择）
- 首页拆 part：`screens/home_screen.dart` + `home_connection_actions_part.dart`、`home_dialogs_part.dart`、`home_public_ip_part.dart`、`home_node_actions_part.dart`、`home_lifecycle_actions_part.dart`
- 原生侧：`android/app/src/main/kotlin/`（守卫脚本 `check-android-native-bridge-guards.sh`、`check-android-built-in-kotlin.sh`）

### macOS（`SSRVPN_MacOS/`）
- 系统代理：`lib/services/system_proxy_service.dart`、`system_proxy_snapshot.dart`（**覆盖率门槛 80%，别降**）
- TUN / 权限：`macos_tun_session.dart`、`macos_tun_request_store.dart`、`macos_tun_rule_staging.dart`
- 启动事务：`macos_start_transaction.dart`、`app_shutdown.dart`
- 私有文件存储：`macos_private_file_store.dart`（`settings_service.dart` 的 part）
- 托盘：`tray_manager.dart`
- 原生侧：`macos/Runner/`（守卫 `check-macos-core-privileges.sh`、`test-macos-tun-dns-transaction.sh`）

### Windows（`SSRVPN_Windows/`）
- 安装/事务：`lib/services/windows_start_transaction.dart`、`windows_tun_elevation_service.dart`
- 凭据：`windows_dpapi_secret_store.dart`（DPAPI）
- 系统代理恢复日志 I/O：`system_proxy_recovery_journal.dart`（`system_proxy_service.dart` 的私有 extension part；锁与事务顺序仍在主服务）
- 有界进程退出支持：`clash_service_process_support.dart`（同库 part，原退出顺序与结果语义不变）
- 进程身份采集入口：`clash_service_identity.dart`（同库 extension part）；原生持有句柄查询：`lib/src/services/windows_core_process_query.dart`；完整 FILETIME：`lib/src/services/windows_file_time.dart`；脱敏失败分类：`lib/src/services/windows_core_identity_failure.dart`
- 配置校验：`clash_service_config_validation.dart`（同库私有 mixin，进程退出/取消回归先于拆分）
- 生命周期：`clash_service_lifecycle.dart`（**遗留热点，新职责别往里加**；`setSystemProxy`/`clearSystemProxy` 只能在这里）
- 恢复策略：`clash_service_recovery_policy.dart`、`clash_service_tun_recovery.dart`、`clash_service_start_preparation.dart`
- 原生侧：`windows/runner/launcher_main.cpp`（守卫 `check-windows-launcher-security.sh`）、安装器 `installer/program_files_transaction.ps1`

### 桌面共享 UI（`packages/ssrvpn_shared/lib/desktop_ui/`）
macOS 与 Windows **共用**这套 UI，不是各自一份（`home_screen.dart` 共挂 **9 个 part** = screens/ 下 7 个 home part + widgets/ 下 2 个 dialog part）：
- `desktop_app_shell_part.dart` + `screens/desktop_home_*_part.dart`（7 个 home part）
- `screens/desktop_node_edit_screen_part.dart`、`desktop_subscription_screen_part.dart`
- `widgets/desktop_home_dialogs_part.dart`、`desktop_force_proxy_sites_dialog_part.dart`、`glass_container_part.dart`

⚠️ **宿主库在平台端，不在 shared**：`SSRVPN_MacOS/lib/screens/home_screen.dart` 与 `SSRVPN_Windows/lib/screens/home_screen.dart` 各自声明 `library desktop_home_screen;` 并 `part 'package:ssrvpn_shared/desktop_ui/...'`，共享文件反过来 `part of desktop_home_screen;`。两端同名库才能共享同一批 part；共享 part 因此能直接引用平台服务（`ClashService` 等）。详见 `architecture.md`。

⚠️ 这些 part **不全是 extension**：`desktop_home_screen_part.dart` 声明 `class HomeScreen` + `_HomeScreenState`；`desktop_home_action_policies_part.dart` 是顶层函数；`desktop_home_dialogs_part.dart` 混合。只有 5 个是 `extension ... on _HomeScreenState`。跨 part 调用靠「同库唯一声明」解析，改名/移动前先确认解析不会断。

## 3. 原生层（`native/proxy_traffic/`，Go）

| 文件 | 职责 |
|---|---|
| `proxy_traffic.go` | 流量统计核心（`GET /ssrvpn/traffic` 端点来源） |
| `target_address.go` | 目标地址解析与候选构建（`ssrvpnProxyTargetCandidates` / `ssrvpnTargetCandidates`）。生产代码只遍历不下标；`conn.Chains()[0]` 有 `len()==0` 守卫 |
| `direct_fallback.go` | DIRECT 兜底直连 |
| `dns_resolution.go` | DNS 解析与并发 |
| `tun_startup.go` / `route.go` | TUN 启动与路由 |
| `macos.patch` / `windows.patch` / `android.patch` | 打进各上游的补丁 |
| `sources.json` | **三端上游来源清单**（三端用三个不同上游，见 architecture.md） |
| `toolchains.json` | 各端 Go 工具链版本 |

⚠️ `direct_fallback.go:95` 的 `if r == nil || !r.Invalid() { r = resolver.SystemResolver }` **是对的**——mihomo 的 `resolver.Invalid()` 语义是**反直觉的**：`Invalid()==true` 表示 resolver **可用**。已对照上游 5 处调用点 + 项目自带测试夹具验证。别"顺手修正"。

## 4. 规则通道（`rule-channel/`）

签名与发布链路：Ed25519 签名 → `smart_rule_bundle.dart` 的 `acceptsManifest` 绑定 manifest sha256 → `providerContentsMatch` 逐文件 sha256 → `_replaceFile` 临时文件 + rename 原子写入。改动任何一环都要重看整条链。

## 5. 门禁脚本（`scripts/`）

- **一键全量**：`verify-all.sh`
- 常用单跑：`check-version-sync.sh`、`check-secrets.sh`、`check-quality-hygiene.sh`、`check_coverage_thresholds.py`、`check-clash-service-boundaries.sh`、`check-desktop-startup-guards.sh`、`verify-core-assets.sh`
- 覆盖率：`run-flutter-coverage.sh` + `check-coverage-thresholds.sh`（⚠️ 连字符；下划线的 `check_coverage_thresholds.py` 是 Python 实现，别混）
- 原生测试：`test-android-native.sh`、`test-macos-native.sh`
- 完整清单与步骤见 `verification.md`
