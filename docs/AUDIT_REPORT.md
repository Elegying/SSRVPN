# SSRVPN 代码审查报告

审查日期：2026-06-30
审查范围：全平台（macOS / Android / Windows）+ 共享包 `ssrvpn_shared`

---

## 一、已修复的问题

### 1.1 YAML 注入风险（BUG 修复）🔴

**问题**：macOS 和 Android 的 `ClashService.generateClashConfig()` 中，`apiSecret` 使用双引号写入 YAML：
```dart
// 修复前（macOS / Android）
result.writeln('secret: "${settings.apiSecret}"');
```
双引号在 YAML 中支持转义序列，如果用户密码包含 `"` `\` 等特殊字符，会导致 YAML 解析失败或注入。

**修复**：改用 `_quote()` 单引号安全转义：
```dart
// 修复后
result.writeln('secret: ${_quote(settings.apiSecret)}');
```

**影响文件**：
- `SSRVPN_MacOS/lib/services/clash_service.dart`
- `SSRVPN_Android/lib/services/clash_service.dart`

### 1.2 Windows AppSettings 缺失字段（BUG 修复）🔴

**问题**：Windows 版 `AppSettings` 缺少 macOS/Android 已有的 6 个字段：
- `startOnBoot` — 开机自启
- `startMinimized` — 启动后最小化
- `closeToTray` — 关闭时最小化到托盘
- `autoUpdateSubscription` — 自动更新订阅
- `updateIntervalHours` — 更新间隔
- `forceProxySites` — 强制代理站点（已有但缺少对应的 `_parseBool` / `_parsePositiveInt` 辅助方法）

**修复**：补全所有缺失字段，添加 `_parseBool` 和 `_parsePositiveInt` 辅助方法，确保 `fromJson` / `toJson` 完整。

**影响文件**：
- `SSRVPN_Windows/lib/models/app_settings.dart`

### 1.3 共享包新增 ClashServiceBase（架构优化）🟡

**问题**：三个平台的 `ClashService` 存在大量重复代码：
- `_extractSection` — YAML 段落提取（3 处完全相同）
- `_extractProxyNames` — 代理名称提取（3 处完全相同）
- `_quote` — YAML 转义（3 处完全相同）
- API 客户端方法（`getProxies`、`switchProxy`、`switchMode`、`getConfigs`）
- 延迟测试（`testLatency`、`testAllLatencies`）
- 健康检查（`_healthCheck`）
- 端口管理（`prepareForStart`、`_findAvailablePort`）
- 连通性验证（`verifyUserConnectivity`、`resolveCurrentExitCountryCode`）

**修复**：在 `ssrvpn_shared` 中创建 `ClashServiceBase` 抽象基类，包含所有公共逻辑。各平台只需实现：
- 核心进程管理（init / start / stop）
- 平台特定的系统代理/VPN 设置
- 平台特定的文件路径和资源释放

**影响文件**：
- `packages/ssrvpn_shared/lib/services/clash_service_base.dart`（新增，704 行）
- `packages/ssrvpn_shared/lib/ssrvpn_shared.dart`（导出新服务）

---

## 二、已确认的代码质量

### 2.1 静态分析
- ✅ `ssrvpn_shared` — `dart analyze` 无问题
- ✅ `SSRVPN_MacOS` — `dart analyze` 无问题
- ✅ `SSRVPN_Android` — `dart analyze` 无问题
- ✅ `SSRVPN_Windows` — `flutter analyze` 无问题

### 2.2 测试
- ✅ `ssrvpn_shared` — 53 个测试全部通过
- ✅ 无 `print()` 调试残留（仅有 `debugPrint`）
- ✅ 无 TODO/FIXME 标记

### 2.3 代码风格
- ✅ 使用 `LogRedactor` 脱敏日志
- ✅ 使用 `Isolate.run()` 避免 UI 卡顿
- ✅ 原子文件写入（`writeStringAtomically`）
- ✅ 端口冲突自动重试

---

## 三、已识别的待改进项（未修改）

### 3.1 ClashService 过大（技术债）🟡

| 平台 | 行数 | 主要问题 |
|------|------|----------|
| macOS | 1424 | 平台特定逻辑与通用逻辑混合 |
| Android | 971 | 同上 |
| Windows | 1350 | 同上 |

**建议**：各平台 `ClashService` 继承 `ClashServiceBase`，删除重复方法。预计可减少 40-50% 代码量。

**影响**：需要重构每个平台的 `ClashService`，风险较高，建议分平台逐步迁移。

### 3.2 HomeScreen 过大（技术债）🟡

| 平台 | 行数 | 主要问题 |
|------|------|----------|
| macOS | 2431 | UI 逻辑与业务逻辑混合 |
| Android | 1209 | 同上 |
| Windows | 2630 | 同上 |

**建议**：拆分为多个子组件（节点列表、连接状态、设置面板等），使用 `Provider` 管理状态。

### 3.3 ProxyMode 枚举重复（代码异味）🟡

`ProxyMode` 枚举在 4 个位置定义：
- `ssrvpn_shared/lib/models/app_settings.dart`
- `SSRVPN_MacOS/lib/models/app_settings.dart`
- `SSRVPN_Android/lib/models/app_settings.dart`
- `SSRVPN_Windows/lib/models/app_settings.dart`

**建议**：统一使用 `ssrvpn_shared` 中的定义，各平台删除本地定义。

### 3.4 AppSettings 重复（技术债）🟡

三端 `AppSettings` 有 80% 相同字段，但各自维护。

**建议**：在 `ssrvpn_shared` 中创建 `AppSettingsBase`，各平台通过继承扩展平台特有字段。

### 3.5 macOS CocoaPods 迁移（依赖管理）🟢

macOS 项目仍使用 CocoaPods，建议迁移到 Swift Package Manager。

### 3.6 签名和公证自动化（发布流程）🟢

macOS/Windows 的签名和公证流程尚未自动化。

---

## 四、安全检查

### 4.1 已确认的安全实践
- ✅ API 密钥使用 Bearer 认证
- ✅ 日志脱敏（`LogRedactor`）
- ✅ YAML 配置安全转义（修复后）
- ✅ 原子文件写入避免数据损坏
- ✅ 端口绑定检查避免冲突

### 4.2 潜在风险
- ⚠️ `apiSecret` 在 JSON 中明文存储（`settings.json`）
- ⚠️ 订阅 URL 在 JSON 中明文存储

**建议**：考虑使用平台原生的安全存储（macOS Keychain、Android Keystore、Windows Credential Manager）。

---

## 五、总结

| 维度 | 修复前 | 修复后 |
|------|--------|--------|
| 安全性 | YAML 注入风险 | 安全转义 |
| 完整度 | Windows 缺 6 字段 | 三端对齐 |
| 可维护性 | 3 份重复代码 | 共享基类 |
| 测试覆盖 | 53 测试通过 | 53 测试通过 |

### 后续建议优先级

1. **高**：各平台 `ClashService` 继承 `ClashServiceBase`（减少 ~2000 行重复代码）
2. **高**：统一 `ProxyMode` 枚举（消除 4 处重复定义）
3. **中**：`AppSettings` 基类提取（减少 ~500 行重复代码）
4. **中**：`HomeScreen` 组件拆分（提升可维护性）
5. **低**：CocoaPods → Swift Package Manager 迁移
6. **低**：签名/公证自动化
