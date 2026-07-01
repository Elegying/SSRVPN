# SSRVPN Android

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN Android 版 - 基于 Clash Meta 的 VPN 客户端

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 Android 应用。

## 支持范围

- Android 安装包仅支持 **arm64-v8a** 设备。
- 当前节点与路由策略明确为 **IPv4-only**，不支持 IPv6 节点、IPv6 强制代理 IP 或 IPv6 出口。

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
- JDK 11

### 构建步骤

```bash
# 1. 获取依赖
flutter pub get

# 2. 构建 Debug 版本
flutter build apk --debug

# 3. 构建 Release 版本（需要 key.properties 配置签名）
flutter build apk --release

# 4. 构建产物位于
# build/app/outputs/flutter-apk/app-release.apk

# 5. 复制为根目录交付件
copy build\app\outputs\flutter-apk\app-release.apk SSRVPN.apk
certutil -hashfile SSRVPN.apk SHA256
```

### 签名配置

正式签名信息存放在 `android/key.properties`（已 gitignore）：

```properties
storeFile=路径/到/keystore.jks
storePassword=密码
keyAlias=别名
keyPassword=密码
```

没有 `key.properties` 时自动回退到 debug 签名，保证能在任何机器上构建。

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
