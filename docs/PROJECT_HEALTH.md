# 项目健康状态

最近审查：2026-07-20<br>
当前应用版本：`v3.4.7`；公开发布状态与产物以 GitHub Release 为准。<br>
`core-assets-v1` 是用于可复现构建的运维 prerelease，不是新的应用版本。

## 结论

SSRVPN 当前源码、三端边界、恢复模型和自动化门禁整体健康。本轮在不扩大产品范围的前提下
完成了以下修复：

- 订阅新增、刷新、更新、删除和缓存提交统一进入有界且可取消的事务；队列等待也计入绝对截止
  时间，取消或旧代次不能在稍后覆盖新状态。大体量 YAML 解析、合并与配置生成移出 UI isolate，
  小输入路径和字节级输出保持不变。
- Android 与桌面节点测速使用批次代次隔离，过期同名节点结果不能污染新订阅；更新检查不再依赖
  VPN 连接成功，崩溃报告复制后只有显式删除才会移除。启动阶段不再在临时应用树展示崩溃弹窗，
  所有应用模态框由同一协调器串行展示。
- macOS TUN 授权取消会等待并收口迟到的授权进程；核心状态 watcher、退出与代理恢复保持严格顺序。
  Windows PowerShell 取消只有在原进程确认退出后才允许后续代理事务，系统代理恢复按
  `ACTIVATION`、`FULL_RESTORE`、`ENDPOINT_RESTORE` 原生阶段恢复并保留未完成证据；同进程事务队列
  与跨进程文件锁共同防止重入。
- Windows launcher 只接管当前应用直接启动、路径/会话/创建时间都匹配的 `mihomo.exe`，持有句柄
  复核后才加入 kill-on-close Job Object；退出前先恢复网络，再终止并等待进程确认退出。

- GeoIP 构建输入从会被上游每日 Release 回收的 Asset ID，迁移到 SSRVPN 自控的
  `core-assets-v1` 内容寻址镜像。普通 bootstrap 只接受固定支持 tag 下的精确资产路径，验证
  deterministic gzip 和解压后数据库两层 SHA-256，不会在构建时跟随上游 mutable `latest`。
- freshness 按“上游三重校验 → 缺失时无覆盖上传 → 公共 URL 双哈希回读 → PR”的顺序执行；
  认证 API 禁止重定向，公开回读只允许 GitHub HTTPS/CDN 主机并剥离凭据。同名上传竞态只能
  复用公开回读后完全匹配的内容，不能 clobber。
- `core-assets-v1` 已发布为非 latest 的 prerelease，其 tag 与应用 `v*` tag 同受 active
  ruleset 保护，禁止更新和删除且没有绕过主体。全新、无缓存的 detached worktree 已实际下载、
  安装并验证 Android、macOS、Windows 三端全部核心与 GeoIP 资产。
- macOS 在 Flutter engine 之前获取每用户 `flock` 单实例租约，第二实例只能请求显示现有窗口并
  退出，且无权执行代理、TUN 或核心清理。核心以 canonical v2 文件持久化
  `PID + Darwin 启动秒/微秒`，身份使用“代际 → 路径 → 代际”双采样并在 TERM/KILL 前复核。
- 非 TUN 核心的 spawn、身份双采样和 v2 记录发布由一个原生串行操作完成；原生持续持有直系
  子进程句柄并有界排空 stdout/stderr。身份采样、记录发布或 PID 文件证据失败时仍能只收口
  该直系子进程。PID 记录以 `RENAME_EXCL` 原子发布；半写失败按 inode 回滚。读取限制为
  no-follow/non-blocking 的 128 字节普通文件，删除
  使用原子隔离与整条记录 CAS；同 PID 新代际、并发写入、符号链接/FIFO、损坏/超大记录、查询
  或信号失败均安全保留。仍存活的旧数字 PID 因缺少代际证据不会被猜测终止。
