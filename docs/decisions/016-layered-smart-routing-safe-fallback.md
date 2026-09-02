# ADR-016：分层智能路由与可用性优先的代理兜底

## 状态

已接受（2026-09-02），取代 [ADR-015](015-gfw-proxy-default-direct-routing.md)。

## 现状核查

三端由共享 `ClashConfigGenerator` 生成 Mihomo 配置，订阅只提供节点 `proxies`，不会把
订阅内的 `rules`、DNS、TUN 或脚本带入运行配置。这样可避免不受控订阅规则覆盖用户设置和
客户端安全边界。当前核心和网络接管如下：

- Android 使用固定源码提交构建的 Mihomo C-shared bridge、系统 `VpnService`、gVisor TUN；
  Windows 使用 Mihomo v1.19.27，macOS 使用 Mihomo v1.19.29。
- TUN 使用 Fake-IP、DNS 劫持、`respect-rules`、代理国际 DoH 和国内直连 DoH；Mihomo 与
  DNS 均关闭 IPv6。Android/Windows 捕获 IPv6 后由首条规则拒绝，避免 IPv4-only 策略旁路。
- macOS/Windows 系统代理模式只接管遵循系统代理的流量；需要覆盖游戏或不遵循系统代理的
  应用时由用户选择 TUN。系统代理与 TUN 的事务、所有权、DNS 恢复和失败关闭边界不变。
- HTTP、TLS、QUIC 嗅探用于补充纯 IP 连接的域名信息。全局 `override-destination` 关闭，
  嗅探失败不阻断连接，流量继续进入 IP、GeoIP 和最终规则。

ADR-015 的 `MATCH,DIRECT` 会把未知海外裸 IP、规则漏项和 Telegram 一类非域名建链直接
送往本地网络；Android 的国内应用排除还会让这些应用完全绕过 Mihomo，使用户手动强制代理
无法覆盖。按国家判断 IP 也无法可靠识别使用海外 CDN、Cloudflare、AWS 或 Azure 的国内服务。

## 决策

### 规则优先级

Mihomo 按列表顺序首次匹配，智能模式固定使用以下层次：

1. IPv6 拒绝及回环、局域网、链路本地和 CGNAT 直连安全规则；这些目标不允许送往远端节点。
2. 用户手动强制代理；同一目标同时存在代理和直连设置时，代理规则先命中。
3. 用户手动强制直连。
4. 内置关键海外域名、Telegram 官方 IP，以及 Android 精确国外应用包名。
5. 用户反馈、AI、常用海外服务和流媒体域名规则集，动作 `PROXY`。
6. 国内企业域名规则集，动作 `DIRECT`；域名判断始终先于 IP、ASN 和 GeoIP。
7. 仅纳入阿里、腾讯、百度、字节已审查网络的窄范围 ASN 前缀，作为 `DIRECT,no-resolve`
   辅助判断；共享云、归属不清和未审查 ASN 不加入。
8. 固定提交的 GFW 域名集走 `PROXY`，固定提交的 CN 域名集、内置国内后缀和 `GEOIP,CN`
   走 `DIRECT`。
9. `MATCH,PROXY`。自动判断缺失、规则包暂不可用或域名嗅探失败时优先保证用户可访问。

本地/私网安全规则是唯一高于用户站点设置的保护层，避免把路由器、回环 API 或局域网设备
错误送往节点。所有自动服务、ASN、CN 和 GeoIP 规则都不能覆盖用户规则。

### DNS 与国内企业海外接口

用户强制代理、用户反馈、AI、海外服务、流媒体和 GFW 域名使用经 `PROXY` 访问的国际 DoH；
用户强制直连、国内企业、CN 和 `.cn` 使用国内 DoH。国内企业集合同时包含主域名、子域名、
API 与已知 CDN 后缀，所以 `api.*` 先由域名规则命中，不会因解析到海外地址再被 GeoIP 改判。
同一域名同时被用户设为代理和直连时，代理 DNS policy 使用首次写入语义，与路由优先级一致。

