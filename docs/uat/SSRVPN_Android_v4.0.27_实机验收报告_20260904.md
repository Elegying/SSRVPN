# SSRVPN Android v4.0.27 实机验收报告

## 1. 结论

2026-09-04 已在 USB 调试 Android 真机上完成 `v4.0.27+4027` 候选 APK 的断网与恢复专项
验收。飞行模式、Wi-Fi/移动网络完全断开、Wi-Fi/蜂窝切换、VPN 保持运行、断网诊断、恢复
后的 Google 与 Telegram 数据通道均达到本版发布标准。

v4.0.26 发现的诊断问题已经修复：真实完全断网后手动重新检查，应用显示“检查完成，发现
1 项提醒”，仅“节点与外部网络”为橙色提醒并给出 `DATA_PLANE_DEGRADED`；核心、配置、
运行状态、Android 原生会话与 Android TUN 继续显示正常。网络恢复后再次检查全部恢复为绿色。
诊断过程没有停止 VPN、重启应用或修改路由。

候选验收通过后，[#193](https://github.com/Elegying/SSRVPN/issues/193) 已关闭，随后才创建
注释标签 `v4.0.27` 并执行三端正式发布。macOS 本机网络按维护者要求始终保持在线，本轮没有
在 macOS 注入断网。

## 2. 验收对象与供应链身份

| 项目 | 结果 |
| --- | --- |
| 设备 / 系统 | Xiaomi 2509FPN0BC / Android 17（API 37） |
| 候选来源 | [Release workflow 33776553209](https://github.com/Elegying/SSRVPN/actions/runs/33776553209)，非标签候选构建 |
| 候选提交 | `40a0083cc96380488c40638a087a52eebab875e8` |
| 候选包身份 | `com.ssrvpn.android`，`4.0.27+4027` |
| 候选 APK SHA-256 | `43e88d7573b9f8015a8c8e48a0d5cd708fe229e0412c63be3616b02e5cdfad58` |
| 候选签名 | APK Signature Scheme v2 有效；证书 SHA-256 与仓库配置的正式发布证书一致 |
| 候选 provenance | GitHub Attestation 验证通过，签名工作流、`main` 来源和提交均匹配 |
| 安装方式 | 从已安装版本使用 `adb install -r` 覆盖安装，既有订阅、节点和设置保留 |

报告不包含设备序列号、节点名称、订阅地址、出口 IP、用户路径、未脱敏日志或截图。候选 APK
与正式 APK 都来自同一提交和同一签名发布链，但属于两次独立构建，二进制摘要不同；本报告的
真机操作对象是上表候选包，不把正式包的线上自动化冒充为第二次真机安装。

## 3. 实机验收结果

| 场景 | 结果 | 证据摘要 |
| --- | --- | --- |
| 覆盖安装与界面 | 通过 | 候选覆盖安装成功且用户数据保留；订阅页显示带文字的“运行日志”入口，应用版本为 `4.0.27` |
| 正常网络基线 | 通过 | 智能模式连接后 Android VPN 为 `CONNECTED/VALIDATED`；Google `generate_204` 返回 204，Telegram API 返回 200 |
| 正常诊断 | 通过 | 页面显示“运行正常，未发现异常”；核心、配置、运行状态、外部网络、Android 原生会话和 Android TUN 全部绿色 |
| 飞行模式完全断网 | 通过 | 关闭 Wi-Fi 与移动数据并开启飞行模式后，外部 HTTPS 请求真实失败；VPN 前台服务、Android VPN 网络和应用进程继续存在 |
| 断网诊断 | 通过 | 手动重新检查后只报告一项橙色外部网络提醒，文案说明核心、系统服务和配置仍保持连接；不再误报全部通过 |
| 飞行模式恢复 | 通过 | 关闭飞行模式并恢复 Wi-Fi，未点击连接或重启应用；数据通道自行恢复，Google 返回 204、Telegram 返回 200，再次诊断全部绿色 |
| Wi-Fi → 蜂窝 | 通过 | 开启移动数据并关闭 Wi-Fi 后蜂窝网络可用；Google 与 Telegram 继续成功，出口国家为新加坡，证明流量仍经当前代理路径 |
| 蜂窝完全断开 | 通过 | Wi-Fi 已关闭时再关闭移动数据，外部请求真实失败；VPN 服务、Android VPN 网络和同一应用进程保持 |
| 蜂窝断开后恢复 Wi-Fi | 通过 | 不手动重连，恢复 Wi-Fi 后约 3 秒恢复外部数据通道 |
| 最终状态恢复 | 通过 | 飞行模式关闭、Wi-Fi 开启、移动数据关闭，与测试前一致；VPN 保持连接，最终诊断与 Google/Telegram 数据通道正常 |

Android 系统在没有底层网络以及部分网络切换瞬间，普通 shell 视角下不一定持续展示 `tun0`；
因此本报告不声称该接口名称在每一秒都可见。可以确认的是 Android VPN 网络与前台服务持续
存在，应用原生 Bridge 的 TUN 状态保持正常，应用进程未重启，而且恢复物理网络后无需人工
重连即可恢复代理数据通道。

## 4. 正式发布结果

- 修复与发布准备分别经受保护 PR [#195](https://github.com/Elegying/SSRVPN/pull/195) 和
  [#198](https://github.com/Elegying/SSRVPN/pull/198) 合并；`main`、注释标签 `v4.0.27` 均
  指向 `40a0083cc96380488c40638a087a52eebab875e8`。
- 精确 [主分支 CI 33774884684](https://github.com/Elegying/SSRVPN/actions/runs/33774884684)、
  [Prepare Release 33782361025](https://github.com/Elegying/SSRVPN/actions/runs/33782361025) 和
  [Release 33782400613](https://github.com/Elegying/SSRVPN/actions/runs/33782400613) 全部成功。
- [GitHub Release v4.0.27](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.27) 已公开，
  是非 draft、非 prerelease 的不可变 latest Release，共七项预期资产。
- 独立下载后的正式 APK SHA-256 为
  `c001c392d89009753264d50fa4e0a3950ecd624ee430de5d04ac5be3e54b2847`，DMG 为
  `ea59a57af7f5556e0668973846adace608cc4514710a6ae738d7947873f28044`，Windows 安装器为
  `987231d64e1495c85c2f9e4116ab5966b39ecba30a11185377a05cc5bb4450d1`。
- 三份实际文件、sidecar、GitHub Release API digest、统一 provenance 与三份 GitHub
  Attestation 的摘要完全一致；attestation 同时限制签名工作流、标签来源、精确提交并拒绝
  自托管 runner。
- OSS `latest.json` 已指向 `4.0.27`。三个版本化安装包从 OSS 再次完整下载，SHA-256 与
  GitHub Release 一致且文件逐字节相同。
- Windows 管理员运行策略测试和正式安装器 smoke 均通过；项目既定的“主客户端和外层启动器
  均以管理员身份运行”规则没有修改。

## 5. 未覆盖边界

- 本轮是 Android 断网与恢复专项，不是抖音评论/私信图片连续 20 轮、30 分钟耗电、第二 VPN、
  多 OEM 或原生 16 KiB page-size 硬件完整矩阵。
- 没有在发布后把第二次独立构建的正式 APK 再覆盖到手机，以免为了重复证明同一提交主动中断
  已恢复的用户 VPN；正式 APK 的包身份、签名、摘要、冒烟与 provenance 已由独立发布校验确认。
- 本轮没有进行 macOS 断网；Windows 只完成线上策略、构建和安装器 smoke，没有新增人工桌面
  TUN/系统代理流量验收。
