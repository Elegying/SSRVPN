# Windows 候选验收提示词（2026-09-18）

以下内容可交给 Windows 上的代码助手执行；先以维护者提供的提交号核对候选身份。

```text
请在 Windows 的 SSRVPN 仓库验收 codex/dual-stack-startup-reliability 分支的本轮最新候选。
先读 AGENTS.md、git status，并保留已有未提交改动和用户订阅、配置。不要 reset、clean、卸载清数据。
核对维护者提供的提交号；只拉取本分支，不合并、不打标签、不正式发布。

本轮关键修复：TUN 提交、物理出口选择器就绪并进入运行状态之后，才启动内置节点健康检查，
避免 Hysteria2 等复用尚未绑定物理出口的启动期传输。另包含 DIRECT 双栈 TCP/UDP 地址选择、
同节点确认不清理连接、首次 IP 查询与外网观察启动窗口修复。

从这个提交对应的 SSRVPN CI 下载 core-assets 制品到仓库根目录；不能使用旧 Release 核心，
也不能忽略哈希不匹配。若制品尚未生成，明确等待，不冒用别的提交制品。
Windows assets/mihomo.exe SHA256 必须为：
69ba83753597335ee5e7bc05f17dd52e6d6419af4511ebccb286086c3d07a464
按 native/proxy_traffic/README.md 校验资产，使用 Flutter 3.44.1。
在 SSRVPN_Windows 中运行项目现有打包入口：
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tool\package_windows.ps1 -DartDefineFromFile ..\config\ssrvpn-usage-defines.json
检查命令退出码并核对产物内核心身份，保留账号流量统计的编译配置。

先不执行额外测速或手动 IP 重试，冷启动后连接原 Hysteria2 节点，记录：
1. 管理员授权完成、核心就绪、首次 IP 显示各自时间，区分人工授权等待与实际启动耗时。
2. 应用自身首次 IP 查询是否成功；外网观察应在连接成功 5 秒后启动，三地址最多两轮，任一成功即通过。
3. 正常网页可用时不能因启动期旧连接出现误导提醒；诊断 API 实际端口必须与健康检查一致。
4. 断开后重连两次，不能用后续手动查询成功代替首次查询通过。
5. 已选中同一节点的确认不得中断现有请求；真正换节点仍正确切换。
6. 无 IPv6 物理出口时，国内双栈 TCP/UDP/QUIC 与抖音桌面版应正常；纯 IPv6 DIRECT 失败不得影响其他连接。
7. PROXY 失败不得转 DIRECT；保留双栈 TUN 接管、规则优先、错误证书拒绝。没有 IPv6 出口节点则相关成功项写未测。
8. 检查 TUN 与系统代理模式、诊断打开/关闭、断开/退出恢复。需要管理员密码时交由用户输入。

Mac 两次冷启动首次 IP 查询分别约 1.37 秒和 1.11 秒；这不是 Windows 已通过的证据。
请记录实际结果，失败保留脱敏诊断和最小复现，不记录订阅 URL、密码、token 或原始配置。
输出通过/失败/未测矩阵，说明是否需要修复；未经另行授权不发布正式版。
```
