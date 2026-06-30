# SSRVPN Windows

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN Windows 版 - 绿色免安装 VPN 客户端

> Active development has moved to the `Elegying/SSRVPN` monorepo. This directory contains the Windows app inside that workspace.

## 支持范围

- 当前节点与路由策略明确为 **IPv4-only**，不支持 IPv6 节点、IPv6 强制代理 IP 或 IPv6 出口。

## 功能特性

- 🎨 与 Android/macOS 版一致的 UI 界面
- 🔒 支持 SSR/SS/VMess/Trojan 等多种代理协议
- 📡 支持订阅链接和 ssr:// 链接导入
- 🚀 基于 Mihomo (Clash Meta) 核心
- 💻 系统代理模式（无需管理员权限）
- 🔧 TUN 模式（需管理员权限，全局代理）
- 📌 系统托盘支持（最小化到托盘继续运行）
- 🔄 在线更新检查
- 📦 绿色免安装，解压即用

## 构建说明

### 环境要求

- Flutter SDK 3.44.1 or compatible stable version
- Visual Studio 2022 (含 C++ 桌面开发工作负载)
- Windows 10/11

### 构建步骤

```bash
# 1. 获取依赖
flutter pub get

# 2. 构建 Release 版本
flutter build windows --release

# 3. 构建产物位于
# build\windows\x64\runner\Release\
```

### 打包为绿色免安装版

推荐直接使用项目内的打包脚本。它会执行 Release 构建、清理旧产物、校验必需文件、附带 VC++ 运行库并生成 SHA256：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\package_windows.ps1
```

最终产物为项目根目录下的 `SSRVPN.zip`。构建完成后，ZIP 内包含：

```
SSRVPN_Windows_Release/
├── ssrvpn_windows.exe    # 主程序
├── mihomo.exe            # Mihomo 核心
├── ssrvpn/               # 配置目录 (首次运行自动创建)
│   ├── settings.json     # 用户设置
│   ├── config.yaml       # Clash 配置
│   ├── subscriptions.json# 订阅列表
│   └── geoip.metadb      # GeoIP 数据库
├── data/                 # Flutter 运行时资源
│   └── flutter_assets/
│       └── assets/
│           ├── geoip.metadb.gz
│           └── icon.ico
└── *.dll                 # 依赖的动态库
```

## Mihomo 核心

便携版 ZIP 已包含 `mihomo.exe`。为了兼容旧 CPU 和旧版 Windows，项目使用官方 `mihomo-windows-amd64-v1-go120` 构建。自行更新时可从 GitHub Releases 下载同类版本：

```
https://github.com/MetaCubeX/mihomo/releases
```

下载后解压，将其中的可执行文件重命名为 `mihomo.exe`，放到 `assets` 目录后重新构建。

## 使用说明

1. 解压到任意目录
2. 双击 `ssrvpn_windows.exe` 启动
3. 点击底部「订阅」标签，添加订阅链接
4. 点击「全部刷新」获取节点
5. 返回主页，点击连接按钮

### 便携模式

本软件为**绿色免安装版**，配置、订阅、缓存和日志默认存储在软件根目录的 `ssrvpn` 文件夹内。系统代理模式运行期间会临时修改当前用户的 Windows 代理设置，断开或退出时自动恢复原设置。

如果程序目录不可写（例如放在受保护目录或只读介质），数据会自动回退到 `%LOCALAPPDATA%\SSRVPN\ssrvpn`。系统代理恢复快照属于当前电脑的运行状态，会单独保存在本机 LocalAppData 中，不会随便携目录复制到其他电脑。

```
SSRVPN_Windows_Portable/
├── ssrvpn_windows.exe      # 主程序
├── mihomo.exe              # 代理核心
├── ssrvpn/                 # 所有用户数据
│   ├── settings.json       # 用户设置
│   ├── subscriptions.json  # 订阅列表
│   ├── config.yaml         # Clash 配置
│   ├── tmp/                # 临时文件
│   ├── geoip.metadb        # GeoIP 数据库
│   └── country.mmdb        # MMDB 数据库
├── data/                   # 应用资源
└── *.dll                   # 依赖库
```

你可以将整个文件夹复制到 U 盘随身携带，换电脑后直接使用，无需重新配置。

### 代理模式

- **系统代理模式**（默认）：通过 Windows 系统代理设置转发流量，无需管理员权限
- **TUN 模式**：通过虚拟网卡代理所有流量，需要以管理员身份运行

### 系统托盘

- 最小化或关闭窗口时会隐藏到系统托盘（可在设置中关闭）
- 右键托盘图标可以：显示窗口、连接/断开、退出
- 托盘图标不可用时不会隐藏窗口，避免程序无法找回

## 项目结构

```
lib/
├── main.dart                 # 入口，窗口初始化
├── app.dart                  # 应用主框架，导航栏
├── models/
│   ├── app_settings.dart     # 设置模型
│   ├── proxy_node.dart       # 代理节点模型
│   ├── proxy_group.dart      # 代理组模型
│   └── subscription.dart     # 订阅模型
├── screens/
│   ├── home_screen.dart      # 主页（连接/节点列表）
│   └── subscription_screen.dart # 订阅管理
├── services/
│   ├── clash_service.dart    # Mihomo 核心管理
│   ├── settings_service.dart # 设置持久化
│   ├── subscription_service.dart # 订阅管理
│   ├── system_proxy_service.dart # Windows 系统代理
│   ├── tray_manager.dart     # 系统托盘
│   └── update_service.dart   # 在线更新
├── theme/
│   └── app_theme.dart        # 主题配置
├── utils/
│   └── responsive.dart       # 响应式布局
└── widgets/
    ├── connection_button.dart # 连接按钮（带动画）
    ├── glass_container.dart   # 毛玻璃容器
    └── liquid_glass.dart      # 液态玻璃效果
```

## 技术栈

- **Flutter** - UI 框架
- **Provider** - 状态管理
- **Mihomo (Clash Meta)** - 代理核心
- **system_tray** - 系统托盘
- **window_manager** - 窗口管理

## Safe Mode And Startup Logs

If SSRVPN starts without a visible window or crashes immediately, run:

```bat
ssrvpn_windows.exe --safe-mode --verbose
```

The release package also includes `ssrvpn_safe_mode.bat`.

Safe mode skips the tray, resets saved window placement, and disables Mihomo
automatic initialization. Startup logs are written to:

```text
%LOCALAPPDATA%\SSRVPN\logs\startup.log
```

Native crash dumps are written to:

```text
%LOCALAPPDATA%\SSRVPN\crashes\
```

When reporting a startup crash, send `startup.log` and any `.dmp` files from
the crashes directory.

## License

MIT License

## 开发路线图

详见 [REFACTOR_PLAN.md](../REFACTOR_PLAN.md) — 三平台代码去重分期计划。
