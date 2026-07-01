# 贡献指南

SSRVPN 是一个多平台 Flutter Monorepo：

- `packages/ssrvpn_shared` 保存平台无关的模型、策略、订阅解析、配置生成和工具函数。
- `SSRVPN_Android`、`SSRVPN_MacOS`、`SSRVPN_Windows` 保存平台专属 UI、原生集成、打包脚本和系统能力。

## 开发规则

- `main` 分支保持稳定，新功能使用 `feature/*` 分支，修复使用 `fix/*` 分支，维护类改动使用 `chore/*` 分支。
- 可复用业务逻辑优先放入 `packages/ssrvpn_shared`。
- 平台目录只处理 UI、系统代理、TUN、VPN Service、托盘、安装包、权限和操作系统差异。
- 不要记录订阅 URL、API secret、密码、Bearer token、代理凭据或签名密钥。
- 除非平台能力确实不同，Android、macOS 和 Windows 的用户行为应保持一致。
- 不要提交 `dist/`、APK、DMG、ZIP、签名文件、密钥、构建缓存或本地生成的交付物。

## 本地验证

共享包检查：

```bash
cd packages/ssrvpn_shared
dart pub get
dart test
dart analyze
```

平台应用检查：

```bash
flutter pub get
flutter analyze
flutter test
```

修改共享行为时，需要在三端应用目录都执行平台检查。提交 PR 前应保持 `flutter analyze` 和 `dart analyze` 干净。

## Issue 规则

- Bug、功能需求和维护任务请使用 GitHub Issue 模板。
- 安全问题不要提交公开 Issue，请按 `SECURITY.md` 私下报告。
- 报告问题时请说明平台、版本、复现步骤、预期结果和实际结果。
- 日志、截图和崩溃文件中必须先移除订阅、token、密码和服务端地址等敏感信息。

## Pull Request 要求

每个 PR 应包含：

- 用户可感知变化的简短说明。
- 影响范围：Android、macOS、Windows、shared 或 docs。
- 本地执行过的验证命令。
- UI 改动的截图或录屏。
- 发布、迁移或兼容风险说明。

更多维护节奏、发布检查和线上/本地一致性规则见 `docs/MAINTENANCE.md`。分支模型和产物策略见 `docs/PROJECT_MANAGEMENT.md`。
