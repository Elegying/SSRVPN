# SSRVPN Android

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN Android 版 - 基于 Clash Meta 的 VPN 客户端

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 Android 应用。

## 支持范围

- Android 安装包仅支持 **arm64-v8a** 设备。
- 支持 IPv4/IPv6 双栈节点、DNS 与 TUN 流量；公网 IPv6 是否可用取决于本地网络和所选节点。

## 功能特性

- 🎨 液态玻璃风格 UI，支持深色/浅色主题
- 🔒 支持 SSR/SS/VMess/Trojan 等多种代理协议
- 📡 支持订阅链接和 ssr:// 链接导入
- 🚀 基于 Clash Meta 核心
- 🔄 节点延迟测速（单个/批量）
- 🧪 流媒体解锁测试（Netflix/YouTube/ChatGPT 等）
- 📌 Android 快捷磁贴（Tile）一键连接
- 🔄 在线更新检查
- 🛡️ 代理模式切换（规则/全局）
- 🌐 强制代理网站管理

## 构建说明

### 环境要求

- Flutter SDK 3.44.1 或兼容的 stable 版本
- Android Studio / Android SDK
- NDK 27.0.12077973
- JDK 17（AGP 8.11 的运行要求；应用源码仍以 Java/Kotlin 11 为字节码目标）

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

# 5. 复制为根目录交付件
copy build\app\outputs\flutter-apk\app-release.apk SSRVPN.apk
certutil -hashfile SSRVPN.apk SHA256
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

## 项目结构

```
lib/
├── main.dart                     # 入口
├── app.dart                      # 应用主框架，导航栏
├── models/
│   ├── app_settings.dart         # 设置模型
│   ├── proxy_node.dart           # 代理节点模型
│   ├── proxy_group.dart          # 代理组模型
│   └── subscription.dart         # 订阅模型
├── screens/
│   ├── home_screen.dart          # 主页（连接/节点列表）
│   ├── subscription_screen.dart  # 订阅管理
│   ├── unlock_test_screen.dart   # 解锁测试
│   └── node_edit_screen.dart     # 节点编辑
├── services/
│   ├── clash_service.dart        # Clash Meta 核心管理
│   ├── settings_service.dart     # 设置持久化
│   ├── subscription_service.dart # 订阅管理
│   ├── unlock_test_service.dart  # 解锁测试
│   └── update_service.dart       # 在线更新
├── theme/
│   └── app_theme.dart            # 主题配置
├── utils/
│   └── responsive.dart           # 响应式布局
└── widgets/
    ├── connection_button.dart     # 连接按钮（带动画）
    ├── glass_container.dart       # 毛玻璃容器
    └── liquid_glass.dart          # 液态玻璃效果
```

## 技术栈

- **Flutter** - UI 框架
- **Kotlin** - Android 原生层（VPN Service、Tile Service）
- **Provider** - 状态管理
- **Clash Meta** - 代理核心

## 许可证

MIT License

## 开发路线图

详见主仓 [Roadmap](../docs/ROADMAP.md) — 三平台代码去重和发布规划。
