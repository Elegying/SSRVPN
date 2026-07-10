# SSRVPN 综合代码审查报告

审查日期：2026-07-10

审查基线：已发布的 `v2.4.5` (`04817a9`)

工作分支：`fix/comprehensive-audit-v2.4.5`

## 结论

本轮审查覆盖 Android、macOS、Windows、共享包、启动/退出链路、订阅与更新边界、原生桥接、日志/崩溃报告、构建脚本和 GitHub Actions。确认的问题已经按小步提交修复，并用回归测试或静态守卫固化。

“私家车”延迟实现、测试和相关延迟文件与 `v2.4.5` 保持一致，本轮没有修改其显示逻辑。

当前代码已经达到“可进入跨平台 CI 和真机验收”的状态，但还不应直接发布：macOS TUN 被安全地停用，Windows 原生 Release 构建只能在 Windows CI 验证，Android VPN/覆盖安装仍需要真机测试；此外 GitHub `main` 仍落后于已发布的 `v2.4.5`，应先把本分支通过 PR 合回主线。

## 已修复的关键问题

### 启动、停止与状态一致性

- 串行化桌面核心启动、停止、代理写入和意外退出清理，避免双击连接、快速退出和异常退出互相覆盖。
- 核心初始化完成后才发布服务实例；设置和订阅单例共享同一个初始化 Future，失败后允许重试，不再暴露半初始化对象。
- Android VPN 权限回调使用启动代次校验，过期授权结果不能复活已经取消的连接；原生桥接健康检查失败时不再假装启动成功。
- Windows 第二实例明确退出，且只有当前代理配置仍属于 SSRVPN 时才恢复备份；macOS 同样使用精确 host/port 所有权判断。
- 启动日志写入改为尽力而为并按大小轮转，日志目录或文件异常不会阻断应用启动。

### 更新与发布供应链

- Android、macOS、Windows 更新下载均要求精确资产名、HTTPS、受信 GitHub host、大小上限和 SHA256；重定向后的最终 URL 也重新校验。
- Android 在申请“安装未知应用”权限前以及调用系统安装器前两次验证 APK：包名、版本号和签名证书/轮换历史必须与已安装应用兼容。
- 发布资产检查使用 GitHub 认证并核对远端 digest 与 `.sha256` 文件；发布版本同时校验三端 build number。
- Release job 必须来自 `main`，手动发布 SHA 也必须属于主线；所有 GitHub Actions 固定到不可变 commit。
- Dependabot 改为在 Flutter workspace 根目录运行，依赖检查只解析一次 workspace。

### 原生权限与平台安全

- 删除 macOS `osascript` + setuid root 核心模型。TUN 在任何核心探测/执行前失败；系统代理模式不受影响。核心安装拒绝链接、目录、setuid/setgid 文件，并校验可信可执行 SHA256。
- 修复 Windows PE 安全标志错误：旧脚本把 `0x1000` 当作 CET，实际会设置 AppContainer。现在通过 `/CETCOMPAT` 与 `/GUARD:CF` 链接器选项构建，并禁止发布脚本再修改 PE 头。
- 删除旧 Windows 进程缓解策略例外的创建路径，提供独立清理脚本；原生诊断只在未处理异常时生成 dump，并限制保留数量。
- Android 动态广播接收器保持应用内部；安全存储失败会显式传播，旧 apiSecret 只有在 Keystore 写入成功后才删除。

### 不可信输入、资源和性能边界

- 订阅刷新改为事务提交；解析、缓存或元数据保存失败会保留最后一个有效状态并回滚。
- 订阅 URL 只接受 HTTP/HTTPS，所有路径拒绝 HTTPS→HTTP 降级；连接、TLS、无数据读取和慢速滴流均有边界，Android gzip 解压后限制为 20 MB。
- 手写 HTTP 解析限制响应头、正文和 chunked 元数据，并严格检查 `Content-Length`、结束 chunk 和截断响应。
- 订阅合并从潜在 O(n²) 名称查找改为集合索引，并限制输入总量、来源数、节点数、字段长度、嵌套深度和集合大小。
- 导入节点按协议校验必需字段、端口、类型和标量大小，修复重复转义并过滤不可运行节点。
- 进程超时清理不会无限等待仍持有输出管道的子进程；日志脱敏先截断恶意超长输入，崩溃报告限制文件数、单文件和总读取大小。

