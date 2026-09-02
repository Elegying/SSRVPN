# ADR-015：智能模式使用 GFW 代理与默认直连

## 状态

已取代（2026-09-02），由 [ADR-016](016-layered-smart-routing-safe-fallback.md) 取代；
历史决策与 v4.0.19 行为继续保留供审计。

## 背景

旧“智能”模式只识别国内直连目标，未命中流量最终由 `MATCH,PROXY` 承接。
这种做法简单保守，但会让大量本可直连的普通服务消耗节点流量。项目已经具备固定版本
的 MetaCubeX 规则 provider、本地缓存、经代理下载和启动后刷新机制，可以在不增加产品
模式的前提下，将代理范围收紧到明确需要的目标。

## 决策

1. 界面仍只显示“智能”和“全局”。“智能”继续对应 `ProxyMode.rule` 和序列化值
   `rule`；“全局”继续对应 `ProxyMode.global`，行为不变。
2. “智能”规则按以下顺序生成：
   - IPv6 总拒绝，以及本地域名、回环、链路本地、私有网络和 CGNAT 直连；
   - 用户保存的强制代理域名或公网 IP；
   - OpenAI、ChatGPT、Google Play 等 SSRVPN 内置强制代理域名；
   - Windows 出口国家检测等平台运行规则；
   - `RULE-SET,ssrvpn-geosite-gfw,PROXY`；
   - `RULE-SET,ssrvpn-geosite-cn,DIRECT`、内置中国域名和 `GEOIP,CN,DIRECT`；
   - `MATCH,DIRECT`。
3. GFW 与 CN provider 同时固定到 MetaCubeX/meta-rules-dat 提交
   `200e6a86736cfab29aae7b07dc266e59f13bc13d`，不使用任何可变分支或发布别名。
4. 两个 provider 都使用 `PROXY` 下载，缓存在各端 Mihomo HomeDir 下的固定
   `providers/*.mrs` 路径，并在核心启动后通过同一次性 API 刷新列表检查更新。
   SSRVPN 的失败路径不删除 provider 文件；Mihomo 刷新失败时继续使用已有可用缓存。
5. 用户和内置强制代理域名、GFW 规则集使用
   `https://1.1.1.1/dns-query#PROXY` 与 `https://8.8.8.8/dns-query#PROXY`；
   CN 规则集和 `.cn` 继续使用国内 DoH。`respect-rules: true`、`direct-nameserver`、
   `proxy-server-nameserver` 和现有防循环设计保持不变。

## 结果与取舍

- 只有明确需要代理的服务消耗节点流量，大量普通国际服务改为直连。
- GFW 规则集可能有漏项或延迟；用户可通过既有“强制代理网站”补充，无需增加新模式。
- 无法获取最新 provider 时保留上次缓存；首次使用且没有缓存时，Mihomo 仍按自身配置
  加载结果处理，不会把 GFW 目标静默改成“全部代理”。

## 验证守卫

- 共享生成器测试解析完整 YAML，固定检查 provider URL、DNS policy、规则顺序和最终
  `MATCH,DIRECT`。
- provider 刷新测试要求 GFW/CN 同时进入启动后 API 刷新，失败响应不得改写既有缓存。
- Android、macOS、Windows 平台测试检查共享语义没有被平台配置覆盖；可用平台使用项目内置
  Mihomo 执行配置语法校验。
