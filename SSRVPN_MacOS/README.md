# SSRVPN macOS

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN macOS 版，基于 Flutter 和 Mihomo/Clash Meta 核心的桌面客户端。

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 macOS 应用。

## 支持范围

- 当前节点与路由策略明确为 **IPv4-only**，不支持 IPv6 节点、IPv6 强制代理 IP 或 IPv6 出口。

## 构建要求

- 安装 Xcode Command Line Tools 的 macOS
- Flutter SDK 3.44.1 或兼容的 stable 版本
- 用于 DMG 打包的 `hdiutil`

## 验证

```bash
flutter pub get
flutter analyze
flutter test
```

## 构建可拖拽安装 DMG

```bash
bash tool/package_macos.sh
```

脚本会生成：

- `SSRVPN.dmg`
- `SSRVPN.dmg.sha256`
- `SSRVPN-macOS-<arch>-v<version>.dmg`

## 开发路线图

详见主仓 [Roadmap](../docs/ROADMAP.md) — 三平台代码去重和发布规划。
