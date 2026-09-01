# SSRVPN 项目健康与发布状态

最近更新：2026-09-01

当前应用版本：`v4.0.19`

最新正式版本：[`v4.0.19`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.19)

## 当前结论

`v4.0.19` 是当前正式版本：“智能”模式改为只代理用户强制代理、SSRVPN
内置强制代理和固定版本 GFW 规则集命中的目标，其他流量默认直连。IPv6
防泄漏、私有网络安全、中国直连、DNS 防循环和“全局”模式语义保持不变。
受保护主分支、精确提交 CI、三平台线上构建、GitHub Release、SHA-256、
provenance 和 OSS 公共通道终验均已完成。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前正式版本 | `4.0.19+4019`，三端 pubspec 与共享常量一致；已完成三端线上构建与公开分发 |
| 当前版本本地门禁 | Flutter `3.44.1` 下 `scripts/verify-all.sh` 退出码 0 |
| 发布源码 | 受保护 `main` 提交 [`027baad`](https://github.com/Elegying/SSRVPN/commit/027baad349bd9cd071c5387a47abd692d665d0a8)；注释标签 `v4.0.19` 解引用到同一提交 |
| 精确 `main` CI | [`33423245637`](https://github.com/Elegying/SSRVPN/actions/runs/33423245637) 成功；工作区、Android、macOS、Windows、安全与原生门禁全部通过 |
| 发布准备与标签 | [`33424668503`](https://github.com/Elegying/SSRVPN/actions/runs/33424668503) 冻结主分支、复用精确 CI、创建标签并等待正式发布成功 |
| 正式线上构建 | [`33424705678`](https://github.com/Elegying/SSRVPN/actions/runs/33424705678) 成功；Android APK、macOS DMG、Windows 安装器、共享包测试和发布后终验全部通过 |
| GitHub Release | [`v4.0.19`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.19) 已公开，共 7 项预期资产；三端二进制 SHA-256、GitHub API digest 与 provenance 一致 |
| OSS 公共通道 | 不可变版本目录、`latest.json` 提升与发布后下载回读均由正式 Release 工作流验证通过 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 质量评分

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 19/20 | 三端连接、取消、切换、核心退出、代理/TUN 所有权与回滚均有行为验证；外部可达性观察不负责断开连接 |
| 安全、隐私与供应链 | 19/20 | 订阅和更新输入有界，日志与诊断脱敏，进程和系统设置按所有权处理，正式资产可校验来源 |
| 架构与可维护性 | 17/20 | 共享领域逻辑和平台集成边界清楚；少数生命周期与安装事务仍是受规模护栏保护的热点 |
| 测试与 CI | 19/20 | 九项受保护检查、四套 Flutter 测试、三端原生/平台门禁和渐进覆盖率门槛通过 |
| 发布工程 | 11/12 | 自动准备、不可变标签、精确 SHA、Draft/OSS/公开事务、失败恢复和发布后终验形成闭环 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **93/100** | **正式发布质量；自动化与线上制品已闭环，但不等同于完整三端人工实机矩阵** |

## 自动化验证摘要

- Release tooling：396 项通过。
- Shared：652 项通过，行覆盖率 85.21%。
- Android Flutter：276 项通过，行覆盖率 67.98%；Android 原生单元测试、守卫和订阅专项测试通过。
- macOS Flutter：284 项通过，行覆盖率 67.38%；原生 RunnerTests 通过。
- Windows Flutter：273 项通过（另有 8 项仅 Windows 主机执行的用例在本地门禁跳过），行覆盖率 54.81%；原生恢复、安装器构建及安装/卸载 smoke 已在线通过。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目是尚未补齐的人工或长期证据，不是已经确认的客户端故障：

1. `v4.0.19` 已完成正式线上构建，但尚未完成完整三端人工实机矩阵；自动化和旧版本真机记录不能替代当前版本实机 UAT。
2. Windows 11 仍需人工复验 Explorer 可见性、UAC 取消，以及应用内更新安装包成功安装后的自动清理体验。
3. Android 仍缺原生 16 KiB page-size 硬件，以及长时、Doze、不同 OEM 和同口径电量复测。
4. macOS 持续断网后的取消专项仍未执行；免费 ad-hoc、未公证分发属于既定边界。
5. Windows 未签名安装器属于既定免费分发边界；SmartScreen 提示不能由 SHA-256 完全替代。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合或趋势告警。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 按 [UAT 矩阵](UAT_MATRIX.md) 补齐 Windows 安装更新、Android 长时/电量和 macOS 故障注入证据。
2. 在原生 16 KiB page-size Android 设备上验证安装、连接、真实流量和断开清理。
3. 在新增行为证据保护下逐步降低生命周期热点复杂度并提高关键文件覆盖率。
4. 每次正式发布后立即回填版本、精确提交、CI、Release、资产和剩余证据边界。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
