# SSRVPN macOS

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN macOS 版，基于 Flutter 和 Mihomo/Clash Meta 核心的桌面客户端。

> Active development has moved to the `Elegying/SSRVPN` monorepo. This directory contains the macOS app inside that workspace.

## 支持范围

- 当前节点与路由策略明确为 **IPv4-only**，不支持 IPv6 节点、IPv6 强制代理 IP 或 IPv6 出口。

## 构建要求

- macOS with Xcode command-line tools
- Flutter SDK 3.44.1 or compatible stable version
- `hdiutil` for DMG packaging

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

详见 [REFACTOR_PLAN.md](../REFACTOR_PLAN.md) — 三平台代码去重分期计划。
