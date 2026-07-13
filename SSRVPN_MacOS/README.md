# SSRVPN macOS

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN macOS 版，基于 Flutter 和 Mihomo/Clash Meta 核心的桌面客户端。

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 macOS 应用。

## 支持范围

- 支持 IPv4/IPv6 双栈节点、DNS、系统代理与 TUN 流量；公网 IPv6 是否可用取决于本地网络和所选节点。
- TUN 每次连接由 macOS 系统管理员授权窗口确认，SSRVPN 不读取或保存管理员密码。

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

## Mihomo 核心

应用内置 `assets/AtlasCore.gz`，当前为 MetaCubeX/mihomo `v1.19.27`
darwin arm64 构建。来源、版本和 SHA256 记录在
`assets/AtlasCore-source.txt`。

自行更新时，从 GitHub Releases 下载同版本 darwin arm64 资产：

```text
https://github.com/MetaCubeX/mihomo/releases
```

下载后可保留官方 gzip，或将解压后的可执行文件重新压缩为
`AtlasCore.gz`；验证时优先比对解压后的可执行文件 SHA256。

## 开发路线图

详见主仓 [Roadmap](../docs/ROADMAP.md) — 三平台代码去重和发布规划。
