# Windows 正式版 20 轮审查记录（2026-07-15）

审查目标：在不购买 Apple/Windows 证书的固定约束下，证明 Windows 安装、连接、
断开和异常恢复达到可发布标准。每一轮必须记录范围、证据、结论和修复；“未发现”只有在
对应调用链、测试和失败路径均被检查后才成立。

## 证据等级

- **L1 静态**：源码、配置或结构守卫。
- **L2 可执行**：单元、集成、打包或故障注入测试。
- **L3 目标系统自动化**：GitHub Windows runner 上的原生构建与运行。
- **L4 人工真机**：Windows 11 用户交互、任务管理器、重启和隔夜验证；本轮明确保留。

## 常规审查

| 轮次 | 方向 | 证据 | 结论/修复 | 状态 |
| --- | --- | --- | --- | --- |
| N1 | 安装流程与每用户权限 | L1 `test_windows_installer_config.py`；L2 `test_windows_installer_runtime.ps1`；L3 Windows job `87180433029` | 修复直接卸载不恢复代理/不停止主程序；停止器只处理固定安装路径，安装仍固定 `%LOCALAPPDATA%` 且无提权 | L3 关闭 |
| N2 | 连接状态机与并发 | L1 调用链复核；L2 `ConnectionIntentTracker` 与 Windows Flutter 65 项 | 启动/停止串行，代际令牌使用户断开可取消排队恢复；未发现未保护的第二启动路径 | 关闭 |
| N3 | 断开、退出与代理恢复 | L1 Dart/launcher/installer 三层恢复链；L2 代理恢复测试 | 修复恢复前未持久化 `RestoreInProgress` 的断电窗口；始终先恢复代理再结束核心 | 关闭 |
| N4 | Mihomo 进程生命周期 | L1 launcher Job Object 与生命周期调用链；L2 `CoreRecoveryPolicy` | 收口主程序后代；异常退出先恢复代理，仅按仍有效的连接意图恢复一次并通知结果 | 关闭 |
| N5 | 编码、本地化与 PS5.1 | L1 ASCII/显式编码/BOM/`/utf-8` 守卫；L2 UTF-8 与 PS5.1 测试；L3 真实 PS5.1 | 修复 PowerShell 非终止错误假成功、Mihomo 非法 UTF-8 导致流中断；安装器完整中文化 | L3 关闭 |
| N6 | 文件、密钥、权限与路径 | L1 DPAPI、原子替换、链接拒绝复核；L2安全存储测试 | 设置 JSON 不含 API secret；写入位于用户目录；目标链接、跨卷/替换失败均拒绝或回滚 | 关闭 |
| N7 | 订阅与网络输入边界 | L1 下载器边界复核；L2 shared 291 项 | HTTPS 降级、跳转、头/正文/解压大小、绝对/无活动超时均有界；正文损坏 UTF-8 明确失败 | 关闭 |
| N8 | 托盘、状态、诊断与更新 | L1 UI 状态链；L2 Widget/静态回归 | 修复托盘未显示真实代理端口；端口调整、核心恢复和最终失败都有可见中文通知 | 关闭 |
| N9 | CI、打包、发布与供应链 | L1 固定 action/Gitleaks/发布顺序；L2 发布工具 69 项；L3 安装日志资产 `8322229205` | Windows CI 新增有界的真实安装/卸载并始终留存日志；Gitleaks 升至 Node 24；GitHub Draft、OSS 不可变目录、备份推广与失败补偿保持完整 | L3 关闭 |
| N10 | 维护性、性能、可观测性与文档 | L1 知识图谱 3955 节点/10742 边、热点复杂度复核；L2 性能冒烟 | 未发现新的无界热循环；保留关键恢复代码的集中事务，新增审查记录和正式版检查清单 | 关闭 |

## 对抗审查

| 轮次 | 攻击/故障模型 | 证据 | 结论/修复 | 状态 |
| --- | --- | --- | --- | --- |
| A1 | PS5.1 与敌对代码页 | L1 禁止非 ASCII 脚本和不兼容 `Split-Path`；L2 PS5.1 round-trip；L3 真实 PS5.1 | 所有嵌入命令先设 `ErrorActionPreference=Stop` 和 UTF-8；JSON `-Raw` 必须显式编码 | L3 关闭 |
| A2 | 锁文件、杀软延迟、半安装、Unicode 路径 | L2 同名多副本故障注入；L3 package smoke | 修复误杀便携同名程序；锁未释放时在 `[InstallDelete]` 前失败，不再用 `restartreplace` | L3 关闭 |
| A3 | 快速连接/断开/重连/退出竞态 | L2 连接代际与恢复策略测试 | 旧恢复意图不能覆盖用户断开或新连接；停止会取消未完成启动并等待清理 | 关闭 |
| A4 | 强杀核心/主程序/launcher 与断电近似 | L1 三层恢复状态机；L2 恢复顺序/单次重试测试 | 修复恢复中断不可续问题；launcher 在清后代前恢复网络，核心仅恢复一次 | 关闭 |
| A5 | 伪造/陈旧恢复日志与外部代理修改 | L1 字段/类型/端点/旁路精确校验；L2 恶意状态测试 | 无效日志不再被信任；仅完整 SSRVPN 指纹会被紧急禁用，外部代理变更不覆盖 | 关闭 |
| A6 | 恶意、超大、压缩、跳转、慢订阅 | L2 大小、chunk、压缩、跳转、停滞、UTF-8 用例 | 拒绝 20 MiB 以上解压正文、超大头、截断 chunk、HTTPS 降级和慢滴流 | 关闭 |
| A7 | 端口冲突、慢核心、API 鉴权失败 | L2 端口避让/鉴权健康检查/15 秒截止 | 实际端口贯穿配置、首页和托盘；API 必须带 secret 且健康后才提交已连接 | 关闭 |
| A8 | 只读、符号链接、路径替换、权限拒绝 | L1 每用户目录和 reparse-point 拒绝；L2 原子写失败回滚 | DPAPI 目标链接与不安全替换失败关闭；安装器不写 `Program Files` | 关闭 |
| A9 | GitHub/OSS 双通道分裂与损坏产物 | L2 manifest/provenance/推广回滚测试 | 非原子双通道以“OSS 备份推广→GitHub 确认→明确失败回滚/歧义保留证据”降低风险 | 关闭（残余风险已记录） |
| A10 | 干净机、运行库缺失、未签名提示、日志与回滚 | L1 VC runtime 打包、SHA256、免费分发守卫；L3 clean runner | 不购买证书边界已统一；CI 验证干净 runner 安装/启动/卸载，用户文档保留 SmartScreen 说明与 `v3.3.5` 回滚 | L3 关闭，L4 待办 |

