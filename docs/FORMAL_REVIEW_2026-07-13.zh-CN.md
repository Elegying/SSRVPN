# SSRVPN 三端正式版本五轮深审与五轮对抗审查

审查日期：2026-07-13

审查分支：`codex/ssrvpn-formal-review`

审查提交：`dfc2262`

审查基线：`v3.1.1` (`aac2cce`)

## 当前结论

Android、macOS、Windows 与共享层已经完成五轮不同方向的深度审查，以及
五轮独立的对抗性审查。当前审查范围内没有遗留已知的 P0、P1 或 P2 代码
缺陷；本地全量门禁与 GitHub 三端矩阵全部通过。

尚未把本轮标记为最终完成：指定 Android 手机仍处于锁屏状态，必须在用户
解锁后完成一次真实的“连接 A 节点、手动切换 B 节点、通知栏立即变化、熄屏
停止数字刷新、唤醒恢复、断开清理”回归。该缺口是实机证据缺失，不以单元
测试代替。

用户明确禁止修改的“私家车”延迟显示策略保持不变；结构守卫与既有三项策略
测试均通过。

## 五轮深度审查

| 轮次 | 审查方向 | 主要证据与结果 |
|---|---|---|
| 1 | 架构、职责与可维护性 | 进程生命周期、系统代理、配置生成和桌面运行时操作已拆成独立边界；主服务与 Android VPN Service 有行数守卫；剩余 900 行热点集中在 UI 组合和 Windows 打包工具，不在正式发布前做无行为收益的大重构。 |
| 2 | 启动、连接、切换、断开与崩溃恢复 | 检查三端启动编排、串行队列、重复操作合并、连接意图失效、核心停止超时、代理所有权和异常退出恢复；Android 未完成的 start 可在 1 秒宽限后强制回收进程，Windows 只终止 SSRVPN 自有核心。 |
| 3 | 网络路由、配置、订阅与解锁探针 | 检查 YAML/URI 解析、超大订阅、压缩膨胀、事务回滚、配置引用、Android 公网路由、重定向和响应体上限；解锁检测坚持服务专用证据，不确定时返回“无法判断”。 |
| 4 | 更新、安装与发布供应链 | 检查 OSS 优先与 GitHub 回退、下载取消、大小和 SHA-256、APK 清理、Windows 安装/迁移、Release 来源、来源清单、OSS 不可变路径、原子 `latest.json` 与失败恢复。 |
| 5 | 用户体验与平台产物 | 检查连接中可取消、节点国旗、通知节点实时更新、60 秒数字限频、熄屏暂停、Quick Tile 真实状态、中文教程、macOS Dock 重开、DMG 拖拽布局和 Windows EXE/ZIP 内容。 |

## 五轮对抗性审查

| 轮次 | 对抗场景 | 结果 |
|---|---|---|
| 1 | 随机测试顺序、并发 start/stop、快速切换与旧请求晚到 | 四个 Flutter 测试集使用随机顺序重跑通过；连接意图、异步初始化和串行恢复没有顺序依赖。 |
| 2 | 核心卡死、子进程持有输出管道、日志目录损坏、系统代理被其他软件修改 | 超时与清理测试通过；只恢复 SSRVPN 确认拥有的代理设置，不覆盖用户或其他软件后续修改。 |
| 3 | 恶意/损坏订阅、HTTPS 降级、跨域伪造解锁正文、超大正文和错误哈希 | 输入被拒绝或保守回退；不会因普通 HTTP 200、关键词或鉴权错误制造“支持”结果。 |
| 4 | 半成品 Release、旧提交重试、OSS 上传中断、恢复再次失败和回滚版本 | 只有已公开、完整、非预发行且来源/哈希一致的 Release 能授权旧提交恢复 OSS；发布前备份完整，恢复失败保留取证包。 |
| 5 | 真实平台构建、产物校验和安装包结构 | macOS 实机 DMG 与原生生命周期测试通过；GitHub Android/macOS/Windows 矩阵通过；Windows runner 实际生成安装 EXE 和便携 ZIP，并通过冒烟与 SHA-256 校验。Android 最终通知栏操作回归待解锁。 |

