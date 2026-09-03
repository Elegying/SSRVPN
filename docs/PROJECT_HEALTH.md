# SSRVPN 项目健康与发布状态

最近更新：2026-09-03

当前应用版本：`v4.0.23`

最新正式版本：[`v4.0.23`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.23)

## 当前结论

`v4.0.23` 已正式发布：保留 v4.0.22 的分层智能规则与未知流量代理兜底，同时只在 Android
“智能”模式恢复 178 个经审查的国内应用包名旁路，覆盖抖音及其轻量版、微信、QQ、国内
电商、支付、影音、出行、银行和国内 AI。浏览器、Telegram、ChatGPT、Claude、Lark 国际版
及不确定包名明确不旁路；“全局”模式不启用国内应用旁路，仍允许用户在需要时让全部应用
进入 TUN。

桌面端已把“运行日志”从节点选择页移到订阅页右上角，并在“关于”页增加手动“检查更新”；
未连接时允许用户主动检查，自动检查仍只在连接成功后执行。macOS 系统代理连接去掉了三次
由 `networksetup -set*proxy` 已隐式完成的重复启用调用，保留代理快照、网络服务身份复核、
guardian、回读确认和失败回滚。Windows/macOS 其余连接门禁未为追求耗时数字而删除。

当前版本已在固定 Flutter 3.44.1 工具链通过完整 `make verify`，覆盖共享规则、三端 Flutter、
Android 原生构建、macOS 原生测试和内置 Mihomo 配置校验；受保护 PR #186、精确主分支 CI、
正式三端构建、标签、公开七项资产、GitHub Attestations 与 OSS 公共通道均已完成终验。
发布时 USB 手机不在线，因此未把自动回归或旧版本实机证据冒充 v4.0.23 抖音/Telegram 真机
复验。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前代码版本 | `4.0.23+4023`，三端 pubspec、共享常量、CHANGELOG 一致；七项正式资产已发布 |
| 当前版本本地门禁 | `mise exec flutter@3.44.1 -- make verify` 全部通过：Release tooling 396 项、Shared 659 项（84.98%）、macOS 286 项（66.75%）、Windows 本地 274 项（54.46%，另有 8 项主机专属用例按设计跳过），并包含 Android Flutter/原生构建、规则清单离线校验与 macOS 内置 Mihomo 配置加载 |
| 正式源码与标签 | 受保护 PR [#186](https://github.com/Elegying/SSRVPN/pull/186) 已 squash 合并；`main` 提交 [`2fe43b5`](https://github.com/Elegying/SSRVPN/commit/2fe43b56b1e45f3462e4362aabcecd6140f3d9aa)，标签 `v4.0.23` 精确解引用到同一提交 |
| 精确正式 `main` CI | [`33713779646`](https://github.com/Elegying/SSRVPN/actions/runs/33713779646) 成功；工作区、Android、macOS、Windows、安全、安装器 smoke 与原生门禁全部通过 |
| 标签与正式构建 | [`Prepare Release 33714753378`](https://github.com/Elegying/SSRVPN/actions/runs/33714753378) 和 [`Release 33714772096`](https://github.com/Elegying/SSRVPN/actions/runs/33714772096) 均成功 |
| Android 实机 | 国内应用旁路、浏览器/国外应用负例、“智能”/“全局”作用域和旧快照兼容均有自动回归；发布时 `adb devices` 无在线设备，v4.0.23 正式 APK 原地升级、抖音评论/私信图片与 Telegram 复验保持未执行 |
| 正式公开资产 | [`v4.0.23`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.23) 共七项资产；完整下载后 APK `7b970325…356e`、DMG `a72faf07…e398`、EXE `e0ede592…c3a1`，实际文件、sidecar、Release API digest、provenance 与 GitHub Attestations 一致 |
| OSS 公共通道 | `latest.json` 已指向 `4.0.23`；三个版本化资产完整下载后的 SHA-256 与 GitHub 一致，且文件逐字节相同 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 最近正式版本质量评分（v4.0.23）

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

- Release tooling：396 项通过。
- Shared：659 项通过，行覆盖率 84.98%；分层顺序、冲突处理、DNS policy、六份规则清单及远程缓存失败回退均有回归。
- Android：Flutter 278 项、原生桥守卫、Kotlin 单测与原生构建通过；正式 Release 生成签名 APK，v2 signer 证书与既有版本一致，arm64 核心保持 16 KiB ELF 对齐。
- macOS Flutter：286 项通过，行覆盖率 66.75%；生命周期关键文件 76.47%、系统代理 88.21%，原生 RunnerTests 和内置 Mihomo v1.19.29 的系统代理/TUN 配置加载通过。
- Windows 正式 runner：282 项通过，行覆盖率 57.13%；生命周期关键文件保持 50.00% 门槛，主机专属检查、安装器构建及安装/卸载 smoke 通过。本地固定工具链执行 274 项并按设计跳过 8 项 Windows 主机专属用例。
- 本地首次完整门禁只暴露 macOS 测试替身未模拟 `networksetup -set*proxy` 自带启用语义；修正测试替身后 83 项定向回归与完整门禁通过，没有恢复冗余生产调用或放宽断言。
- 依赖 PR [#145](https://github.com/Elegying/SSRVPN/pull/145) 仅升级 `gradle/actions/setup-gradle` 6.2.0 → 6.3.0；独立验证后合并，提交 `5e56ed4` 的 [主分支 CI](https://github.com/Elegying/SSRVPN/actions/runs/33497028016) 全部成功。
- 依赖 PR [#121](https://github.com/Elegying/SSRVPN/pull/121) 未与 #145 打包：`flutter_secure_storage` 11.0.0 要求 Android `compileSdk 37`，而当前 AGP 9.0.1 支持边界为 36；真实构建失败后已独立关闭，未降低平台门槛强行合并。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。
- 纯文档保留同名必需检查和 Workspace 门禁，但跳过三端平台重构建；手动 GeoIP 更新 PR、发布与非文档变更始终执行全量矩阵。

## 当前证据边界

以下项目是仍未补齐的人工或长期证据，不得由自动化或其他设备替代：

1. v4.0.23 正式 APK 尚未在旧故障手机完成原地升级、抖音评论/私信图片、Telegram、国内站点、海外站点和国内 AI 服务复验；旧版根因日志与自动回归不能替代正式包真机证据。
2. Android 仍缺原生 16 KiB page-size 硬件、其他 VPN 竞争、蜂窝切换、不同 OEM 和同口径电量复测；4 KiB 真机和 ELF 对齐门禁不能替代这些证据。
3. Windows 正式安装器在线构建、安装/卸载 smoke 已通过，但 v4.0.23 尚无普通桌面 TUN/系统代理人工流量矩阵；UAC 取消和托盘正常退出仍受当前实机策略/自动化边界阻塞。
4. macOS 已用内置核心加载 TUN/系统代理配置并通过自动生命周期测试，但 v4.0.23 尚未执行国内、海外、国内 AI、海外 CDN 与持续断网恢复的完整人工流量矩阵。
5. Windows 未签名安装器、macOS ad-hoc/未公证属于既定免费分发边界；Windows Authenticode、macOS Developer ID 与 notarization 均不计划增加。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合、规则命中上报或趋势告警；本版也未实现会自动改变路由的学习机制。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 在旧故障 Android 手机安装 v4.0.23 正式 APK；完成标准：抖音评论和私信图片连续 20 轮、Telegram、国内/海外站点、国内 AI、规则刷新失败及节点断开恢复均有脱敏日志且无失败。
2. 在普通 Windows 桌面分别执行 TUN 与系统代理矩阵；完成标准：DNS、TCP/UDP/QUIC、IPv6 禁用、嗅探失败兜底、异常退出和系统设置恢复全部记录通过。
3. 在 macOS 分别执行 TUN 与系统代理矩阵；完成标准：国内/海外/国内 AI/海外 CDN、持续离线取消、网络恢复和连接耗时中位数/P95 全部形成同机证据。
4. 扩展 Android 硬件矩阵；完成标准：原生 16 KiB page size、蜂窝/Wi-Fi 切换、第二 VPN、至少一种其他 OEM 后台策略和同机 30 分钟电量基线均完成。
5. 观察版本化规则通道与国内应用名单；完成标准：每次调整都有可复现用户反馈、人工审核、包名来源、浏览器/国外应用负例和失败回退测试，不引入会覆盖用户选择的自动学习。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