## 本轮确认并修复的缺陷

1. **P1**：直接运行卸载器时没有执行代理恢复和进程停止，可能留下死代理或被占用文件。
2. **P1**：恢复原始代理的第一条注册表写入前没有设置可恢复标记，断电可能留下半恢复状态。
3. **P1**：安装清理按进程名处理同会话程序，可能误杀其他目录的同名便携副本。
4. **P1**：PowerShell 默认继续执行非终止错误，恢复命令可能返回假成功。
5. **P2**：损坏恢复日志缺少严格类型、端点和旁路指纹校验。
6. **P2**：Windows Mihomo 输出包含非法 UTF-8 时日志流可能异常结束。
7. **P2**：托盘只显示“已连接”，没有给出实际自动调整后的 HTTP 端口。
8. **P1（发布阻断）**：Inno Setup 6.7.1 的 `ISCC.exe` 文件版本资源为 `0.0.0.0`，按 PE 元数据检查最低版本会误拒绝可用编译器；现改为编译无产物最小脚本并解析真实引擎版本。
9. **P1（发布可靠性）**：Windows PowerShell 的 `Start-Process -Wait` 会等待安装器启动的 SSRVPN 后代进程，导致真实安装冒烟永不返回；现只等待目标进程，安装/卸载各限 120 秒，完整步骤限 15 分钟并始终上传日志。
10. **P2（供应链）**：Gitleaks Action v2 依赖已弃用的 Node 20；CI 与 Release 已固定到行为兼容的 v3.0.0/Node 24 提交。

以上问题均有回归守卫；本地审查结束时无未解决 P0-P2。

## 最终五轴差异复核

| 轴 | 复核结果 |
| --- | --- |
| 正确性 | 安装删除发生在精确进程清理成功之后；连接提交要求 authenticated API 健康；断开、退出和核心丢失都先恢复网络。未发现新的 P0-P2。 |
| 安全 | 恢复日志按字段、类型、端点和完整指纹验证；外部代理修改不会被强制覆盖；订阅、日志、更新和 secret 边界保持有界。 |
| 兼容性 | PowerShell 5.1 参数集、ASCII 源、UTF-8 输入输出、Inno Unicode 和 MSVC `/utf-8` 均有守卫；Inno 最低版本取自真实编译引擎而不是不可靠的 PE 版本资源。Inno 官方说明 Restart Manager 只检查 `[Files]`/`[InstallDelete]` 中要更新的资源，因此不会仅因同名关闭其他目录的便携副本。 |
| 用户体验 | 中文安装与删除提示、锁文件可恢复提示、托盘真实端口、核心恢复过程/结果和诊断入口均可见；没有把错误状态显示为已连接。 |
| 发布与维护 | `make verify`、actionlint、shellcheck 和 20 轮矩阵通过；关键恢复事务虽复杂但职责明确且有故障注入，发布前不做高风险无行为收益重写。 |

参考：[Inno Setup CloseApplications](https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm)、
[CloseApplicationsFilter](https://jrsoftware.org/ishelp/topic_setup_closeapplicationsfilter.htm)、
[Installation Order](https://jrsoftware.org/ishelp/topic_installorder.htm)、
[PowerShell 5.1 Start-Process](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1)、
[Gitleaks Action v3.0.0](https://github.com/gitleaks/gitleaks-action/releases/tag/v3.0.0)。

## 发布结论

20 轮本地审查已关闭。共享 291 项、Android 100 项、macOS 73 项、Windows 65 项、发布
工具 69 项和 Android 原生 JUnit 均通过；覆盖率为 shared 73.86%、Android 58.55%、
macOS 47.07%、Windows 40.22%，高于 65/50/30/30 门槛。本机到 Maven Central 返回 403，
Android 原生测试仅在验证命令中临时改用镜像，仓库源配置未改变。

线上 L3 已由 [CI `29360803602`](https://github.com/Elegying/SSRVPN/actions/runs/29360803602)
关闭：Windows job `87180433029` 使用 PowerShell 5.1，通过 Inno Setup 6.7.1 编译，随后在
`%LOCALAPPDATA%\Programs\SSRVPN` 安装并启动客户端；安装器 12.9 秒返回 0，直接卸载器
2.5 秒返回 0，日志资产为 `8322229205`，安装目录中的两个可执行文件均被删除。
正式 Release 会在 tag 上复跑同一门禁。L4 Windows 11 交互安装、连接、断开、重启与
隔夜验证仍是明确缺口，不能由 CI 替代。
