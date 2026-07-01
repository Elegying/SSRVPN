# 安全策略

## 支持版本

安全修复默认面向当前 `2.x` 版本线，除非单独的 release 分支另有说明。

## 报告安全问题

涉及凭据泄露、代理绕过、权限提升、更新链路、崩溃转储泄露或签名密钥的问题，不要创建公开 Issue。

请私下联系项目维护者，并提供：

- 受影响的平台和版本。
- 可复现步骤。
- 预期行为和实际行为。
- 已脱敏的相关日志、截图或崩溃信息。

## 敏感信息处理

SSRVPN 日志必须脱敏或避免输出以下内容：

- API secret。
- 密码字段。
- Bearer token。
- 订阅 URL。
- 代理节点账号、密码和服务端凭据。
- 签名密钥、keystore、证书密码。

新增日志时，请优先使用共享包中的脱敏工具；如果无法可靠脱敏，应完全避免记录敏感值。

## macOS TUN 权限模型

macOS TUN 模式需要 Clash/Mihomo 核心二进制文件以 root 权限创建虚拟网卡。SSRVPN 使用 setuid root 模型：

1. 首次启用 TUN 时，SSRVPN 通过 `osascript` 请求管理员授权。
2. 核心二进制文件会被设置为 `root:wheel` 所有，并添加 setuid 位（`chmod u+s`）。
3. 只要二进制文件没有变化，后续启用 TUN 不需要重复输入管理员密码。

安全影响：

- 本机任意用户都可能执行带 root 权限的核心二进制文件。
- 如果核心文件被更新或替换，setuid 位会丢失，需要重新授权。
- SSRVPN 每次启动核心前都会检查文件所有者和 setuid 位，不匹配时重新请求授权。
- 授权后核心二进制文件不应对非 root 用户可写。

如果怀疑权限被篡改，可执行：

```bash
stat -f '%Su %Mp%Lp' /path/to/AtlasCore
```

正常情况下应显示 root 所有并带 setuid 位，例如 `root -rwsr-xr-x`。

如需撤销 setuid：

```bash
sudo chown root:wheel /path/to/AtlasCore
sudo chmod u-s /path/to/AtlasCore
```

## Android apiSecret 存储

Android 使用 `EncryptedSharedPreferences` 存储 Clash API secret，底层通过 Android Keystore 提供 AES-256 加密。旧版本曾使用 Base64 编码的 `SharedPreferences`，这不是安全存储方式；升级时 SSRVPN 会自动迁移到加密存储并删除旧 key。

严禁将 apiSecret 存放在：

- 明文文件。
- Base64 编码的 SharedPreferences。
- 编译期常量。
- 源代码。
- 日志或崩溃报告。
