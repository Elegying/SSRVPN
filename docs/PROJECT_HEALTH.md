# SSRVPN 项目健康与发布状态

最近更新：2026-09-03

当前应用版本：`v4.0.25`（发布候选）

最新正式版本：[`v4.0.24`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.24)

## 当前结论

`v4.0.25` 是当前发布候选：三端“运行日志”统一为订阅页右上角的可见文字按钮，节点选择页
不再保留重复入口。诊断默认展示一句话结论、中文检查结果及按本地时间整理的运行记录，内部
事件名、会话编号、路径和冗余核心信息移入默认收起的脱敏技术明细。

本候选同时修复 v4.0.24 远程 provider 已在 Mihomo 内存中刷新、但长期本地 YAML 未更新而
持续触发校验失败的问题。新流程先下载并校验变化文件，再执行核心热更新；全部成功后原子
持久化本地文件并最后提交版本清单。任何失败继续使用旧规则和当前连接。TUN、系统代理、DNS、
路由顺序、国内应用旁路名单和未知流量代理兜底均未改变。

`v4.0.24` 仍是最新正式版本；其受保护源码、三端线上产物、公开七项资产、供应链证明和 OSS
公共通道证据保留在下表。v4.0.25 只有完成固定工具链门禁、受保护合并、精确主分支 CI、正式
三端构建及公开资产复核后才可改记为正式发布。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前代码版本 | `4.0.25+4025` 发布候选，三端 pubspec、共享常量和 CHANGELOG 一致；最新正式资产仍为 v4.0.24 |
| 当前版本本地门禁 | v4.0.25 使用 `mise exec flutter@3.44.1 -- make verify` 全部通过：Release tooling 396 项，Shared 覆盖率 85.52%，Android 279 项及原生构建通过（68.15%），macOS 286 项、原生测试和内置 Mihomo 配置加载通过（66.75%），Windows 本地 274 项通过、8 项主机专属用例按设计跳过（54.46%） |
| 正式源码与标签 | 受保护 PR [#188](https://github.com/Elegying/SSRVPN/pull/188) 已 squash 合并；`main` 提交 [`ff801ba`](https://github.com/Elegying/SSRVPN/commit/ff801ba482a40333077fed92806f4d255d2b66d4)，标签 `v4.0.24` 精确解引用到同一提交 |
| 精确正式 `main` CI | [`33726967743`](https://github.com/Elegying/SSRVPN/actions/runs/33726967743) 成功；工作区、Android、macOS、Windows、安全、安装器 smoke 与原生门禁全部通过 |
| 标签与正式构建 | [`Prepare Release 33728358633`](https://github.com/Elegying/SSRVPN/actions/runs/33728358633) 和 [`Release 33728388311`](https://github.com/Elegying/SSRVPN/actions/runs/33728388311) 均成功 |
| Android 实机 | 182 个国内应用旁路、浏览器/国外应用负例、“智能”/“全局”作用域和旧快照兼容均有自动回归；发布时 `adb devices` 无在线设备，v4.0.24 正式 APK 原地升级、抖音评论/私信图片与 Telegram 复验保持未执行 |
| 正式公开资产 | [`v4.0.24`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.24) 共七项资产；完整下载后 APK `6d8486b4…1d522`、DMG `077fe8b9…53d1d`、EXE `6ccf7262…fd887`，实际文件、sidecar、Release API digest、provenance 与 GitHub Attestations 一致 |
| OSS 公共通道 | `latest.json` 已指向 `4.0.24`；三个版本化资产完整下载后的 SHA-256 与 GitHub 一致，且文件逐字节相同 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 最近正式版本质量评分（v4.0.24）

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 19/20 | 用户规则、国内应用旁路作用域、浏览器/国外应用负例、海外服务、国内企业、GFW/CN/GeoIP 和未知流量安全兜底均有行为测试；正式 Android 包和桌面人工流量矩阵仍未执行 |
| 安全、隐私与供应链 | 19/20 | 规则下载大小、格式、条目与 SHA-256 均有界，失败保留已验证旧规则；正式资产可独立校验来源 |
| 架构与可维护性 | 19/20 | 三端复用同一分层构建器与版本化规则包，没有替换代理核心、改变订阅格式或引入自动学习和新依赖 |
| 测试与 CI | 19/20 | 九项受保护检查、完整三端门禁、正式构建、配置加载和安装器 smoke 通过；仍缺部分真机与人工矩阵 |
| 发布工程 | 12/12 | 精确标签、三端正式构建、七项公开资产、摘要、provenance、attestation 和 OSS 公共通道均已终验 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **96/100** | **达到成熟正式发布状态；剩余缺口是扩大设备与人工场景证据，不阻断当前补丁版本** |

## 自动化验证摘要

- v4.0.25 发布候选：固定 Flutter 3.44.1 完整 `make verify` 通过；三端订阅日志文字入口、Android
  诊断弹层、规整日志与技术明细、旧 provider 缓存升级后长期落盘，以及下载/API/落盘失败保留
  旧版本均有行为回归。受保护合并、主分支 CI 和正式资产尚待完成。
- Release tooling：396 项通过。
- Shared：665 项通过，行覆盖率 85.01%；分层顺序、冲突处理、DNS policy、版本描述、六份规则清单、同版本零下载及远程缓存失败回退均有回归。
- Android：Flutter 278 项、原生桥守卫、Kotlin 单测与原生构建通过；正式 Release 生成签名 APK，v2 signer 证书与既有版本一致，arm64 核心保持 16 KiB ELF 对齐。
- macOS Flutter：286 项通过，行覆盖率 66.75%；生命周期关键文件 76.47%、系统代理 88.21%，原生 RunnerTests 和内置 Mihomo v1.19.29 的系统代理/TUN 配置加载通过。
- Windows 正式 runner：282 项通过，行覆盖率 57.13%；生命周期关键文件保持 50.00% 门槛，主机专属检查、安装器构建及安装/卸载 smoke 通过。本地固定工具链执行 274 项并按设计跳过 8 项 Windows 主机专属用例。
- 规则版本端点、清单与六份 provider 已独立从公开 `main` 下载复核；122 字节版本描述声明的清单 SHA-256 与实算值一致。
- 依赖 PR [#145](https://github.com/Elegying/SSRVPN/pull/145) 仅升级 `gradle/actions/setup-gradle` 6.2.0 → 6.3.0；独立验证后合并，提交 `5e56ed4` 的 [主分支 CI](https://github.com/Elegying/SSRVPN/actions/runs/33497028016) 全部成功。
- 依赖 PR [#121](https://github.com/Elegying/SSRVPN/pull/121) 未与 #145 打包：`flutter_secure_storage` 11.0.0 要求 Android `compileSdk 37`，而当前 AGP 9.0.1 支持边界为 36；真实构建失败后已独立关闭，未降低平台门槛强行合并。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目是仍未补齐的人工或长期证据，不得由自动化或其他设备替代：

1. v4.0.24 正式 APK 尚未在旧故障手机完成原地升级、抖音评论/私信图片、Telegram、国内站点、海外站点和国内 AI 服务复验；旧版根因日志与自动回归不能替代正式包真机证据。
2. Android 仍缺原生 16 KiB page-size 硬件、其他 VPN 竞争、蜂窝切换、不同 OEM 和同口径电量复测；4 KiB 真机和 ELF 对齐门禁不能替代这些证据。
3. Windows 正式安装器在线构建、安装/卸载 smoke 已通过，但 v4.0.24 尚无普通桌面 TUN/系统代理人工流量矩阵；UAC 取消和托盘正常退出仍受当前实机策略/自动化边界阻塞。
4. macOS 已用内置核心加载 TUN/系统代理配置并通过自动生命周期测试，但 v4.0.24 尚未执行国内、海外、国内 AI、海外 CDN 与持续断网恢复的完整人工流量矩阵。
5. Windows 未签名安装器、macOS ad-hoc/未公证属于既定免费分发边界；Windows Authenticode、macOS Developer ID 与 notarization 均不计划增加。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合、规则命中上报或趋势告警；本版也未实现会自动改变路由的学习机制。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 在旧故障 Android 手机安装 v4.0.24 正式 APK；完成标准：抖音评论和私信图片连续 20 轮、Telegram、国内/海外站点、国内 AI、同版本规则零下载、规则刷新失败及节点断开恢复均有脱敏日志且无失败。
2. 在普通 Windows 桌面分别执行 TUN 与系统代理矩阵；完成标准：DNS、TCP/UDP/QUIC、IPv6 禁用、嗅探失败兜底、异常退出和系统设置恢复全部记录通过。
3. 在 macOS 分别执行 TUN 与系统代理矩阵；完成标准：国内/海外/国内 AI/海外 CDN、持续离线取消、网络恢复和连接耗时中位数/P95 全部形成同机证据。
4. 扩展 Android 硬件矩阵；完成标准：原生 16 KiB page size、蜂窝/Wi-Fi 切换、第二 VPN、至少一种其他 OEM 后台策略和同机 30 分钟电量基线均完成。
5. 观察版本化规则通道与国内应用名单；完成标准：每次调整都有可复现用户反馈、人工审核、包名来源、浏览器/国外应用负例和失败回退测试，不引入会覆盖用户选择的自动学习。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
