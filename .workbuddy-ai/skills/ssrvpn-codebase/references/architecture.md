# 架构与边界

## 1. 分层模型

```
┌─────────────────────────────────────────────┐
│  平台壳（薄）                                 │
│  SSRVPN_Android / MacOS / Windows           │
│  · main.dart / app.dart / startup/          │
│  · 原生桥、平台服务（系统代理、TUN、托盘）      │
└──────────────────┬──────────────────────────┘
                   │ 依赖
┌──────────────────▼──────────────────────────┐
│  packages/ssrvpn_shared（厚）                │
│  · services/   业务与平台无关服务             │
│  · models/     纯数据模型（不依赖 dart:io）   │
│  · controllers/ 页面级编排                   │
│  · widgets/ + desktop_ui/  UI               │
│  · utils/ + constants/  策略与常量           │
└──────────────────┬──────────────────────────┘
                   │ 原生桥 / 进程
┌──────────────────▼──────────────────────────┐
│  定制 mihomo（native/proxy_traffic 补丁）     │
│  + GET /ssrvpn/traffic 流量统计端点          │
└─────────────────────────────────────────────┘
```

**判断该放哪**：
- 跨端都要用、不含平台 API → `ssrvpn_shared`
- 只有某端需要、或要调平台 API（系统代理、托盘、TUN、DPAPI、Kotlin 桥）→ 对应端的 `lib/services/`
- 只是数据结构 → `models/`（**保持无 `dart:io`**，错误分类之类的类型判定放 services 层）
- 校验规则 / 策略判定 → `utils/*policy*.dart`，便于单测

macOS 与 Windows 的 UI **共用** `packages/ssrvpn_shared/lib/desktop_ui/`，不要在两端各复制一份。

## 2. part / mixin / extension 可见性（**决定代码能移到哪**）

`clash_service_base.dart` 是 library 文件，`clash_service_*` 是 `part of` 它。这条链上的可见性规则：

| 机制 | 成员归属 | 可被覆写？ | 能实现接口？ | 能看到什么 |
|---|---|---|---|---|
| `part` 文件 | **只能加顶层声明**，不能给别的文件里的类加成员 | — | — | 库内所有私有成员 |
| `mixin X`（无 `on`） | 成为类成员 | ✅ | ✅ | **只能**引用自身成员或自己抽象声明的成员 |
| `mixin X on Y` | 成为类成员 | ✅ | ✅ | Y 的成员 |
| `extension on X` | 不是成员 | ❌ | ❌ | 同库私有成员 |

项目实际用法：
- `clash_service_health_monitor.dart` **同时**有 `mixin _ClashHealthSupport`（给类加成员）和 `extension ClashServiceHealthMonitor on ClashServiceBase`（能看见类成员）。两者分工不同，别合并。
- 桌面 `desktop_home_*_part.dart` **不是全都是 extension**（常见误解）：
  - `desktop_home_screen_part.dart` 声明 `class HomeScreen` + `class _HomeScreenState`（宿主类在这）
  - `desktop_home_action_policies_part.dart` 是**顶层函数**（`@visibleForTesting`）
  - `desktop_home_dialogs_part.dart`（widgets/）混合：`class _DesktopTutorialStep` + `extension _DesktopHomeNodeMenu on _HomeScreenState`
  - `desktop_force_proxy_sites_dialog_part.dart`（widgets/）是 `class StatefulWidget` + `State`
  - 其余 5 个 `screens/desktop_home_*_part.dart`（connection_progress / background_tasks / initial_subscription / runtime_actions / public_ip）才是 `extension ... on _HomeScreenState`
  → 跨 part 调用靠「同一库内唯一声明」解析，**改名/移动前先确认解析不会断**。

### 桌面共享 UI 的真实机制（重要，容易理解反）

代码放在 `packages/ssrvpn_shared/lib/desktop_ui/`，但**宿主库在平台端**：

```dart
// SSRVPN_MacOS/lib/screens/home_screen.dart  与  SSRVPN_Windows/lib/screens/home_screen.dart
library desktop_home_screen;          // ← 两端同名库

part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_screen_part.dart';
part 'package:ssrvpn_shared/desktop_ui/screens/desktop_home_runtime_actions_part.dart';
// ... 共 9 个 part
```

```dart
// packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_screen_part.dart
part of desktop_home_screen;          // ← 反向挂回平台库
```

