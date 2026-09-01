# SSRVPN Windows v4.0.13 实机验收报告

- 验收日期：2026-08-20（Asia/Shanghai）
- 平台：Windows 11 Pro x64，10.0 build 26200
- 硬件：Intel Core Ultra 9 285H，63.6 GiB RAM
- 电源条件：交流供电，平衡电源方案
- 正式版本：4.0.13+4013
- 正式标签：`v4.0.13` -> `aa157395f87959696ad21e6a5d894f54c400cb82`
- 测试分支基线：`origin/main` -> `47c995227e863916555dfc5eaf433acaa0c10fc2`
- 测试分支：`codex/windows-v4.0.13-final-uat`
- 原始证据：`%TEMP%\SSRVPN-Windows-UAT-v4.0.13-<session>\raw`，未加入 Git
- 脱敏约定：节点仅写作 A/B；用户名、用户目录、订阅 URL、凭据和完整公网 IP 均不进入本报告

本次验收通过 Git、仓库内全文检索和文件审查复核源码。测试时使用的是当时公开的 v4.0.13 正式安装器；该历史 Release 现已按项目保留范围移除，源码仍可通过 [v4.0.13 标签](https://github.com/Elegying/SSRVPN/tree/v4.0.13) 追溯。

## 结论

本报告的 16 个 C/W 项目合计：**PASS 10，FAIL 5，BLOCKED 1**。

以下项目按用户最新指令从范围中剔除，不计入 PASS/FAIL/BLOCKED 分母：

- 200% Windows 文本缩放
- Narrator、其他屏幕阅读器、盲文

三项正式版最终修复只有 **1/3 通过**：

1. 诊断复制：**FAIL**。剪贴板确有 4,326 字符报告，但正式版错误显示“复制失败，请重试”；报告还含两个未脱敏公网 IPv4 值。
2. 连接态节点切换：**FAIL**。Mihomo API 和真实数据路径完成 A -> B -> A，但 UI/首选节点提交仍停留在 A，也没有要求的成功提示。
3. 未连接时订阅页状态：**PASS**。连接、断开、再连接、再断开四个页面状态均与核心/代理状态一致。

因此，**v4.0.13 正式安装器不满足最终放行条件**。本分支为前两项根因及 TUN 取消提示补了最小修复和 RED/GREEN 回归，但没有把分支构建冒充正式版结果。

## C-01 ~ C-10 / W-01 ~ W-06

| ID | 状态 | 实机结论 |
|---|---|---|
| C-01 | PASS | 正式安装器来源、sidecar/provenance 和 SHA-256 三方一致；标签及远端基线已重新 fetch 核实。 |
| C-02 | PASS | 正式 4.0.13 同版本覆盖安装退出码 0，约 16 秒；安装时审计的 15 个配置项全部保持，公共桌面/开始菜单快捷方式各 1 个且无用户级重复。 |
| C-03 | FAIL | 正式版诊断剪贴板写入真实发生，但 CRLF/LF 回读比较造成假失败；报告存在未脱敏公网 IPv4。 |
| C-04 | FAIL | 正式版连接态节点运行时切换成功、流量不中断，但 UI/持久首选节点没有提交，成功提示缺失。 |
| C-05 | PASS | 订阅页连接态/未连接态与核心、代理和当前运行节点同步。 |
| C-06 | PASS | 系统代理模式连接/204 请求/断开通过；20 轮均恢复本应用拥有的代理事务、端口和核心。 |
| C-07 | PASS | TUN 设置开启、系统代理保持关闭时两个直连 204 请求通过；主动断开和 3 组快速取消均无核心、端口、TUN 探针残留。连接时 Windows 适配器/路由探针未识别到名称，因此不据此声称适配器名称证据。 |
| C-08 | FAIL | 3 组快速取消最终状态均正确，但正式版没有显示“连接已取消”。 |
| C-09 | FAIL | 20 轮生命周期清理 20/20 通过，但第 1 轮两个数据探针中有一个 TLS 请求为 `000/exit 1`；保留失败样本后，整项不能算全通过。 |
| C-10 | PASS | 断开和连接各完成 30.06 分钟同机空闲采样，CPU/Working Set 低且稳定；`powercfg /energy` 两次均退出 0，但系统级 trace loss 使其内部 CPU 分析不完整，详见能耗章节。 |
| W-01 | PASS | 首次/重复启动、单实例、关闭隐藏、托盘恢复/退出均通过；Explorer 重启后应用进程存活，重建图标曾成功恢复窗口。图标随后移入 shell overflow 后 UIA 不能直接再次定位，未将该自动化限制误报成应用失败。 |
| W-02 | PASS | 强制结束 Flutter 子进程后，native guardian 在 877 ms 内停核、关代理、清端口；强制结束 Mihomo 后 3,253 ms 自动拉起新核心并恢复两个 204 数据请求。 |
| W-03 | PASS | 损坏 RunOnce 日志实测只关闭精确的 SSRVPN 自有代理指纹并清除恢复项；退出码 0、6,217 ms，原 Internet Settings 逐值/逐类型恢复一致。 |
| W-04 | FAIL | TUN UAC 同意、正常数据路径、主动取消和清理已执行；正式版取消提示失败。没有通过修改网络基础设施制造额外 TUN 启动故障。 |
| W-05 | PASS | 默认缩放下只用 Tab、Shift+Tab、Enter、Esc 完成节点页、诊断弹窗、节点选择、订阅页、关闭弹窗和返回首页；6 张截图保存在临时证据目录。Flutter 在 Windows UIA 中只暴露顶层 Pane，因此语义读取不作为本项证据。 |
| W-06 | BLOCKED | 机器开始时已是 4.0.13，没有旧版可做跨版本升级；完整卸载/重装需要明确同意，已单独请求但未获得“同意卸载重装”。已完成不删数据的正式版覆盖安装和最终正式版恢复。 |

## 正式资产与安装

| 项目 | 结果 |
|---|---|
| 历史 Release 资产 | 测试时来自 `v4.0.13` 的 `SSRVPN_Setup.exe`；现已按保留范围移除，不再提供公开下载 |
| 下载时间（UTC） | 2026-08-20 03:58:20 ~ 03:58:28 |
| 文件大小 | 32,057,880 bytes |
| SHA-256 | `50d803295e7f3947893eb1351b743f41f1bb23dac4838b8d77ee95dbebc0b3f2` |
| 预期哈希 | 精确一致 |
| Release sidecar/provenance | 均与安装器哈希一致 |
| Authenticode | `NotSigned`；仅记录客观状态，未误报为已签名 |
| 覆盖安装 | 退出码 0，版本仍为 4.0.13+4013 |
| 配置保持 | 覆盖安装时 15/15 审计项一致；最终现场 12/12 基线文件哈希一致 |

CI 专用的 `test_windows_installer_package.ps1` 明确拒绝在非 GitHub Actions 环境执行破坏性安装/卸载，且本次没有完整卸载授权，因此没有伪造 CI 环境变量绕过保护。

## 三项正式版复验

### 1. 诊断复制：FAIL

- 剪贴板非空，报告长度 4,326 字符，SHA-256 为 `e518919bc5b32a27bf5f82cf0e874b4c21e2f71798d3b53afe3347ee9be90c1f`。
- 用户名、用户绝对目录和 URL 扫描未命中。
- 命中两个不同的未脱敏公网 IPv4；报告仅保留命中数量，不保留地址。
- UI 显示“复制失败，请重试”，没有要求的成功提示。
- 根因：Windows Clipboard 回读把 LF 规范化为 CRLF，正式版使用逐字节字符串比较，真实写入也被判断为失败。

分支修复：比较前只规范化 CRLF/CR/LF；其他字符仍要求完全一致；同时在全局 `LogRedactor` 中脱敏公网 IPv4，保留私网、回环和文档保留地址用于诊断。

### 2. 连接态节点切换：FAIL

- A -> B：Mihomo 运行时组已切换，耗时 499 ms；两个探针均为 204（199/102 ms）。
- B -> A：Mihomo 运行时组已切回，耗时 411 ms；两个探针均为 204（413/400 ms）。
- 两次切换后，UI 选中标记/标题和 `lastSelectedNodeName` 都没有提交目标节点，也没有要求的成功 snackbar。
- 根因：Mihomo 的无害状态通知在 no-op 判断前递增 `_connectionStatusEpoch`，使 `_handleSelectNode` 的异步提交被当成过期操作丢弃。

分支修复：只有连接状态、警告或取消状态真实变化时才递增 epoch。

### 3. 订阅页状态：PASS

| 阶段 | 耗时 | 核心/代理/端口 | 页面证据 |
|---|---:|---|---|
| 初始连接 | - | 核心运行、代理开启、3 端口 | 已连接 + 当前运行节点 |
| 断开 | 1,452 ms | 核心停、代理关闭、0 端口 | `连接状态：未连接` |
| 再连接 | 1,756 ms | 核心运行、代理开启、3 端口 | 已连接 + 当前运行节点；两个探针 204 |
| 最终断开 | 1,523 ms | 核心停、代理关闭、0 端口 | 回到 `未连接` |

## 连接、TUN 与异常恢复

### 系统代理

- 连接后精确拥有 `127.0.0.1:<runtime-port>`，实际 204 请求通过。
- 断开后 `ProxyEnable=0`、核心退出、7890/7891/9090 无监听。
- guardian 异常退出恢复前，RunOnce 和备份键存在；恢复后两者均移除。

### TUN

- 正式版 TUN 连接 1,471 ms；系统代理保持关闭，核心及 3 个监听存在。
- 不显式指定代理的两个 204 请求分别为 1,080/591 ms。
- 正常断开 2,247 ms；核心、代理、监听、TUN 残留探针均为 0。
- 3 组连接中快速取消分别为 392/432/422 ms，三组最终均干净。
- 正式版缺少“连接已取消”提示，因此取消 UX 为 FAIL；分支已增加“停止成功且核心确实退出”条件下的提示，失败时不会假报成功。

### guardian / 核心 / RunOnce

| 场景 | 结果 |
|---|---|
| 强制结束 Flutter 子进程 | 877 ms 内核心 0、代理 0、端口 0、RunOnce 无、备份键无；PASS |
| 强制结束 Mihomo | 3,253 ms 自动生成新核心 PID，代理仍为自有指纹，3 端口恢复，两个探针 204；PASS |
| 损坏恢复日志 | recovery-only 退出 0，6,217 ms；只禁用 SSRVPN 自有指纹，恢复项清除，原设置逐值/类型恢复一致；PASS |

## 20 轮稳定性与性能

预热 1 轮后执行以下 20 轮。`清理` 同时要求核心 PID 空、ProxyEnable=0、7890/7891/9090 无监听、TUN 残留探针为 0；20 轮全部满足。

| 轮次 | App/Core PID | 连接 ms | 探针 | 断开 ms | 连接 App/Core MiB | 断开 App MiB | 清理 |
|---:|---|---:|---|---:|---:|---:|---|
| 1 | 27488/9840 | 1644 | 000/204 | 1600 | 224.95/43.75 | 235.86 | PASS |
| 2 | 27488/4552 | 1685 | 204/204 | 1676 | 225.11/42.44 | 235.64 | PASS |
| 3 | 27488/2556 | 1731 | 204/204 | 1809 | 226.40/42.04 | 224.36 | PASS |
| 4 | 27488/14836 | 1795 | 204/204 | 1882 | 229.84/41.71 | 228.27 | PASS |
| 5 | 27488/20556 | 2011 | 204/204 | 1569 | 236.27/41.70 | 232.97 | PASS |
| 6 | 27488/10800 | 2393 | 204/204 | 1962 | 231.34/42.49 | 228.16 | PASS |
| 7 | 27488/1808 | 2236 | 204/204 | 1663 | 225.36/42.28 | 232.50 | PASS |
| 8 | 27488/13688 | 1829 | 204/204 | 1746 | 236.75/42.53 | 236.63 | PASS |
| 9 | 27488/10840 | 1936 | 204/204 | 1794 | 225.82/42.14 | 226.10 | PASS |
| 10 | 27488/10756 | 1983 | 204/204 | 1989 | 230.54/42.61 | 229.53 | PASS |
| 11 | 27488/25844 | 2050 | 204/204 | 1990 | 235.02/44.06 | 233.02 | PASS |
| 12 | 27488/12004 | 2156 | 204/204 | 2014 | 227.35/42.59 | 224.16 | PASS |
| 13 | 27488/6372 | 2284 | 204/204 | 2152 | 231.96/41.67 | 228.20 | PASS |
| 14 | 27488/4344 | 2465 | 204/204 | 2292 | 225.04/42.58 | 232.00 | PASS |
| 15 | 27488/3228 | 2437 | 204/204 | 2359 | 229.04/41.95 | 236.23 | PASS |
| 16 | 27488/18292 | 2509 | 204/204 | 2307 | 231.71/44.57 | 224.55 | PASS |
| 17 | 27488/11980 | 2503 | 204/204 | 2478 | 233.82/42.62 | 227.57 | PASS |
| 18 | 27488/12628 | 2569 | 204/204 | 2391 | 225.28/43.03 | 233.00 | PASS |
| 19 | 27488/16772 | 2763 | 204/204 | 2519 | 231.36/42.61 | 236.89 | PASS |
| 20 | 27488/8108 | 2856 | 204/204 | 2646 | 233.36/43.44 | 226.12 | PASS |

第 1 轮失败探针未删除，因此 C-09 仍判 FAIL。其余 19 轮两个站点均成功。

| 指标 | n | 中位数 | P95 | 最大值 |
|---|---:|---:|---:|---:|
| 连接 | 20 | 2,196 ms | 2,763 ms | 2,856 ms |
| 断开 | 20 | 1,989.5 ms | 2,519 ms | 2,646 ms |
| 启动（冷+温） | 10 | 173 ms | 207 ms | 207 ms |
| 温启动/单实例激活 | 5 | 128 ms | 149 ms | 149 ms |
| 冷启动 | 5 | 203 ms | 207 ms | 207 ms |

温启动 5/5 复用原 PID 且只有一个实例；冷启动 5/5 只有一个实例且未误启核心。另一次最初可见冷启动约 758 ms，作为环境准备样本单独保留，不混入上述正式 10 次统计。

内存：第 5 轮连接为 App 236.27 MiB/Core 41.70 MiB，断开为 232.97 MiB；第 20 轮连接为 233.36/43.44 MiB，断开为 226.12 MiB。最终断开空闲 2 分钟为 225.84 MiB，较第 5 轮断开基线下降约 3.06%，核心/代理/端口/TUN 均为 0，没有达到 +20% 调查阈值。

## 30 分钟能耗基线

| 状态 | 本地起止时间 | 时长 | CPU 增量 | Working Set | powercfg |
|---|---|---:|---|---|---|
| 断开空闲 | 13:18:44 ~ 13:48:48 | 30.06 min | App +5.469 s（约单核 0.30%） | 218.03 -> 217.56 MiB | exit 0 |
| 连接空闲 | 13:50:10 ~ 14:20:14 | 30.06 min | App +12.203 s（约单核 0.68%）；Core +16.188 s（约单核 0.90%） | App 211.86 -> 217.84 MiB；Core 46.05 -> 45.76 MiB | exit 0 |

- 断开报告：`%TEMP%\SSRVPN-Windows-UAT-v4.0.13-<session>\raw\energy-disconnected-30m.html`，42,898 bytes，SHA-256 `3a68eff592b7fea7ae3d34ca3cef7717bf3350ecd7f1cf09bfb6359e6d706978`。
- 连接报告：`%TEMP%\SSRVPN-Windows-UAT-v4.0.13-<session>\raw\energy-connected-30m.html`，42,898 bytes，SHA-256 `b9e3f7f13c78b1f6df03947e4339d539de1a20f2a95afeba629d0a6685844364`。
- 两份报告均为 9 errors / 6 warnings / 29 information。系统范围存在 lost trace events，`CpuAnalysisFailed=true`，内部可分析窗口只有 778/557 秒；这不改变外部 30.06 分钟 CPU time/Working Set 采样，但意味着不能把 powercfg 的内部 CPU 分析称为完整。
- 两组均记录到 SSRVPN 的 timer-resolution 请求；没有观察到持续高 CPU 或 Working Set 单调增长，因此未启动 WPR。系统另有与 SSRVPN 无关的后台显示/睡眠请求。

## 键盘与已剔除项目

默认缩放下的键盘路径实测通过：启动 -> 节点页 -> 诊断 -> Esc 关闭 -> 节点选择 -> 订阅页 -> 返回首页。目标焦点在截图中可见，顺序可重复。为了不泄漏节点名，截图只留在临时证据目录，不加入仓库；测试产生的首选节点变化已通过最终配置哈希恢复。

200% 文本缩放以及 Narrator/屏幕阅读器/盲文由用户明确要求跳过，均不记 BLOCKED，也不用于降低通过率。

## Windows 生命周期自动化审查

| 生命周期行为 | 现有确定性证据 | 实机证据/缺口 |
|---|---|---|
| 单实例、已有窗口激活 | `test_windows_proxy_shutdown_recovery.py` 的 launcher policy/source guards | 温启动 5/5 PID 复用 |
| 托盘隐藏、退出、失败恢复 | `tray_manager_test.dart`、`app_shutdown_test.dart` | 隐藏/恢复/退出通过；Explorer 重启用实机补足，未为外部 shell 行为重写 launcher |
| 正常退出清理 | `app_shutdown_test.dart`、installer runtime、program-file transaction | 20/20 轮清理通过 |
| guardian 启动/提交/重启边界 | 37 项 Windows proxy/shutdown harness，含原生 token/job harness | Flutter 子进程异常退出 877 ms 清理通过 |
| RunOnce/原生代理恢复 | 8 项 RunOnce Python、原生 C++ registry harness、Flutter recovery tests | 损坏日志 recovery-only 实机通过 |
| TUN UAC/取消/提交边界 | TUN runtime probe、start transaction、launcher guardian guards | UAC 同意与 3 组取消已实测；正式版提示失败 |
| 连接态节点提交 | 原测试不能捕获无害状态通知推进 epoch | 本分支新增 RED/GREEN 纯策略测试 |
| Windows 剪贴板换行/公网 IP | 原测试没有 Windows 回读换行和公网 IP 用例 | 本分支新增 RED/GREEN 测试 |

没有以“launcher 整文件覆盖率低”为理由重构 Win32 架构，也没有新增依赖。

## RED / GREEN 补强

| 缺陷 | RED | 最小修复 | GREEN |
|---|---|---|---|
| 无害状态通知使节点提交过期 | 测试证明“状态未变”错误返回 true | 先判断状态真实变化，再递增 epoch；纯策略移入独立 shared part | policy 2 项通过；Windows 全量覆盖率随后 234 项通过 |
| Windows 剪贴板真实写入被判失败 | CRLF/LF 用例失败 | 仅规范化换行后精确比较 | 诊断组件 20 项通过 |
| 诊断泄漏公网 IPv4 | 公网地址仍出现在脱敏结果 | 全局脱敏可路由公网 IPv4，保留本地/保留网段 | redactor 用例通过 |
| TUN 取消无成功反馈 | 缺少取消反馈策略，RED 编译失败 | 仅在 stop 成功且核心已退出时显示“连接已取消” | 取消策略 3 个断言场景通过 |
| Windows 命令行长度导致 hygiene 失败 | 单次 `xargs` 超过 Windows 命令行限制 | 每批最多 100 个文件 | Dart 335 文件 0 changed，ShellCheck guard 通过 |

## 门禁与退出码摘要

| 命令/门禁 | 退出码 | 摘要 |
|---|---:|---|
| `flutter pub get` | 0 | workspace 依赖解析成功 |
| `dart format --output=none --set-exit-if-changed .` | 0 | 335 files，0 changed |
| `flutter analyze SSRVPN_Windows` | 0 | no issues |
| `flutter analyze` | 0 | workspace no issues |
| `flutter test --coverage`（SSRVPN_Windows） | 0 | 234 tests passed |
| 三个新增回归文件 | 0 | 23 tests passed |
| `flutter build windows --release` | 0 | release exe 构建成功 |
| PowerShell 5.1 compatibility | 0 | 15 tracked scripts |
| package payload guard | 0 | passed |
| installer config Python | 0 | 33 tests |
| proxy shutdown/recovery Python | 0 | 37 tests |
| RunOnce recovery Python | 0 | 8 tests |
| secret scan Python | 0 | 2 tests |
| installer runtime | 0 | passed |
| Program Files transaction fault injection | 0 | passed |
| native proxy recovery C++ harness | 0 | passed |
| launcher security guard | 0 | passed |
| quality hygiene（Git Bash） | 0 | Dart format + ShellCheck passed |
| `test_windows_installer_package.ps1` 本机调用 | 1（预期保护） | 脚本要求 GitHub Actions；未绕过破坏性保护 |
| WSL `make verify` | 127 | WSL 未安装 make |
| WSL `scripts/verify-all.sh` | 1 | PATH 命中 Windows Flutter，CRLF shell 不可执行 |
| Git Bash `scripts/verify-all.sh` | 1 | Windows 相关前置门禁均通过；在 macOS TUN DNS symlink/permission 25 项中 2 项因 NTFS/Git Bash 语义失败 |

`verify-all.sh` 的最终失败属于 macOS 专属 symlink/权限用例在 Windows NTFS/Git Bash 上的环境限制；Windows Flutter、PowerShell、Python、installer、native、proxy、RunOnce 和 launcher 门禁均已在对应宿主上单独通过。

## 最终现场恢复

- 正式 4.0.13 保持安装。
- SSRVPN app/launcher、Mihomo 进程均为 0。
- 用户系统代理关闭；WinHTTP 保持测试前状态。
- 7890/7891/9090 无监听；TUN 设置恢复为测试前用户值（`enableTun=true`）。通用名称匹配的隐藏适配器测试前/后均为 1、Up 均为 0，相关路由测试前/后均为 0；SSRVPN 事务残留探针为 0。
- RunOnce `SSRVPNProxyRecovery` 和 `RuntimeProxyBackup` 均不存在。
- Windows 文本缩放恢复系统默认。
- 5 个被验收运行写入的设置/缓存/诊断历史/日志文件已从测试前备份逐文件恢复；最终 12/12 基线文件哈希一致。
- 原始日志、截图和 powercfg HTML 只保留在本机临时证据目录，不提交。

## 未完成与残余风险

1. 完整卸载/重装和旧版 -> 4.0.13 跨版本升级为 W-06 BLOCKED；需要明确授权和一个旧版基线。
2. 正式版诊断复制、连接态节点 UI 提交、TUN 取消提示仍然失败；分支修复已通过自动化和 release 编译，但尚未替换正式安装器做二进制实机复验。
3. TUN 连接时 Windows adapter/route 名称探针没有识别到对象；数据路径由“系统代理关闭 + 直连 204 请求”证明，适配器名称层证据仍有限。
4. `powercfg /energy` 两次都有系统级 trace loss；本报告的 30 分钟 CPU/内存结论来自同机进程计数器，不把不完整的 powercfg CPU 分析过度外推。
5. 第 1/20 轮有一个真实 TLS 探针失败，虽然后续 19 轮双站点全通过且清理 20/20 通过，仍保留为 C-09 FAIL。

本分支只提交 Windows 验收报告、相关最小修复和回归/门禁补强；不创建 PR，不合并 main，不打标签，不创建 Release，不触发发布工作流。