### CI、资产和维护

- `make verify` 现在会运行共享 barrel 守卫、版本/核心资产/秘密检查、三端 Flutter 测试与覆盖率，以及 Android Kotlin/JUnit 测试。
- 修复 Flutter 3.44 覆盖率参数，CI 产出标准 `coverage/lcov.info`。
- GeoIP 数据已更新到 2026-07-10；日常 CI 只校验仓库固定哈希，独立 freshness workflow 检查上游，Release 再同步最新数据。
- macOS 特权模型和 Windows 启动器安全均有静态发布守卫，避免旧危险逻辑回流。

## 最终验证证据

| 检查 | 结果 |
|---|---|
| `make verify` | 通过 |
| Workspace analyze | 无问题 |
| 共享包 | 182 个测试通过，59.30% 行覆盖率 |
| Android Flutter | 83 个测试通过，45.49% 行覆盖率 |
| Android Kotlin/JUnit | Gradle `app:testDebugUnitTest` 通过 |
| macOS Flutter | 34 个测试通过，32.21% 行覆盖率 |
| Windows Flutter | 30 个测试通过；1 个 Windows-only Mihomo 集成测试在 macOS 跳过；14.05% 行覆盖率 |
| macOS Debug 构建 | 通过 |
| v2.4.5 远端资产/校验和 | APK、DMG、ZIP 均存在且 SHA256 匹配 |
| 本地发布产物 smoke | 本地未生成 APK/DMG/ZIP，因此按 `--allow-missing` 跳过 |
| 性能基线 | Home controller 1706 ms；subscription parser 1318 ms；无 adb 设备样本 |
| “私家车”延迟差异检查 | 与 `v2.4.5` 无差异 |

## 剩余风险与发布阻断项

1. macOS TUN 当前不可用。这是移除不安全 setuid root 模型后的明确安全取舍；恢复前必须完成 Network Extension 或最小权限辅助程序方案。
2. 本机不能构建/运行 Windows 原生 launcher，因此 `/CETCOMPAT`、CFG、便携 ZIP 和旧例外清理必须由 Windows CI/VM 再验证。
3. Android 需要 arm64 真机验证 VPN 权限、快速连接/取消、Tile 冷启动、前台服务恢复、未知来源授权和覆盖安装。
4. macOS/Windows 仍没有付费平台证书；公开分发会遇到 Gatekeeper/SmartScreen 信任提示。
5. Flutter 已警告未来需要迁移 Android Built-in Kotlin；这不是当前构建失败，但应在升级 Flutter/Gradle 前完成。
6. GitHub `main` 仍停在 `v2.4.3`，而最新发布与本轮修复在其他提交线上。新的 Release 守卫会拒绝未先进入 `main` 的 tag，这是正确行为，也意味着必须先合并主线。

## 如果这是我的项目，下一步会做什么

1. 先开 PR，把 `v2.4.5` 与本轮审查分支线性合回 `main`，让 GitHub 三平台 CI 全绿；不直接在审查分支打 tag。
2. 做一轮有脚本记录的发布前真机矩阵：Android arm64 手机、Windows 11 干净 VM、两台干净 macOS 用户环境，覆盖首次启动、重复启动、连接/取消、异常退出、代理恢复和升级。
3. 把 macOS TUN 当作单独的安全项目：先写威胁模型和 ADR，再选择 Network Extension 或 SMAppService 管理的最小辅助程序；在实现完成前从 UI 明确标记不可用。
4. 将这一批行为变化作为 `2.5.0` 预发布候选，不沿用 `2.4.5` 二进制；先发布 prerelease 给小范围用户验证升级和回滚。
5. 接入 Android release keystore 的备份/轮换演练；如果用户量扩大，再投入 Developer ID 公证和 Windows Authenticode。
6. 迁移 Built-in Kotlin，并按可回滚的小批次更新依赖；每批只处理一个生态，避免把工具链升级和业务修复混在一起。
7. 最后再处理大文件和 UI 重构。优先依据性能基线和故障数据拆分 `ClashService`/Home 页面，而不是为了行数做高风险重写。
