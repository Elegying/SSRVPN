# ADR-009：macOS Release 权限最小化

## 状态

已接受

## 日期

2026-08-01

## 背景

SSRVPN 的 macOS 桌面包采用免费 ad-hoc、未公证分发，并通过按次管理员授权启动临时 TUN runner。旧 Release entitlement 继承了 Flutter 调试期需要的 JIT、未签名可执行内存和禁用库校验能力；Xcode 还可能向 ad-hoc Release 注入 `get-task-allow`。这些权限不是当前 AOT Release、系统代理或临时 TUN runner 的运行要求，会扩大进程被调试、动态代码执行和库加载的攻击面。

## 决策

1. Debug 与 Profile 继续使用 Flutter 开发所需 entitlement；Release 不复用这些开发权限。
2. Release 明确禁用 Xcode 基础 entitlement 注入，并不得包含：
   - `com.apple.security.get-task-allow`；
   - `com.apple.security.cs.allow-jit`；
   - `com.apple.security.cs.allow-unsigned-executable-memory`；
   - `com.apple.security.cs.disable-library-validation`。
3. 当前应用架构不启用 App Sandbox；现有网络 client/server entitlement 保留，避免把权限清理与沙箱迁移混为一次高风险改造。
4. 免费分发守卫必须检查构建配置与 entitlement 源文件；在 macOS 上还要构建真实 Release `.app`，使用 `codesign` 读取最终签名并确认禁用项未被工具链重新注入。
5. 如果未来引入 Developer ID、公证、App Sandbox、Network Extension 或新的动态代码需求，必须先以新 ADR 取代本决策，并提供迁移、回滚和目标系统验证。

## 后果

- Release 进程不再携带无运行必要的调试和动态代码权限，降低同用户进程附加调试、注入未签名可执行内存或加载任意库的风险。
- Debug/Profile 开发体验不变；系统代理、临时 TUN runner 和免费 ad-hoc 分发决策不变。
- macOS Release 构建成为权限变更的事实来源；只检查 plist 或配置文本不能替代最终产物检查。

## 未采用的方案

### Release 继续沿用 Debug entitlement

实现简单，但为生产包保留没有运行必要的攻击面，因此拒绝。

### 同时迁移 App Sandbox 或 Network Extension

这会改变核心启动、文件存储、网络扩展签名和分发模型，超出权限最小化的可验证范围，因此单独决策。

### 购买 Developer ID 并公证

项目已固定免费桌面分发，不把付费签名作为当前优化路径；该选择也不能替代 entitlement 最小化。

## 验证

- `scripts/test_free_desktop_distribution.py` 固定检查 Release 配置和禁用 entitlement。
- `flutter build macos --release` 生成真实应用后，通过 `codesign -d --entitlements :-` 核对最终权限。
- 完整门禁继续验证 macOS 原生 runner、核心摘要、系统代理与 TUN 生命周期。

## 相关文档

- [免费分发与签名说明](../RELEASE_SIGNING.md)
- [安全策略](../../SECURITY.md)
- [ADR-006：macOS 核心进程身份](006-macos-core-process-identity.md)
