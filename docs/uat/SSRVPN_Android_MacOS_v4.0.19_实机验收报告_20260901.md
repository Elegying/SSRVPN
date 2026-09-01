# SSRVPN Android / macOS v4.0.19 实机验收报告

- 验收日期：2026-09-01（Asia/Shanghai）
- 正式版本：`v4.0.19+4019`
- 正式提交：`027baad349bd9cd071c5387a47abd692d665d0a8`
- 正式 Release：[v4.0.19](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.19)
- Android：Redmi Note 8，Android 11 / API 30，arm64-v8a，4 KiB page size
- macOS：MacBook Air（Apple M1，8 GB），macOS 26.6.2（25G83），arm64
- 原始证据：本机临时目录及 Android `logcat`；不提交订阅、节点凭据、设备序列号、用户名路径或未脱敏日志

## 结论

Android 正式 APK 的安装、首次启动、VPN 授权拒绝后重试、真实 VPN 数据路径、通知、快捷
磁贴、同版本覆盖安装、30 分钟 Doze、Wi-Fi 中断恢复、TalkBack、200% 字体、诊断复制和
进程恢复均取得真机证据。正式 APK 可以建立系统 `CONNECTED/VALIDATED` VPN 和 `tun0`，
真实 HTTPS 探针返回 HTTP 204；恢复路径不会遗留 `tun0` 或 7890/7891 数据端口。

