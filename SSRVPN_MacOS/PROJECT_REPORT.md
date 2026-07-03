# SSRVPN macOS 项目审查报告

生成时间：2026-06-29 19:30:37 CST

## 本轮审查角度

本轮从发布交付、安全边界、macOS 原生集成、签名封装和维护一致性角度复审，重点覆盖：

- macOS Info.plist / entitlements 合法性
- DMG 打包脚本、拖拽安装结构、资源完整性
- 外部系统命令调用在 Finder 双击启动场景下的可靠性
- 系统代理、TUN 授权、核心进程清理的发布版路径依赖
- 签名封签、嵌套 Framework 校验、Gatekeeper 状态
- 废弃代码、重复入口和旧打包脚本的维护风险

## 新发现并已修复的问题

1. 发布版依赖 shell PATH 的隐患
   - 问题：Dart 侧调用 `networksetup`、`chmod`、`stat`、`osascript`、`pkill`、`file`、`open` 时使用裸命令名。
   - 风险：从 Finder 双击启动时 PATH 不稳定，可能导致系统代理设置、TUN 授权、核心清理或打开下载链接失败。
   - 修复：改为使用 `/usr/sbin/networksetup`、`/bin/chmod`、`/usr/bin/stat`、`/usr/bin/osascript`、`/usr/bin/pkill`、`/usr/bin/file`、`/usr/bin/open` 等固定路径。

2. 废弃托盘实现残留
   - 问题：项目中同时存在旧的 `lib/widgets/tray_manager.dart` 和新的 `lib/services/tray_manager.dart`。
   - 风险：后续维护时容易误 import 旧实现，造成托盘行为不一致。
   - 修复：删除旧的 `lib/widgets/tray_manager.dart`，保留当前服务层实现。

3. 旧发布脚本不完整
   - 问题：根目录 `build_release.sh` 仍是旧流程，缺少核心资源校验、版本化 DMG、SHA256 输出和教程文件。
   - 风险：误用旧脚本会产出不一致的安装包。
   - 修复：`build_release.sh` 改为委托正式脚本 `tool/package_macos.sh`。

4. App 外层签名封签不自洽
   - 问题：Flutter release app 单独构建后，`codesign --verify --deep --strict` 对外层 app 报嵌套代码封签不一致。
   - 风险：DMG 可挂载，但 macOS 安全校验更容易拦截。
   - 修复：打包脚本在生成 DMG 前执行 ad-hoc 深度重签名，并强制通过 `codesign --verify --deep --strict`。

## 验证结果

- `plutil -lint macos/Runner/Info.plist macos/Runner/Release.entitlements macos/Runner/DebugProfile.entitlements`：通过
- `git diff --check`：通过
- 裸系统命令扫描：通过，未发现发布代码中残留裸命令调用
- `flutter analyze`：通过，`No issues found`
- `flutter test`：通过，`19 tests passed`
- `bash -n tool/package_macos.sh build_release.sh`：通过
- `hdiutil verify SSRVPN-macOS-arm64-v2.0.0.dmg`：通过
- DMG 挂载检查：通过，包含 `SSRVPN.app`、`Applications`、`使用教程.txt`
- DMG 内 app 签名校验：通过，`codesign --verify --deep --strict`

## 最终构建产物

- `SSRVPN.dmg`
- `SSRVPN-macOS-arm64-v2.0.0.dmg`
- 架构：arm64
- 大小：约 28 MB
- SHA256：`eea60145ac04716bd024ee3f1f6b9083984ad98a120700e89b52571b905cb9b4`

## 非阻断说明

- macOS 已移除 CocoaPods 集成文件，改用 Flutter Swift Package Manager 集成；当前工程不再保留 `Podfile` / `Podfile.lock`。
- 当前包为 ad-hoc 签名，未使用 Apple Developer ID 签名和 Apple 公证；`spctl` 会拒绝陌生机器上的普通双击打开。仓库没有可用的 Developer ID 证书配置，因此本轮已做到本地封签自洽和 DMG 可拖拽安装；正式公开分发仍建议接入 Developer ID + notarization 流程。