## 本轮审查发现并修复的问题

1. Android 公网路由表缺少 `102.0.0.0/7`，会遗漏 `102/8` 和 `103/8`；已
   恢复并加入路由覆盖回归测试。
2. Android 节点切换成功后通知栏没有实时更新；现在由确认成功的代理切换
   触发原生通知更新，并同步持久化冷启动节点。
3. Android 通知数字刷新过于频繁；现在状态变化立即更新，流量数字每 60 秒
   最多更新一次，熄屏停止周期刷新，亮屏重新采样。
4. 旧提交可借助完整草稿 Release 进入重试路径；现在只有已公开正式 Release
   能授权旧提交执行 OSS 恢复。
5. macOS Finder 布局的超时包装器会在交互式终端预读 stdin 到 EOF，可能
   在启动子进程前卡住；现在直接透传 stdin，并加入“调用者不关闭 stdin”
   的回归测试。
6. 普通 CI 漏掉新增的来源清单、旧提交重试和超时包装测试；CI 已补齐，与
   发布工作流的门禁保持一致。

## 验证证据

| 检查 | 当前结果 |
|---|---|
| `scripts/verify-all.sh` | 全部通过；Workspace analyze 零问题 |
| 发布/故障工具 | 47 项通过 |
| `ssrvpn_shared` | 234 项通过，68.29% 行覆盖率（门槛 50%） |
| Android Flutter | 96 项通过，58.33% 行覆盖率（门槛 40%） |
| Android Kotlin/JUnit | 通过，含并发操作、通知策略和公网路由 |
| macOS Flutter | 44 项通过，33.89% 行覆盖率（门槛 10%） |
| macOS 原生 XCTest | 4 项通过，覆盖 Dock 重开、退出清理和自有核心路径 |
| macOS DMG | arm64 构建、ad-hoc 签名结构、映像校验、挂载、Applications 链接和中文教程通过；SHA-256 `7d6cbc0762d43db4a69da66ad786b4fcc8ee71e6ec1dbdb2b9964bd01861d8f8` |
| Windows Flutter | 38 项通过，1 项因本机不是 Windows 按预期跳过，15.99% 行覆盖率（门槛 12%） |
| GitHub PR CI | Run `29205517230`：Workspace、Android、macOS、Windows 全绿 |
| Windows CI 产物 | `SSRVPN_Setup.exe` 31,875,908 bytes；`SSRVPN.zip` 41,414,994 bytes；两项 SHA-256 校验通过，ZIP Unicode 中文教程和入口文件存在 |
| Android 指定手机 | `3.1.1-debug (311)` 已覆盖安装，测试节点已准备；手机锁屏，最终通知栏回归待执行 |

## macOS TUN 结论

macOS TUN 不是当前可以低风险顺手修复的小问题。正式实现至少需要：

1. Apple Developer Program 和可用于发布的 Developer ID；
2. Network Extension 或 System Extension entitlement；
3. Packet Tunnel Provider 或经过签名的特权辅助组件；
4. 安装授权、升级兼容、卸载清理、代码签名和 notarization；
5. 对 DNS、IPv4/IPv6、休眠唤醒、网络切换和崩溃恢复做单独实机矩阵。

当前代码在核心启动前安全拒绝 macOS TUN，自动迁移旧设置到系统代理，并在
界面明确显示“暂不可用”。不得恢复旧的 setuid root 或直接以 root 运行 Mihomo
方案。

参考 Apple 官方文档：

- [Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [System Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 剩余限制与下一步

1. 解锁指定 Android 手机，完成最后一项通知栏实机操作回归。
2. 在真实 Windows 11 或干净虚拟机执行安装、运行中覆盖升级、连接、退出和
   代理恢复矩阵；CI 已证明构建与脚本正确，但不能代替用户桌面交互。
3. 在下一次正式发布前配置 macOS Developer ID/notarization 与 Windows
   Authenticode，降低 SmartScreen 和 Gatekeeper 警告。
4. 后续只按屏幕区块拆分纯 UI 热点，不再扩大核心生命周期、代理和配置文件。
5. 官方页面变化时，解锁探针继续回退到“无法判断”，绝不制造“支持”的假结果。

