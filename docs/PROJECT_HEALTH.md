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

2026-09-01 的 v4.0.19 实机验收确认了两个发布后问题：Android 11 在连接/断开循环中会因
自有 TUN lease 无法确认释放而进入 fail-closed 进程终止恢复；Windows 内置更新器下载并
标记的安装包在安装成功后未自动清理。两者都以安全保留或安全终止收敛，没有遗留流量资源、
误删用户文件或破坏用户数据，但均不满足完整 UAT 放行条件。复现与边界见
[#167](https://github.com/Elegying/SSRVPN/issues/167)、
[Android/macOS 实机报告](uat/SSRVPN_Android_MacOS_v4.0.19_实机验收报告_20260901.md)和
[Windows 实机报告](uat/SSRVPN_Windows_v4.0.19_实机验收报告_20260901.md)。

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
| 功能正确性与失败恢复 | 15/20 | 自动化边界完整，但 Android 11 真机循环断开会终止进程，Windows 已验证更新包成功安装后未自动清理 |
| 安全、隐私与供应链 | 19/20 | 订阅和更新输入有界，日志与诊断脱敏，进程和系统设置按所有权处理，正式资产可校验来源 |
| 架构与可维护性 | 17/20 | 共享领域逻辑和平台集成边界清楚；少数生命周期与安装事务仍是受规模护栏保护的热点 |
| 测试与 CI | 18/20 | 九项受保护检查、四套 Flutter 测试和三端门禁通过；真机发现现有自动化未覆盖的 Android 与 Windows 真实系统差异 |
| 发布工程 | 9/12 | 资产、标签、provenance 和公开事务闭环；当前正式版本有两项需由修复版关闭的实机阻断 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **86/100** | **工程与供应链达到成熟发布水平；当前客户端处于“修复已开始、真机复验后再发版”阶段** |

## 自动化验证摘要

- Release tooling：396 项通过。
- Shared：652 项通过，行覆盖率 85.21%。
- Android Flutter：276 项通过，行覆盖率 67.98%；Android 原生单元测试、守卫和订阅专项测试通过。
- macOS Flutter：284 项通过，行覆盖率 67.38%；原生 RunnerTests 通过。
- Windows Flutter：273 项通过（另有 8 项仅 Windows 主机执行的用例在本地门禁跳过），行覆盖率 54.81%；原生恢复、安装器构建及安装/卸载 smoke 已在线通过。
- 依赖 PR [#145](https://github.com/Elegying/SSRVPN/pull/145) 仅升级 `gradle/actions/setup-gradle` 6.2.0 → 6.3.0；独立验证后合并，提交 `5e56ed4` 的 [主分支 CI](https://github.com/Elegying/SSRVPN/actions/runs/33497028016) 全部成功。
- 依赖 PR [#121](https://github.com/Elegying/SSRVPN/pull/121) 未与 #145 打包：`flutter_secure_storage` 11.0.0 要求 Android `compileSdk 37`，而当前 AGP 9.0.1 支持边界为 36；真实构建失败后已独立关闭，未降低平台门槛强行合并。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目同时包含已确认故障和仍未补齐的人工或长期证据，不得互相替代：

1. Android v4.0.19 已确认连接/断开循环触发 TUN lease 校验失败和进程终止，见 #167；这是客户端故障，不是单纯证据缺口。
2. Windows v4.0.19 已确认内置更新器的可信标记安装包在安装成功后未自动清理；手动未标记包正确保留，没有越界删除。
3. Android 仍缺原生 16 KiB page-size 硬件、其他 VPN 竞争、蜂窝切换、不同 OEM 和同口径电量复测；4 KiB 真机和 ELF 对齐门禁不能替代这些证据。
4. macOS 持续断网后的取消专项仍未执行；免费 ad-hoc、未公证分发属于既定边界，不再作为待办。
5. Windows 未签名安装器属于既定免费分发边界，不再作为待办；UAC 取消和托盘正常退出仍受当前实机策略/自动化边界阻塞。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合或趋势告警。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 修复 #167，同时保留 fail-closed 清理；在 Redmi Note 8 上完成 App 与快捷磁贴各 20/20 轮连接/断开、快速取消和 Doze 回归。
2. 修复 Windows 已验证安装包清理助手的启动时机，并用真实安装器验证可信包成功后删除、手动包继续保留。
3. 两项修复通过三端自动化和 Android/Windows 实机复验后发布补丁版本；macOS 持续离线取消继续明确为未执行。
4. 在原生 16 KiB page-size Android 设备上验证安装、覆盖升级、连接、真实流量和断开清理。
5. 修复版发布后立即回填精确提交、CI、Release、资产摘要和三端正式二进制复验结果。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
