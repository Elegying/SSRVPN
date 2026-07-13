# 安全策略

## 支持范围

安全修复面向当前最新稳定版 `3.x`。旧安装包和历史平台仓库不再单独维护；报告问题前请先确认能在最新 Release 复现。

## 私下报告

涉及凭据泄露、代理绕过、权限提升、更新链路、崩溃转储或签名材料的问题，不要创建公开 Issue。请私下联系维护者，并提供受影响平台和版本、最小复现步骤、预期与实际行为，以及已经脱敏的日志或截图。

不要发送真实订阅 URL、API secret、Bearer token、节点密码、服务端凭据、keystore、证书私钥或证书密码。

## 信任边界

SSRVPN 需要同时处理不受信任的订阅内容、网络响应、本地核心进程和操作系统网络设置。安全相关改动至少要满足：

- 订阅、重定向、压缩响应、节点数量和生成配置有明确边界，失败不能覆盖最后一份可用配置。
- 日志、错误与诊断信息使用共享脱敏逻辑；无法可靠脱敏时不记录原值。
- 更新只接受预期 HTTPS 来源、精确资产名、匹配版本与 SHA256，下载完成后再替换。
- 只停止 SSRVPN 能通过 PID、路径或会话证明归属的核心进程，不按通用进程名清理。
- 系统代理只在 SSRVPN 仍拥有对应端点时恢复，不能覆盖用户或其他软件之后的修改。

## 本地凭据与数据

`apiSecret` 是 SSRVPN 与本机 Mihomo API 之间的随机认证值，不是远端账号密码。

| 平台 | 长期保存 | 迁移规则 |
| --- | --- | --- |
| Android | Android Keystore 支持的安全存储 | 安全写入并确认成功后，才删除旧 SharedPreferences / JSON 副本 |
| macOS | Application Support 内独立的 `.api-secret`；目录 `0700`、文件 `0600` | 原子写入、同步目录并回读一致，无 secret 的 JSON 落盘后，才清理旧副本；启动/重置清除崩溃遗留的 secret 临时文件 |
| Windows | `.api-secret.dpapi`：当前用户 DPAPI 密文，同目录临时文件落盘后以 `MoveFileExW` 替换 | 安全写入并回读一致后，才清理旧设置 JSON；替换失败保留上一份密文，后续清理遗留临时文件 |

普通设置保存不得把 `apiSecret` 写回 JSON。轮换或重置必须与设置更新串行执行；新值回读验证失败时恢复并验证旧值。存储读写失败必须显式失败，不得删除唯一可用旧副本。旧 JSON 的其他字段即使损坏，也要独立提取并先迁移可恢复的 secret；诊断备份必须移除 `apiSecret`，无法安全清理时不得原样归档。

当前 macOS 免费包是 ad-hoc 签名，代码 designated requirement 不能跨构建稳定复用，
而 file-based Keychain 的默认访问控制会跟踪该身份。为避免升级后凭据访问提示或拒绝导致
启动失败，本版本不把长期 secret 放入 Keychain；`.api-secret` 仍是同用户可读的明文边界，
不能宣称达到 Keychain 的保护强度。配置稳定 Developer ID 后再迁移到 Keychain。依据见
[Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) 与
[TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。

订阅 URL、节点信息、缓存和其他非密钥设置仍保存在应用数据目录；Windows 便携版的数据目录位于程序旁。不要共享整个数据目录，并确保便携目录只对可信的当前用户开放。

Mihomo 运行时 `config.yaml` 必须包含 API secret 才能提供受认证控制接口，因此核心运行期间仍存在一份短期明文：macOS 以独占方式创建空临时文件，先将权限设为 `0600`，再写入含 secret 的内容并原子替换正式配置；Windows 继承应用/便携目录 ACL。同一系统用户下的其他进程仍可能读取该文件，这是当前残余风险，不应描述为“完全消除明文”。决策与回滚边界见 [ADR 001](docs/decisions/001-desktop-api-secret-storage.md)。

## macOS TUN 权限模型

macOS 不使用 setuid 核心，也不把 Mihomo 永久安装为 root。每次启用 TUN 时，应用通过系统管理员授权启动一个与当前应用会话绑定的临时 root runner：

- 启动前校验应用归属、核心和 runner 的固定摘要，并把所需文件复制到 root 管理的临时目录。
- runner 监视发起应用 PID，应用退出、断开、超时或校验失败时清理核心、路由与暂存文件。
- 普通系统代理模式继续以当前用户运行经过摘要校验的核心。

当前 macOS 包采用 ad-hoc 签名且未公证。管理员授权不能证明软件发布者身份；用户只能从官方 Release 或固定下载地址获取并校验 SHA256。面向更广泛公开分发前，应迁移到 Developer ID、公证以及经过审计的最小权限 helper 或 Network Extension。

## 分发限制

Android 正式包由项目固定的自签名 keystore 签名，后续版本必须保留同一签名谱系。macOS 与 Windows 当前没有付费平台签名，可能分别触发 Gatekeeper 与 SmartScreen 警告；SHA256 能验证下载完整性，但不能替代受信任发布者签名。

实现和发布检查见 [测试策略](docs/TESTING.md)、[发布签名说明](docs/RELEASE_SIGNING.md) 与 [发布检查清单](docs/RELEASE_CHECKLIST.zh-CN.md)。
