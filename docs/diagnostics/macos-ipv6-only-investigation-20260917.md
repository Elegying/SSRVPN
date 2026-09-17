# macOS IPv6-only 目标访问归因（2026-09-17）

## 结论与证据边界

本轮没有证明需要修改客户端转发逻辑的缺陷，未修改生产代码、配置、订阅或远端服务，未重连、重启、推送或发布。现有未提交工作全部保留。

维护者明确说明当前节点无 IPv6 出口，且没有可用的 IPv6 出口节点。实测显示：IPv6-only 查询目标在物理 Wi-Fi 上成功，在显式 SOCKS 和 TUN 上均失败；两条失败路径均走 PROXY。国内 IPv6 DIRECT 正常。macOS 上 TUN 的 IPv6 DIRECT 已实测成功；失败范围与当前代理出口限制一致。未取得远端服务端错误，不能进一步断言具体远端路由、防火墙或拒绝机制。

## 当前候选身份

- 工作树基线：`712a6d02173628b1ba39545e116a07d991154102`，存在大量既有未提交修改。
- 安装应用：`/Applications/SSRVPN.app`，`com.ssrvpn.ssrvpnClient`，5.0.8 / 5008。
- 安装 App.framework/App SHA256：`b0342529810769f0bbc3b8ce7318ba6108cf06863064bc2bec7ea8cd7fd0e32e`。
- 安装包与仓库 AtlasCore.gz SHA256 相同：`afe3bdec05c62fd79adb4c3b36271e1200f427d0af2dfa60489fe64dadf5b1cd`。
- 用户数据目录核心 SHA256：`7d95f1a82fd1a69dfa3b0417850c2f5465877766b8b62694a056142919fa8f00`，与资产清单一致。
- 实际控制 API 返回 `v1.19.29-ssrvpn.1`，rule 模式、IPv6 开启、TUN gVisor / utun4；混合端口 7890、SOCKS 7891。当前代理类型 Hysteria2。
- 磁盘 DNS 为 IPv6 开启 / fake-ip。目标 IPv6 路由实际指向 utun4；普通 default 条目仍可指向 en0，不能仅凭 default 条目判断是否接管。
- `codesign --verify --deep --strict` 通过；三端核心源码契约检查通过。
- **身份限制**：root TUN 运行目录不可由当前普通用户读取，未独立取得实际执行文件哈希。API 版本不是哈希证明；本轮未重建应用，也未取得完整 Flutter 源码构建溯源。不能声称完整工作树与正在运行的二进制逐字节一致。

## 对照方法与实机结果

相同域名固定同一真实 A/AAAA，通过 `curl --resolve` 保留 TLS/SNI/HTTP Host。Wi-Fi 使用 en0；显式代理使用 SOCKS5；TUN 使用默认连接且禁用 curl 环境代理。连接超时 4 秒、总超时 7 秒。没有关闭证书验证。用认证核心日志观察规则和出站，仅保存脱敏摘要。

| 目标 | 物理 Wi-Fi | 显式 SOCKS | TUN | 核心观察 |
| --- | --- | --- | --- | --- |
| IPv4-only `ipv4.icanhazip.com` | HTTP 200 | HTTP 200 | HTTP 200 | Match → PROXY |
| 国内双栈 `www.baidu.com` 固定 A | HTTP 200 | HTTP 200 | HTTP 200 | 国内域名规则 → DIRECT |
| 国内双栈 `www.baidu.com` 固定 AAAA | HTTP 200 | HTTP 200 | HTTP 200 | 国内域名规则 → DIRECT |
| IPv6-only `ipv6.lookup.test-ipv6.com/ip/` 固定 AAAA | HTTP 200 | TLS 握手失败 | TLS 握手失败 | 海外服务规则 → PROXY |
| 海外双栈 `www.cloudflare.com` 固定 AAAA 入站 | TLS 握手失败 | HTTP 200 | HTTP 200 | 海外服务规则 → PROXY |
| Cloudflare IPv6 字面地址 HTTPS | TLS 握手失败 | TLS 握手失败 | TLS 握手失败 | Match → PROXY |

双栈海外请求成功与域名恢复后优先 IPv4 的实现一致，但生产日志不披露代理协议实际承载的最终目标地址族，本轮没有解密抓包证明该字段。字面地址在物理路径也失败，不能据此归因 SSRVPN；该目标不作为正向 IPv6 出口验收依据。

