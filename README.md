# SSRVPN

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)

SSRVPN 是一个跨平台 Flutter VPN 客户端 Monorepo，用同一套共享业务逻辑维护 Android、macOS 和 Windows 三端应用。平台相关的界面、原生能力和打包脚本分别放在独立目录，订阅解析、节点模型、路由策略、配置生成等通用能力统一放在共享包中。

历史上的平台独立仓库已停止作为主开发入口，后续功能开发、修复、测试和发布都以本仓库为准。

## 支持平台

| 平台目录 | 说明 | 发布产物 |
| --- | --- | --- |
| `SSRVPN_Android` | Android VPN 客户端，包含 VPN Service、快捷磁贴、订阅导入和在线更新 | `SSRVPN.apk` |
| `SSRVPN_MacOS` | macOS 桌面客户端，包含系统代理、TUN 集成、资源安装和 DMG 打包 | `SSRVPN.dmg` |
| `SSRVPN_Windows` | Windows 客户端，包含系统代理、TUN、托盘、安装版和便携版 | `SSRVPN_Setup.exe` / `SSRVPN.zip` |

当前节点与路由策略明确按 IPv4-only 设计，不支持 IPv6 节点、IPv6 强制代理 IP 或 IPv6 出口。

## 仓库结构

```text
SSRVPN/
├── packages/ssrvpn_shared/    # 三端共享模型、服务、策略和测试
├── SSRVPN_Android/            # Android Flutter 应用和原生集成
├── SSRVPN_MacOS/              # macOS Flutter 应用、TUN/代理集成和 DMG 打包
├── SSRVPN_Windows/            # Windows Flutter 应用、系统代理、TUN 和便携打包
├── docs/                      # 项目管理、维护、发布、路线图和仓库审计文档
├── scripts/                   # 本地维护脚本
└── dist/                      # 本地交付目录，已被 Git 忽略
```

## 环境要求

- Flutter `3.44.1` 或兼容的 stable 版本。
- Dart SDK 版本需与 Flutter 匹配。
- Android 构建需要 Android SDK、NDK 和 JDK。
- macOS 构建需要 Xcode Command Line Tools 和 `hdiutil`。
- Windows 构建需要 Visual Studio 2022、“使用 C++ 的桌面开发”工作负载和 Inno Setup 6。

## 本地验证

仓库使用 Flutter workspace，推荐在根目录执行统一入口：

```bash
scripts/workspace.sh pub-get
scripts/workspace.sh analyze
scripts/workspace.sh test
```

完整合并前检查（含资源、测试覆盖率阈值和发布前守卫）可执行：

```bash
scripts/workspace.sh verify
```

提交或合并前应保持 analyzer 没有 warning、info 和 error。

## 常用维护命令

仓库根目录的 `Makefile` 封装了常见操作：

```bash
make status
make sync
make assets
make feature name=my-change
make verify
make deps
scripts/check-secrets.sh
scripts/smoke-release-artifacts.sh --allow-missing
scripts/performance-baseline.sh
```

- `make status`：查看本地分支、远端同步状态和交付目录状态。
- `make sync`：在工作区干净时同步远端 `main`。
- `make assets`：从固定 GitHub Release 下载并校验三端核心资产。
- `make feature name=...`：从稳定分支创建功能分支。
- `make verify`：运行仓库级完整校验（含资源、analyze、测试和覆盖率阈值）。
- `make deps`：查看共享包和三端依赖是否有可升级版本，建议按月运行。
- `scripts/check-secrets.sh`：扫描明显高危密钥泄露模式。
- `scripts/smoke-release-artifacts.sh --allow-missing`：本地有 APK/DMG/Windows 包时检查产物结构。
- `scripts/performance-baseline.sh`：记录源码热点、关键测试耗时和可选 adb 启动/内存样本。

## 发布构建

Android APK：

```bash
cd SSRVPN_Android
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk SSRVPN.apk
sha256sum SSRVPN.apk > SSRVPN.apk.sha256
```

Windows 安装版和绿色版 ZIP：

```powershell
cd SSRVPN_Windows
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tool\package_windows.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tool\build_installer.ps1
```

macOS 拖拽安装 DMG：

```bash
cd SSRVPN_MacOS
bash tool/package_macos.sh
shasum -a 256 SSRVPN.dmg > SSRVPN.dmg.sha256
```

推送匹配 `v*` 的 tag 会触发 GitHub Actions 发布流程，自动上传三端产物和 SHA256 校验文件。

个人免费发布限制：

- Android Release workflow 使用同一个自签名 keystore secret 时可覆盖升级。
- macOS DMG 是拖拽安装形式，但未做 Apple Developer ID 签名和公证，首次打开可能需要右键打开。
- Windows 默认更新产物为每用户安装版 `SSRVPN_Setup.exe`，同时保留绿色便携 ZIP；两者未代码签名时都可能出现 SmartScreen 提示。
- Android 当前只随包提供 arm64 核心库；项目网络策略按 IPv4-only 设计。

## 重要文档

- `docs/OWNER_GUIDE.zh-CN.md`：项目所有者日常维护手册。
- `docs/PROJECT_MANAGEMENT.md`：分支模型、产物策略、本地流程和发布规则。
- `docs/PRODUCT_REQUIREMENTS.zh-CN.md`：安装包、首次导入、节点排序和记忆节点行为要求。
- `docs/GITHUB_REPOSITORY_AUDIT.zh-CN.md`：GitHub 仓库清理审计和保留/归档建议。
- `docs/PROJECT_HEALTH.md`：项目完整度、可维护性、发布准备度和风险评分。
- `docs/MAINTENANCE.md`：每周维护、PR、发布和线上/本地一致性检查表。
- `docs/ROADMAP.md`：已完成事项和后续技术路线。
- `docs/RELEASE_SIGNING.md`：Android 自签名、macOS/Windows 免费发布和系统提示说明。
- `docs/RELEASE_CHECKLIST.zh-CN.md`：个人维护者发布前后检查清单。
- `docs/OSS_RELEASE_OPERATIONS.zh-CN.md`：阿里云 OSS 正常发布、密钥轮换、故障恢复和回滚手册。
- `docs/UI_DESIGN_GUIDE.md`：三端 UI 色板、字号层级和组件规范。
- `docs/CORE_ASSETS.md`：Mihomo/AtlasCore 二进制来源、版本和兼容性说明。
- `docs/TESTING.md`：CI 覆盖率、平台依赖测试和本地验证策略。
- `MIGRATION.md`：从历史平台仓库迁移到本 Monorepo 的说明。

## 安全说明

不要在日志、Issue、PR、截图或崩溃报告中泄露订阅 URL、API secret、Bearer token、代理密码、服务端凭据或签名密钥。新增日志时应使用共享包里的脱敏工具，或完全避免输出敏感值。

安全报告请按 `SECURITY.md` 的流程私下提交，不要创建公开 Issue。

## 许可证

MIT License
