# 双栈兼容复审与验证：2026-09-17

状态：本地候选，未提交、未发布，未替换用户当前客户端。
基线：`712a6d02173628b1ba39545e116a07d991154102`，含本轮未提交修改。

## 本轮发现与修复

1. Android 与共享桌面手动规则弹窗仍以 `host.contains(':')` 拒绝 IPv6。
   共享解析、持久化与规则生成原本已支持 IPv6，因此仅移除 UI 的过时拒绝条件，
   保留完整地址校验。强制代理、强制直连均生成 `/128` 精确规则；非法 IPv6、
   区域标识、多目标输入仍拒绝。补测三端实际弹窗输入、保存和共享规则生成。
2. 诊断弹窗没有继承页面的壁纸纹理来源，存在退回实时背景取样、混入前景卡片的路径。
   已共享来源并验证缩放、嵌套弹窗与前景隔离。具体说明见
   [弹窗背景复审](dialog-wallpaper-capture-20260917.md)。尚未做安装后的 GPU 验收。
3. 双栈实现审查中已确保只将真正尝试过的 IPv6 计入失败观察；候选列表中存在但
   尚未拨号的 IPv6 不应产生提醒。该修复包含于下面的最终核心摘要。

原有 Windows TUN 恢复记录诊断误报修复仍保留：活动会话的恢复保护记录不再
直接视为历史残留，真正待恢复的记录不清除、不隐瞒。

## 新增深入验证

`scripts/check-core-dual-stack-protocols.py` 启动两份隔离核心，使用临时本机
SS / Trojan / AnyTLS 服务端、独立 DNS、IPv4 / IPv6 HTTP 与 UDP 回显目标。
不使用用户节点，不修改系统代理、路由、DNS 或用户 VPN。TLS 测试信任临时测试证书，
保持证书校验开启，没有使用 `skip-cert-verify: true`。

三种协议均验证通过：

- 双栈目标实际抵达 IPv4 服务；IPv6-only 与 IPv6 字面地址抵达 IPv6 服务。
- 实际加密 TCP 载荷完整收发，非单纯端口连通性。
- UDP 往返、同一源端口/关联中 IPv4→IPv6→IPv4 的目标映射与载荷一致。
- A 查询无响应、AAAA 可用，以及 AAAA 无响应、A 可用，仍能完成访问。

原有 `check-core-dual-stack.py` 补充到验证入口，覆盖 HTTP CONNECT/SOCKS5、
IPv4 目标失败后 IPv6 回退、DNS 失败后保留原节点远端解析、IPv4/IPv6 DIRECT、
HTTPS 主机名/SNI、错误证书拒绝、IPv6-only 失败后核心与其他访问继续工作。
`check-routing-core.py` 验证智能、全局、保守规则和恢复规则下的手动覆盖及代理兜底。
`check-core-proxy-traffic.py` 验证仅代理流量统计，避免影响已有节点流量功能。

这些是 macOS 主机上的隔离真实核心验证，不能等同 Windows/Android TUN 真机通过；
也不能证明之前用户提供的特定 SS 节点已经可用。

## 自动化结果与首次失败记录

固定 Flutter 3.44.1；本机 Xcode 测试使用临时 12.0 deployment override，
生产工程的最低系统配置没有改动。

| 检查 | 结果 |
| --- | --- |
| 三端核心源码测试与重建 | 通过；包含 config、tunnel、统计、outbound、route、resolver |
| 核心摘要、Android ELF/构建信息、macOS 特权资源契约 | 通过 |
| Android 完整 Flutter | 340 通过 |
| macOS 完整 Flutter首次 | 345 通过，1 项 30 秒超时；该用例单独补跑通过 |
| Windows 完整 Flutter首次 | 318 通过，7 跳过，3 项更新弹窗等待超时；相关文件及 TUN 诊断补跑 42 通过、3 跳过 |
| shared 完整 Flutter首次 | 1347 通过、1 跳过；新弹窗测试编辑期间缺 import 导致该文件编译失败，已修正并补跑 |
| 最终共享规则/设置/弹窗定向回归 | 59 通过 |
| 三端手动 IPv6 输入保存回归 | Android 3、macOS 2、Windows 2 通过 |
| Android 原生 | 191 通过，0 失败，0 跳过 |
| macOS 原生 | 固定 Flutter 版本重跑退出 0，含原生测试后的崩溃/残留门禁 |
| 发布工具测试 | 437 通过；核心工具定向 8 通过 |
| 四套覆盖率门禁 | 通过；shared 89.36%、Android 71.10%、macOS 73.63%、Windows 60.80% |
| 最终静态检查 | 四套 analyze、格式/ShellCheck、文档一致性、职责边界、秘密扫描、diff 空白检查通过 |

