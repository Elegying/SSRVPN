# SSRVPN Windows v4.0.19 实机验收报告

- 验收日期：2026-09-01（Asia/Shanghai）
- 源码分支：`main`
- 本地/远端提交：`eb2ed1fcbacbc443f5ac0a017966cf0fbe7487d0`
- 正式标签：`v4.0.19` -> `027baad349bd9cd071c5387a47abd692d665d0a8`
- 应用版本：`4.0.19+4019`
- 正式 Release：[SSRVPN v4.0.19](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.19)
- 执行人：Codex（用户授权的本机发布验收）
- 脱敏规则：不记录订阅 URL、节点凭据、节点名称、用户名路径、完整公网 IP、原始截图或原始配置

## 结论

本轮结论：**release blocked**。

Windows 的正式覆盖升级、用户数据保留、系统代理、TUN 数据路径、系统代理/TUN 异常退出恢复，以及手动未标记安装器保留均有真实系统证据并通过。但是，4.0.17 内置更新器下载并写入可信标记的 4.0.19 安装包，在成功安装以及完整等待 130 秒后仍未自动删除；隔离重现得到相同结果。该行为违反发布清单对 v4.0.15 及以上内置更新包的清理契约，按发布门禁记为 P1 阻断；实际用户影响偏 P2，因为实现安全地多保留文件，没有误删用户文件。

本报告的 Windows 执行主机没有 macOS 主机或 Android 真机，因此下表对应项只表示该主机的证据边界，不代表项目当前另外两端的结果；独立实机结论见同日 Android/macOS 报告。

## 证据头

### Windows 实机

| 字段 | 内容 |
|---|---|
| 平台与系统版本 | Windows 11 专业版 x64，10.0 build 26200 |
| 设备型号与 CPU | Beelink GTi15，Intel Core Ultra 9 285H，63.6 GiB RAM |
| PowerShell / Flutter | PowerShell 7.6.4；Flutter 3.44.1；Dart 3.12.1 |
| 升级前应用 | 正式安装版 4.0.17 |
| 升级后应用 | 正式安装版 4.0.19 |
| 网络 | 活跃物理局域网；网络名称和公网地址已脱敏 |
| UAC 基线 | `EnableLUA=1`、`ConsentPromptBehaviorAdmin=0`、`PromptOnSecureDesktop=0` |
| 测试前网络状态 | 系统代理关闭；无 SSRVPN/Mihomo 进程；无 7890/7891/9090 监听；无 Meta TUN 适配器 |
| 用户数据策略 | 不清数据；测试前临时私密备份；恢复核对后删除备份 |

### Windows 执行主机上的 macOS / Android 证据边界

| 平台 | 设备状态 | 本轮证据边界 |
|---|---|---|
| macOS | Windows 执行主机无 macOS/Xcode 环境 | 本报告不评价 macOS 真机结果；项目当前结果另见 macOS/Android 实机报告 |
| Android | Windows 执行主机的 `adb devices -l` 无设备 | 本报告不评价 Android 真机结果；项目当前结果另见 macOS/Android 实机报告 |

## 正式资产与来源

GitHub Release 于 2026-09-01 02:35:42 +08:00 发布，非 draft、非 prerelease；标签提交属于当前 `main` 的祖先。三端资产均从正式 Release 下载并与 sidecar、provenance 三方比对。

| 资产 | 大小 | SHA-256 | 结果 |
|---|---:|---|---|
| `SSRVPN_Setup.exe` | 32,033,650 bytes | `c71b9799cac17a2b2269187c60cc62e336543d4ac7ecc576eb10fe1e67cd19f8` | pass |
| `SSRVPN.apk` | 31,184,273 bytes | `8f1cbf8f45f879a400c57623db53f3fa72ad9001f4d720e14b0df5b6d3b0b09b` | pass |
| `SSRVPN.dmg` | 30,856,853 bytes | `aac40e6634265f6d1d32d15489d59648a06a080dd6fee9b6916fb990942d3727` | pass |
| `SSRVPN-release-provenance.json` | 376 bytes | commit/tag/三资产摘要精确一致 | pass |

补充验证：

- Windows 安装器 Authenticode 为 `NotSigned`，与项目免费未签名分发策略一致。
- Android APK 包名 `com.ssrvpn.android`、`versionName=4.0.19`、`versionCode=4019`、`targetSdk=36`、仅 `arm64-v8a`。
- Android APK v2 签名验证通过；签名证书 SHA-256 为 `caf5bb670e4513c4e3d7815a7314f489281c37f02827db07d0a59e1242f2cc0c`。
- `zipalign -c -P 16 -v 4` 通过；仓库核心守卫确认 `libgojni.so` 的 ELF LOAD alignment 全为 16,384 bytes。

