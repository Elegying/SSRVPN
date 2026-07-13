# SSRVPN macOS 安装与权限

导入订阅、连接、状态判断和订阅刷新请先阅读
[公共用户指南](../docs/USER_GUIDE.zh-CN.md)。本页只说明 macOS 差异。

## 安装

1. 从项目正式 Release 或官网固定下载地址获取 `SSRVPN.dmg`。
2. 按发布页提供的 SHA256 校验文件核对 DMG。
3. 打开 DMG，把 `SSRVPN.app` 拖入 `Applications`。
4. 当前公开包未使用 Developer ID 公证。首次运行时，到“应用程序”中右键 SSRVPN，
   选择“打开”；不要通过关闭 Gatekeeper 的方式绕过提示。

## 系统代理与 TUN

- 系统代理无需管理员权限，适合浏览器和遵循 macOS 系统代理设置的应用。
- TUN 会接管更广泛的 IPv4/IPv6 流量。每次启动 TUN 时，macOS 会显示系统管理员授权
  窗口；管理员密码由 macOS 处理，SSRVPN 不读取或保存密码。
- 取消授权、授权超时或检测到冲突的隧道时，连接会失败并执行清理。重试前先退出其他
  VPN、TUN 或代理软件。

当前公开包是 ad-hoc 签名且未公证。TUN 授权只表示本机用户同意本次提权，不代表系统
已经验证软件发布者；应始终从正式渠道下载并核对 SHA256。

长期 API secret 不再写入普通设置 JSON，而是保存在 Application Support 数据目录的
独立 `.api-secret` 文件中；目录权限为 `0700`、文件为 `0600`。当前公开包没有稳定的
Developer ID 身份，直接使用 file-based Keychain 可能在升级后触发访问提示或拒绝，
因此暂不启用。该文件对当前登录用户下的恶意进程不是加密屏障，不要共享数据目录。

## 窗口与退出

关闭主窗口时应用可能继续驻留在菜单栏。需要重新打开时点击菜单栏图标；需要完全结束
核心、TUN 和系统代理时，从菜单选择“退出 SSRVPN”。

## 排查

Gatekeeper、TUN 授权、连接或代理恢复问题见
[常见问题排查](../docs/TROUBLESHOOTING.zh-CN.md)。

## 技术依据

- [Apple TN3137：macOS Keychain 与 Data Protection Keychain](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Apple TN2206：Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
