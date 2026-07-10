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

SSRVPN 不再使用 setuid root 核心、`osascript` 管理员授权或持久化特权二进制。
当前版本在 macOS 上会在触达核心启动链路前拒绝 TUN 模式，并提示用户切换到系统代理模式。

核心资产以普通用户权限安装为 `0755` 文件。启动前会拒绝符号链接、非普通文件以及 setuid/setgid 位；安装和复用时会用应用包中的可信 SHA256 清单校验核心内容。旧版本遗留的链接或带特权位核心会被安全替换，而不会跟随链接修改其目标。

恢复 macOS TUN 的前提是引入受审计的 Network Extension 或最小权限特权辅助程序，并完成相应签名、公证、IPC 认证和升级/卸载设计。在此之前，不应重新引入 setuid root 方案。

## Android apiSecret 存储

Android 使用 `flutter_secure_storage` 将 Clash API secret 保存到 Android Keystore 支持的安全存储。旧版本曾使用 Base64 编码的 `SharedPreferences` 或设置 JSON，这不是安全存储方式；升级时 SSRVPN 会先确认安全写入成功，再删除旧值并清理磁盘上的遗留副本。

新安装首次加载设置时会生成随机 apiSecret 并保存到加密存储。VPN service 的原生重启路径不会把 secret 回写到普通 `SharedPreferences`；如果没有从 Flutter 层传入 secret，会跳过需要认证的代理组切换。

安全存储读取或写入失败时，初始化/保存必须明确失败，不能静默轮换 secret 或留下内存、JSON 与 Keystore 三份状态不一致。

严禁将 apiSecret 存放在：

- 明文文件。
- Base64 编码的 SharedPreferences。
- 编译期常量。
- 源代码。
- 日志或崩溃报告。

## 桌面端本地数据

macOS 和 Windows 版的设置、订阅 URL、apiSecret 和缓存保存在应用配置/便携目录中。这是当前的产品取舍：用户卸载 macOS 应用时可以同步清理配置和缓存，Windows 用户删除整个文件夹即可清空软件数据。

因此桌面端不会默认迁移到 Keychain 或 Credential Manager。用户应保护自己的系统账号、磁盘和便携目录，不要把配置目录打包发给他人。
