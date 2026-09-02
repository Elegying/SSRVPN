# SSRVPN 文档中心

这里是仓库内当前有效文档的统一入口。请先按自己的角色选择入口；正在开发的行为以当前源码和验证结果为准，已经安装或下载的行为以对应正式 Release 为准。

过期审查报告和一次性执行计划不保留在当前文档树中；需要追溯时使用 Git 历史。

## 我是用户

- [获取帮助](../SUPPORT.md)：先排查，再安全地提交可复现问题。
- [公共用户指南](USER_GUIDE.zh-CN.md)：导入、连接、状态判断、订阅刷新和安全提示。
- [功能列表](FEATURES.zh-CN.md)：当前三端已实现能力、协议、平台差异和明确不支持项。
- [常见问题排查](TROUBLESHOOTING.zh-CN.md)：按现象定位原因并采取动作。
- [Android 安装与权限](../SSRVPN_Android/USER_GUIDE.md)
- [macOS 安装与权限](../SSRVPN_MacOS/USER_GUIDE.md)
- [Windows 安装与权限](../SSRVPN_Windows/USER_GUIDE.md)

## 我想参与开发

- [贡献指南](../CONTRIBUTING.md)
- [测试策略](TESTING.md)：本地、CI、原生与覆盖率验证。
- [依赖升级策略](DEPENDENCIES.md)：自动更新、兼容性迁移和上游阻塞的处理边界。
- [UI 设计规范](UI_DESIGN_GUIDE.md)
- [Monorepo 迁移说明](../MIGRATION.md)
- [项目管理](PROJECT_MANAGEMENT.md)：分支、源码与产物边界。

## 我负责维护与发布

- [项目所有者手册](OWNER_GUIDE.zh-CN.md)：常用维护、验证和发布入口。
- [维护指南](MAINTENANCE.md)：日常维护和合并要求。
- [性能基线](PERFORMANCE.md)：关键路径测量方法、比较边界与回归处置。
- [真机验收矩阵](UAT_MATRIX.md)：三端生命周期、无障碍、性能与电量的统一验收标准。
- [项目健康状态](PROJECT_HEALTH.md)：最近一次审查基线、证据与已知风险。
- [路线图](ROADMAP.md)：尚未完成的优先事项。
- [根变更日志](../CHANGELOG.md)：正式版本的用户可见变化。
- [发布检查清单](RELEASE_CHECKLIST.zh-CN.md)：正式发版的唯一逐步检查入口。
- [OSS 发布运维](OSS_RELEASE_OPERATIONS.zh-CN.md)：发布、密钥轮换、故障恢复和回滚。
- [免费分发与签名说明](RELEASE_SIGNING.md)：固定分发策略、校验方式和系统警告。
- [核心资产来源](CORE_ASSETS.md)：Mihomo、Android 原生核心与 GeoIP 来源。
- [第三方许可清单](../third_party/THIRD_PARTY_NOTICES.md)：随包组件的许可证、精确源码与修改说明。

## 产品、安全与架构

- [功能列表](FEATURES.zh-CN.md)
- [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)
- [安全策略](../SECURITY.md)
- [社区行为准则](../CODE_OF_CONDUCT.md)
- [IPv4-only 与 IPv6 防绕过规范](IPV6_DUAL_STACK_SPEC.zh-CN.md)
- [ADR-001：桌面端 API Secret 的长期存储](decisions/001-desktop-api-secret-storage.md)
- [ADR-002：Windows 安装版数据保留与多来源隔离](decisions/002-windows-installed-data-preservation.md)
- [ADR-003：Windows 只发布安装器](decisions/003-windows-installer-only-distribution.md)
- [ADR-004：三端只保留首页与订阅](decisions/004-two-page-product-surface.md)
- [ADR-005：使用 SSRVPN 自控的内容寻址 GeoIP 镜像](decisions/005-content-addressed-geoip-mirror.md)
- [ADR-006：macOS 核心进程所有权使用持久化原生代际](decisions/006-macos-core-process-identity.md)
- [ADR-007：默认路由使用国内直连与国外兜底代理（已取代）](decisions/007-domain-based-domestic-routing.md)
- [ADR-008：macOS API Secret 的会话轮换边界](decisions/008-macos-session-api-secret-rotation.md)
- [ADR-009：macOS Release 权限最小化](decisions/009-macos-release-entitlement-minimization.md)
- [ADR-010：以行为证据控制高风险职责拆分](decisions/010-risk-controlled-maintainability-boundaries.md)
- [ADR-011：发版前刷新 GeoIP（已由 ADR-014 取代）](decisions/011-release-gated-geoip-refresh.md)
- [ADR-012：自动准备可复现的正式版本](decisions/012-automatic-release-preparation.md)
- [ADR-013：客户端连接后仅使用 GitHub Releases 更新](decisions/013-github-release-connected-update.md)
- [ADR-014：GeoIP 仅按明确指令手动更新](decisions/014-manual-only-geoip-updates.md)
- [ADR-015：智能模式使用 GFW 代理与默认直连（已取代）](decisions/015-gfw-proxy-default-direct-routing.md)
- [ADR-016：分层智能路由与可用性优先的代理兜底](decisions/016-layered-smart-routing-safe-fallback.md)

## 文档维护规则

- 当前状态只写入本索引列出的文档，避免在审查报告中维护第二份事实。
- 已完成事项写入根 `CHANGELOG.md`；未完成事项写入 `ROADMAP.md`。
- 一次性审查证据保留在对应提交、Issue 或 Pull Request，不新增快照型 Markdown。
- 引用历史结论前，必须在当前提交上重新执行对应测试或检查。
- 文档门禁自动枚举全部受版本控制 Markdown；`CHANGELOG.md` 只做链接检查，其余当前文档还会检查已知陈旧结论和危险发布命令。
