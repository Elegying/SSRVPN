# SSRVPN 5.0.4 macOS 已连接实测与复审

## 当前会话

确认 /Applications/SSRVPN.app 为 5.0.4+5004，进程 81838；特权 TUN 核心为进程 82108。当前会话于本地 14:41:50 完成就绪，14:43:51 完成规则版本检查（2.0.1，无需下载）。检查结束时连续运行超过十分钟，未切换节点、断开、重连或修改运行中的规则、DNS、系统代理。

- 控制 API version/configs/providers/rules/connections 均可读；普通接口初次采样约 1–4 ms。
- 八组规则全部为 File provider，运行规则数量逐项匹配本地已验证清单，规则文件 SHA256 逐项一致。
- TUN 为 gVisor，utun4，auto-route 开启；测试外部地址 1.1.1.1 的路由指向 utun4。物理 default 路由仍为 en0 是本次分段路由方式的正常结果。
- 系统 HTTP/HTTPS/SOCKS 代理均关闭，与 TUN 模式一致；DNS 为运行脚本配置的 114.114.114.114，核心启用 any:53 劫持。
- 恢复记录已确认规则 2.0.1，无 rejectedThrough。本会话应用日志没有失败或恢复异常；额外约 20 秒核心日志采样无 warning/error/fatal。

## 小流量网络实测

所有 curl 传输退出码为 0、TLS 校验值为 0。测试未绕过 TLS 证书验证，未更改系统网络配置。

| 地址 | HTTP | 用时 | 核心实际分流 |
| --- | --- | --- | --- |
| www.baidu.com | 200 | 约 0.16 秒 | china-domains / DIRECT |
| www.qq.com | 默认 curl 为 501，浏览器 User-Agent 为 200 | 约 0.17 / 0.21 秒 | china-domains / DIRECT |
| www.gstatic.com/generate_204 | 204 | 约 0.42 秒 | foreign-services / PROXY |
| www.cloudflare.com/cdn-cgi/trace | 200 | 约 0.43 秒 | foreign-services / PROXY |

腾讯首页默认 curl 通过 TUN 和显式本地 mixed 代理均返回 501，更换浏览器 User-Agent 后返回 200；这些结果不支持将它归因于本次 TUN 传输故障。

五次短采样中，GUI CPU 0.0%，核心 CPU 0–3.6%；GUI RSS 约 70 MiB、核心约 55–58 MiB，结束快照约 45/42 MiB。RSS 和 ps 短时 CPU 不是 GPU、能耗或长期内存泄漏结论。

## 新发现并本地修复的异常恢复边界

新增的 TUN_RULE_FILES 缺失/空文件错误没有进入 SmartRuleRecovery 的既有回退识别，导致新候选文件丢失或为空时，即使有已确认旧规则也只会启动失败。用真实临时规则目录和恢复日志复现：修复前两种情况测试均失败。现在将这两种明确错误接入既有一次回退流程，仍排除权限和不明确的读取失败，不扩大重试次数。

修复后规则恢复与诊断共 44 项通过，静态分析及 diff 检查通过。该改动仅在本地源码，未提交、未构建新版本、未替换正在运行的 5.0.4。

## 边界与证据

此次是当前连接的只读检查、小流量网络测试及相关生命周期/规则恢复代码复核。没有执行断开后的 DNS/路由恢复、睡眠唤醒、切网、崩溃注入、长期负载或 UI/GPU 压测，因此不能保证这些场景均无问题。观察到的当前连接功能正常，未见新的在线故障。

脱敏采样与前后回归日志位于 artifacts/macos-5.0.4-live-audit-20260915。/memory 接口是持续流，核验工具改为只读取首帧并关闭；该接口返回 0，未将其用于资源结论，采用系统进程 RSS。
