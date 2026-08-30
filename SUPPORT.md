# 获取帮助

遇到问题时，请先按下面的顺序排查。这样通常比直接提交 Issue 更快，也能避免公开敏感信息。

## 1. 先确认基本信息

- 从 [GitHub Releases](https://github.com/Elegying/SSRVPN/releases/latest) 安装最新正式版。
- 确认平台受支持：Android 7.0+ arm64、Apple M 系列 macOS 11+、Windows 10/11 x64。
- SSRVPN 不提供节点或订阅服务；订阅账号、套餐、流量和服务端可用性问题请联系服务商。
- 暂时退出其他 VPN、代理、网络过滤或安全软件，再复现一次。

## 2. 按文档排查

- [公共用户指南](docs/USER_GUIDE.zh-CN.md)
- [常见问题排查](docs/TROUBLESHOOTING.zh-CN.md)
- [Android 安装与权限](SSRVPN_Android/USER_GUIDE.md)
- [macOS 安装与权限](SSRVPN_MacOS/USER_GUIDE.md)
- [Windows 安装与权限](SSRVPN_Windows/USER_GUIDE.md)

## 3. 提交可复现的问题

如果最新版本仍能稳定复现，请使用 [Bug 模板](https://github.com/Elegying/SSRVPN/issues/new?template=bug_report.yml)，并提供：

- SSRVPN 版本、操作系统版本、设备型号或 CPU 架构；
- 连接方式：Android 系统 VPN、系统代理或 TUN；
- 最短复现步骤、预期结果和实际结果；
- 应用显示的错误编号；
- 已脱敏的诊断文本或截图。

请不要公开订阅 URL、Token、节点地址、节点密码、API secret、Bearer token、真实用户名、完整本地路径或崩溃转储。无法确认是否安全时，宁可先不上传。

## 安全问题

凭据泄露、代理绕过、权限提升、更新链路或其他安全问题不要提交公开 Issue。请按照 [安全策略](SECURITY.md) 使用 GitHub 私有漏洞报告。

## 功能建议与贡献

- 新功能或体验建议使用 [功能建议模板](https://github.com/Elegying/SSRVPN/issues/new?template=feature_request.yml)。
- 准备提交代码前，请阅读 [贡献指南](CONTRIBUTING.md) 和 [社区行为准则](CODE_OF_CONDUCT.md)。
