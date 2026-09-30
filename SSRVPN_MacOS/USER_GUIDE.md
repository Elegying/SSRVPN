# SSRVPN macOS 安装与权限

导入订阅、连接、状态判断和订阅刷新请先阅读
[公共用户指南](../docs/USER_GUIDE.zh-CN.md)。本页只说明 macOS 差异。

当前正式 DMG 仅支持 Apple M 系列芯片，不支持 Intel Mac；系统要求为 macOS 13.0 或更高版本。

## 安装

1. 在“关于本机”确认设备使用 Apple M 系列芯片，再从项目正式 Release 或官网固定下载地址获取 `SSRVPN.dmg`。
2. 按发布页提供的 SHA256 校验文件核对 DMG。
3. 打开 DMG，把 `SSRVPN.app` 拖入 `Applications`。
4. 当前公开包采用 ad-hoc 签名，没有 Developer ID，也未经过 Apple 公证。先从“应用程序”尝试打开 SSRVPN。
5. 如果系统提示无法验证开发者，且你已确认下载来源和校验和，打开“系统设置 → 隐私与安全性”，
   找到 SSRVPN 的阻止记录，选择“仍要打开”，再按系统提示确认。不同系统版本的按钮文字可能不同。
6. 如果显示软件会损坏电脑、包含恶意软件，或校验和不一致，停止安装并反馈具体提示。
   如果设备由组织管理且没有允许入口，请联系管理员；不要关闭 Gatekeeper 或执行删除隔离属性的命令。

将 DMG 与同一正式版本的 `SSRVPN.dmg.sha256` 放在同一文件夹，在该文件夹打开终端执行：

```bash
shasum -a 256 -c SSRVPN.dmg.sha256
```

结果必须为 `SSRVPN.dmg: OK`。校验和证明下载字节与发布记录一致，不代表 Apple 已审核或信任发布者。
“仍要打开”只针对你确认的这个应用；它与之后连接 TUN 时的管理员授权是两件事。
苹果的[安全打开应用说明](https://support.apple.com/102445)解释了这些提示和单应用例外。

## 系统代理与 TUN

- 系统代理无需管理员权限，适合浏览器和遵循 macOS 系统代理设置的应用。
- TUN 会接管 IPv4 / IPv6 流量，并沿用同一套分流规则；IPv6-only 代理目标仍需要节点具备 IPv6 出口。客户端不会修改 macOS 的全局 IPv6 开关。每次启动 TUN 时，macOS 会显示系统管理员授权
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

### 网络环境变化后的恢复

- 自动代理（PAC/WPAD）启用时，系统代理模式会说明冲突原因。关闭自动代理后重试，或使用 TUN；客户端不会擅自覆盖自动代理策略。
- 切换 macOS 网络位置后，原位置中的网络服务仍然存在。若提示恢复未完成，请在系统设置中切回原网络位置后重试断开；客户端会保留恢复记录和必要的监听进程，直到完成恢复。
- 新建的 TUN DNS 恢复记录使用服务稳定 ID，网络服务改名后仍能找回原 DNS。旧版记录没有稳定 ID，若无法确认服务身份，会保留记录而不猜测恢复目标。