但 Android **不满足当前版本放行条件**：快速连接/断开第 2 轮、正常节奏循环第 5 轮均出现
自有 TUN lease 无法确认释放，随后应用按 fail-closed 设计自终止进程并由恢复 Activity 拉起。
资源最终清理是安全的，但 C-03 明确要求 20 轮不崩溃、不终止进程，因此必须判定失败。问题
已记录为 [#167](https://github.com/Elegying/SSRVPN/issues/167)。

macOS 正式 DMG 的摘要、镜像、布局、版本、arm64 架构和 ad-hoc 签名已核实。系统代理和
TUN 两种模式都取得真实数据路径证据；正常断开、GUI 异常退出和 TUN 授权取消后，代理、
DNS、路由、核心与监听均恢复。持续离线取消没有取得有效证据，保持“未执行”，不以一次
短暂网络切换或自动恢复冒充通过。

项目免费分发边界维持不变：macOS 不采用 Developer ID 或 notarization，Windows 不采用
Authenticode；这两项不是缺陷或待办。

## 正式资产

| 资产 | SHA-256 | 结果 |
| --- | --- | --- |
| `SSRVPN.apk` | `8f1cbf8f45f879a400c57623db53f3fa72ad9001f4d720e14b0df5b6d3b0b09b` | 与 sidecar、provenance 和 GitHub digest 一致 |
| `SSRVPN.dmg` | `aac40e6634265f6d1d32d15489d59648a06a080dd6fee9b6916fb990942d3727` | 与 sidecar、provenance 和 GitHub digest 一致 |

Android APK 通过 APK Signature Scheme v2 校验；安装后系统报告 `versionName=4.0.19`、
`versionCode=4019`、`minSdk=24`、`targetSdk=36`。DMG 通过 `hdiutil` 完整校验，包含
`SSRVPN.app` 和 `Applications` 链接；应用为 arm64，`CFBundleShortVersionString=4.0.19`、
`CFBundleVersion=4019`、`Signature=adhoc`、`TeamIdentifier=not set`，与既定策略一致。

## Android 真机结果

| ID | 状态 | 实机证据 |
| --- | --- | --- |
| C-01 | PASS | 全新安装后冷启动成功，约 2.13 秒进入首页；首次教程可正常关闭，无 crash 或 ANR。MIUI 首次 USB 安装要求用户确认，确认后安装成功。 |
| C-02 | PASS | 导入自控 HTTP 测试节点后延迟为 10–54 ms；“全部刷新”取得 1 个节点、0 个分组且不破坏当前连接，节点选择和订阅在覆盖安装后仍保留。 |
| C-03 | **FAIL** | 快速循环第 2 轮、正常 2.5 秒连接/2 秒断开节奏第 5 轮均触发进程自终止；未达到 20 次同进程稳定性标准。 |
| C-04 | FAIL | 最终状态与断开操作一致且无残留，但快速重复操作进入进程终止恢复路径，因此不能记为通过。 |
| C-05 | PARTIAL | 关闭 Wi-Fi 后同一 PID 和 VPN 会话保留，真实 HTTPS 探针在 10 秒预算内失败；恢复 Wi-Fi 后同一会话自动重新取得 HTTP 204。设备无 SIM，蜂窝切换保持 BLOCKED。 |
| C-06 | PASS（状态与数据） | 锁屏强制 Doze 30 分钟后保持同一 PID、前台 Service、通知、`tun0` 和 `CONNECTED/VALIDATED` VPN，真实 HTTPS 探针仍返回 204。USB 供电使本轮不能作为耗电证据。 |
| C-07 | PASS | 保护性进程终止后应用自动恢复为可操作的未连接状态，不复用陈旧 TUN；最终无 `tun0`、7890/7891 监听或假连接。该 PASS 不抵消 C-03。 |
| C-08 | PASS | 应用准确显示版本 4.0.19，当前版本未出现错误的升级提示。 |
| C-09 | PASS | 实际启用 TalkBack 与 200% 字体；关键控件可取得读屏焦点并由键盘顺序到达，`logcat` 没有 RenderFlex overflow。测试后已恢复设置。 |
| C-10 | PASS | 诊断报告写入后读回完全一致；对真实剪贴板做不输出正文的扫描，URL、非回环私网 IP、本机用户名路径及 fixture 敏感值命中均为 0。 |
| A-01 | PASS | 首次 VPN 系统授权点“取消”后应用显示连接异常且无 `tun0`；重试点“确定”后成功连接。 |
| A-02 | PARTIAL（OEM 限制） | 常驻通知显示当前节点与实时速率；MIUI 通知面板没有显示应用提交的“断开”动作。快捷磁贴可真实连接/断开，Flutter、Service、系统 VPN 与 TUN 状态一致。 |
| A-03 | PASS | 保护性进程终止后应用自动恢复为可操作的未连接状态，不复用陈旧 TUN；触发终止本身仍计入 C-03 失败。 |
| A-04 | PARTIAL | 锁屏、强制 Doze 30 分钟和 Wi-Fi 中断/恢复通过真实数据探针；设备无 SIM，蜂窝切换及 OEM 白名单设置仍为 BLOCKED。 |
| A-05 | PARTIAL | VPN AppOp 改为拒绝后，下一次连接重新出现授权对话框；取消不建立 `tun0`，重试确认后恢复真实 HTTP 204。没有第二个 VPN 应用，竞争场景保持 BLOCKED。 |
| A-06 | PASS（同版本覆盖） | `adb install -r` 覆盖 v4.0.19 成功；版本仍为 4019，订阅、当前节点和未连接状态保留。未把同版本覆盖称为跨版本升级。 |

### Android 真实数据路径与失败摘要

Mac 上的隔离本地直连代理作为 UAT fixture，Android 通过应用正常导入节点并建立
`VpnService`。连接后系统 `NetworkAgent` 报告 `CONNECTED` 和 `VALIDATED`，`tun0` 具有
IPv4/IPv6 地址及默认路由；设备内不显式指定代理访问
`https://www.gstatic.com/generate_204` 返回 204，同时 fixture 流量计数增加，证明流量实际
经过 VPN 数据面。

两种循环节奏均出现以下脱敏日志：

```text
Bridge.stop returned
Bridge stopped but the owned TUN lease is still present
Bridge shutdown could not be verified
Core shutdown incomplete; terminating process to release the detached TUN fd
```

进程终止后新 PID 正常启动，旧 `tun0` 和数据端口均被操作系统释放。安全兜底有效，但 TUN
release verifier 在该 Android 11 设备上不满足稳定性要求；修复不得简单移除 fail-closed 终止。

## macOS 真机结果

| ID | 状态 | 实机证据 |
| --- | --- | --- |
| M-01 | PARTIAL | 正式 DMG 完整校验、只读挂载、应用版本、架构、布局和 ad-hoc 签名通过；未把 CLI 挂载冒充带 quarantine 的首次 Gatekeeper/右键打开体验。 |
| M-02 | PASS | 系统代理连接后 HTTP/HTTPS/SOCKS 均为 `127.0.0.1:7890`，核心和 7890/7891/9090 监听存在，显式代理 HTTPS 返回 204；正常断开与强制结束 GUI 后，guardian 均恢复代理并清理核心/监听。 |
| M-03 | PASS | TUN 授权取消后没有假连接、root 核心、监听或启动阶段文件；授权同意后存在 root 核心、`utun4`、捕获路由和 `198.18.0.1`，普通 HTTPS 返回 204，DNS 得到 Fake-IP。正常断开后全部恢复。 |
| M-04 | PASS | Cmd+Q、重新启动和单实例行为正常；异常退出恢复后重启显示未连接，用户订阅保持。 |
| M-05 | PARTIAL | 系统代理/TUN 正常断开和异常退出均恢复 DNS；持续离线取消没有有效执行，保持“未执行”。测试中一次 Wi-Fi 服务不可用被立即恢复并完成代理、DNS、DHCP 与 HTTPS 204 复核，不把该过程记为通过证据。 |
| M-06 | PARTIAL | 正式 DMG 与已安装 App 均为 4.0.19+4019；本轮不覆盖 `/Applications` 中同版本应用，避免无必要改写用户安装。 |

### macOS 系统状态与 DNS 边界

- 系统代理模式：连接期间只有本应用拥有的 HTTP/HTTPS/SOCKS 代理被启用；正常断开和 GUI
  异常退出均恢复测试前的关闭状态。
- TUN 模式：系统代理始终关闭；授权成功后 Wi-Fi DNS 临时使用项目配置，流量由 `utun4`
  捕获。断开后 root 核心、`utun4`、捕获路由、7890/7891 监听和启动阶段文件消失，Wi-Fi DNS
  恢复为自动。
- 授权取消：应用报告连接错误，不制造已连接状态，不留下 root 核心、端口、DNS 或路由。
- 最终状态：Wi-Fi 已开启并取得 DHCP 地址，HTTP/HTTPS/SOCKS 均关闭，DNS 为自动，Wi-Fi
  指定接口访问 HTTPS 探针返回 204；没有 SSRVPN 核心或 7890/7891/9090 监听。

## 16 KiB、OEM 与未执行边界

Redmi Note 8 的内核 page size 为 4 KiB。仓库门禁验证正式 Android core 为 AArch64、含 JNI
ABI，四个 ELF `LOAD` 段对齐均为 16384；这只证明打包兼容性，不替代原生 16 KiB page-size
真机安装、启动、连接、断开和升级 UAT。

MIUI 允许 USB 安装；SSRVPN 处于 active standby bucket，Android 前台 VPN Service 和常驻
通知可在强制 Doze 中保持。OEM 自启动/省电白名单没有可移植的标准 AppOps 证据，不能概括为
“所有 OEM 后台限制通过”。macOS 持续离线取消因会中断测试主机的诊断与联网能力，不再采用
关闭网络服务的方式执行，本轮保持未执行。

## 最终现场恢复

- Android：停止并移出本地 fixture，清除应用测试数据、订阅、节点和快捷磁贴；VPN AppOp
  恢复默认，字体、TalkBack、自动旋转和 Doze 状态恢复，系统无 `tun0`。
- macOS：Wi-Fi 开启、DHCP 和 HTTPS 204 正常；代理关闭、DNS 自动，无 SSRVPN 核心、TUN
  启动阶段文件或 7890/7891/9090 监听。用户订阅保持不变。

## 未解决风险

1. Android C-03/C-04 因可复现的 TUN lease 校验失败而不通过；[#167](https://github.com/Elegying/SSRVPN/issues/167) 是客户端发布阻断项。
2. 4 KiB 设备不能补齐原生 16 KiB page-size 硬件证据。
3. 没有第二个 VPN 应用和蜂窝网络，竞争 VPN 与蜂窝切换保持阻塞。
4. USB 调试期间设备持续充电，30 分钟后台测试只证明状态与数据路径，不形成可靠耗电基线。
5. macOS 持续离线取消没有有效证据，明确保持“未执行”。
