# SSRVPN 三端 IPv4-only 与 IPv6 防绕过规范

## 目标

Android、macOS、Windows 客户端永久使用 IPv4-only 运行配置，以避免不完整的
底层 IPv6 网络造成连接等待；Android 与 Windows 另外捕获并拒绝 IPv6，以防止绕过
VPN，macOS 的禁用范围保持在 Mihomo 内部：

- 只请求 A 记录并建立 IPv4 连接；
- Android 与 Windows 的 IPv6 流量在 TUN 入口被捕获并拒绝；macOS
  只关闭 Mihomo 内部 IPv6，不修改系统全局 IPv6；
- 不改变“私网安全、用户代理/直连、服务分层、GFW/CN 和未知代理兜底”的 IPv4 规则顺序；
- 首页公网 IP 只展示 IPv4。

## 行为约束

1. 生成的 Mihomo 配置必须设置顶层 `ipv6: false` 与 `dns.ipv6: false`，且不得生成 `fake-ip-range6`。
2. 规则列表第一项必须是 `IP-CIDR6,::/0,REJECT,no-resolve`，优先于私网、用户、GFW/CN 和最终代理规则。
3. Android 原生 VPN 与 Windows TUN 必须声明 IPv6 捕获地址、接管 IPv6 默认路由且不得排除 ULA 或链路本地 IPv6。这些地址与路由只用于把 IPv6 送入拒绝规则，不代表支持 IPv6。macOS 保留已验证稳定的自动路由形态，不额外声明 IPv6 TUN 地址，也不修改系统全局 IPv6 开关。
4. IPv4 局域网排除项保持不变；IPv4 的私网安全、用户规则、服务分层、GFW/CN 与默认代理顺序保持不变。
5. 解析层可以继续识别历史订阅中的 IPv6 字面量，以安全地读取和展示数据，但运行时不保证这类节点可用。
6. 所有外部地址输入继续使用标准库解析，不拼入 shell，不新增依赖；非法、含区域标识或歧义输入按原有保守策略拒绝。
7. 首页公网 IP 使用 IPv4 专用端点，备用端点返回 IPv6 时必须拒绝展示。

## 验收标准

- 共享配置测试确认 `ipv6: false`、`dns.ipv6: false`、没有 `fake-ip-range6`，且 IPv6 拒绝规则排在第一项。
- Android、macOS 与 Windows 平台测试确认共享 IPv4-only 约束未被平台层覆盖；Android 与 Windows 另行确认 IPv6 防绕过捕获。
- Android 原生单元测试确认 IPv4 公网路由保持不变，同时保留 IPv6 地址与 `::/0` 防绕过路由。
- 公网 IP 服务测试确认主端点固定请求 IPv4，备用端点不会把 IPv6 返回给首页。
- 三端 Dart 测试、静态分析、配置语法校验与构建门禁通过。
- Android 真机连接后，生成配置满足 IPv4-only 约束，常用 IPv4 应用不再出现 IPv6 `network is unreachable` 重试，断开后路由正常清理。
- 代码审查确认 IPv6 没有直连或代理绕过路径。

## 非目标

- 不支持 IPv6 节点、IPv6-only 目标或公网 IPv6 访问。
- 不修改操作系统全局 IPv6 开关；禁用范围是 SSRVPN 生成的运行配置和 VPN/TUN 数据路径。
- 不新增 IPv6 连通性或营销判断。
- 不改变现有节点延迟测试、排序与显示逻辑。
