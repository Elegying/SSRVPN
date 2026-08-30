# SSRVPN Android

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN Android 版是基于 Flutter、Kotlin 和 Mihomo 的系统 VPN 客户端。

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 Android 应用。

[下载正式版](https://github.com/Elegying/SSRVPN/releases/latest) · [用户指南](USER_GUIDE.md) · [获取帮助](../SUPPORT.md) · [返回主项目](../README.md)

## 支持范围

- Android 7.0 或更高版本，正式安装包仅支持 **arm64-v8a** 设备。
- 永久使用 IPv4-only 运行配置；不请求 DNS AAAA，不建立 IPv6 连接。系统 VPN 仍捕获并拒绝 IPv6，防止流量绕过 VPN。

## 功能特性

- 深色/浅色主题和简化的“主页 + 订阅”两页流程。
- 支持 Mihomo/Clash YAML、Base64 订阅、常见节点 URI 和受控客户端标识兼容协商。
- Android `VpnService`、前台通知和快捷设置磁贴。
- 单节点/批量延迟测试、规则/全局模式和强制代理网站管理。
- 连接成功后从正式 GitHub Release 检查和下载更新。

## 构建说明

### 环境要求

- Flutter SDK **3.44.1**；其他 stable 版本不能替代
- Android Studio / Android SDK
- NDK 28.2.13676358
- JDK 17（AGP 9.0.1 与应用源码均使用 JVM 17）

### 构建步骤

```bash
# 1. 获取依赖
flutter pub get

# 2. 构建 Debug 版本
flutter build apk --debug

# 3. 构建本地 Release 验证包（正式发布由 GitHub Actions 签名）
flutter build apk --release

# 4. 构建产物位于
# build/app/outputs/flutter-apk/app-release.apk

# 正式安装包由 GitHub Release workflow 使用固定签名在线构建
```

### 签名配置

推荐从仓库根目录生成免费自签名 keystore：

```bash
scripts/create-android-release-keystore.sh
```

正式发布由 GitHub Release workflow 在线构建并签名。仓库需要配置
`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、
`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` 四个 secrets；workflow 会临时
生成 `android/key.properties`。

本地如果需要手动签名，可创建 `android/key.properties`（已 gitignore）：

```properties
storeFile=路径/到/keystore.jks
storePassword=密码
keyAlias=别名
keyPassword=密码
```

没有 `key.properties` 时本地构建会回退到 debug 签名；debug 包只用于验证，
不能作为正式 Release 发布。GitHub Actions 中请求 release 构建时必须存在
secrets 生成的临时 `key.properties`，否则构建会直接失败。

## 项目边界

- `lib/`：Flutter UI、Android 平台服务和应用编排。
- `android/`：Kotlin VPN Service、快捷磁贴、原生桥接和构建配置。
- `test/`：Flutter 行为、连接生命周期和订阅回归。
- 跨平台模型、解析和策略位于 [`packages/ssrvpn_shared`](../packages/ssrvpn_shared/README.md)。

## 技术栈

- **Flutter**：UI 与应用状态
- **Kotlin**：VPN Service、Tile Service 与原生桥接
- **Provider**：状态管理
- **Mihomo（Clash Meta）**：代理核心

## 许可证

SSRVPN 自有代码采用 [MIT License](../LICENSE)。安装包内置的 Mihomo、GeoIP
数据库及其他第三方组件分别遵循各自许可证；精确版本、对应源码、修改说明和随包
许可证正文见[第三方许可清单](../third_party/THIRD_PARTY_NOTICES.md)。

完整验证、贡献规则和路线图请从仓库根目录的[贡献指南](../CONTRIBUTING.md)与[文档中心](../docs/README.md)进入。
