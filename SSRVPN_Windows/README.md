# SSRVPN Windows

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)

SSRVPN Windows 客户端支持系统代理、需要管理员权限的 TUN、系统托盘与在线更新。Windows
对外只发布每用户安装器 `SSRVPN_Setup.exe`；不再构建或发布便携 ZIP。

## 构建要求

- Flutter SDK 3.44.1 或兼容 stable 版本；
- Visual Studio 2022，安装“使用 C++ 的桌面开发”工作负载；
- Inno Setup 6.5 或更高版本；
- Windows 10/11 x64。

## 构建安装器

在 Windows PowerShell 5.1 中运行：

```powershell
flutter pub get
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\package_windows.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\build_installer.ps1
```

`package_windows.ps1` 生成并校验安装器内部载荷目录 `SSRVPN_Windows_Release`，其中包含
启动器、Flutter 应用、Mihomo、VC++ 运行库和资源；该目录不是公开发布产物。
`build_installer.ps1` 随后生成：

- `SSRVPN_Setup.exe`
- `SSRVPN_Setup.exe.sha256`

构建机访问 `pub.dev` 不稳定时，可为载荷脚本加 `-ChinaMirror` 或 `-OfflinePub`。

## 在线更新

客户端仍从 OSS/GitHub Release 的固定资产 `SSRVPN_Setup.exe` 下载更新，因此官网和发布
链接无需随版本变化。安装包通过 SHA256 校验后，以
`SSRVPN_Setup_v<版本号>.exe` 保存到当前 Windows 用户的真实桌面目录；客户端只提示用户
手动安装，不会自动运行安装包或退出 SSRVPN。

## 安装数据边界

安装器固定写入 `%LOCALAPPDATA%\Programs\SSRVPN`，无需管理员权限。覆盖升级只替换已知
程序文件，保留安装目录 `bin\ssrvpn`、`%LOCALAPPDATA%\SSRVPN\ssrvpn` 与窗口状态。
安装器不会搜索或合并桌面、下载目录等位置遗留的旧独立副本；若已安装实例或系统代理无法
安全关闭，会在修改程序文件前失败。

CI 在 Windows runner 上验证 PowerShell 5.1 兼容、安装器结构、静默安装、覆盖升级、数据
保留、缓存清理与卸载。Windows 10/11 的交互向导、系统代理、管理员 TUN、重启与读屏仍需
真机验收。

## Mihomo 核心

安装器载荷包含 `mihomo.exe`。项目使用官方
`mihomo-windows-amd64-v1-go120` 构建；来源、版本与 SHA256 记录在
`assets/mihomo-source.txt`。更新核心时必须同步来源记录并运行根目录验证。

## 验证

在仓库根目录运行：

```bash
make verify
```

Windows 打包变更还必须在 Windows 上实际构建安装器并执行
`scripts/test_windows_installer_package.ps1`。用户操作见 [Windows 指南](USER_GUIDE.md)。
