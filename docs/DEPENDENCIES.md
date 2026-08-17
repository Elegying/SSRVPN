# 依赖升级策略

依赖更新以用户路径和目标平台构建证据为准，不以“全部最新”为目标。Dependabot 每周提出
GitHub Actions 与 Dart workspace 更新；合并前仍必须经过完整门禁和触达平台构建。

## 更新等级

- 补丁与兼容次版本：单独更新 lockfile，运行 `make verify`；涉及 FFI、原生插件或打包时增加
  对应平台构建。
- 主版本：先记录迁移项和回滚点，再分别验证数据迁移、失败回滚、三端构建和受影响真机流程。
- Flutter、Dart、Gradle、AGP、Kotlin、NDK 或 Xcode：视为工具链迁移，不与无关功能合并。
- Mihomo、Android Go bridge 和 GeoIP：按核心资产来源、哈希、ABI 与生命周期门禁处理，不能
  由普通包升级替代。

## 当前边界

- Windows `win32` 已提升到 `^6.4.0`，需由 workspace analyze、Flutter 测试和 Windows CI
  共同确认；macOS 本地结果不代表 DPAPI/注册表 FFI 已在 Windows 执行。
- `flutter_secure_storage` 11 属于原生主版本迁移，并明确要求 `compileSdk 37`；当前 Flutter
  3.44.1 默认 `compileSdk 36`。现阶段保留 10.x，直到 Flutter/Android 工具链要求对齐，并在
  Android APK、原生测试、旧密文读取、写失败回滚和覆盖升级上提供证据。
- `uuid` 4 当前被桌面托盘依赖 `system_tray 2.0.3` 的 `uuid ^3.0.6` 约束阻塞。只有托盘插件
  升级或替换并通过 macOS/Windows 托盘重建、退出和资源管理器恢复测试后，才迁移该主版本。
- analyzer、test 等由 Flutter SDK 约束的传递依赖跟随受支持的 stable 工具链，不强行覆盖。

## 维护命令

```bash
make deps
flutter pub outdated
flutter pub upgrade --dry-run
make verify
```

更新 PR 必须列出直接依赖变化、目标平台、lockfile 差异、已执行命令、跳过项和回滚方式。
安全修复若被工具链阻塞，应单独评估最小约束升级，不等待常规批量更新。
