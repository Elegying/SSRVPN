# 项目健康状态

最近审查：2026-07-19<br>
当前应用基线：已发布的 `v3.4.6`（`bcac3d1`）<br>
本地加固分支：`fix/review-hardening-20260719`，尚未推送、创建 PR、应用 tag 或应用 Release。
`core-assets-v1` 是用于可复现构建的运维 prerelease，不是新的应用版本。

## 结论

SSRVPN 当前源码、三端边界、恢复模型和自动化门禁整体健康。本轮在不扩大产品范围的前提下
完成了以下修复：

- GeoIP 构建输入从会被上游每日 Release 回收的 Asset ID，迁移到 SSRVPN 自控的
  `core-assets-v1` 内容寻址镜像。普通 bootstrap 只接受固定支持 tag 下的精确资产路径，验证
  deterministic gzip 和解压后数据库两层 SHA-256，不会在构建时跟随上游 mutable `latest`。
- freshness 按“上游三重校验 → 缺失时无覆盖上传 → 公共 URL 双哈希回读 → PR”的顺序执行；
  认证 API 禁止重定向，公开回读只允许 GitHub HTTPS/CDN 主机并剥离凭据。同名上传竞态只能
  复用公开回读后完全匹配的内容，不能 clobber。
- `core-assets-v1` 已发布为非 latest 的 prerelease，其 tag 与应用 `v*` tag 同受 active
  ruleset 保护，禁止更新和删除且没有绕过主体。全新、无缓存的 detached worktree 已实际下载、
  安装并验证 Android、macOS、Windows 三端全部核心与 GeoIP 资产。
- macOS 遗留核心清理同时核验 PID、精确可执行路径和进程代际，并在 TERM/KILL 前重新确认
  所有权；查询超时、权限不足、信号失败、PID 文件损坏或 PID 复用均安全失败并保留证据。
  原生退出使用 Darwin 微秒级进程身份，PID 文件通过同目录原子隔离和内容复核清理，不会删除
  并发写入的新 PID。
- macOS 原生 RunnerTests 已接入本地 `make verify`、普通 CI 和正式 Release；覆盖延迟 TERM、
  强制退出、信号失败、PID 复用、PID 文件竞态和窗口/Dock 生命周期。
- LCOV 门禁不再信任可伪造的 `LF/LH` 汇总；任一 source 缺少有效 `DA`、重复 canonical、路径
  别名或未知 target 都会失败。除平台总门槛外，Windows/macOS 关键生命周期文件新增渐进下限。
- Android、macOS、Windows 的活动产品表面仍只包含首页和订阅，解锁测试没有重新出现；首页
  标题版本号继续来自共享版本常量。

Windows 安装数据保留与安装器单一分发决策不变：安装器固定使用每用户目录，只替换程序文件，
不搜索或合并桌面、下载目录及其他旧独立副本。因此多个旧数据源不会进入安装事务，保留安装版
订阅和设置不会重新引入旧的多来源安装失败。边界分别由
[ADR-002](decisions/002-windows-installed-data-preservation.md) 和
[ADR-003](decisions/003-windows-installer-only-distribution.md) 固定。

本轮没有修改 HTTP 订阅策略。Apple/Windows 付费签名也仍不属于项目目标；免费桌面分发缺少
受信任发布者身份是需要持续向用户说明的限制。

## 当前评分：93 / 100

| 维度 | 得分 | 当前证据 | 主要缺口 |
| --- | ---: | --- | --- |
| 正确性与恢复 | 19/20 | 连接代际、取消、核心恢复、系统代理事务、更新交接、安装门闩、TUN 所有权和 macOS 进程代际均有故障注入或结构守卫 | Android 快捷磁贴、粘性重启、通知与长连接耗电仍需真机长期观察 |
| 安全与信任边界 | 19/20 | 有界外部输入、统一脱敏、Keystore/DPAPI/私有文件、全历史密钥扫描、受保护分支/tag；GeoIP 与发布资产均有摘要链 | Release 管理员仍可删除支持资产；免费桌面包没有平台发布者身份 |
| 用户体验与状态可信度 | 18/20 | 三端收敛为两个主任务；连接取消、端口调整、恢复状态、诊断建议和更新失败均有明确反馈 | TalkBack、VoiceOver 和 Narrator 的完整实机流程仍需补充 |
| 可维护性与自动验证 | 19/20 | `make verify` 覆盖四套 Flutter、Android JUnit、macOS XCTest、覆盖率、性能、密钥、产品表面、结构与发布工具；复杂文件有体量或关键覆盖门禁 | Windows 生命周期关键文件覆盖仍低；Android 第三方插件兼容桥接仍待上游消除 |
| 发布与文档 | 18/20 | 当前行为、五份 ADR、变更日志、核心资产说明和仓库门禁一致；Windows 只接受安装器；全新 worktree 可重建资产 | 本地分支尚未经过受保护 PR 的线上 CI；本轮没有目标 Windows 设备执行证据 |

分数只代表当前仓库及已有真机报告中的可复核证据，不代表应用商店审核、第三方渗透测试或
所有网络环境。源码测试不能替代目标系统真机证据。

## 当前验证证据

2026-07-19 在 macOS 主机执行完整本地门禁：

```bash
make verify
```

结果：