- macOS 发现待恢复代理时保持旧核心、PID 记录和资产不动；代理恢复成功后才按“清理旧代际 →
  安装核心/GeoIP → 探测”继续。正常断开也使用原生完整记录终止，不再由 Dart `Process.kill`
  发送 PID-only 信号。
- macOS launch/status/terminate/remove 操作统一进入原生串行队列；Cmd+Q 会先排空原生核心操作。
  系统代理 set/clear 全事务持有原生令牌，活跃令牌会让退出延迟到全部快照与 `networksetup` 命令
  完成；若令牌遗失，超时只会安全取消本次退出，绝不在事务中途强退。快照必须先通过完整 schema
  校验，至少包含一个服务；精确元数据键不会吞掉 `_Wi-Fi`
  等合法名称，撞到保留键的服务会在代理接管前被拒绝。无所有权证明、畸形内容或不安全路径
  都会保留并阻止核心清理。
- macOS 原生 RunnerTests 已接入本地 `make verify`、普通 CI 和正式 Release；测试覆盖单实例、
  原生 spawn/记录原子边界、直接子进程收口、原子发布回滚、身份双采样、退出令牌与安全超时取消、
  延迟 TERM、强制退出、信号失败、PID 文件竞态、流式 UTF-8 诊断、严格代理快照和窗口/Dock 生命周期。
- LCOV 门禁以可审计生产源码清单为分母；`DA` 只接受 canonical ASCII 十进制，非法 UTF-8、
  缺失源码、伪造/越界 `SF`、汇总错配、路径别名或未知 target 都会失败。macOS/Windows 实际
  拥有的 16 个 shared desktop `part` 分别进入消费平台分母；四端总门槛和关键生命周期渐进
  下限均已在真实完整测试套件上通过。
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
| 发布与文档 | 18/20 | 当前行为、六份 ADR、变更日志、核心资产说明和仓库门禁一致；Windows 只接受安装器；全新 worktree 可重建资产 | 本版本仍须以受保护 PR、三端 CI、Release 资产与公开下载复验作为最终发布证据；本轮没有新的 Windows 11 人工验收 |

分数只代表当前仓库及已有真机报告中的可复核证据，不代表应用商店审核、第三方渗透测试或
所有网络环境。源码测试不能替代目标系统真机证据。

## 当前验证证据

2026-07-20 在 macOS 主机执行完整本地门禁：

```bash
make verify
```

结果：

- workspace analyze：零问题；版本同步为 `3.4.7+347`；
- shared：351 项通过，覆盖率 `77.98%`（`3576/4586`，门槛 `65%`）；
- Android Flutter：172 项通过，Gradle/JUnit 构建成功，覆盖率 `45.31%`
  （`2028/4476`，门槛 `30%`）；
- macOS Flutter：141 项通过，覆盖率 `58.76%`（`3188/5425`，门槛 `30%`）；
- macOS RunnerTests 通过；生命周期关键文件 `308/485`（`63.51%`，门槛
  `60.00%`），系统代理关键文件 `220/258`（`85.27%`，门槛 `80.00%`）；
- Windows：147 项通过、7 项按平台明确跳过，覆盖率 `49.57%`
  （`3078/6209`，门槛 `30%`）；生命周期关键文件 `24/525`（`4.57%`，门槛 `4.19%`）；
- 发布工具：190 项通过；文档、密钥、核心资产、产品表面、性能和结构守卫全部通过。
- 两轮 fresh-context 终审均为 `Critical 0 / Required 0 / Recommended 0`；`git diff --check`
  通过，测试后无新增 `xcodebuild`、Runner、XCTest、AtlasCore 或 `flutter_tester` 残留进程。

另在无缓存 detached worktree 执行 `scripts/bootstrap-core-assets.sh`，真实下载并验证 Android
`libgojni.so`、macOS `AtlasCore.gz`、Windows `mihomo.exe` 与三端 GeoIP；命令以 0 退出，临时
worktree 随后移除。当前 GeoIP 镜像 gzip SHA-256 为
`073889534886f211285398d5622922e540e3fb052d18e649e07351dc73323c9a`，解压后 SHA-256 为
`7cf5ed69574a73021735c6cba9891509aaa205dd3854db049571664b476df1f4`。