含义：
- 共享 part **编译进平台库**，所以能直接引用平台侧类型（`ClashService`、`SettingsService`、`TrayManager`…）。这也是为什么这套 UI 只能在 macOS/Windows 共用——两端的服务 API 得对得上。
- 两端必须用**同一个库名** `desktop_home_screen`，共享 part 才挂得上。
- `macos/Runner` 之外同理：`SSRVPN_MacOS/lib/widgets/glass_container.dart` 用 `part 'package:ssrvpn_shared/desktop_ui/widgets/glass_container_part.dart'`，`SSRVPN_MacOS/lib/app.dart` 挂 `desktop_app_shell_part.dart`。
- 守卫 `check-desktop-startup-guards.sh` 会检查两端 `home_screen.dart` 是否引用了全部 4 个 desktop home part（runtime_actions / initial_subscription / background_tasks / public_ip）。

## 3. 上游分歧（补丁漂移的根因）

`native/proxy_traffic/sources.json` 里**三个平台用了三个不同上游**：

| 平台 | 上游 | 版本 | Go |
|---|---|---|---|
| macOS | MetaCubeX/mihomo @ `e26714a` | v1.19.29 | go1.26.5 |
| Windows | MetaCubeX/mihomo @ `5184081` | v1.19.27 | go1.20.14 |
| Android | **zeyugao/mihomo fork** @ `7031b75` | — | go1.25.11 |

结果：`android.patch` 相对上游缺 `ssrvpnStartupProviders`（0 vs 1）和 `loadProvider`（2 vs 4）的同步。**动补丁前先确认对应上游的基线**，别拿 macOS 的上下文去改 Android 的 patch。

## 4. 安全信任链（改任何一环都要重看整条）

1. **Ed25519 签名**（`smart_rule_signature.dart`）：验证 `'SSRVPN rules v1\n${descriptor.version}\n${descriptor.manifestSha256}\n'`
2. **`acceptsManifest`**（`smart_rule_bundle.dart:35`）把 manifest 的 sha256 绑进签名载荷
3. **`providerContentsMatch`** 逐文件 sha256 校验内容
4. **`_replaceFile`**（`:756`）临时文件 + rename 原子写入
5. **`_isValidProviderBytes`** + `bounded_yaml.dart` 限制 YAML 体积

### YAML 注入防御
- 代理字段一律经 `jsonEncode` 重新输出（JSON 是 YAML 子集，天然转义）→ `clash_config_generator.dart` 的 `_quote` / `buildProxiesText`
- 域名由 `ForceProxySitePolicy.isValidHost` 校验，label 严格 `[a-z0-9-]`

## 5. 数据面观察的「世代（epoch）」语义

- **失效只有一个入口**：`_invalidateDataPlaneObservationAndReprobe()`（`clash_service_data_plane_support.dart`）= epoch++ / 清 coalesced / sessionReset / 清告警 / `if (isRunning) scheduleDataPlaneObservation()`。**路由变化与物理网络变化共用它**——两条路径语义必须一致，别各写一份。
- `isDataPlaneObservationCurrent` 靠 `runZoned` 携带的 epoch 比对；不匹配则 `setConnectivityWarning` 拒收。**「让旧观察失效」= 递增 epoch**，不是删告警。
- **跨世代探测重叠是既有设计**：`Future.timeout` 不取消源，bump epoch 后旧探测仍在跑（最多 2 倍请求）。旧结果被双重丢弃（zone epoch 拒收 + `finishObservation` 的 epoch 不匹配）。
- `clearConnectivityWarningSilently()` 是**静默**的，用户可见性由**调用方**负责。路由路径在 `clash_service_base.dart:512`（紧接 `onDataPlaneRouteChanged()` 之后）调用 `_notifyStatusChanged()`（定义在 :718）；物理网络变化路径**没有这样的调用方**，必须自己补 `notifyStatusChanged()`，否则「清了但界面照旧」。
- 可测性钩子：`buildNetworkFingerprint()`（`@protected`，返回 null = 未知不动状态）、`runNetworkChangeCheck()`（`@visibleForTesting`）。
- 指纹只含**有非 link-local 地址**的接口；`awdl0`/`llw0`/`utun*` 只有 `fe80::` 被整接口滤掉。真实噪声源只有 IPv6 临时地址轮换（约每天一次）。

## 6. 外部网络探测（数据面健康）契约

