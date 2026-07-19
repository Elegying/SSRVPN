# ADR-006：macOS 核心进程所有权使用持久化原生代际

## 状态

已接受

## 日期

2026-07-19

## 背景

macOS 系统代理模式会启动普通用户权限的 `AtlasCore` 子进程。应用异常退出后，下一次启动
必须只终止上一次由 SSRVPN 启动的核心，不能因为 PID 被系统复用而向其他进程发送信号，也
不能在旧记录清理期间删除另一个实例刚写入的新记录。

只在 PID 文件中保存数字 PID 无法证明进程代际。等到清理时再读取路径和启动时间也不够：
如果 PID 在首次查询之前已经被同路径的新进程复用，后续两次查询会稳定一致，却仍不是原来
记录的进程。Dart `ps lstart` 还只有秒级精度，无法作为这一所有权边界的持久凭据。

## 决策

1. 在创建 Flutter engine、读取代理快照或接触 PID 文件之前，GUI 进程先对每用户固定 lock file
   获取 `flock(LOCK_EX | LOCK_NB)` 租约。租约描述符使用 `O_CLOEXEC` 且持有到退出清理结束；
   未获得租约的第二实例只请求主实例显示窗口并退出，其 `applicationWillTerminate` 不得恢复代理、
   删除 TUN 请求或终止核心。
2. PID 文件使用唯一的 canonical v2 格式：

   ```text
   v2 <pid> <darwin-start-seconds> <darwin-start-microseconds>
   ```

   启动时间来自 `proc_pidinfo(PROC_PIDTBSDINFO)`，可执行路径来自 `proc_pidpath`。原生层按
   “代际第一次采样 → 路径 → 代际第二次采样”的顺序读取，两次代际必须完全相同；路径必须
   精确等于当前运行目录中的 `AtlasCore`。
3. 非 TUN 核心由原生串行操作直接 spawn；同一个操作有界重试身份双采样并发布记录，完成前
   不把句柄交回 Dart，因此不存在 `Process.start` 与 MethodChannel 入队之间的无记录窗口。
   原生层持续持有 Foundation `Process` 直系子进程句柄并有界排空 stdout/stderr；身份采样或
   记录发布失败时，即使尚无 PID 文件也只收口该直系子进程。记录先写入同目录、随机命名的私有临时文件，完成
   `0600`、完整长度校验和 `fsync` 后，再用 `renameatx_np(..., RENAME_EXCL)` 原子发布；最终
   `AtlasCore.pid` 永远不会暴露空文件或半条记录。发布前失败只按临时文件 inode 回滚，并用
   已捕获的精确进程身份在原生层终止刚启动的核心；不会回退到裸 PID 信号。
4. 遗留核心清理以 non-blocking/no-follow 方式只接受不超过 128 字节的普通文件记录。v2 记录必须和当前原生
   `PID + 精确路径 + 秒 + 微秒` 完全一致，并在 TERM 和 KILL 前重新确认同一身份；信号结果
   和有界退出等待也必须成功。身份变化、权限不足、查询失败或退出无法确认都安全失败并
   保留记录。
5. 旧版数字 PID 记录只在进程已确认不存在时删除。若该 PID 仍存活，因为旧记录没有代际
   证据，不发送信号并阻止新核心启动；用户结束旧进程或重启系统后即可自动完成迁移。
6. 记录删除使用同目录 `renameatx_np(..., RENAME_EXCL)` 原子隔离，再对整条记录做 CAS。
   PID 相同但代际不同也属于新记录，必须保留；隔离后若另一个实例提交了记录，本次清理
   返回失败而不是把“旧进程已退出”误报成“运行目录可重新使用”。
7. Dart 与原生层通过专用 `ssrvpn/core_process` MethodChannel 交互，暴露原子
   `launchOwnedCore`、`ownedCoreStatus`、启动期 `terminateOwnedCore`、正常停止使用的
   `terminateOwnedCoreRecord` 和 `removeOwnedCorePidRecord`；旧的两段式 persist channel 已删除。
   正常停止把内存中的完整 v2 文本
   交给原生层；TERM/KILL 前同时复核磁盘全文与进程代际。Dart 不使用 `ps`、`kill -0`、
   `Process.killPid` 或 `Process.kill` 作为所有权边界。
8. 启动发现待恢复系统代理时，保留旧核心、PID 记录和资产，禁止终止或替换 `AtlasCore`。
   只有代理恢复成功后，才按“清理旧代际 → 安装核心/GeoIP → 可选版本探测”的顺序准备资产并
   解除启动禁用；核心 executable 不会在旧进程身份确认前被替换。
9. launch/status/terminate/remove MethodChannel 操作在原生专用串行队列执行。
   `applicationWillTerminate` 持有单实例租约并同步排空该队列后，才恢复代理和清理核心；因此
   Cmd+Q 不会越过原生 spawn/记录操作。运行期状态 watcher 使用可等待的代际取消，正常停止先
   排空 watcher，再读取稳定的内存句柄与记录，避免自然退出删除和手动终止互相竞态。
