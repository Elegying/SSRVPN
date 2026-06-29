# Changelog

## v2.0.0 (2026-06-26)

### Security
- 硬编码 Fast.com API token 提取为命名常量

### Added
- GitHub Actions CI 工作流（analyze + test + 构建 ZIP）
- Git LFS 追踪大文件（mihomo.exe、geoip.metadb.gz）
- 共享包 `ssrvpn_shared` 提取 unlock_test_service

### Changed
- `withAlpha()` → `withValues(alpha:)` 适配 Flutter 3.x
- 构建产物（ZIP）移除出 Git 追踪

### Fixed
- 退出时防止重复 quit 调用
- 托盘菜单连接状态实时同步
