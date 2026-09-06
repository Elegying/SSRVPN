# SSRVPN 项目健康与发布状态

最近更新：2026-09-06

当前应用版本：`v4.0.33`

最新正式版本：[`v4.0.33`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.33)

## 当前结论

`v4.0.33` 已正式发布：三端账号卡显示面板实际用量/额度及比例（例如
`125GB/250GB 50%`），单位自动选择，新增「每月1日重置」提醒。零额度显示 `—%`，
超额不截断；提醒不触发客户端清零。既有可信归属、统计有效期与本机三项采样保持原逻辑。
详见 [额度与重置提醒验证](ACCOUNT_USAGE_QUOTA_VALIDATION.md)。

[PR #211](https://github.com/Elegying/SSRVPN/pull/211) 经全部必需门禁合并，正式源码
`e6c302f3000b372835ad4c043a48d8c64b3a611c`。[PR CI](https://github.com/Elegying/SSRVPN/actions/runs/34024813436)、
[精确 main CI](https://github.com/Elegying/SSRVPN/actions/runs/34025766797)、
[Prepare](https://github.com/Elegying/SSRVPN/actions/runs/34025778428)、
[Release](https://github.com/Elegying/SSRVPN/actions/runs/34026493664) 均成功。
正式公开时间 `2026-09-06T10:19:35Z`，Release ID `383541265`。

| 正式产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| SSRVPN.apk | 30,753,424 | `5db9df8796ce0387d1c3c95d08c7e4dd9479e45325ab924822d88a5bee2c96de` |
| SSRVPN.dmg | 27,399,144 | `5eb40c69a5bb6ca72edef6bfdaa71457d6e61a365ca9868999e001725a94a6cd` |
| SSRVPN_Setup.exe | 31,149,617 | `e17660ca75cc17f667da2797a6db5da5bb18369a813994003e1dac385705197e` |

GitHub/OSS latest、三端固定与版本化完整文件、sidecar/API digest 全部独立核验一致。
Android原正式签名、macOS镜像/代码签名、三份绑定精确源码的attestation及Windows
安装/升级/卸载日志通过核验。本地完整门禁通过，精确PR共享1070项、最终布局270项
通过，最小字号10px；Android隔离原生9步和macOS隔离原生8步通过。Windows交互UI
及三端生产VPN实机验收不在本次证据范围内，未操作USB正式客户端或真实账号。

### v4.0.32 发布记录

`v4.0.32` 已正式发布：保持已确认的紧凑并排布局；高窗口纵向布局将节点卡自身固定在
扣除系统/标题栏安全区后的主页中心，三卡/五卡、连接/断开不使节点卡漂移。
统计区继续贴底，公网 IPv4 与节点卡至少间隔 12px，现有最小窗口及默认启动尺寸不变。
详见 [首页节点居中验证](HOME_NODE_CENTER_VALIDATION.md)。

[PR #209](https://github.com/Elegying/SSRVPN/pull/209) 经全部必需门禁合并，正式源码
`3f123e0d0c6cbff86d02529c94f5fc310c967f12`。
[PR CI](https://github.com/Elegying/SSRVPN/actions/runs/34020379011)、
[精确 main CI](https://github.com/Elegying/SSRVPN/actions/runs/34020954461)、
[Release](https://github.com/Elegying/SSRVPN/actions/runs/34021696215) 最终全部成功。
[初始 Prepare](https://github.com/Elegying/SSRVPN/actions/runs/34020994062) 已创建正确标签并
触发 Release；首轮 runner 到 OSS 上传仅约 30–36 KiB/s，首个文件上传至 84% 时取消
该次发布作业以更换 runner，因此 Prepare 的等待结果为失败。随后仅重试发布作业，
复用同一草稿 ID、标签、三端安装包和构建证明；没有重建覆盖资产或移动标签。
正式公开时间 `2026-09-06T08:52:59Z`，Release ID `383515955`。

| 正式产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| SSRVPN.apk | 30,751,132 | `6e77188ec12258c75f9ec0544508ae496ed0b01592028883d83f0abbe1e11057` |
| SSRVPN.dmg | 27,399,892 | `e1e7ce4814003b78235681f7c8116febc7c747699357d33f515f8cd679ea3ffe` |
| SSRVPN_Setup.exe | 31,149,886 | `82cc69d8bc87cde7f5bcd5e96c1bf4a2c782c2c5549f120606b14abf17812cb5` |

独立完整下载核验：GitHub latest、OSS latest、三端固定/版本化文件、SHA256 sidecar
与 GitHub API digest 全部一致。三份 attestation 绑定正式标签、工作流和精确源码；
Android 原正式签名与 4.0.32/4032、macOS 镜像和代码签名/版本通过核验。
PR、main、Release 的 Windows 安装、升级、卸载日志均独立确认成功，三端符号另行归档。

完整本地 `make verify` 通过，共享 1006 项/87.65% 覆盖率、Android 289 项、macOS 316 项、
Windows Flutter 293 项通过；本机 7 项 Windows API 测试按平台跳过，由 Windows CI 验证。
中文布局 206 项通过；六张紧凑布局截图与 4.0.31 逐字节一致。隔离 Android 原生九步、
macOS 原生八步通过；macOS 380×762 视口中卡中心始终为 (190,381)。未冒充三端正式
客户端实机验收，未操作 USB 手机、生产 VPN 或真实账号。

### v4.0.31 发布记录

`v4.0.31` 已正式发布：统计卡片仍贴近底栏，上方各组按剩余高度均衡分配间距；
桌面最小窗口节点卡与公网 IPv4 保持 12 逻辑像素间隔。桌面默认 440×720 适配显示器
可用工作区并居中，保留已保存尺寸与原最小限制。短暂后台保留同账号未过期统计，
过期、失败、身份变化仍一起隐藏两块。详见 [首页与后台验证](HOME_SPACING_VALIDATION.md)。

[PR #207](https://github.com/Elegying/SSRVPN/pull/207) 经九项必需检查合并，正式源码
`6529f5c4f73732ba09767d3206bd0295dbb94061`。
[PR CI](https://github.com/Elegying/SSRVPN/actions/runs/34014446266)、
[精确 main CI](https://github.com/Elegying/SSRVPN/actions/runs/34015089738)、
[Prepare Release](https://github.com/Elegying/SSRVPN/actions/runs/34015141809)、
[Release](https://github.com/Elegying/SSRVPN/actions/runs/34015736615) 全部成功。
于 2026-09-06 06:21:49 UTC 正式公开，Release ID `383485765`。

| 正式产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| SSRVPN.apk | 30,751,080 | `07edee827642886ac333546e7b466dbe321dd8419afded695c6b066380fc50ad` |
| SSRVPN.dmg | 27,397,912 | `c6928661472c9da0db3d3333935776297771397f035185f3acd4d64849c4bf21` |
| SSRVPN_Setup.exe | 31,144,148 | `6f3d1650ab90106aff0990ed86e13b5b039684b354cb84637df937c1c9148c5e` |

独立实际下载确认：GitHub latest、OSS latest 指针、三端固定及版本化文件、sidecar 和
GitHub API digest 全部一致；七项公开资产与统一 provenance 校验通过。
三份 GitHub Attestations 绑定 `release.yml`、`refs/tags/v4.0.31` 与精确源码。
Android 版本 4.0.31/4031 与原正式签名一致；macOS 镜像、代码签名与 4.0.31/4031
版本校验通过。PR、main、Release 的 Windows 安装、升级、卸载日志均独立确认成功。
符号单独归档，原有完整功能与优化构建保持。

本地四包静态检查通过，共享 996 项通过、覆盖率 87.55%；中文布局 196 项通过；
Android 真实首页组件 24 项、macOS 首页/启动 35 项、Windows 首页/启动 19 项通过。
隔离 Android 模拟器实际 Home 切后台两秒再恢复，已连接状态下五卡完整，九步生命周期
与本地 HTTPS 状态检查通过。未覆盖 USB 正式客户端或用户 VPN 会话，未冒充三端实机验收。

### 上一正式版本

`v4.0.30` 已正式发布：三端可信账号统计、首页无滚动自适应、设备数比例显示与原生
380×560 逻辑像素最小窗口限制同步上线。正式构建已注入可信提供方配置，真实授权账号
三轮 HTTPS 查询通过，原有本机采样口径保持不变。

功能与发版准备经 [PR #204](https://github.com/Elegying/SSRVPN/pull/204) 合并；发版前主分支
暴露的 Android 并发测试短等待竞态经 [PR #205](https://github.com/Elegying/SSRVPN/pull/205)
改为实际写入完成信号，产品代码不变。Windows 既有 TUN 时限用例一次失败后，在新 runner
以相同提交、相同生产时限复验通过，随后精确主分支和正式 Release 再次通过全部门禁。

发布源码：`efe6f1046c977b883752b8b496455a0c56caf8d1`。
[精确 main CI](https://github.com/Elegying/SSRVPN/actions/runs/34011501621)、
[Prepare Release](https://github.com/Elegying/SSRVPN/actions/runs/34011511934)、
[Release](https://github.com/Elegying/SSRVPN/actions/runs/34012175726) 全部成功。
GitHub 正式 Release 于 2026-09-06 04:54:44 UTC 公开；七项资产、provenance、三份
构建来源证明、OSS latest 指针与固定/版本化下载文件均已独立回读核验。

| 正式产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| Android APK | 30,750,136 | `138572c926707e58882e11ba6631e29975cebd5b5a0c1bb2e9cf0e6ba6d17239` |
| macOS DMG | 27,396,188 | `bab2f1c9ef4ad06ae8f89618c87b42c2314d2b17e638ded274e96dfaed24ef0d` |
| Windows EXE | 31,144,068 | `73eed60d769a2ccabe2cfb241b6100a08d26fba25c635be6948ffbd9d17e626a` |

Android 版本 4.0.30（4030）及原签名指纹通过核对；macOS DMG 校验、ad-hoc 签名和
版本通过核对，两端 AOT 产物中确认存在可信统计配置。Windows 正式安装、升级、卸载
日志通过核对。三端分离调试符号已下载归档。未把这些构建证据冒充 Windows 手动交互、
三端生产系统代理/TUN 与账号联调或面板账本独立对账；完整布局与平台边界见
[验收记录](ACCOUNT_USAGE_VALIDATION.md)。

## 上一正式版 v4.0.29

`v4.0.29` 已正式发布，三端首页同步显示上传速率、下载速率与本次累计流量。
卡片固定等宽等高，数值与单位分行；小屏、大字号、极端数值和前后台采样均通过回归。
三端分离 Dart 调试符号，macOS 与 Windows 提高安装容器无损压缩强度，保留核心、规则和运行功能。

受保护 [PR #202](https://github.com/Elegying/SSRVPN/pull/202)、精确主分支
[CI](https://github.com/Elegying/SSRVPN/actions/runs/33976690480)、
[Prepare Release](https://github.com/Elegying/SSRVPN/actions/runs/33976701467) 和
[Release](https://github.com/Elegying/SSRVPN/actions/runs/33977507611) 均成功。
发布提交为 `5a6518731150a763325640fca94af3712076143f`。本地完整 `make verify` 通过，
包含共享 765、Android 288、macOS 314、Windows 291 项通过测试，以及原生、覆盖率与发布工具门禁；
本地非 Windows 平台跳过的 7 项 Windows 专属测试由原生 CI 验证。

| 正式产物 | v4.0.28 字节数 | v4.0.29 字节数 | 减少 |
| --- | ---: | ---: | ---: |
| Android APK | 31,291,572 | 30,727,312 | 1.8% |
| macOS DMG | 30,946,657 | 27,393,856 | 11.5% |
| Windows EXE | 32,108,502 | 31,125,187 | 3.1% |

七项公开资产、SHA-256 与 provenance 校验通过；三端构建证明绑定同一标签，调试符号已单独下载归档。
GitHub 公开包与 OSS 固定下载逐一独立下载，摘要完全一致，OSS 最新指针为 4.0.29。
Android 正式包与上一版签名一致，16 KB 对齐通过；正式 DMG 重新挂载后签名、架构、布局及核心摘要通过；
Windows 正式安装包原始日志确认安装、覆盖升级、卸载事务全部成功。

固定布局 Android 测试 APK 已在 USB 真机覆盖安装并核对首页显示。本轮未新增正式安装包的完整三端
人工网络验收；自动化与结构终验不替代三端所有真实网络场景的人工验证。

## v4.0.28 发布结论

`v4.0.28` 已正式发布，包含多轮审查后的连接、订阅事务与实机问题修复。
失败提示明确区分原因与操作建议；Android 手动断开同步、macOS 有效代理确认、异常记录
分类和长文本显示均有回归验证。受保护 PR #200、精确 `main` CI、三端正式构建、发布审批、
七项公开资产和 OSS 通道终验均已完成；本地完整门禁各项通过，macOS 自动恢复测试已改为
跟随实际代理端口，并验证端口冲突后恢复成功。

本轮未新增正式安装包的完整三端人工实机验收；下文 `v4.0.27` 实机记录仅代表上一正式版。
macOS 本轮按维护者要求不执行断网测试，自动化构建与 smoke 不替代这些人工证据。

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

`v4.0.27` 修复与发布准备分别经受保护 PR #195、#198 合并。精确主分支 CI、Prepare Release、三端
正式构建、人工 `release` 环境审批、公开七项资产、资产摘要、统一 provenance、三份 GitHub
Attestation 与 OSS 公共更新通道均已独立复核。Windows 主客户端和外层启动器继续固定以管理
员身份运行；TUN、系统代理、DNS、用户规则优先级、国内应用旁路和未知公网流量代理兜底没有
被本版稳定性修复削弱。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## v4.0.28 历史验证证据

| 项目 | 当前结果 |
| --- | --- |
| 当前代码版本 | `4.0.28+4028` 正式版，三端 pubspec、共享常量与 CHANGELOG 一致 |
| 当前版本本地门禁 | 固定 Flutter 3.44.1 执行 `make verify`；修正 macOS 固定端口测试桩后，重跑完整桌面测试、原生测试、分析、格式和覆盖率，全部门禁逐项通过。Release tooling 396 项、shared 748 项、Android 287 项、macOS 314 项、Windows 291 项通过；7 项 Windows 主机专属用例由线上 runner 补齐 |
| 正式源码与标签 | 受保护 PR [#200](https://github.com/Elegying/SSRVPN/pull/200) 经九项必需检查后 squash 合并；正式源码提交 [`ea0b200`](https://github.com/Elegying/SSRVPN/commit/ea0b200e11c5a360e0073df78e6c465a7517f544)，注释标签 `v4.0.28` 精确解引用到同一提交，合并文件树与已验证 PR 一致 |
| 精确正式 `main` CI | [`33966155104`](https://github.com/Elegying/SSRVPN/actions/runs/33966155104) 成功；Workspace、Android、macOS、Windows、安全、安装器 smoke 与原生门禁全部通过 |
| 标签与正式构建 | [`Prepare Release 33966225633`](https://github.com/Elegying/SSRVPN/actions/runs/33966225633) 和 [`Release 33967015011`](https://github.com/Elegying/SSRVPN/actions/runs/33967015011) 均成功；正式 Windows 安装器安装与卸载退出码均为 0，smoke 明确通过 |
| 当前实机证据边界 | 本轮未新增正式安装包的完整三端人工验收；Android 17 断网与恢复证据仍属于 `v4.0.27`，macOS 本轮未执行断网测试 |
| 正式公开资产 | [`v4.0.28`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.28) 为不可变、非 draft、非 prerelease 的 latest，共七项资产；独立完整下载后 APK `d1e83a84…10ff5e`、DMG `4aa08eb3…3c4368`、EXE `6837e952…c7e38`，实际文件、sidecar、Release API digest、provenance 与三份 GitHub Attestations 一致；证明绑定本仓库 `release.yml`、精确标签与源码提交 |
| OSS 公共通道 | `latest.json` 已指向 `4.0.28`；三个版本化安装包均已独立完整下载，SHA-256 与 GitHub 实际文件及清单一致 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 最近一次综合评分（v4.0.27，历史基线）

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

- v4.0.28：本地完整门禁逐项通过，行覆盖率 shared 86.85%、Android 69.03%、macOS 68.90%、
  Windows 55.57%；macOS 系统代理关键文件 89.46%，Windows 生命周期关键文件 50.00%。
  受保护 PR、精确 main CI、三端正式构建、发布与公开渠道独立终验均成功。以下 v4.0.27
  数量与实机记录保留为历史证据。
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
