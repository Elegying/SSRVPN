# SSRVPN macOS 历史审查快照

> 本文只记录 2026-07-10 当时的实现与验证，macOS TUN、覆盖率、测试数量和安全存储
> 结论均可能已变化。当前状态以[项目健康文档](../docs/PROJECT_HEALTH.md)、
> [安全策略](../SECURITY.md)和[路线图](../docs/ROADMAP.md)为准。

更新时间：2026-07-10

## 当前行为

- 系统代理模式保留正常的 Mihomo 启动、配置校验、健康检查和代理接管流程。
- TUN 模式暂时停用，并在任何核心探测或执行前明确失败。当前版本不会请求管理员密码，也不会创建 setuid root 核心。
- 核心安装拒绝符号链接、目录和带 setuid/setgid 位的文件；应用会校验打包清单中的可执行文件 SHA256，并以普通 `0755` 权限原子替换旧核心。
- 系统代理只会在当前配置仍精确属于 SSRVPN 时恢复，避免覆盖用户或其他代理软件之后的修改。
- 启动、停止、意外退出清理和代理写入已串行化，减少双击连接、快速退出和核心异常退出造成的竞态。

## 验证结果

- `flutter analyze --fatal-infos --fatal-warnings --no-pub`：通过。
- `flutter test --coverage`：34 个测试通过，行覆盖率 32.21%。
- `flutter build macos --debug --no-pub`：通过。
- `scripts/check-macos-core-privileges.sh`：通过。
- `scripts/check-desktop-startup-guards.sh`：通过。

## 尚未完成

- 要恢复 TUN，必须实现受审计的 Network Extension 或最小权限辅助程序；不能恢复旧 setuid root 方案。
- Developer ID 签名、公证、首次启动、系统代理恢复和真实网络切换仍需在发布机上做端到端验收。
- 本地 Debug 构建不能替代 Release DMG 的签名、公证与陌生机器安装验证。
