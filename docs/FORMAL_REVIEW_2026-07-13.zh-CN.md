# SSRVPN 三端正式版本五轮深审与五轮对抗审查

审查日期：2026-07-13

审查分支：`codex/ssrvpn-formal-review`

代码修复提交：`cd019b4`

审查基线：`v3.1.1` (`aac2cce`)

审查范围：Android、macOS、Windows、共享 Dart 包、安装与发布自动化。按用户
要求，本次只做代码、静态分析、单元/组件/原生单测和 CI 构建审查，不把手机、
Windows 或 macOS 的人工操作与实机回归列为完成条件。

## 当前结论

五轮深度审查与五轮对抗审查已经完成。本轮新增确认并修复 3 类代码缺陷，
每项均先由失败回归测试证明，再实施最小修复。修复后本地全量门禁通过；没有
遗留已知的 P0、P1 或 P2 代码缺陷。

用户明确禁止修改的“私家车”延迟显示逻辑保持不变，相关结构守卫及三项策略
测试均通过。

## 五轮深度审查

| 轮次 | 审查方向 | 主要证据与结论 |
|---|---|---|
| 1 | 正确性、进程与连接生命周期 | 追踪桌面核心 start/stop、超时、取消、输出收集，Android start generation、重复操作合并和强制回收；发现正常退出进程的后代若继承输出管道，命令执行器会继续等待，已限时收尾并补回归。 |
| 2 | 架构边界与可维护性 | 检查进程生命周期、系统代理、配置生成、桌面运行时拆分及 Mac/Windows 重复边界；核心职责守卫通过。剩余大文件主要是 UI 组合和 Windows 打包脚本，不在正式版本前做无行为收益的大重构。 |
| 3 | 配置、订阅、路由与解锁探针 | 检查 YAML/URI 注入、字段上限、压缩膨胀、HTTPS 降级、事务回滚、Android 公网路由及解锁证据；发现持久化的非法 `tunStack` 可逃逸 YAML 行，现只接受 `gvisor/system/mixed`。解锁不确定时仍回退“无法判断”。 |
| 4 | 更新、安装、系统代理与供应链 | 检查 OSS 优先/GitHub 回退、SHA-256、大小限制、下载取消、APK 身份、Windows 自有进程识别、代理所有权日志、Release 来源和 OSS 恢复；未发现新的确定性缺陷。 |
| 5 | 性能、资源释放与长期维护 | 检查通知限频、熄屏暂停、HTTP client/stream 关闭、定时器、日志内存/磁盘上限和启动日志；发现 UTF-8 多字节截断会突破声明的字节上限，小于截断标记的极小队列也不受限，现统一按合法 UTF-8 边界截断。 |

## 五轮对抗审查

| 轮次 | 对抗场景 | 结果 |
|---|---|---|
| 1 | 随机测试顺序、并发刷新、快速 start/stop、旧请求晚到 | 四套 Flutter 测试使用随机种子重跑通过；连接意图、串行保存、订阅提交及 Android 重复操作没有顺序依赖。 |
| 2 | 核心卡死、正常退出但后代持管道、停止超时、代理被其他软件修改 | 超时/取消/后代管道测试通过；Windows 只识别记录 PID 和精确路径，三端只恢复 SSRVPN 能证明拥有的代理状态。 |
| 3 | 恶意/损坏 YAML、超大订阅、gzip 膨胀、HTTPS 降级、伪造解锁正文 | 非法输入被拒绝或保守降级；`tunStack` 注入被归一化；普通 HTTP 200、跨服务跳转或模糊关键词不会制造“支持”。 |
| 4 | 半成品 Release、旧提交重试、错误哈希、OSS 写入/恢复中断、回滚目标 | 47 项发布与故障注入测试通过；只有完整公开正式 Release 能授权重试，公开别名在完整备份后更新，失败时验证恢复。 |
| 5 | 三端边界、资源缺失、平台专属代码和打包配置 | Workspace 与四项目分析零问题；Android Kotlin/JUnit、macOS 安全边界、Windows 安装/代理恢复静态测试通过；PR CI 负责三平台真实 runner 构建。 |

## 本轮新增修复

1. `TimedProcessRunner` 在直接进程正常退出后无限等待继承 stdout/stderr 的后代
   进程。回归中旧实现约等待 2 秒；现在在直接进程完成后对输出收尾统一设置
   250 ms 上限，超时和取消仍终止进程树。
2. `AppSettings.tunStack` 从损坏的本地 JSON 恢复时未校验，换行值可插入额外
   Mihomo YAML 字段。现在构造和反序列化只接受 `gvisor`、`system`、`mixed`，
   其他值回退 `gvisor`。
3. `BoundedFileLogger` 从 UTF-8 字符中间截断时，替换字符可能令结果超过
   `maxPendingBytes`；当上限小于截断标记时也会超限。现在从合法 UTF-8 边界
   取尾部，并对极小上限裁剪标记。

## 验证证据

| 检查 | 结果 |
|---|---|
| `scripts/verify-all.sh` | 全部通过；Workspace analyze 零问题 |
| 发布/故障工具 | 47 项通过 |
| `ssrvpn_shared` | 238 项通过，68.42% 行覆盖率（2541/3714，门槛 50%） |
| Android Flutter | 96 项通过，58.33% 行覆盖率（门槛 40%） |
| Android Kotlin/JUnit | 通过；含并发操作、通知策略和公网路由 |
| macOS Flutter | 44 项通过，33.89% 行覆盖率（门槛 10%） |
| Windows Flutter | 38 项通过，1 项因本机非 Windows 按预期跳过，15.99% 行覆盖率（门槛 12%） |
| 随机顺序 | 共享层、Android、macOS、Windows 四套测试均通过 |
| 安全与边界守卫 | secrets、启动编排、Android bridge、解锁探针、macOS 核心权限、Windows launcher、私家车延迟策略全部通过 |
| GitHub PR CI | Run `29210248603`：Workspace、Android、macOS、Windows 全绿；Windows EXE/ZIP 构建与冒烟通过 |

## 已知限制与后续优先级

1. Android Gradle 输出已提示当前显式 Kotlin Gradle Plugin 将在未来 Flutter
   版本中不再兼容；下次升级 Flutter/Gradle 时迁移到 Built-in Kotlin，并先在
   独立分支验证 native bridge。
2. macOS TUN 已改为每次连接显式请求管理员授权，并使用按次 root runner、固定
   资源摘要、启动超时和退出清理；不使用 setuid 位。由于当前包仍为 ad-hoc
   签名，这只能建立“本机用户同意本次提权”的边界，不能验证发布者身份。
   Developer ID、notarization，以及最小签名 helper 或 Network Extension 仍是
   正式商用分发前的最高优先级安全工作。
3. Windows 和 macOS 正式公开分发前配置 Authenticode、Developer ID 与
   notarization，降低 SmartScreen/Gatekeeper 警告。
4. 后续按屏幕区块继续拆分纯 UI 热点；核心生命周期、系统代理和配置边界保持
   当前稳定接口，避免为了行数再次耦合。
5. 官方页面变化时，解锁探针继续回退到“无法判断”，绝不制造“支持”的假结果。