## 请求重点结果

| 平台 | 场景 | 状态 | 实际结果 |
|---|---|---|---|
| Windows | 4.0.17 -> 4.0.19 覆盖升级 | pass | 正式标记安装器退出码 0；注册表和主程序版本均为 4.0.19；安装器结束旧实例且未自动启动 GUI。 |
| Windows | 用户数据保留 | pass | DPAPI secret、设置、订阅清单、订阅缓存和窗口状态 5/5 前后 SHA-256 一致；运行缓存因连接活动变化，不作为静态数据丢失。 |
| Windows | UAC 提示、取消、失败 | blocked | UAC 保持启用，但本机管理员策略自动批准；安装从中等完整性会话进入高完整性并成功，无法观察弹窗或取消分支。未修改用户现有 UAC 策略。 |
| Windows | 系统代理连接/断开 | pass | 连接后 `ProxyEnable=1`、`127.0.0.1:7890`，7890/7891/9090 监听，显式代理 HTTPS 返回 204；断开后核心和监听消失，`ProxyEnable` 精确恢复为 0。 |
| Windows | 系统代理异常退出恢复 | pass | 连接中只强制结束 Flutter GUI；外层 launcher/guardian 在 15 秒观察窗内结束 Mihomo、关闭代理并清除监听。 |
| Windows | TUN 数据路径 | pass | `Meta Tunnel` 为 Up，地址 `198.18.0.1/30`，捕获路由下一跳为 `198.18.0.2`；系统代理保持关闭，Mihomo `tun.enable=true`，普通 HTTPS 返回 204。 |
| Windows | TUN 异常退出恢复 | pass | TUN 连接中只强制结束 Flutter GUI；20 秒内 Mihomo、Meta 适配器、捕获路由和三个监听全部消失。 |
| Windows | 内置更新提示与下载 | pass | 4.0.17 连接后准确显示 4.0.17 -> 4.0.19；下载到真实桌面，文件摘要、隐藏 sidecar 和 NTFS owner stream 均有效。 |
| Windows | 长下载取消 | 未执行 | 32 MB 安装包在第二次点击到达前已完成；500 ms 取消尝试没有进入取消状态，不能标记通过。 |
| Windows | 标记安装器成功后自动清理 | fail | 真实应用内下载和隔离复现均在安装成功后保留安装包与标记；严格复现等待 130 秒仍未清理。 |
| Windows | 手动未标记安装器保留 | pass | staging 中未标记的正式安装器同版本安装退出码 0；文件和 SHA-256 保持，未生成标记。 |
| Windows | 托盘菜单正常退出 | blocked | Flutter UIA 只暴露顶层 Pane；高完整性托盘菜单无法由当前自动化会话可靠触发。没有用强制结束冒充正常托盘退出。 |
| macOS | 系统代理连接/断开 | blocked | 无 macOS 主机。 |
| macOS | TUN 授权同意/取消/失败 | blocked | 无 macOS 主机。 |
| macOS | DNS 精确恢复 | blocked | 无 macOS 主机；WSL 自动化 25/25 通过仅作为逻辑证据。 |
| macOS | 长时间离线后取消 | blocked | 无 macOS 主机，未执行 30 分钟离线专项。 |
| Android | VPN 首次授权、拒绝后重试 | blocked | 无已授权 Android 设备。 |
| Android | 后台/进程回收恢复 | blocked | 无已授权 Android 设备。 |
| Android | 原生 16 KiB page-size 设备 | blocked | 包结构与核心对齐通过，但无原生 16 KiB page-size 设备，未冒充硬件验收。 |
| Android | OEM 后台限制 | blocked | 无 MIUI/ColorOS/One UI 等 OEM 真机。 |

## Windows 安装器清理失败

### 最小复现

1. 在正式 4.0.17 中连接系统代理，等待底部出现 4.0.19 更新。
2. 点击“立即更新” -> “下载到桌面”。
3. 核对 `SSRVPN_Setup_v4.0.19.exe` 的 SHA-256、隐藏 `.ssrvpn-verified-update` sidecar 和 `ssrvpn-update-owner` NTFS stream。
4. 运行该安装器执行 4.0.17 -> 4.0.19 覆盖升级；安装退出码为 0。
5. 等待并检查桌面。安装包和 sidecar 均仍存在。
6. 用相同正式二进制在隔离目录重建完全有效的 v2 sidecar/owner stream，同版本重装并等待 130 秒；安装包和 sidecar 仍存在，无 `.ssrvpn-cleanup.*` quarantine 残留。

### 预期与实际