首次 `make verify` 在新增 Dart 格式提示处停止，修复后按原入口补跑后续项目。
中途原生命令曾误用机器另一套 Flutter，分别遇到 SDK 二进制不匹配/工程配置问题；
切回固定版本后重跑成功。完整测试并发过高时出现超时，降低并发后补跑通过。
不将上述过程描述为“一次 make verify 全绿”。

## 最终核心身份

- 扩展源码：`95c9472f4f4909c4726bb8453882330464f02645e44d4201bc5d5754720b35a9`
- macOS gzip：`afe3bdec05c62fd79adb4c3b36271e1200f427d0af2dfa60489fe64dadf5b1cd`
- Windows exe：`5f3efc9ee9e975f0b5451f758b1bb5b35d6d474fd59807ff6e8fd01c273ad9b8`
- Android so：`7267825f5c0840cb5d9f1922277b9a903439eadf9157d1750b7f02150ec7dad2`

三端来源清单及 macOS 特权启动固定摘要已同步。镜像名称只表示预期资产身份，
没有在本轮上传镜像或发布新版。

## 仍需真实环境验收

- Windows、Android 的真实 TUN、IPv4-only/双栈接入网、目标节点出口 IPv6 能力。
- 国内 IPv6-only 在本地没有 IPv6 出口时无法直连，不能通过地址选择凭空解决。
- 原核心连接总预算及重试上限保留；一次拨号耗尽预算时不保证尝试全部地址。
- 部分协议没有远端连接确认，UDP 静默无法可靠归因为节点不支持 IPv6。
  失败观察不会自动切节点、泄漏为直连或断开整个 VPN。
- 智能规则命中直连目标才直连，未知目标仍代理；未被 GFW 名单收录不等同确认可直连。

本轮未发现上述已覆盖隔离用例中的新转发失败，但不据此宣称所有网络和节点零故障。

## 补充复审：升级兼容、规则回滚与本地端口

本次复审未确认新的产品故障，保留现有运行代码，新增三条回归用例：

- IPv6 loopback 独占 UDP 端口、IPv4 TCP 同端口可绑定时，混合代理端口检查仍拒绝复用。测试使用真实本地 socket；主机不支持 IPv6 loopback 时明确跳过，本机执行未跳过。
- 新双栈配置触发规则恢复后，只切回已确认规则包，顶层 IPv6 开关、DNS、TUN 地址、节点配置和手动 IPv6 规则保持不变。
- 旧 IPv4 配置触发同一恢复流程后，原开关、捕获地址和旧规则保持不变，规则回滚不擅自迁移网络策略。

另复核了系统禁用 IPv6 时的端口探测错误分类、Windows 核心使用安装目录文件的路径，以及 Android 启动时重建统计会话的调用；这些为源码核验，不冒充 Windows/Android 本轮实机验收。

验证入口（共享包目录，固定 Flutter 3.44.1，单 worker）：

```sh
flutter test --concurrency=1 test/runtime_port_allocation_test.dart test/smart_rule_recovery_test.dart test/force_proxy_site_policy_test.dart test/app_settings_test.dart
flutter analyze --no-pub
```

最终结果：39 项通过、0 跳过；静态分析无问题，格式与 `git diff --check` 通过。首次新增测试的 import 位置错误导致编译失败，修正后重新跑完上述测试。此次只增加回归测试与报告，没有更换用户安装包、改动系统网络、推送或发布。
