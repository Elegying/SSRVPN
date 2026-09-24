# SSRVPN macOS

SSRVPN macOS 版，基于 Flutter 和 Mihomo/Clash Meta 核心的桌面客户端。

[下载正式版](https://github.com/Elegying/SSRVPN/releases/latest) · [用户指南](USER_GUIDE.md) · [获取帮助](../SUPPORT.md) · [返回主项目](../README.md)

## 支持范围

- macOS 11 或更高版本，正式包仅支持 Apple M 系列芯片。
- 支持 IPv4 / IPv6 双栈，遵循统一分流规则；客户端不修改 macOS 的全局 IPv6 开关。详见[双栈规范](../docs/IPV6_DUAL_STACK_SPEC.zh-CN.md)。
- TUN 每次连接由 macOS 系统管理员授权窗口确认，SSRVPN 不读取或保存管理员密码。
- Release 使用 AOT 与最小化 entitlement，不包含调试、JIT、未签名可执行内存或禁用库校验权限；免费 ad-hoc、未公证分发边界不变。

## 构建要求

- 安装 Xcode、Command Line Tools 与 CocoaPods 的 macOS
- Flutter SDK **3.44.1**；其他 stable 版本不能替代
- 用于 DMG 打包的 `hdiutil`

## 验证

先在仓库根目录运行 `make assets`，获取并校验固定资源，再进入 `SSRVPN_MacOS`：

```bash
flutter pub get
flutter analyze
flutter test
```

完整验证从仓库根目录运行 `make verify`；Release 权限决策与产物核对见
[ADR-009](../docs/decisions/009-macos-release-entitlement-minimization.md)。

## 构建可拖拽安装 DMG

```bash
bash tool/package_macos.sh --dart-define-from-file=../config/ssrvpn-usage-defines.json
```

从仓库根目录可运行 `scripts/build-macos-local.sh`，自动携带账户查询配置。
手动构建本地验收应用时也必须带上同一配置：

```bash
flutter build macos --release --dart-define-from-file=../config/ssrvpn-usage-defines.json --dart-define=SSRVPN_FRAME_DIAGNOSTICS=true
```

遗漏该配置会禁用账户用量与设备数查询。

脚本会生成：

- `SSRVPN.dmg`
- `SSRVPN.dmg.sha256`
- `SSRVPN-macOS-<arch>-v<version>.dmg`

## Mihomo 核心

应用内置 `assets/AtlasCore.gz`，为基于 Mihomo `v1.19.29`、带 SSRVPN 流量统计扩展的
`v1.19.29-ssrvpn.1` arm64 构建。源码提交、补丁和压缩包/可执行文件 SHA-256 固定在
[`assets/AtlasCore-source.txt`](assets/AtlasCore-source.txt)，由 `make assets` 获取。

不能直接用上游原版核心替换，否则会缺少代理流量统计接口。更新和重建遵循
[核心资产说明](../docs/CORE_ASSETS.md)，与三端行为测试一起审查。

完整验证、贡献规则和路线图请从仓库根目录的[贡献指南](../CONTRIBUTING.md)与[文档中心](../docs/README.md)进入。