- workspace analyze：零问题；版本同步为 `3.4.6+346`；
- shared：282 项通过，覆盖率 `75.28%`（`3094/4110`，门槛 `65%`）；
- Android Flutter：123 项通过，Gradle/JUnit 构建成功，覆盖率 `64.78%`
  （`894/1380`，门槛 `50%`）；
- macOS Flutter：87 项通过，覆盖率 `50.54%`（`702/1389`，门槛 `30%`）；
- macOS RunnerTests：18 项通过；生命周期关键文件 `71/418`（`16.99%`，门槛
  `16.98%`），系统代理关键文件 `30/169`（`17.75%`）；
- Windows：127 项通过、7 项按平台明确跳过，覆盖率 `48.08%`
  （`1092/2271`，门槛 `30%`）；生命周期关键文件 `21/501`（`4.19%`）；
- 发布工具：148 项通过；文档 28 份、密钥、核心资产、产品表面、性能和结构守卫全部通过。

另在无缓存 detached worktree 执行 `scripts/bootstrap-core-assets.sh`，真实下载并验证 Android
`libgojni.so`、macOS `AtlasCore.gz`、Windows `mihomo.exe` 与三端 GeoIP；命令以 0 退出，临时
worktree 随后移除。当前 GeoIP 镜像 gzip SHA-256 为
`073889534886f211285398d5622922e540e3fb052d18e649e07351dc73323c9a`，解压后 SHA-256 为
`7cf5ed69574a73021735c6cba9891509aaa205dd3854db049571664b476df1f4`。

Windows Explorer/`kernel32`、PowerShell 5.1、DPAPI、Mihomo 和真实网络 cmdlet 测试在 macOS
上明确跳过；此前 Windows 11 UAT 仍是当前可接受的实机基线。只有后续改动触达对应边界或
准备正式发布时，才需要按风险重跑相关 Windows 烟雾测试。

## 代码整洁度与已知残余

- 活动 Dart 源码中不存在解锁测试的类、服务、路由或文案；三端导航由守卫精确限制为两项。
- 未发现循环依赖、重复实现扩散、隐藏全局状态链或无人调用的兼容门面。共享领域逻辑集中在
  `ssrvpn_shared`，平台层承载系统集成，调用方向清晰。
- 高认知复杂度主要位于 Windows 子进程/代理/安装恢复、Android VPN 启动编排和仓库一致性
  校验。它们具有职责边界、超时/回滚语义、体量上限或回归测试，不属于无边界耦合的“屎山”；
  后续修改仍应先加目标回归，再小步提取职责。
- macOS Dart 使用 `ps lstart` 表示遗留进程代际，精度为秒；同一 PID 在同一秒内复用且命令
  完全相同理论上无法区分。应用原生退出路径使用 Darwin 微秒级身份，不受此限制。
- Android 应用模块已使用 AGP 9 内置 Kotlin。当前 Gradle 警告来自 Flutter included build
  请求 Kotlin `2.2.20`，而 Gradle `kotlin-dsl` 内嵌 `2.2.0`；把显式版本改为 `2.2.0` 的隔离
  实验没有消除警告，因此没有提交无收益的降级。第三方插件迁移完成前继续保留逐模块兼容桥接，
  并在 Flutter/插件支持后于 AGP 10 前移除已弃用开关。
- 当前本地代码与门禁没有已确认的 P0-P2；这不等于未来不会产生缺陷，也不替代线上 CI 与目标
  平台验收。

## 平台状态

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| Shared | 健康 | 订阅、配置、更新、脱敏、桌面控制器、窗口状态和启动日志公共逻辑集中维护；已删除解锁检测服务 |
| Android | 健康，建议观察真机耗电 | VPN Service、快捷磁贴、通知和恢复共用会话代际与启动租约；第三方插件的 AGP 兼容开关仍待上游消除 |
| macOS | 本机 Flutter/XCTest 健康，免费分发信任受限 | 核心退出、PID 复用、系统代理与 TUN 恢复边界有测试；公开包保持 ad-hoc、未公证并提供 SHA256 |
| Windows | 代码、自动化与现有 UAT 基线健康 | 只发布安装器；固定安装数据与其他来源隔离；代理、guardian、RunOnce、安装门闩、TUN 清理和更新交接均有回归 |

## 下一步门槛

1. 用户决定同步时，推送当前分支并通过受保护 PR 的全部必需 CI；不绕过主分支保护，也不把本地
   macOS 结果冒充 Windows CI。
2. 以后有 Android 真机时观察快捷磁贴、系统回收后粘性重启、通知断开和长时间连接耗电。
3. 用 TalkBack、VoiceOver 和 Narrator 验证首页连接、订阅导入、诊断恢复和动态状态播报。
4. 后续触达 Windows 生命周期或 Android 原生高复杂度区时，先增加目标平台回归，再小步提取；
   Windows 生命周期覆盖应随每次行为改动继续抬升，不为百分比编写无断言测试。
5. Flutter 与第三方插件完成 AGP 9 内置 Kotlin 迁移后，删除逐模块兼容开关并重新跑 APK、JUnit
   和完整 CI。

## 更新规则

每次更新只记录已验证事实：版本、提交、命令、平台、产物和残余风险。历史审查保留作证据，
但不得覆盖本文件、[安全策略](../SECURITY.md)、[测试策略](TESTING.md) 与
[文档索引](README.md) 的当前结论。
