# SSRVPN 项目健康与发布状态

最近更新：2026-09-02

当前应用版本：`v4.0.22`

最新正式版本：[`v4.0.22`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.22)

## 当前结论

`v4.0.22` 已正式发布：在 v4.0.21 Telegram 修复基础上，将三端“智能”模式升级为
用户规则优先、海外服务代理、国内企业域名/ASN 直连、GFW/CN/GeoIP 兜底和未知流量默认代理
的统一分层。六份带版本与 SHA-256 清单的规则随包内置，远程刷新失败不阻断连接；Android
普通用户应用全部进入 TUN，使手动强制代理不再被应用级旁路绕过。

Android v4.0.20 实机日志确认 Telegram 三处数据中心地址被旧规则判为 `DIRECT` 后超时，
同一节点经代理访问全部成功；因此根因是分流遗漏，不是节点不可用。v4.0.22 正式 APK
发布前手机已断开 USB，未把未执行的正式 APK 原地升级和 Telegram 复验冒充实机通过。

当前版本已在固定 Flutter 3.44.1 工具链通过完整 `make verify`，覆盖共享规则、三端 Flutter、
Android 原生构建、macOS 原生测试和内置 Mihomo 配置校验；受保护 PR #183、精确主分支 CI、
正式三端构建、标签、公开七项资产、GitHub Attestations 与 OSS 公共通道均已完成终验。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前代码版本 | `4.0.22+4022`，三端 pubspec、共享常量、CHANGELOG 一致；七项正式资产已发布 |
| 当前版本本地门禁 | `mise exec flutter@3.44.1 -- make verify` 全部通过：Release tooling 396 项、Shared 658 项（85.68%）、macOS 284 项（67.28%）、Windows 273 项（54.80%），并包含 Android Flutter/原生构建、规则清单离线校验与 macOS 内置 Mihomo 配置加载；8 项 Windows 主机专属用例按设计留给线上 CI |
| 正式源码与标签 | 受保护 PR [#183](https://github.com/Elegying/SSRVPN/pull/183) 已 squash 合并；`main` 提交 [`eb3d161`](https://github.com/Elegying/SSRVPN/commit/eb3d161015f1abdb154c370b0c2de3bc2b0be57d)，标签 `v4.0.22` 精确解引用到同一提交 |
| 精确正式 `main` CI | [`33625677508`](https://github.com/Elegying/SSRVPN/actions/runs/33625677508) 成功；工作区、Android、macOS、Windows、安全与原生门禁全部通过 |
| 标签与正式构建 | [`Prepare Release 33627188347`](https://github.com/Elegying/SSRVPN/actions/runs/33627188347) 和 [`Release 33627219065`](https://github.com/Elegying/SSRVPN/actions/runs/33627219065) 均成功 |
| Android 实机 | v4.0.20 旧规则根因与同节点代理可达性已实机确认；v4.0.22 正式 APK 发布前手机断开 USB，正式包原地升级与 Telegram 复验保持未执行 |
| 正式公开资产 | [`v4.0.22`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.22) 共七项资产；完整下载后 APK `81faed6d…1ac72`、DMG `c66039fb…1c3ef`、EXE `5a15890d…80152`，实际文件、sidecar、Release API digest、provenance 与 GitHub Attestations 一致 |
| OSS 公共通道 | `latest.json` 已指向 `4.0.22`；三个版本化资产完整下载后的 SHA-256 与 GitHub 一致，版本化与公共 `latest.json` 逐字节一致 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 最近正式版本质量评分（v4.0.22）

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 18/20 | 用户规则、海外服务、国内企业、GFW/CN/GeoIP 和未知流量安全兜底均有行为测试；正式 Android 包和桌面人工流量矩阵仍未执行 |
| 安全、隐私与供应链 | 19/20 | 规则下载大小、格式、条目与 SHA-256 均有界，失败保留已验证旧规则；正式资产可独立校验来源 |
| 架构与可维护性 | 19/20 | 三端复用同一分层构建器与版本化规则包，没有替换代理核心、改变订阅格式或引入自动学习和新依赖 |
| 测试与 CI | 19/20 | 九项受保护检查、完整三端门禁、正式构建、配置加载和安装器 smoke 通过；仍缺部分真机与人工矩阵 |
| 发布工程 | 12/12 | 精确标签、三端正式构建、七项公开资产、摘要、provenance、attestation 和 OSS 公共通道均已终验 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **95/100** | **达到成熟正式发布状态；剩余缺口是扩大设备与人工场景证据，不阻断当前补丁版本** |

## 自动化验证摘要

- Release tooling：396 项通过。
- Shared：658 项通过，行覆盖率 85.68%；分层顺序、冲突处理、DNS policy、六份规则清单及远程缓存失败回退均有回归。
- Android：Flutter 配置、原生桥守卫、Kotlin 单测与原生构建通过；正式 Release 生成签名 APK 并通过包结构 smoke。
- macOS Flutter：284 项通过，行覆盖率 67.28%；原生 RunnerTests 和内置 Mihomo v1.19.29 的系统代理/TUN 配置加载通过。
- Windows Flutter：273 项通过（另有 8 项仅 Windows 主机执行的用例在本地门禁跳过），行覆盖率 54.80%；正式 Windows runner 执行主机专属检查、安装器构建及安装/卸载 smoke 并通过。
- PR 首次 Workspace 尝试出现一项既有订阅刷新时序用例抖动；只重跑失败 job 后通过，同一用例随后在精确 `main` CI 与正式 Release 再次通过，没有为追求绿色结果放宽断言。
- 依赖 PR [#145](https://github.com/Elegying/SSRVPN/pull/145) 仅升级 `gradle/actions/setup-gradle` 6.2.0 → 6.3.0；独立验证后合并，提交 `5e56ed4` 的 [主分支 CI](https://github.com/Elegying/SSRVPN/actions/runs/33497028016) 全部成功。
- 依赖 PR [#121](https://github.com/Elegying/SSRVPN/pull/121) 未与 #145 打包：`flutter_secure_storage` 11.0.0 要求 Android `compileSdk 37`，而当前 AGP 9.0.1 支持边界为 36；真实构建失败后已独立关闭，未降低平台门槛强行合并。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目是仍未补齐的人工或长期证据，不得由自动化或其他设备替代：

1. v4.0.22 正式 APK 尚未在旧故障手机完成原地升级、Telegram、国内站点、海外站点和国内 AI 服务复验；旧版根因日志与自动回归不能替代正式包真机证据。
2. Android 仍缺原生 16 KiB page-size 硬件、其他 VPN 竞争、蜂窝切换、不同 OEM 和同口径电量复测；4 KiB 真机和 ELF 对齐门禁不能替代这些证据。
3. Windows 正式安装器在线构建、安装/卸载 smoke 已通过，但 v4.0.22 尚无普通桌面 TUN/系统代理人工流量矩阵；UAC 取消和托盘正常退出仍受当前实机策略/自动化边界阻塞。
4. macOS 已用内置核心加载 TUN/系统代理配置并通过自动生命周期测试，但 v4.0.22 尚未执行国内、海外、国内 AI、海外 CDN 与持续断网恢复的完整人工流量矩阵。
5. Windows 未签名安装器、macOS ad-hoc/未公证属于既定免费分发边界；Windows Authenticode、macOS Developer ID 与 notarization 均不计划增加。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合、规则命中上报或趋势告警；本版也未实现会自动改变路由的学习机制。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 在旧故障 Android 手机安装 v4.0.22 正式 APK，复验 Telegram、国内/海外站点、国内 AI 海外接口、规则刷新失败和节点断开恢复。
2. 在普通 Windows 桌面分别执行 TUN 与系统代理矩阵，补齐 DNS、TCP/UDP/QUIC、IPv6 禁用、嗅探失败兜底和系统设置恢复证据。
3. 在 macOS 分别执行 TUN 与系统代理矩阵，补齐国内/海外/国内 AI/海外 CDN、持续离线取消和网络恢复证据。
4. 扩展 Android 硬件矩阵：补做原生 16 KiB page size、蜂窝/Wi-Fi 切换、第二 VPN、至少一种其他 OEM 后台策略和同机电量基线。
5. 观察版本化规则通道的更新失败率与用户反馈；只以人工审核规则更新修正误判，不引入会覆盖用户选择或静默改变路由的自动学习。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
