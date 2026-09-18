# Clash Verge Rev 与 SSRVPN 双栈实现对照

日期：2026-09-18。源码审查不是两款客户端在同机、同网、同节点上的故障率测试。

## 样本身份

- Clash Verge Rev 正式版：v2.5.2，提交 `28f2efc504059b1dc75c793618b775c8e1b2a5f1`。
- Clash Verge Rev 开发分支：`c599f5547ec98cf998626a30c0003b41a5bd5579`。不能把开发分支新增代码算作正式版能力。
- SSRVPN：PR #254 的 `b801970466673a6c034fab37e571b80159e5bd39`，加本地未提交修复。
- SSRVPN 三端核心锁定信息见 `native/proxy_traffic/sources.json`；本轮未升级上游版本。

## 数据路径及主要差别

Clash Verge Rev：订阅配置 → 应用默认配置/TUN 与 DNS 联动 → 用户 Merge/Script 与受保护设置 → Mihomo → 规则 → 原生出口。

SSRVPN：仅提取订阅节点 → 客户端生成规则/DNS/TUN → Mihomo → 规则 → SSRVPN 目标处理扩展 → 原生出口。

| 层次 | Clash Verge Rev | SSRVPN 当前候选 |
| --- | --- | --- |
| 顶层 IPv6 | 正式版和开发版模板均为 true | true |
| TUN 栈 | 默认 gvisor | 默认 gvisor，可按设置生成 |
| 自动路由/检测接口 | 模板均开启 | 开启 |
| Windows strict-route | 模板 false，可受设置影响 | true |
| macOS strict-route | 模板 false | false |
| DNS 与 TUN 联动 | Fake-IP 模式开启 TUN 时同步 dns.ipv6，补缺失的 IPv6 池 | 共享生成器明确配置双栈池，接口与 Fake-IP 使用不同前缀 |
| DNS 来源 | 保留订阅/覆盖配置；DNS 设置覆盖默认不开启 | 客户端统一生成，分开节点入口、DIRECT、PROXY 解析 |
| DNS 设置页模板 | respect-rules=false，direct-nameserver 为空；不代表每位用户的最终配置 | respect-rules=true，DIRECT 独立解析器，手动规则优先 |
| TCP/UDP 目标选择 | 审查的 GUI 代码没有自建目标族回退器，主要交给下载的 Mihomo | 有自定义目标候选、TCP 回退和本轮 DIRECT 修复，验证责任更重 |
| 网络变化 | 开发版 macOS network_watch 重设系统代理；不是 IPv6 Internet 能力检测 | 核心原生接口监控刷新接口/DNS 缓存；本轮复用这一机制 |
| IPv6 Internet 能力 | 未在所审查 GUI 路径找到完整的出口探测/能力状态机 | 本轮仅识别“物理源地址明确只有 IPv4”；GUA/ULA 存在仍为未知 |

Clash Verge Rev 的 `prebuild.mjs` 下载官方 Mihomo 正式/Alpha 制品，不应从 GUI 版本号推断用户实际核心版本。正式版和开发版配置也存在差异：TUN 自动补全的 IPv6 Fake-IP 前缀由正式版的 `fdfe:dcba:9876::1/64` 改为开发版的 `2001:2::0/64`；开发版 DNS 设置初始化仍有旧前缀，不能把所有入口概括成同一值。

Mihomo 官方文档说明，未跳过系统 IPv6 检查时，TUN IPv6 可能因本机接口能力检查而被禁用。Clash Verge Rev 所审查 GUI 未设置 `SKIP_SYSTEM_IPV6_CHECK`。SSRVPN 则对显式捕获地址保留双栈接管，这是维护者要求的额外边界。是否触发上游检查，还取决于用户最终配置、环境和实际核心版本，不能据此直接证明某次抖音故障原因。

## 稳定性判断

现阶段更适合把 Clash Verge Rev 正式版作为对照基线：GUI 对底层转发的自定义较少，减少了跨核心版本的适配面。这里是工程风险判断，不是同机实测得出的排名。

SSRVPN 的统一规则、双栈强制捕获、禁止 PROXY 失败转 DIRECT 有明确产品目标，但目标严格不等于实现更稳定。PR #254 和本轮改动仍需完整的平台验收。不能宣称 SSRVPN 的 IPv6 可靠性已经优于成熟客户端，也不能声称 Clash Verge Rev 对所有 IPv6-only、QUIC、切网情况都有保证。

最值得借鉴：保留域名让原生出口工作、最终生效配置可审计、配置合并后的语义测试、系统网络变化的生命周期处理。不要机械照抄 strict-route=false 或 DNS 模板；Windows strict-route 涉及多网卡 DNS 防泄漏，也可能有应用兼容性代价，需要隔离变量的 A/B。

## 本轮证实并修复的共享缺口

1. DNSMapping 恢复的真实 AAAA 在 DIRECT 候选中经过 `Pure()` 丢掉域名。旧代码的 TCP 依赖失败后补试，UDP 没有对应失败回退。新增测试先在旧代码失败，显示域名为空且固定 IPv6。
2. 在规则已经选定 DIRECT 后，仅对已恢复域名的 IPv6 DNSMapping 清除拨号用 DstIP，保留域名给原生 TCP 竞争和 UDP 解析。显式 hosts、内部请求、无域名字面地址、仅嗅探域名、拒绝出口保持原义。路由与日志用原始元数据不修改。
3. 明确只有 IPv4 源地址的物理出口，对 DIRECT 的域名先查 A，避免 AAAA 先到而 A 稍慢的部分解析结果绕过 IPv4。没有 A 时仍交回原解析器，不编造地址，不改成其他出口。
4. 复用 `iface.ResolveInterface` 的 20 秒缓存和核心接口变化刷新；不对每条连接运行外部探测、PowerShell 或网络配置命令。不增加启动等待。
5. 此判据不是完整 Internet 能力认证：存在 GUA/ULA 但没有默认路由/外网的情况仍交给原生双栈逻辑。不得据此显示“IPv6 出口已验证可用”。