Windows Explorer/`kernel32`、PowerShell 5.1、DPAPI、Mihomo 和真实网络 cmdlet 测试在 macOS
上明确跳过；此前 Windows 11 UAT 仍是当前可接受的人工实机基线。用户已明确结束本阶段 Windows
人工测试并授权发版；本版本新增代码以受保护 PR 的 Windows runner 原生编译、PowerShell 5.1、
故障注入、安装与卸载烟雾作为发布门禁，但这些自动证据仍不冒充新的 Windows 11 人工验收。

## 代码整洁度与已知残余

- 活动 Dart 源码中不存在解锁测试的类、服务、路由或文案；三端导航由守卫精确限制为两项。
- 未发现循环依赖、重复实现扩散、隐藏全局状态链或无人调用的兼容门面。共享领域逻辑集中在
  `ssrvpn_shared`，平台层承载系统集成，调用方向清晰。
- 覆盖率分母现在包含全部可审计生产库和桌面跨包 owned parts；新增测试执行真实启动诊断、
  首页节点与连接、订阅组件、节点编辑和输入校验，不使用无断言导入或删除生产分支换取百分比。
- 高认知复杂度主要位于 Windows 子进程/代理/安装恢复、Android VPN 启动编排和仓库一致性
  校验。它们具有职责边界、超时/回滚语义、体量上限或回归测试，不属于无边界耦合的“屎山”；
  后续修改仍应先加目标回归，再小步提取职责。
- macOS 已持久化 Darwin 微秒级代际，解决清理开始前已发生的 PID 复用和同 PID 文件 ABA。
  macOS 没有公开的 pidfd 等价接口，身份复核与按 PID 发信号仍不是同一个原子系统调用；实现
  在每次 TERM/KILL 前即时复核，并在任何不确定状态下拒绝重新启动，这是当前系统能力下的
  明确残余边界。
- Android 应用模块已使用 AGP 9 内置 Kotlin。当前 Gradle 版本提示来自 Flutter included build
  请求 Kotlin `2.2.20`，而 Flutter/AGP 默认的 Gradle `9.1.0` 内嵌 `2.2.0`；升级 Gradle 9.2
  只能消除这一条提示，不能消除 Flutter 3.44 为未迁移插件保留的兼容桥警告，因此本轮不为降噪
  扩大工具链变化。第三方插件迁移完成前继续保留逐模块兼容桥接，并在后续 Flutter/插件支持后
  于 AGP 10 前移除已弃用开关。
- 当前本地代码与门禁没有已确认的 P0-P2；这不等于未来不会产生缺陷，也不替代线上 CI 与目标
  平台验收。

## 平台状态

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| Shared | 健康 | 订阅、配置、更新、脱敏、桌面控制器、窗口状态和启动日志公共逻辑集中维护；已删除解锁检测服务 |
| Android | 健康，建议观察真机耗电 | VPN Service、快捷磁贴、通知和恢复共用会话代际与启动租约；第三方插件的 AGP 兼容开关仍待上游消除 |
| macOS | 本机 Flutter/XCTest 健康，免费分发信任受限 | GUI 单实例、原生原子启动、退出令牌、核心 PID 复用、严格代理快照与 TUN 边界有测试；公开包保持 ad-hoc、未公证并提供 SHA256 |
| Windows | 代码、自动化与现有 UAT 基线健康 | 只发布安装器；固定安装数据与其他来源隔离；代理、guardian、RunOnce、安装门闩、TUN 清理和更新交接均有回归 |

## 下一步门槛

1. 每次发布都必须通过受保护 PR 的全部必需 CI，再从合并后的 `main` 创建不可改写 tag；不绕过
   主分支保护，也不把本地 macOS 结果冒充 Windows CI。
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
