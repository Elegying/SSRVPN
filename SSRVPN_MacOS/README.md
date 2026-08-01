# SSRVPN macOS

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN macOS 版，基于 Flutter 和 Mihomo/Clash Meta 核心的桌面客户端。

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 macOS 应用。

## 支持范围

- 永久使用 IPv4-only Mihomo 运行配置；不请求 DNS AAAA，不通过核心建立 IPv6 连接。客户端不会修改 macOS 的全局 IPv6 开关。
- TUN 每次连接由 macOS 系统管理员授权窗口确认，SSRVPN 不读取或保存管理员密码。
- Release 使用 AOT 与最小化 entitlement，不包含调试、JIT、未签名可执行内存或禁用库校验权限；免费 ad-hoc、未公证分发边界不变。

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

完整验证从仓库根目录运行 `make verify`；Release 权限决策与产物核对见
[ADR-009](../docs/decisions/009-macos-release-entitlement-minimization.md)。

## 构建可拖拽安装 DMG

```bash
bash tool/package_macos.sh
```

脚本会生成：

- `SSRVPN.dmg`
- `SSRVPN.dmg.sha256`
- `SSRVPN-macOS-<arch>-v<version>.dmg`

## Mihomo 核心

应用内置 `assets/AtlasCore.gz`，当前为 MetaCubeX/mihomo `v1.19.29`
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