10. 退出兜底把代理快照视为不可信恢复证据：原生层以 `O_NOFOLLOW | O_NONBLOCK` 打开，只
    接受当前用户拥有、单硬链接、非 group/other 可写且不超过 1 MiB 的普通文件，并从同一文件
    描述符完成有界读取。缺少 `_ownedProxyHost/_ownedProxyPort` 的旧快照、目录、悬空链接、FIFO、
    不可读或过大的路径均保留并返回失败；快照还必须在任何 `networksetup` 前通过完整 schema
    校验，包含至少一个 web/secureWeb/socks 状态完整的服务。元数据只匹配三个精确保留键，
    `_Wi-Fi` 等名称仍按服务恢复；服务名撞到保留键时，在保存快照或接管代理前拒绝操作。
    代理不能证明已恢复时不得终止旧核心。Dart 运行期的 `clearSystemProxy` 使用 single-flight。
11. Dart 的 set/clear（含初始化恢复）在第一条快照或 `networksetup` 操作前同步获取原生事务令牌，
    并只在整个事务结束后释放。若 Cmd+Q 遇到活跃令牌，`applicationShouldTerminate` 返回
    `terminateLater`；最后一个精确 token 释放后才回复继续退出，从而不允许原生恢复/删除快照后
    Dart 又把后续代理类型指回即将终止的核心。

## 信任边界与限制

- 单实例租约是 GUI 生命周期的第一道边界；PID/代际协议仍独立成立，不能因为通常只有一个 GUI
  就放宽进程身份检查。XCTest 宿主使用隔离 fixture，原生测试入口关闭并行宿主执行。
- 记录防住“清理开始前已经发生”的 PID 复用、采样期间代际变化和同 PID ABA 文件竞态。macOS 没有 Linux
  `pidfd_send_signal` 的等价公开接口，身份复核与按 PID 发信号不能合成一个原子系统调用；
  实现通过每次信号前的原生微秒级复核缩小该操作系统固有限制，并在任何不确定状态下拒绝
  第二次启动。
- 运行目录、lock file 和 MethodChannel 都属于当前用户进程的信任域。相同用户权限的恶意程序仍可造成
  拒绝服务，但符号链接、FIFO、超大记录、记录替换和非法内容不能让 SSRVPN 误杀未经证明的进程或阻塞退出。
- 管理员授权的 TUN 核心由附着式 root runner 和请求租约管理，不使用本 PID 记录协议。

## 结果

- 应用崩溃、Cmd+Q、延迟退出、PID 复用和并行实例都共享同一原生所有权定义；Cmd+Q 会先等待
  代理事务令牌并排空核心队列，第二 GUI 实例不会接管第一实例的代理或核心。
- 无法证明归属时会保留进程或记录并拒绝重新连接，优先避免误杀和双核心。
- 旧数字记录的迁移比“猜测并终止同路径进程”更保守；升级后首次遇到仍存活的旧核心时可能
  需要用户结束该进程或重启一次。

## 未采用的方案

### 只保存数字 PID，并在清理时查询两次

无法识别首次查询前已经完成的 PID 复用，因此拒绝。

### 使用 `ps lstart` 和命令行文本

文本格式依赖 locale、只有秒级精度，路径和参数解析也不如 Darwin 原生结构稳定，因此拒绝。

### 使用 `pkill -f` 或进程名批量终止

不能证明进程所有权，可能终止用户独立运行的 Mihomo 或其他同名进程，因此禁止。

### 仅依赖应用单实例行为

LaunchServices 的常规启动通常复用现有应用，但直接执行二进制、测试和异常恢复仍可能产生
并发。进程所有权必须由运行时协议本身保证，不能把 UI 单实例当作安全边界。

## 验证守卫

- `SSRVPN_MacOS/macos/RunnerTests/RunnerTests.swift` 的 58 项测试覆盖单实例租约、原生 spawn/记录、
  直系子进程收口、有界输出、canonical 记录、原子发布与半写回滚、身份双采样、旧记录迁移、
  同 PID 新代际、退出令牌、安全超时取消、流式 UTF-8 诊断、完整记录 CAS，以及代理快照的
  链接/FIFO/目录/权限/大小和 schema 拒绝。
- macOS 的 124 项 Flutter 测试覆盖原生 launch/status payload、watcher 取消、代理事务前后顺序、
  strict snapshot、保留服务名，以及代理恢复失败时保留旧核心/记录/GeoIP 的顺序。
- `scripts/check-macos-core-privileges.sh` 和 `scripts/test_macos_native_gate.py` 禁止恢复 PID-only
  清理，并由 `make verify`、普通 CI 和 Release workflow 执行真实 Swift/XCTest。

## 相关文档

- [测试策略](../TESTING.md)
- [项目健康状态](../PROJECT_HEALTH.md)
- [macOS 用户指南](../../SSRVPN_MacOS/USER_GUIDE.md)
