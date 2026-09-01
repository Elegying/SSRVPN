# SSRVPN 项目健康与发布状态

最近更新：2026-09-02

当前应用版本：`v4.0.20`

最新正式版本：[`v4.0.19`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.19)

## 当前结论

`v4.0.20` 是针对 v4.0.19 两项实机问题的补丁候选：Android 停止事务现在能区分仍由应用
持有的 TUN 与 MIUI 延迟移除但描述符已经关闭的接口，继续对未知或活动自有 TUN 失败关闭；
Windows 安装事务会在成功提交后启动可信更新包清理助手，同时继续保留手动包、失败包和
身份不匹配文件。“智能”、全局、订阅、节点格式和连接协议没有变化。

修复代码已通过受保护主分支 CI 和三端正式形态候选构建。Redmi Note 8 / Android 11 实机
完成 App 入口 20/20 轮连接与断开、10/10 轮快速取消，以及后台和 Doze 回归，关闭了旧版
进程终止复现；完整证据见
[v4.0.20 Android 修复候选报告](uat/SSRVPN_Android_v4.0.20_修复候选实机验收报告_20260902.md)。
Windows 修复已通过正式安装器在线 smoke，但没有把线上自动化冒充新的桌面人工 UAT。
当前最新公开版本仍是 v4.0.19；v4.0.20 需在版本提交合并后完成标签、Release、七项资产、
摘要、provenance 和公共下载终验。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前候选版本 | `4.0.20+4020`，三端 pubspec、共享常量和 CHANGELOG 一致；尚未创建标签或 Release |
| 当前版本本地门禁 | Flutter `3.44.1` 下完整 `make verify` 退出码 0；版本、文档、格式、三端测试和覆盖率门禁全部通过 |
| 修复源码 | 受保护 `main` 提交 [`ae83e52`](https://github.com/Elegying/SSRVPN/commit/ae83e529a60830e51054b710db764293dcf53732)；版本提升只允许修改版本和证据文件 |
| 精确修复 `main` CI | [`33543771035`](https://github.com/Elegying/SSRVPN/actions/runs/33543771035) 成功；工作区、Android、macOS、Windows、安全与原生门禁全部通过 |
| 三端候选构建 | [`33545476322`](https://github.com/Elegying/SSRVPN/actions/runs/33545476322) 成功；Android APK、macOS DMG、Windows 安装器和 shared 全部通过，发布步骤按非标签运行设计跳过 |
| Android 实机候选 | APK SHA-256 `432e385f…6ae`；App 20/20、快速取消 10/10、后台/Doze 与真实 HTTPS 通过 |
| 最新正式版本 | [`v4.0.19`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.19) 仍公开；v4.0.20 标签、七项资产和公共通道待本轮正式发布 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 质量评分

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 19/20 | Android 旧故障机完成 20 轮正常循环、10 轮快速取消和 Doze；Windows 清理修复通过真实安装器在线 smoke |
| 安全、隐私与供应链 | 19/20 | 订阅和更新输入有界，日志与诊断脱敏，进程和系统设置按所有权处理，正式资产可校验来源 |
| 架构与可维护性 | 18/20 | 以描述符证据和现有清理助手完成局部修复，没有放宽所有权边界或引入新依赖 |
| 测试与 CI | 19/20 | 九项受保护检查、完整三端门禁、候选构建和 Android 真实故障机回归通过；仍缺部分硬件矩阵 |
| 发布工程 | 10/12 | 候选资产、摘要、签名谱系和 provenance 已预验；v4.0.20 正式标签、公开资产与通道终验待执行 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **93/100** | **修复候选达到补丁发版条件；正式发布事务和发布后公开资产复验尚未完成** |

## 自动化验证摘要

- Release tooling：396 项通过。
- Shared：652 项通过，行覆盖率 85.21%。
- Android Flutter：276 项通过，行覆盖率 67.98%；Android 原生 171 项及守卫、订阅专项测试通过。
- macOS Flutter：284 项通过，行覆盖率 67.38%；原生 RunnerTests 通过。
- Windows Flutter：273 项通过（另有 8 项仅 Windows 主机执行的用例在本地门禁跳过），行覆盖率 54.81%；原生恢复、安装器构建及安装/卸载 smoke 已在线通过。
- 依赖 PR [#145](https://github.com/Elegying/SSRVPN/pull/145) 仅升级 `gradle/actions/setup-gradle` 6.2.0 → 6.3.0；独立验证后合并，提交 `5e56ed4` 的 [主分支 CI](https://github.com/Elegying/SSRVPN/actions/runs/33497028016) 全部成功。
- 依赖 PR [#121](https://github.com/Elegying/SSRVPN/pull/121) 未与 #145 打包：`flutter_secure_storage` 11.0.0 要求 Android `compileSdk 37`，而当前 AGP 9.0.1 支持边界为 36；真实构建失败后已独立关闭，未降低平台门槛强行合并。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目是仍未补齐的人工或长期证据，不得由自动化或其他设备替代：

1. Android App 入口的旧故障已关闭；快捷磁贴只有真实单轮证据。当前 MIUI 对组件命令连续注入两次点击，不能据此标记 20 轮人工单击通过。
2. Android 仍缺原生 16 KiB page-size 硬件、其他 VPN 竞争、蜂窝切换、不同 OEM 和同口径电量复测；4 KiB 真机和 ELF 对齐门禁不能替代这些证据。
3. Windows 清理修复已通过正式安装器在线 smoke，但尚无修复后的普通桌面人工复验；UAC 取消和托盘正常退出仍受当前实机策略/自动化边界阻塞。
4. macOS 持续断网后的取消专项仍未执行；免费 ad-hoc、未公证分发属于既定边界，不再作为待办。
5. Windows 未签名安装器属于既定免费分发边界，不再作为待办；Windows Authenticode、macOS Developer ID 与 notarization 均不计划增加。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合或趋势告警。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 合并 v4.0.20 版本与证据提交，等待精确 `main` 的九项必需检查全部成功。
2. 通过 `Prepare Release` 创建不可变 `v4.0.20` 标签，等待三端正式构建和发布事务完成。
3. 重新下载七项公开资产，核对 SHA-256、Android 签名谱系、三端版本身份、provenance、attestation 和 OSS 公共通道。
4. 发布后回填精确标签、CI、Release、资产摘要和公共下载证据，并关闭已完成的 Android 故障 Issue。
5. 后续补齐原生 16 KiB Android、可靠的 MIUI 磁贴 20 轮、蜂窝/第二 VPN/更多 OEM，以及 Windows 被策略阻塞的人工场景。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
