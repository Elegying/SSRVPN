# SSRVPN 跨平台可靠性审计

审计日期：2026-09-16（Asia/Shanghai）。第 1–10 节保留修复前证据；后续授权修复见文末追加记录。此报告**不是公开发版证明**。后续变更提示：F03 涉及的 IPv6 处理已于 5.0.12 由 [ADR-019](decisions/019-dual-stack-routing.md) 改为三端双栈，第 10 节中“与当前 IPv4-only 产品范围一致”的建议只代表 5.0.6 基线。

## 1. 范围与基线

- 审计基线：`67dc7a06c350f823939a617a9bab8c6fd1d1d33a`，分支 `codex/5.0.6-stability-audit`，源码版本 `5.0.6+5006`。
- 收到本轮只审计指令时 `git status --short` 为空。前轮修复已经提交推送；本轮仅新增本报告、隔离复现与证据，不修改生产文件、依赖、核心、CI，不提交或推送。
- 在线核实远端 main 为 `be46ebe934a34d54d9b3ee06c4cbfb6e94583adb`，正式版本仍为 `v5.0.5`（2026-09-15 发布）。本地候选**不等于** main 或正式版本。
- 本机 macOS 26.6.2 / 25G83，arm64；固定 Flutter 3.44.1，SDK 为 darwin-x64。核心源码复现使用已安装 Go 1.26.5，明确设置 GOROOT。未升级工具链。
- 根目录没有 AGENTS.md；遵循会话提供的中文、最小改动约束。已阅读 README、CONTRIBUTING、.fvmrc、TESTING、UAT_MATRIX、产品需求、控制端口审查与发布清单。
- 文档基线存在陈旧信息：UAT_MATRIX 顶部仍把 v4.0.36 称为“当前正式版本”。其历史记录不能用于证明 5.0.6 已验收；本轮不顺手改写历史证据。
- 三端确为 Flutter + Mihomo；Android VpnService，桌面系统代理/TUN；保持 IPv4-only、应用优先分流、手动规则、免费桌面分发与无自动遥测。未增加 iOS/Linux/IPv6 支持。
- 没有操作正在使用的 VPN、系统代理、DNS、路由或防火墙，没有强杀用户进程。新网络复现仅连接 loopback，假域名、假凭据、临时目录。

证据分类：A 已确认；B 疑似；C 本轮限定范围未发现；D 不适用；E 环境阻塞或未完成。严重性与可信度分别列出。C 不是“永远安全”，E 不是“测试通过”。

## 2. 核心、格式与系统基线

来源记录：`native/proxy_traffic/sources.json:1`、三端 `assets/*-source.txt`、`third_party/THIRD_PARTY_NOTICES.md:37`。本轮运行 `scripts/verify-core-assets.sh` 成功，并重新计算下列文件 SHA-256。

| 平台 | 固定来源/版本/提交 | 打包文件 SHA-256 | 构建与最低系统 |
| --- | --- | --- | --- |
| macOS | MetaCubeX/mihomo v1.19.29，`e26714a181ac0e2fa803453c0a8e9a9ce94e31cb` | AtlasCore.gz `9a1e4cb6ca6c3ac9d94e1e09ecb353453185945488abdf4bd16bd27e821e986b`；解压可执行文件 `a6de08ac2e76bab9222cdb7aabe6fb9e8e916b871536ddcaa1abcd0c8220e841` | Go 1.26.5 / arm64 / with_gvisor；macOS 11+，ad-hoc、未公证 |
| Windows | MetaCubeX/mihomo v1.19.27，`5184081ac327394d9e15fa5d5f9f4a61e723fd94` | mihomo.exe `bf080b1c2e4fe68583b7f51da5f1a46d3c62f9de840d96d34d69bd25e5f9a020` | Go 1.20.14 / amd64 v1 / with_gvisor；Windows 10/11 x64，未签名 |
| Android | zeyugao/mihomo，`7031b7569831677a8d89ad8a8a3347db116ba1a8`，不能套桌面版本号 | libgojni.so `45252c806a566d4de4d2bc9c1a416a7116d80fc91ab74fb81621691e25989b80` | Go 1.25.11 / arm64 / with_gvisor,cmfa / c-shared；NDK r28c，API 24；Android 7+ |

三端都使用 Mihomo YAML；共享生成器只提取远端节点，再生成本地控制面、规则和监听配置。Android 另用 `SSRVPN_Android/native/bridge/bridge.go`（来源记录哈希 `2042b01acbdd25bfade905cdfcb949ab779fd430d4dc86d45658446ad20c8621`）。三端附加 `native/proxy_traffic/{android,macos,windows}.patch`，扩展摘要 `add0ca72837ed8194cea006c1ccbe1dac8d601584f12505db861f75222911f05`；这些补丁不改 DNS relay 或 config 的 IPv6 处理。

最低系统是工程/产品声明。本机运行不是 macOS 11 验收，Windows CI 不是 Windows 10 用户实机，Android Kotlin 测试不是 Android 7 VpnService 实测。本轮未构建、安装新的正式产物。

## 3. 上游参考：已阅读原文，查询日均为 2026-09-16