本轮代码：`native/proxy_traffic/target_address.go`、`direct_fallback.go`、三端 direct.go 补丁和对应测试。三端核心重建后同步来源摘要及 macOS 特权启动器固定摘要。保留之前“成功后 5 秒、3 地址两轮”探测修改。

## 构建身份

- 扩展源码摘要：`92cbc9bee36f2e692578ae90e89edd1c9b4f7d23bb7230f26df817b328c670fe`。
- macOS 核心归档：`2a4b7ba3ce811575c5ce127f87d32ed83b5f904cefc38b754850f4255480b524`。
- Windows 核心：`a86c57a0384a71564e482147058fc88ca1a5805002a9c84653827848d64e881f`。
- Android 核心：`5326a535c157d489d9f045a78e436e000f24701edae13eba5c7cefd11f313707`。
- 已构建的 Mac 应用为 5.0.11+5011，内置上述新核心；已安装应用仍含旧核心归档 `9cf5ea6a97f1af81d76c0d6946ab69119a91e763f9a7e71c2a78f7c872c42e7e`，未替换安装，不能混称真机候选通过。

后续安装和追加修复见 [晚间增量验收](../uat/SSRVPN_双栈候选晚间增量验收_20260918.md)。以下未安装/未提交状态是本轮源码对比完成时的历史快照。

## 验证边界

- 新增原生 TCP 应用数据收取、UDP 双向收发验证，覆盖双栈结果中的不可达 IPv6 + 可达 IPv4，以及 IPv6-only 本地目标。
- 扩展真实核心脚本 `scripts/check-core-dual-stack.py`：真实 AAAA 的 DNSMapping 进入核心后，经 DIRECT 的 IPv4 完成 TCP 请求和 UDP 回包，UDP 回包恢复应用原 IPv6 身份。旧已安装核心在该新增映射用例超时；新核心完整矩阵通过。不同出口使用独立 UDP 源 socket，避免把原生 UDP 会话固定出口误当成逐数据报重新分流。
- 新增 DNSMapping 经过 UDP 二次 Pure、拒绝/内部/hosts/字面地址保护、源地址分类、A/AAAA 部分返回和取消测试。
- 三端固定上游和工具链重建核心；Windows 源码测试在 macOS 主机执行，Windows exe 是交叉编译，不是 Windows 原生验收。
- 本机真实核心双栈矩阵及 SS/Trojan/AnyTLS 的九组加密数据路径通过，含失败不转 DIRECT、错误证书拒绝、其他连接继续可用。
- UDP 收发不等于真实 HTTP/3/QUIC 应用完整验收；没有把抖音全功能、Hysteria2 远端 IPv6 能力、真实切网/睡眠、所有十种网络矩阵写成通过。
- 未完成独立的默认路由 + 实际 IPv6 Internet 探测状态机；网络变化事件未覆盖时依赖最多 20 秒的接口缓存刷新，既有 UDP 会话没有重放或强行迁移。
- 本机 Xcode 27 不支持仓库 macOS 11 部署目标。默认 Mac 应用构建失败；仓库外临时设为 macOS 12 后本地候选构建成功，不修改发布兼容目标，不等同于 macOS 11 构建/实机通过。
- 在仓库外 macOS 12 本地构建配置下运行 `make verify`，退出码 0：共享 1362 通过/1 跳过；Android Flutter 341；macOS Flutter 348；Windows Flutter 323/7 跳过。Android 原生、macOS 原生、四包 analyze、核心资产及特权摘要、DNS 恢复 28 项、发布工具 442 项和覆盖率门禁均通过。Windows Flutter 测试运行于 macOS，跳过项不等于 Windows 真机通过。
- 新的真实核心映射回归在完整门禁之外另行运行通过；旧核心对照超时。Mac 候选严格签名校验通过，尚未安装替换。
- 当前仍不可据此宣称正式发布验收完成；没有提交、推送或发布。

## 来源

- [v2.5.2 配置模板](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src-tauri/src/config/clash.rs)
- [v2.5.2 TUN/DNS 联动](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src-tauri/src/enhance/tun.rs)
- [开发版配置合并与 IPv6 池补全](https://github.com/clash-verge-rev/clash-verge-rev/blob/c599f5547ec98cf998626a30c0003b41a5bd5579/src-tauri/src/enhance/mod.rs)
- [开发版 macOS 网络变化处理](https://github.com/clash-verge-rev/clash-verge-rev/blob/c599f5547ec98cf998626a30c0003b41a5bd5579/src-tauri/src/core/network_watch.rs)
- [开发版官方核心下载流程](https://github.com/clash-verge-rev/clash-verge-rev/blob/c599f5547ec98cf998626a30c0003b41a5bd5579/scripts/prebuild.mjs)
- [Mihomo TUN 官方说明](https://wiki.metacubex.one/en/config/inbound/tun/)
