# Changelog

## v2.0.0 (2026-06-26)

### Security
- 硬编码 Fast.com API token 提取为命名常量
- Android 添加 network_security_config，仅本地回环放行明文流量

### Added
- GitHub Actions CI 工作流（自动 analyze + test）
- Git LFS 追踪大文件（.so、assets）
- 共享包 `ssrvpn_shared` 提取 unlock_test_service

### Changed
- `withAlpha()` → `withValues(alpha:)` 适配 Flutter 3.x
- 构建产物（APK）移除出 Git 追踪

### Fixed
- 初始化失败时可点击重试
- `late final` → 可空字段防止二次赋值崩溃
