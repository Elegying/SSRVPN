# SSRVPN Windows

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)


SSRVPN Windows 版 - 安装版与绿色便携版 VPN 客户端

> 主动开发已迁移到 `Elegying/SSRVPN` Monorepo。本目录是该工作区内的 Windows 应用。

## 支持范围

- 支持 IPv4/IPv6 双栈节点、DNS、系统代理与 TUN 流量；公网 IPv6 是否可用取决于本地网络和所选节点。

## 功能特性

- 🎨 与 Android/macOS 版一致的 UI 界面
- 🔒 支持 SSR/SS/VMess/Trojan 等多种代理协议
- 📡 支持订阅链接和 ssr:// 链接导入
- 🚀 基于 Mihomo (Clash Meta) 核心
- 💻 系统代理模式（无需管理员权限）
- 🔧 TUN 模式（需管理员权限，全局代理）
- 📌 系统托盘支持（最小化到托盘继续运行）
- 🔄 在线更新检查
- 📦 支持每用户安装版和解压即用的绿色便携版

## 构建说明

### 环境要求

- Flutter SDK 3.44.1 或兼容的 stable 版本
- Visual Studio 2022 (含 C++ 桌面开发工作负载)
- Inno Setup 6（仅构建安装版需要）
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

推荐直接双击项目根目录的 `build_release.bat`。它会执行 Release 构建、清理旧产物、自动收集并校验绿色版必需文件、附带 VC++ 运行库和 `d3dcompiler_47.dll`，最后生成 ZIP 与 SHA256：

```bat
build_release.bat
```

也可以在 PowerShell 中手动调用底层打包脚本：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\package_windows.ps1
```

如果构建机访问 `pub.dev` 不稳定，脚本会自动重试 Flutter 中国镜像：

```text
PUB_HOSTED_URL=https://pub.flutter-io.cn
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

也可以手动指定：

```bat
build_release.bat -ChinaMirror
build_release.bat -OfflinePub
```

最终产物为项目根目录下的 `SSRVPN.zip`。构建完成后，ZIP 内包含：

```text
SSRVPN_Windows_Release/
├── ssrvpn_windows.exe          # 主目录唯一启动程序
├── 使用教程.txt
├── SSRVPN_Diag.bat
├── SAFE_MODE_README.txt
├── *.dll                      # 主启动器需要的 VC++ 运行库
└── bin/
    ├── ssrvpn_windows_app.exe  # 内部 Flutter 程序
    ├── mihomo.exe              # Mihomo 核心
    ├── ssrvpn/                 # 配置目录 (首次运行自动创建)
    │   ├── settings.json       # 用户设置
    │   ├── config.yaml         # Clash 配置
    │   ├── subscriptions.json  # 订阅列表
    │   └── geoip.metadb        # GeoIP 数据库
    ├── data/                   # Flutter 运行时资源
    │   └── flutter_assets/
    │       └── assets/
    │           ├── geoip.metadb.gz
    │           └── icon.ico
    └── *.dll                   # 依赖的动态库
```

### 打包为安装版

安装版复用已经校验的便携目录，不需要管理员权限，默认安装到
`%LOCALAPPDATA%\Programs\SSRVPN`。构建便携目录后运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\build_installer.ps1
```

生成 `SSRVPN_Setup.exe` 和对应 SHA256 文件。安装或升级时，安装器先请求
Windows Restart Manager 关闭旧版本；如果托盘驻留阻止正常退出，只兜底结束
`ssrvpn_windows_app.exe` 与启动器进程，不会按名称结束其他软件的
`mihomo.exe`。从便携版首次迁移到安装版时，请保持旧版 SSRVPN 正在运行并
直接启动安装器；安装器会在结束旧进程前复制已有订阅和设置。安装完成后自动
启动新版本，以恢复并重新接管 SSRVPN 的系统代理状态。

## Mihomo 核心

便携版 ZIP 已包含 `mihomo.exe`。为了兼容旧 CPU 和旧版 Windows，项目使用官方 `mihomo-windows-amd64-v1-go120` 构建。自行更新时可从 GitHub Releases 下载同类版本：

```
https://github.com/MetaCubeX/mihomo/releases
```

当前来源、版本和 SHA256 记录在 `assets/mihomo-source.txt`。下载后解压，将其中的可执行文件重命名为 `mihomo.exe`，放到 `assets` 目录后重新构建。

## 使用说明

1、下载完 ZIP 后，使用解压软件解压出来。
2、双击 `ssrvpn_windows.exe` 打开软件。
3、粘贴你的节点代码或者订阅链接。
4、点击连接按钮即可。

### 便携模式

本软件为**绿色免安装版**，解压后主目录只有一个面向用户的 `ssrvpn_windows.exe`，并保留启动器必需的 VC++ 运行库 DLL。应用内部文件放在 `bin` 目录，配置、订阅、缓存和日志默认存储在 `bin\ssrvpn` 文件夹内。系统代理模式运行期间会临时修改当前用户的 Windows 代理设置，断开或退出时自动恢复原设置。

如果程序目录不可写（例如放在受保护目录或只读介质），数据会自动回退到 `%LOCALAPPDATA%\SSRVPN\ssrvpn`。系统代理恢复快照属于当前电脑的运行状态，会单独保存在本机 LocalAppData 中，不会随便携目录复制到其他电脑。

```
SSRVPN_Windows_Portable/
├── ssrvpn_windows.exe          # 主目录唯一启动程序
├── 使用教程.txt
├── SSRVPN_Diag.bat
├── SAFE_MODE_README.txt
├── *.dll                      # 主启动器需要的 VC++ 运行库
└── bin/
    ├── ssrvpn_windows_app.exe  # 内部 Flutter 程序
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

## 安全模式和启动日志

如果 SSRVPN 启动后没有显示窗口，或启动后立刻崩溃，可以运行：

```bat
ssrvpn_windows.exe --safe-mode --verbose
```

发布包中也包含 `ssrvpn_safe_mode.bat`。

安全模式会跳过托盘初始化、重置已保存的窗口位置，并禁用 Mihomo 自动初始化。启动日志写入：

```text
%LOCALAPPDATA%\SSRVPN\logs\startup.log
```

原生崩溃转储写入：

```text
%LOCALAPPDATA%\SSRVPN\crashes\
```

报告启动崩溃时，请提供 `startup.log` 以及崩溃目录中的 `.dmp` 文件，并先移除敏感信息。

## 许可证

MIT License

## 开发路线图

详见主仓 [Roadmap](../docs/ROADMAP.md) — 三平台代码去重和发布规划。
