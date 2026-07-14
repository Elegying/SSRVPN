# ADR-001：桌面端 API Secret 的长期存储

## 状态

已接受；Windows 安装器的数据保留条款已于 2026-07-14 部分取代

## 日期

2026-07-13

## 背景

SSRVPN 使用 `apiSecret` 保护本机 Mihomo 控制接口。旧版 macOS 和 Windows 会把长期
secret 与普通设置一起写入 `settings.json`，导致配置备份、便携目录或同一账号下能读取
文件的进程可以直接获得该 secret。

应用仍需要在启动 Mihomo 时生成运行时 `config.yaml`，Mihomo 也必须从该文件读取
secret。因此本决策解决的是长期设置存储和迁移，不声称运行期间完全消除明文副本。

## 决策

1. 长期 `apiSecret` 与普通 `settings.json` 分离：
   - macOS 当前公开包采用 ad-hoc 签名，使用 Application Support 数据目录内独立的
     `.api-secret` 文件。数据目录设为 `0700`，秘密文件先以空临时文件创建并设为
     `0600`，随后写入并原子替换，再 `fsync` 数据目录；读取时拒绝符号链接和非普通文件，
     并修复/验证权限；启动和重置会清除崩溃遗留的 `.api-secret.tmp.*`；
   - Windows 使用系统 `CryptProtectData` / `CryptUnprotectData` 生成与当前登录用户绑定的
     `.api-secret.dpapi` 密文。密文先写入并 flush 同目录独占临时文件，再用带
     `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` 的 `MoveFileExW` 替换旧值；
     替换失败时不得截断或删除上一份可用密文，后续读写会清理崩溃遗留的加密临时文件。
2. 当目标存储还没有可用 secret、旧 `settings.json` 或 macOS 旧
   `SharedPreferences app_settings` 中存在 secret 时，必须先写入目标存储，再回读并
   逐字验证。只有验证成功、无 secret 的新 `settings.json` 也落盘后，才允许清理旧
   副本；写入或回读失败必须明确失败，不能删除唯一可用副本。目标存储已有值时，以其
   为准并清理 JSON/SharedPreferences 的旧副本。完整设置解析失败时仍要独立提取可恢复
   secret；坏文件备份必须删除 `apiSecret`，无法安全清理时不能原样归档。
3. 普通设置保存会从序列化结果中移除 `apiSecret`。修改端口、主题或其他设置不得再次把
   secret 写回 `settings.json`。
4. Mihomo 运行期间的 `config.yaml` 仍必须包含控制接口 secret：
   - macOS 以独占方式创建空临时文件，先执行 `chmod 0600`，再写入含
     secret 的内容，最后通过原子 `rename` 替换正式配置；
   - Windows 运行时文件继承其所在数据目录的 ACL。安装目录和便携目录应保持为当前用户
     私有，不应放入公共共享目录。
5. 显式轮换和重置必须占用与普通设置更新相同的串行队列。替换值写入后先回读验证；若
   验证失败，恢复并验证旧值。重置只有在 secret 和默认设置文件提交成功后才删除其他
   用户数据；无法删除的条目必须列入失败，不能把部分重置报告为成功。
6. 内存中的 `AppSettings` 可以持有当前 secret，供本机控制接口请求和配置生成使用；日志、
   崩溃报告和诊断输出不得记录该值。

## 结果

- 复制 `settings.json` 不再同时复制长期 API secret。
- 旧用户可以沿用原 secret，迁移失败不会先破坏现有配置。
- Windows 进程或写入错误发生在替换前时，上一份 DPAPI 密文保持不变；解密失败不会自动
  删除密文恢复证据。
- 重置或显式更新 secret 时，写入、回读验证和失败回滚是提交新状态的前置条件；并发
  设置操作按调用顺序串行化。
- 运行时配置、进程内存和当前用户可读目录仍是敏感边界。获得同一用户权限的恶意进程
  仍可能读取运行中的 `config.yaml`、检查进程内存或调用当前用户可访问的本机接口；
  `0600`/DPAPI 不能防御已经控制同一登录会话的攻击者。
- Windows 便携模式保留可移动数据的产品特性，但移动或共享整个便携目录会同时移动订阅、
  缓存、DPAPI 密文和运行时配置，用户必须自行保护该目录。自 `v3.3.3` 起，安装版按照
  已确认的全新覆盖策略清除旧安装数据，不再保留或恢复 `.api-secret.dpapi`、订阅和设置；
  这只取代安装器迁移条款，不改变应用运行期间使用当前用户 DPAPI 保护长期 secret 的决策。
- macOS 公开包当前使用 ad-hoc 签名，没有稳定签名身份、provisioning profile 或
  `keychain-access-groups` entitlement。file-based Keychain 的默认访问控制会按代码
  designated requirement 跟踪创建应用；当前 ad-hoc 构建的 requirement 含构建相关
  `cdhash`，不能作为跨版本升级身份。因此本版本不使用 Keychain，避免升级后弹出访问
  提示或因用户拒绝导致启动失败。项目当前不购买 Developer ID，因此保持 `.api-secret`
  边界；只有分发决策被明确取代时，才以新 ADR 设计到 Keychain 的验证后迁移与回滚。

## 未采用的方案

### 继续把 secret 保存在 JSON

实现简单，但会让备份、诊断包和便携目录长期携带可直接使用的控制接口凭据，因此拒绝。

### 使用应用内固定密钥加密 JSON

固定密钥必须随应用分发，无法建立独立于应用文件的信任边界；自建密钥管理也会增加迁移
和恢复风险。Windows 使用 DPAPI；macOS 在拥有稳定代码签名身份前明确采用最小文件权限，
不把弱内置加密描述成系统凭据保护。

### 在当前 ad-hoc 包中使用 file-based Keychain

Keychain 本身能保护凭据，但默认 ACL 会跟踪创建应用的 designated requirement。Apple
要求该 requirement 既能被更新版本满足，又不能被其他程序满足；当前每次重新 ad-hoc
签名得到的 `cdhash` 不具备这种升级稳定性。仅用 bundle identifier 自定义 requirement
又会让其他同用户程序更容易冒充，因此当前拒绝该折中。

### 从运行时配置中完全移除 secret

Mihomo 需要该值保护控制接口，移除后会破坏当前控制链路。若未来核心支持由受保护 IPC
注入 secret，可通过新的 ADR 取代本决策中的运行时文件方案。

## 相关文档

- [安全策略](../../SECURITY.md)
- [公共用户指南](../USER_GUIDE.zh-CN.md)
- [Windows 安装、便携版与权限](../../SSRVPN_Windows/USER_GUIDE.md)

## 官方依据

- [Apple TN3137：macOS Keychain 与 Data Protection Keychain](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Apple TN2206：Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Microsoft：CryptProtectData](https://learn.microsoft.com/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
- [Microsoft：MoveFileExW](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw)