### Android 应用保障

删除国内普通应用的 `VpnService.addDisallowedApplication` 排除和对应 package visibility 清单；
除既有 ADB 工具外，所有用户应用进入 TUN。这样微信、淘宝、百度和国内 AI 应用可由国内域名
直连，也可被用户针对具体域名强制代理。Telegram、WhatsApp、Signal、Instagram、X、
YouTube、Gemini、ChatGPT、Netflix 等精确包名规则继续作为域名/IP 规则之外的第二保障。

### 可更新规则包

SSRVPN 自有规则通道包含 `ai_services`、`foreign_services`、`streaming_services`、
`china_domains`、`company_asn` 和 `user_feedback_rules`：

- 每个客户端内置一份完整 YAML 基线及 `manifest.json`，清单记录 schema、语义版本、条目数、
  固定上游提交和 SHA-256；构建门禁离线校验文件集合、格式、CIDR、摘要和数量。
- 启动时只修复缺失、链接、超限或语法无效的本地 provider。有效缓存原样保留，内置规则准备
  失败只记稳定告警，不阻断核心启动。
- 核心就绪十分钟后才通过 Mihomo API 一次性检查更新，所有下载经当前 `PROXY`。HTTP、解析
  或刷新失败时不删除本地有效文件，也不影响已经建立的连接。
- 规则版本作为仓库内一个原子变更审查；回滚时整体恢复 `rules/latest` 到上一已知版本。
  GFW/CN provider 仍使用同一不可变 MetaCubeX Git 提交，不改为可变上游地址。

### 不启用自动学习

本版不记录域名级 DIRECT/PROXY 成功历史，也不自动调整生产优先级。客户端没有可靠的应用层
成功定义，节点、网络和 CDN 的短时结果容易产生噪声或被投毒；如未来实现，必须本地、限量、
可清除，只能在自动规则层提供建议，永远不能覆盖用户设置或改变安全兜底。

## 与 Shadowrocket 的借鉴边界

Shadowrocket 对外说明的核心模型是接管应用流量，按域名、域名后缀、关键词、CIDR 和 GeoIP
匹配，并可从 URL 导入规则文件，同时支持 DoH/DoT/DoQ。SSRVPN 借鉴“域名优先、IP/GeoIP
兜底、远程规则资源、用户规则可编辑”的产品模型；不复制其闭源实现、HTTPS 解密、脚本或
URL 重写能力，也不为本次分流引入新的代理核心。

## 风险与回滚

- 国内企业域名误收会使应代理目标直连：海外/AI 规则在国内集合之前，用户强制代理可立即
  覆盖；规则通道可整体回滚，未知目标最终仍代理。
- ASN 可能包含共享业务：只采用窄范围已审查企业 ASN，域名和用户规则优先；发现误判时先从
  `company_asn` 移除，不扩大到“所有中国企业”自动猜测。
- 远程规则不可用或损坏：随包基线保证首次连接，缓存失败保留，准备失败不阻断启动。
- 若 v4.0.22 出现广泛回归，首选回滚远程 `rules/latest`；仍不能恢复时回滚到 v4.0.21，
  不移动既有标签、不改变订阅和用户设置格式。

## 验证守卫

- 共享测试解析完整配置并固定检查用户冲突、各层顺序、DNS policy、`MATCH,PROXY`、规则包
  安装、有效缓存保留和损坏缓存恢复。
- Android 测试要求国内应用不再被排除、国外应用包名仍在自动直连之前；原生桥守卫禁止重新
  引入国内应用旁路。
- macOS 使用内置 Mihomo 对系统代理与 TUN 配置执行真实语法加载；Windows 在线 CI 负责
  Windows TUN、构建和安装器 smoke，其他平台的模拟不能替代。