- 共享常量 `AppConstants.dataPlaneProbeAttempts = 6`、`dataPlaneProbeRetryDelay = 1s`，**三端调用点显式传参**。
- **6 是硬上限**：`verifyUserConnectivity` 内部 `clamp(1, 6)`，调大常量只会被静默截断。理由：单轮最坏 ≈ 41 秒，须留在 `dataPlaneObservationTimeout`（60 秒）内。clamp 刻意写死 6 不引用常量（引用会同时放宽安全边界）。已有测试锁定上下界。
- 端点顺序：TUN `youtube`→`cp.cloudflare.com`→`gstatic`；系统代理 `gstatic`→`cloudflare`→`youtube`。
- 成功判据：**仅 HTTP 200 / 204**。单次超时 6s、连接超时 5s、整体 60s。
- ⚠️ 探测**经本地代理发出**，mihomo 在链路上 → **节点死亡时 mihomo 主动返回 HTTP 502 而不抛异常**。因此「有响应即通道可用」是错的；只认 200/204 是正确设计。也意味着「端点状态码异常」无法与「节点已死」区分——措辞上不要断言是站点问题。
- 失败**只告警**，永不重启核心 / 断开 / 切节点。自动恢复由**控制面** `onPeriodicHealthCheckResult` 驱动。
- 文案两分支（**引自 `clash_service_data_plane_support.dart` 原文**）：有响应 → `'外部网络验证未通过（端点 HTTP $lastStatusCode），仅供参考'`；全程无响应 → `'外部网络验证未通过（连接无响应），仅供参考'`。两分支都带「，仅供参考」后缀。
- 诊断页读**缓存告警**不重新探测（完整探测最坏 41s > `diagnosticCheckTimeout` 10s），用 `buildDataPlaneDiagnosticSummary()` 标注观察年龄。三端均已接线。
- 错误分类**先按异常类型**（`TimeoutException`/`HandshakeException`/`http.ClientException`/`SocketException`），再退回字符串匹配。类型判定只放 services 层。
- ⭐ **三端唯一实现是公开的 `safeRuntimeErrorCode`**（part `clash_service_runtime_support.dart`）。**不要在平台侧复制**——Android 曾自带 `_safeLogErrorCode`，其 `.timeout()` 自身的 catch 把超时写成 `cause=UNKNOWN`。5.0.14 已删除，并由 `check-android-native-bridge-guards.sh` 加护栏（出现 `String _*ErrorCode(` 即失败）。

## 7. 两个反复咬人的 Dart 陷阱

### 默认参数不承载契约
**可选参数默认值由「被调用实现」解析，不是调用点的静态类型。**
最小复现：基类 `f({int x = 6})`、子类覆写 `f({int x = 3})`、mixin 调 `f()` → 得到 **3**。
→ 把跨端契约写在默认参数里 = 任何覆写（含测试替身）都会**静默**改掉它。
→ **规则：契约参数必须写在调用点**（如 `AppConstants.dataPlaneProbeAttempts`），默认值只作兜底。

### `??` 的延迟绑定
`a ?? b` 里 `b` 是延迟求值的，但若 `a` 是方法调用且副作用依赖求值时机，行为会和直觉不符。复杂表达式改用显式 `if`。

## 8. mihomo 字段解析探针法（可复用）

**判定「某个 YAML 字段是否真被核心读取」，必须用非法值当探针。**
只验证「配置能加载」是**无效证据**——mihomo 对完全未知的字段也静默接受（实测 `bogus-field-xyz` 通过）。

手法：给字段塞一个**类型错误**的值，跑 `AtlasCore -d <dir> -t -f <config.yaml>`，报错 = 被解析，通过 = 被忽略。
⚠️ **"test is successful" 走 stdout，不要重定向 stdout**（踩过：四个用例全报失败含对照组）。

已测结论（内嵌 AtlasCore v1.19.29-ssrvpn.1）：

| 字段 | url-test | fallback |
|---|---|---|
| `tolerance` | 解析 | **静默忽略** |
| `lazy` | 解析 | 解析 |
| `interval` | 解析 | 解析 |

→ `clash_config_generator.dart`：「自动选择」（url-test）写 `tolerance: 50` + `lazy: true`；「故障转移」（fallback）**只写 `lazy: true`**。改这里时同提交要同步 `subscription_yaml_merger_test.dart`。
