# ADR-020：安装器只处置可证明归属的系统代理

## 状态

已接受

## 日期

2026-09-22

## 背景

Windows 安装器在替换程序文件前，用 `Test-SystemProxySafeToStop`
（`SSRVPN_Windows/installer/stop_ssrvpn_processes.ps1`）判断当前系统代理是否可以被安全处置。
该函数把下面四件事同时成立当作「这是 SSRVPN 自己的代理」，并要求失败关闭：

- 当前系统代理是回环端点；
- `ProxyOverride` 恰好等于本脚本的 `$script:OwnedProxyOverride`；
- `AutoDetect` 关闭；
- 没有 `AutoConfigURL`。

这个判定过宽，原因是两处形状都不可靠：

1. `Test-OwnedProxyServer` 只做 `^127\.0\.0\.1:([0-9]{1,5})$` 形状匹配，并接受 1–65535
   的**全部**端口。用户的代理端口自 5.0.3 起可自定义，因此任何本地代理工具都能落在同一
   形状里。
2. `$script:OwnedProxyOverride` 是常见约定串
   （`<local>;localhost;127.*;10.*;172.16.*`–`172.31.*`;`192.168.*`），第三方工具很容易
   逐字节相同。

结果是：**机器上从未运行过 SSRVPN、不存在任何恢复状态时，一台装有其他本地代理工具的全新
安装机器也会被判成「自有代理且不安全」，安装直接中止。** 而提示只让用户「退出 SSRVPN，
确认 Windows 系统代理和网络正常后重试；如果仍然失败，请重启 Windows」——对从未安装过
SSRVPN 的机器，这两条建议都不成立。Issue #256（Windows 10 22H2，诊断阶段码
`PROXY_UNSAFE`）即该现象。

同一仓库内 `Repair-InvalidProxyRecoveryState` 对同一事实采用了相反的前提：没有任何恢复
状态时它直接返回、不写 Internet Settings，理由是「没有本安装的东西要善后」。两个函数对
「没有恢复状态」的解读不一致，本 ADR 消除该不一致。

## 决策

1. 系统代理的归属**只能由本安装自身的恢复记录证明，不得凭端点形状推断**。
2. `Test-SystemProxySafeToStop` 只有在 `Test-ProxyRecoveryStatePresent` 为真时，才把
   「回环端点 + 自有 `ProxyOverride`」的指纹判为自有；没有恢复状态时，该端点按外来处理：
   原样保留，判定为可以继续。
3. `Test-ProxyRecoveryStatePresent` 同时检查原生恢复键
   `HKCU:\Software\SSRVPN\RuntimeProxyBackup` 与 JSON 回退
   `%LOCALAPPDATA%\SSRVPN\runtime\system_proxy_backup.json`，与
   `Repair-InvalidProxyRecoveryState` 的既有前提保持一致。
4. 不结束任何第三方进程；不接管、不改写外来系统代理；不为外来代理写入恢复记录。
5. 有恢复状态时的既有行为**不变**：`Test-NativeRecoveryJournalNonReplayable` 可重放仍
   失败关闭，`Repair-InvalidProxyRecoveryState` 与 `Disable-OwnedSystemProxyEndpoint` 的
   语义与顺序均不修改，既有全部守卫断言保留。

## 结果

- 全新安装在有其他本地代理工具的机器上可以正常进行，不再被误判为自有代理不安全。
- 有 SSRVPN 恢复状态时的失败关闭语义完整保留，未以可用性换取安全降级。
- 剩余的失败关闭出口（恢复日志残留 pending 标志、`APP_INSTANCE_ACTIVE`、进程身份无法
  证明等）继续失败关闭，其中 `APP_INSTANCE_ACTIVE` 给出的「退出其他目录或便携版实例」
  是可执行建议；**残留恢复日志引起的失败仍没有人工越过入口**，留待后续按真实用户数据
  单独处置。
- 本决策不改变硬规则 #11：安装、卸载与恢复仍只结束路径、PID、会话、创建时间和所有权
  能够证明属于当前 SSRVPN 安装的进程。

## 未采用的方案

### 以「安装成功最高优先」放开进程结束范围

被拒绝。该提案不解决本问题：本判定门只读取注册表状态，其输入不含任何进程信息，结束进程
无法改变 `ProxyEnable`、`ProxyServer`、`ProxyOverride`、`AutoDetect`、`AutoConfigURL` 或
恢复键中的任何一个值。同时它会把静默断网（第三方工具被结束后系统代理仍指向已死端口）、
孤儿 TUN 网卡与路由、以及未签名安装器出现杀进程行为后被 AV/EDR 拦截等风险引入安装关键
路径，等于用一个已认证的安全性质换取零收益。

### 记录当前代理原值后接管

本问题不需要接管。正确归属路径下 SSRVPN 从未设置过该系统代理，因此既没有要记录的原值，
也没有要改写的对象；相比之下「不触碰」比「接管」更保守，且不会产生任何卸载后需要还原的
额外状态。

## 验证守卫

- `scripts/test_windows_installer_config.py` 新增断言：`$ownedFingerprint` 必须以
  `$hasProxyRecoveryState` 佐证开头，`Test-ProxyRecoveryStatePresent` 必须同时检查原生键
  与 JSON 回退路径。删除佐证条件会使该断言失败。
- 既有断言全部保留，包括 `Repair-InvalidProxyRecoveryState` 仍须持有
  `Test-OwnedProxyServer`、`$script:OwnedProxyOverride`、`ProxyEnable -Type DWord -Value 0`、
  `Remove-ProxyRecoveryState`。
- `scripts/test_windows_installer_runtime.ps1` 中「不得结束无关进程」的断言未放宽。

## 证据边界

根因判定基于源码路径分析与本地桩探针的四场景对照（恢复状态有无 × 修复前后），未在
Windows 10 22H2 实机复现，也未取得 Issue #256 报告者的注册表取值。该机器上第三方工具
的实际 `ProxyServer`/`ProxyOverride` 与残留恢复键状态仍需用户回填后才能确认命中本 ADR
描述的分支；本 ADR 只保证「无恢复状态 + 回环端点 + 自有 override 串」这一在全新机器上
可达的分支不再失败关闭。
