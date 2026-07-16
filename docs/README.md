# SSRVPN 文档中心

这里是仓库内当前有效文档的统一入口。正在开发的行为以当前源码和验证结果为准；用户
已经安装或下载到的行为以对应正式 Release、产物和发布工作流结果为准。

历史审查报告记录的是特定日期与提交上的判断，不代表当前版本状态，也不能替代重新验证。

## 用户文档

- [公共用户指南](USER_GUIDE.zh-CN.md)：导入、连接、状态判断、订阅刷新和安全提示。
- [常见问题排查](TROUBLESHOOTING.zh-CN.md)：按现象定位原因并采取动作。
- [Android 安装与权限](../SSRVPN_Android/USER_GUIDE.md)
- [macOS 安装与权限](../SSRVPN_MacOS/USER_GUIDE.md)
- [Windows 安装、便携版与权限](../SSRVPN_Windows/USER_GUIDE.md)
- [产品行为要求](PRODUCT_REQUIREMENTS.zh-CN.md)：不可随意改变的用户可见行为。

## 开发与维护

- [贡献指南](../CONTRIBUTING.md)
- [项目所有者手册](OWNER_GUIDE.zh-CN.md)：常用维护、验证和发布入口。
- [Monorepo 迁移说明](../MIGRATION.md)
- [项目管理](PROJECT_MANAGEMENT.md)：分支、源码与产物边界。
- [维护指南](MAINTENANCE.md)：日常维护和合并要求。
- [当前实现计划](../tasks/plan.md)与[执行清单](../tasks/todo.md)：本轮可维护性拆分的边界、验收和进度。
- [测试策略](TESTING.md)：本地、CI、原生与覆盖率验证。
- [性能基线](PERFORMANCE.md)：关键路径测量方法、比较边界与回归处置。
- [项目健康状态](PROJECT_HEALTH.md)：最近一次审查基线、证据与已知风险。
- [路线图](ROADMAP.md)：尚未完成的优先事项。
- [根变更日志](../CHANGELOG.md)：正式版本的用户可见变化。

## 发布与运维

- [发布检查清单](RELEASE_CHECKLIST.zh-CN.md)：正式发版的唯一逐步检查入口。
- [OSS 发布运维](OSS_RELEASE_OPERATIONS.zh-CN.md)：发布、密钥轮换、故障恢复和回滚。
- [免费分发与签名说明](RELEASE_SIGNING.md)：固定分发策略、校验方式和系统警告。
- [核心资产来源](CORE_ASSETS.md)：Mihomo、Android 原生核心与 GeoIP 来源。

## 安全与架构

- [安全策略](../SECURITY.md)
- [IPv6 双栈规范](IPV6_DUAL_STACK_SPEC.zh-CN.md)
- [UI 设计规范](UI_DESIGN_GUIDE.md)
- [ADR-001：桌面端 API Secret 的长期存储](decisions/001-desktop-api-secret-storage.md)
- [ADR-002：Windows 安装版数据保留与多来源隔离](decisions/002-windows-installed-data-preservation.md)

## 历史材料

以下文件只保存审查当时的证据和背景。阅读时必须同时查看其审查日期、基线提交和
后续变更；其中的版本号、测试数量、功能开关和风险状态可能已经失效。

- [全面评估历史快照](FULL_ASSESSMENT.md)
- [综合代码审查历史快照](AUDIT_REPORT.md)
- [包内教程、国旗与解锁审查快照](AUDIT_PACKAGE_UNLOCK_2026-07-10.zh-CN.md)
- [三端正式版本审查快照](FORMAL_REVIEW_2026-07-13.zh-CN.md)
- [GitHub 仓库整理快照](GITHUB_REPOSITORY_AUDIT.zh-CN.md)
- [macOS 旧审查结论](../SSRVPN_MacOS/PROJECT_REPORT.md)
- [旧项目记忆](../MEMORY.md)

这些历史材料不属于“当前有效状态”检查范围。需要引用结论时，应先在当前提交上
重新执行对应测试或检查。