- 预期：只有 v4.0.15 及以上内置更新器下载、摘要校验并标记的安装包，在安装事务成功后自动删除；手动包、取消包、失败包和无关文件保留。
- 实际：手动未标记包正确保留；可信标记包也被保留。
- 安全边界：未观察到误删或越界删除。失败模式是 fail-closed 的多保留，而不是误删。

### 日志摘要

- Inno 日志在 18:29:52 和隔离复现 18:43:23 均记录 `SSRVPN detected a marked in-app update installer.`。
- 安装器进程清理记录 `exit=0 stage=OK`，随后完成程序文件事务并进入 `Deinitializing Setup`。
- 完整等待后没有 `post_install_cleanup.ps1` 进程，也没有 quarantine 文件；原安装包、sidecar、摘要和 owner stream 仍完整有效。
- 直接在相同用户会话调用已安装的 `post_install_cleanup.ps1` 并打开逐行跟踪时，脚本能完成移动、二次校验和删除，最终无 residue。故障边界位于安装器自动清理的启动/参数/会话交接链路，尚未在本轮修改源码。

## 自动化与静态门禁

| 门禁 | 结果 | 摘要 |
|---|---|---|
| `flutter analyze` | pass | 全仓库无问题 |
| Release tooling（WSL + checksum 验证的临时 `jq`） | pass | 396/396 |
| macOS TUN DNS transaction（WSL） | pass | 25/25 |
| Windows native proxy recovery | pass | 原生 C++ fault harness 通过 |
| secret / TLS policy scan | pass | 未发现泄漏 |
| Android Flutter tests | pass | 299/299 |
| Windows Flutter tests | pass | 317/317 |
| Android native unit tests（Windows 宿主） | partial | 160/161；仅真实 symlink 语义用例在 Windows 失败，不据此判产品失败 |
| macOS Flutter tests（Windows 宿主） | invalid host | POSIX 权限、symlink 和 `networksetup` 不可用；不作为 macOS 产品结论 |
| Shared Flutter tests（Windows 宿主） | fail | 627 pass、3 skipped、22 fail；失败集中于桌面更新下载/恢复/取消/发布路径，包含 Windows 分隔符期望差异和级联对话框失败 |
| 核心与 APK 16 KiB guards | pass | Android ELF 16,384-byte LOAD alignment；APK `zipalign -P 16` 通过 |

完整 `verify-all.sh` 在 Git Bash 会因 macOS symlink/权限语义失败；同一 DNS 脚本在 WSL 25/25 通过。发布工具初次 WSL 运行因缺少 `jq` 有 10 项提前失败；下载官方 `jq-linux-amd64` 并核对官方 SHA-256 `5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5` 后，396/396 通过。这些环境入口均保留在摘要中，没有被包装成首次即全绿。

## 本轮未执行的完整矩阵

以下项目没有因本轮重点验证而自动升级为通过：C-03 连续 20 轮、C-04 快速重复取消、C-05 弱网/断网/切网、C-06 后台 30 分钟与休眠唤醒、C-09 200% 字体/读屏、30 分钟电量，以及 W-05 RunOnce 重启恢复和 W-06 Explorer 重启。它们均为 `未执行`，不引用自动化或历史快照替代本轮真机证据。

## 最终现场恢复

- 正式 4.0.19 保持安装，工作版本为 `4.0.19+4019`。
- SSRVPN、Mihomo 进程为 0；7890/7891/9090 监听为 0。
- 系统代理为测试前的关闭状态；WinHTTP 保持 direct。
- Meta/TUN 适配器和下一跳 `198.18.0.2` 的捕获路由均为 0。
- 用户设置恢复为 `proxyMode=rule`、`enableTun=false`；订阅清单仍存在且未输出内容。
- DPAPI secret、设置、订阅清单、订阅缓存和窗口状态的测试前/后摘要一致。
- 原始节点截图、公网 IP、临时私密备份、测试辅助脚本和下载 staging 在报告复核后整体移入 Windows 回收站；仓库只保留本脱敏报告。

## 发布建议

1. Windows 安装器清理失败关闭前，不把 v4.0.19 记为 Windows 完整实机通过。
2. 优先修复或定位 Inno `LaunchVerifiedUpdatePackageCleanup` 到原用户 PowerShell 的交接，并新增“真实安装器 + 完整等待上限”的本机回归，不能只测清理脚本函数。
3. 修复 Windows 宿主 shared update 测试的路径语义并复跑 22 项失败，区分测试期望错误与真实发布路径错误。
4. macOS 与 Android 以独立实机报告为准；原生 16 KiB page-size Android 和更多 OEM 仍需后续硬件覆盖。
