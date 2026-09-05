# SSRVPN 项目健康与发布状态

最近更新：2026-09-05

当前应用版本：`v4.0.28`

最新正式版本：[`v4.0.27`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.27)

## 当前结论

`v4.0.28` 为当前发布候选，包含多轮审查后的连接、订阅事务与实机问题修复。
失败提示明确区分原因与操作建议；Android 手动断开同步、macOS 有效代理确认、异常记录
分类和长文本显示均增加回归。完整本地门禁、精确提交的线上 CI、正式签名包的实机验收和
正式发布结果将分别补记；下文 `v4.0.27` 记录仅代表上一正式版，不能代替本候选的证据。
macOS 本轮按维护者要求不执行断网测试。

## 上一正式版结论

`v4.0.27` 已正式发布。非标签候选 APK 已在 USB Android 17 真机完成飞行模式、Wi-Fi/移动
网络完全断开、VPN 保持、断网诊断、网络恢复、Wi-Fi/蜂窝切换和恢复后数据通道验收。真实
完全断网现在会把“节点与外部网络”显示为不阻断连接的橙色提醒，恢复后重新诊断回到全部正常；
[#193](https://github.com/Elegying/SSRVPN/issues/193) 已关闭。

六份自有智能规则同时改为按语义版本完整校验和原子激活。当前连接始终使用建连时的完整规则
版本；新版本通过摘要、大小、条目数、语法和精确文件集合检查后长期保存，并在下一次生成配置
时整体启用。失败继续使用已验证旧版本或随包基线，不停止连接，也不会让新旧规则混用。

`v4.0.26` 已正式发布：三端“运行日志”统一为订阅页右上角的可见文字按钮，节点选择页
不再保留重复入口。诊断默认展示一句话结论、中文检查结果及按本地时间整理的运行记录，内部
事件名、会话编号、路径和冗余核心信息移入默认收起的脱敏技术明细。

修复与发布准备分别经受保护 PR #195、#198 合并。精确主分支 CI、Prepare Release、三端
正式构建、人工 `release` 环境审批、公开七项资产、资产摘要、统一 provenance、三份 GitHub
Attestation 与 OSS 公共更新通道均已独立复核。Windows 主客户端和外层启动器继续固定以管理
员身份运行；TUN、系统代理、DNS、用户规则优先级、国内应用旁路和未知公网流量代理兜底没有
被本版稳定性修复削弱。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前代码版本 | `4.0.27+4027` 正式版，三端 pubspec、共享常量与 CHANGELOG 一致 |
| 当前版本本地门禁 | `mise exec flutter@3.44.1 -- make verify` 全部通过；Release tooling 396 项、三端 Flutter/原生检查、配置校验、覆盖率与安装器守卫均成功，Windows 主机专属用例在 macOS 本地按设计跳过并由线上 Windows runner 补齐 |
| 正式源码与标签 | 受保护 PR [#195](https://github.com/Elegying/SSRVPN/pull/195) 与 [#198](https://github.com/Elegying/SSRVPN/pull/198) 已 squash 合并；最终 `main` 提交 [`40a0083`](https://github.com/Elegying/SSRVPN/commit/40a0083cc96380488c40638a087a52eebab875e8)，注释标签 `v4.0.27` 精确解引用到同一提交 |
| 精确正式 `main` CI | [`33774884684`](https://github.com/Elegying/SSRVPN/actions/runs/33774884684) 成功；Workspace、Android、macOS、Windows、安全、安装器 smoke 与原生门禁全部通过 |
| 标签与正式构建 | [`Prepare Release 33782361025`](https://github.com/Elegying/SSRVPN/actions/runs/33782361025) 和 [`Release 33782400613`](https://github.com/Elegying/SSRVPN/actions/runs/33782400613) 均成功 |
| Android 实机 | 同一正式提交的候选 APK 已在 Android 17 真机验证两次真实完全断网、飞行模式、Wi-Fi/蜂窝切换、VPN 保持、诚实诊断和无人工重连恢复；Google/Telegram 数据通道恢复，[#193](https://github.com/Elegying/SSRVPN/issues/193) 已关闭 |
| 正式公开资产 | [`v4.0.27`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.27) 为不可变、非 draft、非 prerelease 的 latest，共七项资产；独立完整下载后 APK `c001c392…b2847`、DMG `ea59a57a…28044`、EXE `987231d6…450d1`，实际文件、sidecar、Release API digest、provenance 与 GitHub Attestations 一致 |
| OSS 公共通道 | `latest.json` 已指向 `4.0.27`；三个版本化安装包完整下载后的 SHA-256 与 GitHub 一致，且文件逐字节相同 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 最近正式版本质量评分（v4.0.27）

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 20/20 | 用户规则、分流与未知流量安全兜底均有行为测试；Android 断网诊断缺陷已完成自动回归和真机关闭，恢复无需人工重连 |
| 安全、隐私与供应链 | 19/20 | 规则下载大小、格式、条目与 SHA-256 均有界，失败保留已验证旧规则；正式资产可独立校验来源 |
| 架构与可维护性 | 19/20 | 三端复用同一分层构建器与版本化规则包，没有替换代理核心、改变订阅格式或引入自动学习和新依赖 |
| 测试与 CI | 19/20 | 九项受保护检查、完整三端门禁、正式构建、配置加载和安装器 smoke 通过；仍缺部分真机与人工矩阵 |
| 发布工程 | 12/12 | 精确标签、三端正式构建、七项公开资产、摘要、provenance、attestation 和 OSS 公共通道均已终验 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **97/100** | **达到成熟正式发布状态；剩余缺口是扩大设备与人工场景证据，不阻断当前补丁版本** |

## 自动化验证摘要

- v4.0.27 正式版：固定 Flutter 3.44.1 完整 `make verify`、受保护合并、精确主分支 CI、Prepare、
  三端正式构建和公开渠道终验全部通过。Android 离线/未验证/未知原生网络状态、恢复后复查，
  以及版本化规则的完整激活、失败回退和下次连接启用均有行为回归。
- Release tooling：396 项通过。
- Shared：正式 Release 674 项通过，行覆盖率 85.14%；分层顺序、冲突处理、DNS policy、版本描述、六份规则清单、同版本零下载及远程缓存失败回退均有回归。
- Android：正式 Release Flutter 280 项、原生桥守卫、Kotlin 单测与原生构建通过；生成签名 APK，v2 signer 证书与既有版本一致，arm64 核心保持 16 KiB ELF 对齐，行覆盖率 68.22%。
- macOS Flutter：286 项通过，行覆盖率 66.75%；生命周期关键文件 76.47%、系统代理 88.21%，原生 RunnerTests 和内置 Mihomo v1.19.29 的系统代理/TUN 配置加载通过。
- Windows 正式 runner：282 项通过，行覆盖率 57.13%；生命周期关键文件保持 50.00% 门槛，主机专属检查、安装器构建及安装/卸载 smoke 通过。本地固定工具链执行 274 项并按设计跳过 8 项 Windows 主机专属用例。
- GitHub 清理仅删除未公开 v4.0.25 的两个临时 Actions 产物及已被最终提交取代的两份 CodeQL trap 缓存；正在使用的构建缓存、v4.0.26 恢复产物、`v4.0.15` 起的正式发行版和全部 Git 历史均保留。
- 规则版本端点、清单与六份 provider 已独立从公开 `main` 下载复核；122 字节版本描述声明的清单 SHA-256 与实算值一致。
- v4.0.27 Android 断网与恢复步骤、真实覆盖范围、发布证据和恢复后终态见
  [实机验收报告](uat/SSRVPN_Android_v4.0.27_实机验收报告_20260904.md)；原始设备标识、
  用户路径、订阅、节点和出口信息未写入仓库。v4.0.26 Android/macOS 基线继续见
  [上一版报告](uat/SSRVPN_Android_MacOS_v4.0.26_实机验收报告_20260903.md)。
- 依赖 PR [#145](https://github.com/Elegying/SSRVPN/pull/145) 仅升级 `gradle/actions/setup-gradle` 6.2.0 → 6.3.0；独立验证后合并，提交 `5e56ed4` 的 [主分支 CI](https://github.com/Elegying/SSRVPN/actions/runs/33497028016) 全部成功。
- 依赖 PR [#121](https://github.com/Elegying/SSRVPN/pull/121) 未与 #145 打包：`flutter_secure_storage` 11.0.0 要求 Android `compileSdk 37`，而当前 AGP 9.0.1 支持边界为 36；真实构建失败后已独立关闭，未降低平台门槛强行合并。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目是仍未补齐的人工或长期证据，不得由自动化或其他设备替代：

1. v4.0.27 候选 APK 已在 Android 17 真机验证飞行模式、Wi-Fi/移动网络完全断开、Wi-Fi/蜂窝切换、诚实诊断和无人工重连恢复；v4.0.26 的抖音评论/私信图片、国内应用旁路和五轮重连基线仍有效，但尚未达到连续 20 轮长期矩阵，也未覆盖完整国内 AI 场景。
2. Android 仍缺原生 16 KiB page-size 硬件、其他 VPN 竞争、不同 OEM 和同口径电量复测；本轮已补齐单机蜂窝切换，但 4 KiB 真机和 ELF 对齐门禁不能替代其他硬件证据。
3. Windows v4.0.27 正式安装器在线构建、管理员策略和安装/卸载 smoke 已通过，但尚无本版普通桌面 TUN/系统代理人工流量矩阵；UAC 取消和托盘正常退出仍受当前实机策略/自动化边界阻塞。
4. macOS 最近一次人工基线已验证 TUN/系统代理、国内/海外 HTTP、DNS、TCP、同版规则零下载及断开恢复；国内 AI 业务、海外 CDN、UDP/QUIC 和持续断网恢复仍未形成完整人工矩阵。本轮按维护者要求未断开本机网络。
5. Windows 未签名安装器、macOS ad-hoc/未公证属于既定免费分发边界；Windows Authenticode、macOS Developer ID 与 notarization 均不计划增加。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合、规则命中上报或趋势告警；本版也未实现会自动改变路由的学习机制。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 在普通 Windows 桌面分别执行 TUN 与系统代理矩阵；完成标准：DNS、TCP/UDP/QUIC、IPv6 禁用、嗅探失败兜底、异常退出和系统设置恢复全部记录通过。
2. 补齐 Android 长期与硬件矩阵；完成标准：抖音评论/私信图片连续 20 轮、国内 AI、原生 16 KiB page size、第二 VPN、其他 OEM 后台策略和同机 30 分钟电量基线形成证据。
3. 按实际产品风险补齐 macOS 尚未覆盖的国内 AI、海外 CDN、UDP/QUIC 场景；本机断网仅在不影响工作网络的独立窗口执行。约 14 秒端到端观察含人工授权等待，不作为待修性能问题；只有分离计时后才能评价程序阶段。
4. 观察版本化规则通道与国内应用名单；完成标准：每次调整都有可复现用户反馈、人工审核、包名来源、浏览器/国外应用负例和失败回退测试，不引入会覆盖用户选择的自动学习。
5. 定期演练现有 OSS/GitHub 发布回滚路径；完成标准：使用既有维护工作流验证不可变版本资产、公共指针降级保护和恢复备份，不删除当前或历史正式版本。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