另做正常域名解析路径验证：

- 查询目标真实 DNS：A 记录 0、AAAA 记录 1；系统给出 Fake-IP IPv4。固定真实 AAAA 和普通 Fake-IP 域名请求均在代理路径失败，失败并非只发生于 Fake-IP。
- Cloudflare 真实 DNS 有 A/AAAA；普通域名的 TUN、SOCKS5-hostname 请求均 HTTP 200。
- `wrong.host.badssl.com` 在 TUN、SOCKS5-hostname 均被拒绝（curl 60），证书域名校验仍有效。
- IPv6-only 失败后，双栈 HTTPS 仍成功、核心 API 仍响应。没有把单个目标失败升级为整体断连。

## 协议与诊断边界

`native/proxy_traffic/target_address.go` 在路由完成后生成 IPv4 优先的候选，DIRECT/拒绝出口保持原行为；无可恢复域名的 IPv6 字面地址不转换，解析失败不降级为 DIRECT。

`native/proxy_traffic/macos.patch` 在现有拨号重试内逐个取候选，最终拨号失败才记录 IPv6 失败观察。该机制**不等于任意应用层错误均可重试**。

当前 Hysteria2 依赖 `sing-quic` 的 DialConn 先打开 QUIC stream；Write 发送目标和首段载荷；首次 Read 才读取远端 TCPResponse。因此远端连接失败可能出现在拨号循环结束以后。核心的路由日志不是 HTTPS 成功证明；没有 IPv6 拨号失败计数，也不代表所有 IPv6 目标可用。

本轮未改成首次读失败后重发：已经发送的应用载荷不能无条件重放，且 IPv6-only 根本没有 IPv4 可退。没有将缺乏远端确认的错误包装成“节点永久不支持 IPv6”。如果后续完善读写阶段诊断，需要保留具体协议错误与请求阶段证据，不能把通用 EOF/TLS 握手失败一律归为 IPv6 出口故障。

## 自动化验证

使用与安装包哈希相同的仓库核心资产，启动隔离的本地测试核心；不改变系统路由：

- `python3 scripts/check-core-dual-stack.py`：通过。覆盖 TCP/UDP 目标 IPv4 优先、IPv6-only、DNS 回退、IPv4/IPv6 DIRECT、TLS/SNI、错误证书拒绝、有限失败观察、失败后核心可用。
- `python3 scripts/check-core-dual-stack-protocols.py`：SS、Trojan、AnyTLS 三组通过；覆盖加密 TCP/UDP 实际数据、IPv6-only、字面地址及 UDP association 复用。
- `python3 scripts/core-traffic-source.py verify`：三端源码契约通过。
- `git diff --check`：通过。

本轮未定位新的可修复转发缺陷，因此未人为增加镜像实现的单元测试，未重跑无关 UI/全项目构建。隔离环境的 IPv6-only 成功不是当前真实节点的 IPv6 出口成功，也不是 Android/Windows 实机通过。

## 路由器补充证据（维护者提供，非本轮自行复测）

维护者在 iStoreOS 上固定目标 IP，对比 Open-Box 与 WAN 直连：有效查询端点均 HTTP 200；洛杉矶 IPv4/IPv6 HTTPS 检测端点均证书域名不匹配，两条路径证书指纹相同；对应 IPv6 HTTP 端点成功。证书的 `*.test-ipv6.com` 不覆盖 `ipv6.losangeles.test-ipv6.com`。

路由器还存在“直连支持 IPv6、代理仅 IPv4”的已知策略限制。这与检测服务器证书问题、SSRVPN 当前节点的出口能力是三个不同层面。没有为测试站点分数放宽证书验证或修改 Open-Box/SSRVPN 路由。

## 本轮交付与剩余限制

仅新增本报告并补充 ADR 中的读写阶段诊断边界，无生产代码修改、无新候选安装、无公开发布。

脱敏实测原始摘要存于忽略目录 `artifacts/ipv6-only-investigation-20260917/`，不包含订阅、密码、密钥或公网出口地址。

未覆盖：真实 IPv6 出口节点的正向代理验收、root 运行核心独立哈希、远端服务端日志、代理协议最终目标地址族抓包、Android/Windows 本轮实机验证。按维护者要求不继续寻找 IPv6 节点，不改变现有连接或远端配置。