| 编号 | 原始来源及固定锚点 | 证据性质及采用范围 |
| --- | --- | --- |
| S01 | [Clash Verge Rev releases](https://github.com/clash-verge-rev/clash-verge-rev/releases)，v2.5.2，2026-07-19，非预发布 | 发布说明明确记载 gzip/空密码 Basic Auth、API 状态、内存与 App Translocation 等修复。用于选择测试，不代表 SSRVPN 自动有相同缺陷。 |
| S02 | [FlClash CHANGELOG](https://github.com/chen08209/FlClash/blob/7c61c90ac20493b474d19c75ec96262b478b4b88/CHANGELOG.md)，v0.8.98 / `60f371a` | 仓库变更记录称修复 Windows 睡眠/App 暂停时核心维持运行；未独立验收其发布资产。 |
| S03 | [v2rayN releases](https://github.com/2dust/v2rayN/releases)，7.25.1，2026-09-10，**预发布** | 核心配置迁移及下载器修复记录；Xray 字段不能直接套到 Mihomo。 |
| S04 | [v2rayNG releases](https://github.com/2dust/v2rayNG/releases)，2.3.8，2026-09-10，**预发布** | TCP ping 并发控制、订阅后台操作与启动设置变更；不照搬其自动删除无效节点策略。 |
| S05 | [Hiddify #1096](https://github.com/hiddify/hiddify-app/issues/1096)，2024-07-22，Windows 1.7.0 等 | 用户报告低 ping/网卡存在但无法联网；已关闭、state_reason=completed，未取得对应修复提交，因此不写“已修复”。 |
| S06 | [Tailscale changelog](https://tailscale.com/changelog)，v1.68.2 | 已发布的睡眠唤醒/切网可靠性修复记录；只借鉴生命周期场景。 |
| S07 | [Mullvad security design](https://github.com/mullvad/mullvadvpn-app/blob/main/docs/security.md) | 官方设计文档；其默认防火墙阻断策略不是 SSRVPN 的产品承诺，不擅自新增 kill switch。 |
| S08 | [Tunnelblick Common Problems](https://tunnelblick.net/cCommonProblems.html) | 官方网络/DNS/子网冲突排查说明，OpenVPN/kext/PPP 的具体命令不适用于本工程，未执行页面命令。 |
| S09 | [Mihomo #3037](https://github.com/MetaCubeX/mihomo/pull/3037)，合并 `fb002210ffe56b7c393ef021533d30d41d55de39`，2026-07-27 | **已合并修复**，核对原始 patch 与三端精确源码，见 F01。 |
| S10 | [Mihomo v1.19.30](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30)，2026-08-16，`ac017cd` | **正式发布**含 #3037，以及 UDP EDNS、嗅探、WebSocket 顺序等修复。除 #3037 外，未逐条证明本工程触发，不能一并列为确认漏洞。 |
| S11 | [general](https://wiki.metacubex.one/config/general/) / [DNS](https://wiki.metacubex.one/config/dns/) / [TUN](https://wiki.metacubex.one/config/inbound/tun/) | 官方当前机制；Private DNS、LAN DNS、多网卡、IPv6 配置约束用于确定边界。最终以打包核心源码为准，不能把新文档字段视为旧核心一定支持。 |
| S12 | [sing-box TUN](https://sing-box.sagernet.org/configuration/inbound/tun/) | 仅比较平台/路由设计；sing-box 专属字段及 Linux-only auto_redirect 不用于 SSRVPN。 |
| S13 | [Android VPN 官方文档](https://developer.android.com/develop/connectivity/vpn) | prepare/protect/establish、前台服务与非主线程 onRevoke 的机制依据；需原生/设备测试。 |

## 4. 模块地图和实际状态流

共享入口 `desktop_connection_coordinator.dart:80`：连接意图 → 串行事务 → prepareForStart → 生成/写配置 → 平台 start → 有界就绪 → 选节点确认 → connected。显式 bind 失败最多再准备一次；每个 await 后检查 revision/intent。控制 API 实际端口只由 `clash_service_base.dart:131` 的运行设置给出，预期端口用于诊断。

运行路径：已运行 → 周期健康检查 → 连续失败达到门槛 → 停止本代监控 → 串行恢复队列 → 再检查监控代次/连接意图 → 平台当前端点复核 → 保留或有界重建。新意图令旧队列失效；用户停止取消自动重启。`clash_service_health_monitor.dart:149–300`。

macOS：Flutter 生命周期 → 原生 CoreProcess 或授权 runner → 核心/DNS journal/请求所有者 → 退出恢复。Windows：启动准备/UAC → 自有进程与代理恢复记录 → 核心 → TUN 观察。Android：connection_orchestrator → MethodChannel → VpnService start generation → establish/保护 socket/Go bridge → 受控 commit → native state，停止通过 stop gate/stop operation 合流。存在多层状态是平台分工，不能只因没有同名 enum 就判定错误。

重要区别：`_logSessionId` 是服务实例日志 ID，不等同每次连接/核心 attempt；健康日志另有 connection。后续建议将 core attempt 和单调事件序号贯通，不记录 secret。当前同秒、倒序截图不能重建精确事件顺序。

## 5. R01–R14 审计矩阵

路径以仓库根目录为起点；行号绑定上述 commit。矩阵包含局部结论，不能用一格 C 覆盖同一主题的 E。

| 项 | 上游/适用性 | 代码证据、已有保护和实际检查 | 分类、严重性/可信度 | 测试 |
| --- | --- | --- | --- | --- |
| R01 端点/归属 | S01/S11，三端适用 | `clash_service_base.dart:287–315` 本地 API 专用 DIRECT client；`runtime_support.dart:79` 先选端口再配置；`desktop_connection_coordinator.dart:127–157` 有界 bind 重试。真实监听测试验证避让后各 API 新端口且第三方仍存活。Mac `AppDelegate.swift:791` 发信号前复核身份；runner 见 B03。 | C 端点迁移；B 极端 PID 复用；P1潜在影响/低至中可信。HTTP状态能保留，但 socket/timeout 在 health:89 仍合并提示，P2诊断限制。 | T01/02/07/23 |
| R02 会话/恢复 | S01/S02，三端适用 | `health_monitor.dart:149–300` epoch+intent；Mac/Win lifecycle 当前端点复核；`desktop_connection_coordinator.dart:98` stale rollback；Android `NativeVpnSessionCoordinator.kt:10` generation、`SsrvpnVpnService.kt:806` stop gate。前轮排队旧恢复测试红绿，本基线已修。 | C 已测旧任务边界；E 所有真实权限/系统回调组合。P1场景/中高。 | T03–06 |
| R03 假连接/误恢复 | S05，三端适用 | health:31 version+必需 providers；平台还查监听/配置。`Windows/test/tun_runtime_health_test.dart:33` 明确网卡观察仅 advisory；公网IP/外部探针失败不 stop。不等于数据通道必然可用。 | C 可选接口不误停；B F03导致网卡观察不准确；E 门户/NXDOMAIN实网。P1–P2/中高。 | T06/13/16 |
| R04 系统状态恢复 | S07/S08，桌面重点 | Mac `AppDelegate.swift:1282` 文件/owner/service identity，`1873` 分步骤恢复；Windows `system_proxy_recovery.cpp:564–643` snapshot与事务阶段。共享订阅事务与系统代理事务区分。读取和写OS设置仍非跨进程原子CAS。 | C 已有回滚/第三方接管测试；B B03；E 磁盘满/同时外部修改全步骤实机。P1潜在影响/中。 | T08/09/21 |
| R05 睡眠/切网 | S02/S06/S08/S11 | Mac runner:853 只有明确网络/DNS变更才停，未知查询保留；26项隔离shell事务测试通过。Android UnderlyingNetworkMonitor按代次处理；Windows恢复预算有界。 | C 模拟unknown/确定变更；E 合盖/睡眠/DHCP/多VPN真实组合。P1场景/中。 | T10/11 |
| R06 DNS/规则 | S09/S11 | config generator:194–234 DNS policy，:334–370 路由次序；ForceProxySitePolicy:28规范化；AppSettings:126同host冲突处理；DirectFetcher:80起安全Fake-IP备用解析、校验后固定地址。父子域DNS见 F04，大响应见F01。 | A F01/F04；C 已测Fake-IP/TLS/取消；E Private DNS/DoH实机。P1/P2分别列下。 | T12/13/15 |
| R07 IPv4边界 | S11/S12 | generator:127 ipv6:false，Windows config:18仍写inet6-address；固定core parseIPV6会清除此值。Android VpnRouteInstaller:29由系统Builder另加IPv6 route，不能套桌面结论；排除应用在边界外。 | A F03配置失配；B 实际旁路程度；E 双栈真机。P1/配置证据高。 | T14 |
| R08 核心/协议 | S09/S10 | 三份 exact resolver relay 相同，补丁无回移；真实函数复现F01。协议转换测试/真实核心路由不等于远端Hysteria2/Trojan/SSR端到端。 | A F01；B v1.19.30其他修复影响待证；E SSE/WS/UDP长测。P1/高。 | T15/16 |
| R09 订阅 | S01/S03/S04 | Android subscription_service:347安全解析/:393TLS/:484原始HTTP；`subscription_processing.dart:27/110` isolate阈值；merger:18上限10000节点；transaction:22恢复与提交。远端仅节点，20MB/解析复杂度上限、取消、乱序保护已有测试。 | A F02；C gzip/HTML/取消/旧数据保存等基线测试；B B02小载荷同步解析压力。P2/高至中。 | T17–20/25 |
| R10 配置/更新 | S03/S10 | `update_service_download.dart:35–57` 独立临时文件和publication锁；publication:184有界恢复、:303只清本次staging；subscription_service_transaction:115journal。TLS来源限制+SHA；客户端并非逐次验Sigstore，发布证明是发布端/外部核验。 | C 失败保留有效包/回滚行为测试；E 当前候选安装升级、断电、磁盘满全链。P1场景/中高。 | T21/22/29 |
| R11 控制/特权/日志 | S07/S11/S13 | API loopback+持久保护的随机secret；不是每attempt重新生成，勿误述。Mac runtime0700/config0600+corehash；原生身份与记录校验；LogRedactor标记凭据测试。 | C 已测本地权限与脱敏路径；B B03；E 全授权环境动态攻击验证。无新增遥测。P1潜在/中。 | T07/23 |
| R12 资源/UI | S01/S04 | health:95 abort请求；runtime_support旧reply丢弃；physical_tcp_latency:13全局8并发/64等待；批测速应关联当前revision。processing:110阈值下同步。性能仅下节实测，不宣称优化。 | B B02；C 已测cancel释放worker/请求；E 长时间CPU/FD/内存趋势、完整千级UI。P2/中。 | T24/25 |
| R13 Android原生 | S13 | `SsrvpnVpnService.kt:487` establish，:504 protect callback，:806失效generation，:857两次stop/等待pendingstart/释放ownedFD，:993onRevoke；Go bridge protect有session/timeout，不回退未protect socket。 | C 已有原生隔离测试保护；E 真机权限撤销/另一VPN/进程重建，不能由Widget证明。P1场景/中。 | T05/26 |
| R14 桌面/安装 | S01/S02 | Mac AppDelegate身份/授权session；Windows UAC start_preparation:157、launcher/proxy恢复，非Clash Verge相同service架构；三端最低版本/免费签名来自打包规范。 | E 当前包安装/最低系统/Explorer/Translocation；C 既有平台测试限定范围；D 其他客户端service专属方案。 | T27–29 |

## 6. 已确认问题

### F01：三端核心的 TUN DNS relay 缓冲区缺陷（A，P1，高可信）

**条件**：DNS 响应有大量同名记录，未压缩大小超过调用者缓冲区，压缩结果仍能放入 2048 字节。与网络 MTU、节点密码、Flutter 页面无关。

**调用链**：精确 core `listener/sing_tun/dns.go:110–133` 将 writeBuff.FreeBytes 交给 `component/resolver/relay.go:79–102`；后者 `PackBuffer` 可能分配新slice，调用者只采用返回长度，仍发送writeBuff。三端relay源码SHA均为 `76d62b089cb7611d640413284f57bcd4ed79980134cc16ebc28113d012dabb6a`。已查看Android固定分支，无等效回移。

**最小复现**：[Go 测试](audit/repro_dns_buffer_test.go) 调用固定Mac核心源码真实 `RelayDnsPacket`，仅替换DefaultService为120条合成A记录。预期原buffer等于返回报文；实际返回1974字节合法报文、原buffer头仍`a5a5`，应为DNS ID `1357`。退出1，属于预期揭示缺陷，不是基线测试失败。[日志](audit/evidence/dns-buffer-correct-toolchain.log)。没有真实TUN抓包，因此不说三台设备都实测失败。

**影响**：命中该路径的DNS请求可能ID错误/超时，表现为局部域名打不开、连接可用但部分业务异常。不能把它追认为用户9090断连的根因。

**最小修复建议**：单独回移已审查的#3037缓冲区copy补丁到各固定核心，保持原构建目标，重新生成来源/哈希/镜像；或另立受控版本升级，不直接latest。进一步验EDNS 512/1232/2048/4096、截断TC和TCP回退、真实TUN。回退必须保存旧固定核心/记录整组版本，不替换已公开同标签资产。本轮未实施。

### F02：Android 接受带凭据订阅 URL，但不发送 Basic Auth（A，P2，高可信）

**条件**：`http(s)://user:password@host/feed`，包括空密码。URL policy接受userinfo；Android `_fetchOnce`只把host/path传给`_sendHttpRequest`，后者没有Authorization。不是凭据泄露，而是认证信息丢失。

**复现**：[隔离测试](audit/repro_android_basic_auth_test.dart) 在随机loopback端口提供要求认证的服务器，使用生产fetchSubscription、地址校验和HTTP编码，仅将socket连接映射至本地。空/非空密码各一次；预期服务器收到Basic头并返回合成节点，实际均收到null并返回401。两项退出1，[日志](audit/evidence/basic-auth.log)。用HTTP避免引入证书因素；HTTPS使用相同请求编码，后续仍应补真实TLS case。

**影响与范围**：Android已证实。DirectFetcher手写请求也无userinfo处理，桌面直连通道有同类静态证据，但常规HttpClient回退行为未在本轮完整实测，因此不笼统宣称三端所有路径失败。

**最小修复建议**：复用共享URL认证策略，在原域名请求中按正确URL解码处理用户名/密码，支持空密码；跨origin重定向不转发旧Authorization，日志不打印userinfo。若产品决定不支持，则应导入时明确拒绝，不能默默接受后401。回归空/非空/转义/Unicode/跨域/TLS/取消，保护旧节点；不引入新依赖。回滚限定订阅网络层。本轮未修。

### F03：Windows IPv6捕获配置与固定核心解析语义冲突（A配置失配，P1，高可信；实际旁路为B）

**证据**：共享generator:127输出`ipv6:false`；Windows config:18输出TUN inet6-address。固定Windows core `config/config.go:1650–1654` 的 `parseIPV6` 因顶层false将地址置nil。Mac固定源码相同逻辑，真实函数隔离测试也清除了地址，[复现](audit/repro_ipv6_config_test.go)、[日志](audit/evidence/ipv6-config.log)。没有在用户机器建立TUN或关全局IPv6。

**用户影响**：Windows产品文档承诺捕获/拒绝IPv6，仅生成YAML地址和IP-CIDR6拒绝规则不足以兑现；流量必须先进入TUN。`windows_tun_runtime_probe.dart:911–917`又要求同网卡同时有预期IPv4/IPv6，可能持续报告adapterMissing。该观察当前是advisory，不能据此断言必然无法连接。

**边界**：Windows strict-route防火墙的实际IPv6效果、已缓存IPv6/DoH应用是否旁路，需要隔离双栈Windows抓包；本轮未证实“实际泄漏”。macOS文档本来只承诺关闭核心内部IPv6，不据此强加全设备阻断。Android Builder独立捕获IPv6，不受同一生成方式结论直接支配。

**最小修复建议**：先用固定Windows核心与隔离双栈机器验路由/防火墙/IPv6字面地址，选择与当前IPv4-only产品范围一致的捕获并拒绝方案；同时调整实际网卡诊断。禁止简单全局打开IPv6、关闭OS IPv6或把文档改成“已修”。回归系统代理不受影响、TUN断开恢复、其他VPN不受损。本轮未改。

### F04：父域强制代理与子域直连的 DNS 优先级不一致（A，P2，高可信；跨平台数据通路待测）

**触发**：forceProxySites含`example.com`，forceDirectSites含`api.example.com`，核心需要实际解析子域。产品要求父子域重叠时强制代理优先，代理域使用代理DNS。

**调用链与复现**：[生成器取证](audit/export_rule_dns_fixture.dart)直接调用生产`generateConfig`，输出路由PROXY位置1、DIRECT位置2；同时输出父域代理DoH与子域国内DoH两个policy，[输出](audit/evidence/dns-policy-generator.log)。固定核心`dns/resolver.go:533–556`将域名policy放入trie，`dns/policy.go:15`按域名匹配；[真实核心匹配测试](audit/repro_dns_policy_test.go)用loopback地址作为解析器标签，未发送任何网络请求，实际选中子域DIRECT解析器，预期失败退出1，[日志](audit/evidence/dns-policy.log)。这不是重写一个匹配算法来验证自身。

**边界与影响**：确认Mac固定核心配置/选择语义与产品要求不一致；三端共享生成器都产生该冲突，但Windows/Android实际解析器与协议数据通路尚未端到端验收。可能导致强制代理域名依赖国内解析、解析结果不一致；不宣称已经发生明文泄漏，也不宣称业务路由绕过PROXY。

**最小建议**：统一手动规则的优先关系，生成DNS policy时排除被强制代理父域覆盖的直连子域策略，保留其它直连例外。补同域/父子/伪后缀/尾点/punycode和真实DNS查询的表驱动测试；不替换整套分流。回滚限定配置生成器，保留最后可用配置。本轮未修。

## 7. 疑似风险与最小补证

- **B02，R12/P2，中可信**：`SubscriptionProcessing._run`对小于256KiB工作量直接同步process。本轮960节点基准的合并/配置各数秒，但同时在编译Go，且Flutter为x64模拟环境；不能推广到用户机或宣称回归。最低补证：固定空闲硬件，100/1000/4800/10000合成节点，采frame timing、event-loop lag、p50/p95；再决定降低isolate阈值或按节点数切换，不先重构。
- **B03，R01/R04/P1潜在影响，低至中可信**：授权shell在TERM之后用数字PID再次KILL（runner:688–701），没有普通原生CoreProcess同等级的启动时间/可执行身份复核；父子进程、shell回收行为和PID复用窗口需证实。不得把普通原生路径的ABA测试当root shell路径证明。最低补证为隔离shell调度/信号替身与短寿命自有子进程；不在用户机制造PID耗尽或向真实无关进程发信号。当前不称已发生误杀。
- **B04，R08/P2，中低可信**：v1.19.30还有嗅探失败保连接、HTTP/2等待、WS顺序修复；只核实发布记录，没有逐条触发测试。需精确diff/补丁包含关系和本地协议服务A/B，不一起升级全核心“碰运气”。
- **诊断限制（静态确认，P2）**：health:89–92把SocketException、TimeoutException等合成同一CORE_API_UNAVAILABLE文字；HTTP401/403仍保留状态码。建议复用现有错误映射增加阶段/耗时/实际端点/attempt，保留脱敏，不新增另一套状态机。

强制规则真值表：同host不同写法由后保存方胜出；父域PROXY+子域DIRECT为PROXY；父域DIRECT+子域PROXY为PROXY；伪后缀不应命中DOMAIN-SUFFIX；IPv4字面生成/32；IPv6输入拒绝、旧值受首条REJECT；Unicode域名当前校验拒绝，punycode ASCII可用。没有域名元数据的纯IP请求不能靠域名规则识别。前两类设置/生成行为有现有测试；完整真实DNS/路由交叉真值表尚未执行。

## 8. T01–T29 执行映射

“基线通过”指实际完成的既有套件，不是新真机测试。模拟/函数边界与OS结果分列。

| 测试 | R | 本轮证据与缺口 |
| --- | --- | --- |
| T01 | R01 | 共享端口计划9090/9091/9092及真实随机第三方监听避让通过；config和API请求一致。 |
| T02 | R01/02 | coordinator显式bind冲突最多二次、401/错误状态既有测试通过；空闲到bind被真实第三方抢占、伪API完整身份链未新测。 |
| T03 | R02/03 | Mac 2秒延迟API、不就绪/授权退出的生命周期测试通过；不启动周期恢复。 |
| T04 | R02 | 共享旧health/旧group/旧恢复与新意图、平台迟到启动测试通过。 |
| T05 | R02/13/14 | 取消/恢复预算/授权迟到自动化有证据；Android系统真实回调并发未测。 |
| T06 | R03 | 瞬断/持续失败门槛、当前端点复核、外部观察warning-only测试通过。 |
| T07 | R01/11 | 无关真实listener存活、普通Mac原生身份历史测试；root shell PID重用未证，B03。 |
| T08 | R04 | 26项TUN DNS事务模拟通过，Windows注册表原生证据需绑定目标CI；未做系统断电/磁盘满。 |
| T09 | R04 | 保存值/第三方接管/恢复记录测试通过；跨进程最后读取至写回窗口仍需OS注入。 |
| T10 | R05 | unknown与确定网络变化shell模拟；真实睡眠/DHCP/切网E。 |
| T11 | R05/06 | 本地API专用直连、Android protect源码/测试；多VPN/虚拟网卡实网E。 |
| T12 | R06 | settings/规则规范化与真实核心四模式路由通过；父子域DNS选择新复现F04；全真值表仍未补齐。 |
| T13 | R06 | Fake-IP备用解析、公网校验、pin连接、错误TLS/重定向/取消通过；Private DNS/DoH/门户实机E。 |
| T14 | R07 | 新核心parseIPV6测试预期失败；双栈OS、缓存/字面地址抓包E。 |
| T15 | R08 | 新真实RelayDnsPacket大压缩响应测试预期失败；完整EDNS/UDP-TCP/TUN矩阵E。 |
| T16 | R08 | 未配置隔离Hysteria2/Trojan/SSR服务，SSE/WS/HTTP2/大文件/UDP长测E。不索取真实节点密码。 |
| T17 | R09 | gzip、非法Base64/YAML、HTML假成功、空内容、重复节点/不支持节点既有解析与服务测试通过。 |
| T18 | R09 | transaction/refresh controller/source cache乱序、删除、取消、旧状态保留测试通过。 |
| T19 | R09 | 新Android Basic Auth 2项失败；现有redirect安全与日志脱敏通过；桌面Basic/编码完整交叉E。 |
| T20 | R09 | 20MB响应、10000节点、bounded YAML和远端仅节点现有测试通过；不是无上限压测。 |
| T21 | R04/10 | journal/半提交/热加载失败回滚的隔离测试通过；真实磁盘满和断电E。 |
| T22 | R10 | 取消/HTTP错误/hash/发布失败保留已有文件、并发publication的既有测试通过。 |
| T23 | R11 | 日志假凭据、配置/ownership记录损坏边界通过；特权动态完整审计E。 |
| T24 | R12 | abort请求/worker取消既有测试；多轮完整连接CPU/FD/句柄/内存趋势未测。 |
| T25 | R12 | 240×4=960节点smoke实测；4800/10000 UI、空闲可比基线、p95未测。 |
| T26 | R13 | Kotlin与Go bridge历史证据有，当前真机onRevoke/另一VPN/进程重建E。 |
| T27 | R14 | Mac授权session单测通过；本轮未安装/移动/Translocation/真实授权测试。 |
| T28 | R14 | Windows源码与Dart测试；UAC/Explorer/系统代理原生完整结果待目标环境。 |
| T29 | R10/14 | 三端打包输入core哈希通过；本候选尚未公开，安装卸载/最低OS全矩阵E。 |

## 9. 测试账本和重现命令

固定PATH：`/Users/jared/.local/share/mise/installs/flutter/3.44.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`。

| 类别 | 命令/环境 | 结果及证据边界 |
| --- | --- | --- |
| 已启动的既有完整测试 | `scripts/run-flutter-coverage.sh <workspace> --concurrency=2`，逐workspace；随后check-coverage-thresholds | 本机共享1306通过/1跳过、Android336、Mac344、Windows311/7跳过，共2297通过/8跳过。Windows为Mac主机，跳过真实exe/Windows专属；共享开始于前轮最后小补丁前，该补丁另有19项health和1项偏好回归通过，不能伪称整套是单次精确HEAD验收。退出均0。 |
| 覆盖率 | 同上 | shared89.13%，Android71.41%，Mac73.58%，Windows59.92%；Mac lifecycle76.83%、proxy89.46%，Windows lifecycle52.43%。未降门槛。 |
| 前轮专项 | shared142、Windows定向62、Mac定向旧诊断断言修正后重跑 | 作为前轮候选修复证据保留，不合并计数冒充本轮新测试。 |
| 核心集成 | `python3 scripts/check-routing-core.py` | loopback真实Mac核心rule/global/fallback/recovered四模式通过；旧运行曾502/就绪不足，前轮已改独立端口与就绪。不是完整协议或TUN实测。 |
| 本轮新增失败复现 | Android命令如下 | 2失败，退出1，预期揭示F02；独立docs目录，不污染常规test发现。 |
| 本轮新增核心函数 | Go命令如下 | DNS buffer 1失败、IPv6 parser 1失败、DNS policy 1失败，退出1，预期揭示F01/F03/F04；固定Mac上游源码真实函数。Windows/Android同源相关代码另行核对，未伪称其OS二进制已运行。 |
| 核心资产 | `scripts/verify-core-assets.sh` | 退出0，[日志](audit/evidence/core-assets.log)。 |
| 性能 | `scripts/check-performance-baseline.sh` | 退出0，[原始JSON](audit/evidence/performance.log)。960合并节点；两次采样parse median439280µs、merge4134192µs、config2908025µs。当时并行Go编译、x64 SDK，不能算正常连接p50/p95或性能提升。 |
| 静态/规范 | 前轮final shared analyze、四workspace analyze、quality hygiene、boundary、docs、diff check | 已通过记录；本轮生产文件无改动。审计文件单独格式化。 |
| 原生/设备 | 新审计未启动破坏网络的原生场景 | 本机保留原VPN。没有本候选USB/Windows10/最低Mac实机验收。 |
| 完整入口 | `make verify` = `scripts/verify-all.sh` | 本轮没有重新从头运行一次完整make；继承此前分段验证，原始JAVA_HOME/中断记录不抹除。不能写“make全绿”。 |

本轮初次Go命令因环境GOROOT仍指1.27、可执行1.26.5而编译失败；纠正环境后才得到上述功能失败，不将工具链错误计为产品缺陷。新审计不会触发发布；此前已启动的PR CI只读观察，未以本次审计文件另行提交。

Android复现（假凭据，不连接外网）：

```sh
cd SSRVPN_Android
flutter test --no-pub ../docs/audit/repro_android_basic_auth_test.dart --reporter expanded
```

核心复现：在临时目录下载并解压固定 `https://github.com/MetaCubeX/mihomo/archive/e26714a181ac0e2fa803453c0a8e9a9ce94e31cb.tar.gz`，保留许可证；将本仓库 `docs/audit/repro_dns_buffer_test.go` 复制至该源码 `component/resolver/`，将 `repro_ipv6_config_test.go` 复制至 `config/`。没有改上游生产函数或SSRVPN核心资产。

```sh
# 在上述精确源码目录，使用已安装的匹配Go，不改变全局环境
GOROOT=/Users/jared/.local/share/mise/installs/go/1.26.5 GOTOOLCHAIN=local \
  /Users/jared/.local/share/mise/installs/go/1.26.5/bin/go test ./component/resolver \
  -run '^TestAuditDNSPackedBytesRemainInCallerBuffer$' -count=1 -v
GOROOT=/Users/jared/.local/share/mise/installs/go/1.26.5 GOTOOLCHAIN=local \
  /Users/jared/.local/share/mise/installs/go/1.26.5/bin/go test ./config \
  -run '^TestAuditIPv4OnlyRetainsRequiredTunIPv6Capture$' -count=1 -v
```

失败断言保留；不能删断言、跳过生产文件或降低门槛来“修绿”。本轮未复制上游实现进入产品，仅新写隔离测试。DNS policy测试复制到同一源码`dns/`后，用同一Go执行`go test ./dns -run ^TestAuditParentProxyPolicyMustWinChildDirectDNS$ -count=1 -v`；生成器取证在SSRVPN根目录执行`dart --packages=.dart_tool/package_config.json docs/audit/export_rule_dns_fixture.dart`。

### 前轮候选 CI 的最终失败证据（独立于新增审计复现）

[PR CI 35053641951](https://github.com/Elegying/SSRVPN/actions/runs/35053641951)绑定同一`67dc7a0`。本轮仅观察，未重新触发或推送。记录时共享、Android、策略与核心资产等通过，macOS native仍在运行，两个桌面任务已失败：

- macOS job `104661024657`：339通过/5失败；`UpdateProxyFixture.create`的系统证书预检报`Unknown critical cert extension`，并输出CT/SCT信息。属于合成证书fixture失败；底层证书扩展的具体原因未最终确认，不能认定生产订阅TLS坏了。fixture初始化失败后的LateInitializationError是次生测试错误。真实核心四模式分流步骤本次通过。
- Windows job `104661024723`：316通过/1失败/1跳过；共享`update_proxy_transport_test`下载成功路径没有注入Windows native publisher，抛`Windows verified update publication requires a native publisher`。实际Windows update_service:106会提供原生publisher，因此这是当前测试接线问题的明确证据，不能据此说正式更新流程必然失败；打包步骤被前置测试阻断，本轮不能宣称Windows构建成功。

精简原始摘录见[CI失败记录](audit/evidence/ci-failures.log)。这些阻塞尚未修复，本轮不修改既有测试、生产TLS或发布流程来掩盖它们。下一轮必须先恢复有效目标平台测试，再谈发布。

## 10. 未完成环境、第一批建议与恢复清单

第一批应分开处理：

1. F01 DNS缓冲区：独立核心回移候选、固定来源、三端相关测试，保留回退资产；不要夹带v1.19.30所有变更。
2. F03 Windows双栈：先隔离Windows10/11双栈网卡抓包，证明实际路径，再实现最小IPv4-only捕获/拒绝及诊断修复。不能让YAML字符串测试继续充当内核生效证明。
3. F02 Basic Auth：共享策略小修，先使隔离失败转绿，再补跨域/编码/TLS和三端通道回归。
4. F04共享生成器最小修复；B02性能另行补证，B03用信号替身审查，不以高风险系统试验求证。

所需隔离环境：可回滚Windows10/11 VM（管理员、双栈、可抓包）、可离线Android设备/模拟器（VPN权限/Private DNS/另一VPN可控）、专用Mac或明确授权的测试时段；本地合成Hysteria2/Trojan/SSR服务、测试CA、DNS多记录/EDNS服务。所有协议凭据自动生成，不需要真实节点密码。SSE/WS/HTTP2、大文件/UDP按每种协议和切网场景分批执行。

待办：T02真实bind竞态和错误实例完整认证；T08/09真实OS失败注入；T10/11/14网络矩阵；T12/13全DNS真值表；T15/16协议核心矩阵；T24/25资源与UI长期曲线；T26–29原生和安装最低系统。R01–R14已有初步地图，但这些E项未完成，不标安全。

不适用：Linux/iOS、sing-box专属选项、Mullvad默认kill switch、Clash Verge同构service假设、Tauri/WebView渲染修复直接移植Flutter、要求付费桌面签名。系统代理模式也不等于全设备VPN。

本轮结论：确认了四个具体问题/失配，均有生产请求链路或固定核心真实函数证据；配置失配不等于已证实系统旁路。前轮端点/会话修复证据保留，不能由此证明所有长时间闲置断连已消除。**等待用户后续明确修复指令，不修改生产行为、不发布。**

## 11. 授权修复记录（2026-09-16，未提交候选）

用户在上述审计后明确要求“修复”。以下记录属于后续实施阶段，不改写前面的
审计基线、失败复现日志或正式版本状态。未提交、推送、打标签、上传核心镜像或发布安装包。

### 已实施的修复

| 项目 | 实施与证据 | 验证边界 |
| --- | --- | --- |
| F01 | 三端固定核心补丁回移 S09 的 PackBuffer 修复；120 条合成 A 记录调用真实 RelayDnsPacket，三份源码均转绿；构建脚本强制执行该回归 | 已重建三端核心；未进行用户设备 TUN 长时 DNS 测试 |
| F02 | `SubscriptionUrlPolicy.basicAuthorization` 每跳生成认证头；Android 原始 HTTP、共享 DirectFetcher、桌面 HttpClient 路径复用；空密码、百分号编码、相对和跨来源重定向回归 | Android 和共享原始 HTTP 用 loopback 服务器验证；无真实订阅凭据，无新增依赖 |
| F03 | 仅 Windows 核心解析器在 IPv4-only 时保留显式 TUN IPv6 捕获地址，同时清空 IPv6 Fake-IP 范围、保持 IPv6 出站关闭；真实 parseIPV6 回归转绿 | 仅证明配置不再被清除；Windows 双栈路由、防火墙及实际旁路仍未实测 |
| F04 | 删除被手动代理父域覆盖的直连子域 DNS 策略，保持流量规则顺序不变；保留不同标签边界、直连父域和代理子域；内置代理子域不覆盖手动直连父域 | 客户端实际生成的合成策略已通过固定 Mihomo 的真实 DNS 匹配器验证 |
| Windows 测试阻塞 | 平台包装测试注入正式 `UpdateService.publishVerifiedInstaller`，保留生产的原生无覆盖保存要求 | 本机共享传输测试通过；Windows 原生 MoveFileExW 分支仍待 Windows CI |
| macOS 测试证书 | 使用显式最小 OpenSSL 配置、独立 CA 名称及 SKI/AKI；失败时输出合成公钥证书详情，setUp 失败不再被 late teardown 异常掩盖 | 系统 LibreSSL 本机 TLS、域名不匹配拒绝及取消测试通过；远端 macOS 15 的原始错误尚未重新验证，不能宣称 CI 已修复 |

三端核心都保持原有上游 commit、Go、标签和目标架构。macOS TUN 内嵌归档摘要同步到
新核心，未放宽核心身份验证。新内容寻址镜像字段仅表示预期身份，**不代表镜像已上传**；
缺少镜像时仍沿用项目既有的固定源码重建路径。

| 本地新资产 | SHA-256 |
| --- | --- |
| Android libgojni.so | `41f36eba2846cf470e8fc78230ea5908da3fc204c00f0e495b360576129fb285` |
| macOS AtlasCore.gz | `274120bc51aa3afb13662d0105b252472133f3764eb85f3b3e8046cee6a1edd9` |
| Windows mihomo.exe | `1109fa80a2e90e6429204ae6f2d1b465d082e292e4ed45e5bdea63fd4f822287` |

核心扩展摘要：`8b813d2479840161797631a3ac6c92c1ff79062794a4ec824804926e19aac259`。
三端资产校验、Android build-info/JNI ABI/16 KB ELF 对齐均通过。

### 验证说明

- 新增 `SSRVPN_Android/test/subscription_basic_auth_test.dart`，加入常规测试发现。
- 共享现有 URL、网络传输、配置测试中补回归，不建立第二套生产错误状态。
- 核心回归源为 `native/proxy_traffic/dns_buffer_test.go` 和
  `native/proxy_traffic/ipv6_capture_test.go`；对应构建脚本会执行。
- `docs/audit/verify_generated_dns_policy_test.go` 消费
  `export_rule_dns_fixture.dart` 的真实生成结果，复制到固定核心 `dns/` 后设置
  `SSRVPN_DNS_POLICY_FIXTURE=<JSON路径>`，运行 `go test ./dns -run TestSSRVPNGeneratedParentProxyDNS`。
  原有 `repro_dns_policy_test.go` 刻意保留修复前错误策略，是历史红证据，不能当作新策略验收。
- 完整门禁使用 `make verify`。本机 Xcode 27 SDK 的最低部署目标为 12；仅本轮原生测试
  用临时 `XCODE_XCCONFIG_FILE` 指定 12.0，仓库仍声明 macOS 11。此测试不证明 macOS 11 兼容性。
- 未操作用户当前 VPN、系统代理、DNS、防火墙或订阅；未安装本轮候选客户端。

### 本轮验证结果

- `make verify` 退出码 0，日志末尾为 `All verification commands completed.`。
  其中共享层 1,311 通过 / 1 跳过，Android 339 通过，macOS 344 通过，
  Windows-on-macOS 311 通过 / 7 跳过；所有覆盖率门槛通过。
- 共享、Android、macOS、Windows 四项 analyzer 均零诊断；发布工具 436 项通过；
  TUN DNS 事务行为 26/26 通过；实际新 macOS 核心四种模式的生成规则验证通过。
- Android Gradle 原生任务成功，其 `app:testDebugUnitTest` 为 UP-TO-DATE；
  JUnit 结果为既有 188 项、零失败，不冒称本轮重新执行了这 188 项。
- macOS 原生脚本退出码 0，临时 deployment target 12；退出后崩溃/残留进程门禁通过。
  Xcode 的 CoreDevice/CoreSimulator 版本警告及第三方 deprecated API 警告未阻止 macOS 测试；
  本轮没有改系统 Xcode 组件，也不把它计作 iOS 模拟器或 macOS 11 验收。
- 完整门禁进行期间，最终复核补充了“内置代理子域不覆盖手动直连父域”的同类修复。
  完整门禁中的共享测试对应细化前快照；细化后的共享全套、覆盖率和静态检查另行补跑，
  最终结果见下文，避免把不同快照混称为一次完整发布验证。
- 最后细化后的共享全套：**1,312 通过 / 1 跳过**，覆盖率 **89.13%**；
  四项 analyzer 再次零诊断，Dart 格式 / ShellCheck / 文档链接 / `git diff --check` 通过。
  三端客户端套件与最终共享套件合计 **2,306 通过 / 8 跳过**；Windows 跳过项不算系统验收。
- 修复后阶段区分：**代码修复完成；三端核心重建完成；本地自动化通过；真机安装验收未做；
  Windows/macOS 远端 CI 未重跑；公开版本未发布**。远端 macOS 15 测试证书问题是否消除仍待该环境确认。

本轮本地完整日志：`/tmp/ssrvpn-repair-verify.log`；最终共享补测：
`/tmp/ssrvpn-repair-final-shared.log`；最终 analyzer：
`/tmp/ssrvpn-repair-final-analyze.log`。仓库仅保存脱敏结果摘要，未保存真实订阅、私钥或原始用户配置。
