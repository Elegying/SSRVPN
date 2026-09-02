# SSRVPN 项目健康与发布状态

最近更新：2026-09-02

当前应用版本：`v4.0.22`

最新正式版本：[`v4.0.21`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.21)

## 当前结论

`v4.0.22` 是当前待发布版本：在 v4.0.21 Telegram 修复基础上，将三端“智能”模式升级为
用户规则优先、海外服务代理、国内企业域名/ASN 直连、GFW/CN/GeoIP 兜底和未知流量默认代理
的统一分层。六份带版本与 SHA-256 清单的规则随包内置，远程刷新失败不阻断连接；Android
普通用户应用全部进入 TUN，使手动强制代理不再被应用级旁路绕过。

Android v4.0.20 实机日志确认 Telegram 三处数据中心地址被旧规则判为 `DIRECT` 后超时，
同一节点经代理访问全部成功；因此根因是分流遗漏，不是节点不可用。正式 v4.0.21 APK
发布后手机已断开 USB，未把未执行的正式 APK 原地升级和 Telegram 复验冒充实机通过。

当前候选已在固定 Flutter 3.44.1 工具链通过完整 `make verify`，覆盖共享规则、三端 Flutter、
Android 原生构建、macOS 原生测试和内置 Mihomo 配置校验；受保护 PR、精确主分支 CI、
正式三端构建、标签、公开资产与 OSS 公共通道仍需完成后才能将 v4.0.22 标记为正式发布。
最新已完成全部发布终验的版本仍是 v4.0.21。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 当前版本与最近正式发布证据

| 项目 | 当前结果 |
| --- | --- |
| 当前代码版本 | `4.0.22+4022`，三端 pubspec、共享常量、CHANGELOG 一致；正式资产尚待线上构建 |
| 当前版本本地门禁 | `mise exec flutter@3.44.1 -- make verify` 全部通过：Release tooling 396 项、Shared 658 项（85.68%）、macOS 284 项（67.28%）、Windows 273 项（54.80%），并包含 Android Flutter/原生构建、规则清单离线校验与 macOS 内置 Mihomo 配置加载；8 项 Windows 主机专属用例按设计留给线上 CI |
| 正式源码与标签 | 受保护 `main` 提交 [`5954b86`](https://github.com/Elegying/SSRVPN/commit/5954b863403c27dfd8ac640fbc7835e10f07ec73)；带注释标签 `v4.0.21` 精确解引用到该提交 |
| 精确正式 `main` CI | [`33613958571`](https://github.com/Elegying/SSRVPN/actions/runs/33613958571) 成功；工作区、Android、macOS、Windows、安全与原生门禁全部通过 |
| 标签与正式构建 | [`Prepare Release 33615546792`](https://github.com/Elegying/SSRVPN/actions/runs/33615546792) 和 [`Release 33615580444`](https://github.com/Elegying/SSRVPN/actions/runs/33615580444) 均成功 |
| Android 实机 | v4.0.20 旧规则根因与同节点代理可达性已实机确认；v4.0.21 正式 APK 发布后手机断开 USB，正式包原地升级与 Telegram 复验保持未执行 |
| 正式公开资产 | [`v4.0.21`](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.21) 共七项资产；APK `7f477620…2cd4`、DMG `b6881b9c…aa77`、EXE `dbb21f27…6af6`，摘要与 provenance 一致 |
| OSS 公共通道 | `latest.json` 已指向 `4.0.21`；Release 发布后步骤已逐项验证 GitHub 与 OSS 公共通道 |

发布流程在三平台产物和 shared 测试全部成功后才获准进入 `release` 环境；
Draft Release、不可变 OSS 目录、公共通道提升和 GitHub Release 最终发布按事务顺序完成。

## 最近正式版本质量评分（v4.0.21）

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 19/20 | Android 旧故障机完成 20 轮正常循环、10 轮快速取消和 Doze；Windows 清理修复通过真实安装器在线 smoke |
| 安全、隐私与供应链 | 19/20 | 订阅和更新输入有界，日志与诊断脱敏，进程和系统设置按所有权处理，正式资产可校验来源 |
| 架构与可维护性 | 18/20 | 以描述符证据和现有清理助手完成局部修复，没有放宽所有权边界或引入新依赖 |
| 测试与 CI | 19/20 | 九项受保护检查、完整三端门禁、候选构建和 Android 真实故障机回归通过；仍缺部分硬件矩阵 |
| 发布工程 | 12/12 | 精确标签、三端正式构建、七项公开资产、摘要、provenance、attestation 和 OSS 公共通道均已终验 |
| 文档与治理 | 8/8 | README、用户指南、安全策略、ADR、UAT、维护手册与正式发布证据齐全 |
| **综合** | **95/100** | **达到成熟正式发布状态；剩余缺口是扩大设备与人工场景证据，不阻断当前补丁版本** |

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

1. 在可可靠记录独立单击的 MIUI 环境中补做快捷磁贴 20 轮连接/断开，证明 UI、Service、TUN 和最终状态始终一致。
2. 在原生 16 KiB page-size Android 设备上完成安装、连接、真实数据路径、断开和覆盖升级，补齐结构检查无法替代的硬件证据。
3. 扩展 Android 真机矩阵：补做蜂窝/Wi-Fi 切换、第二 VPN 竞争、至少一种其他 OEM 后台策略，并建立同机同口径空闲电量基线。
4. 在普通 Windows 桌面会话补做修复后 UAT，重点保留 UAC 取消、托盘正常退出和可信更新安装器清理的可复核证据。
5. 在 macOS 补做持续离线后的取消与网络恢复专项；如需更早发现现场问题，可在不上传用户流量内容的前提下建立可选本地诊断趋势基线。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
