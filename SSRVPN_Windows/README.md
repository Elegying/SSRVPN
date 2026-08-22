# SSRVPN Windows

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)

SSRVPN Windows 客户端支持系统代理、TUN、系统托盘与在线更新。安装后的客户端默认请求
Windows 管理员权限，因此每次启动都会显示 UAC；授权后系统代理与 TUN 均在同一管理员
实例中运行。安装完成后不会自动启动客户端，用户需从桌面或开始菜单自行打开并确认 UAC。
Windows 对外只发布每用户安装器 `SSRVPN_Setup.exe`；不再构建或发布便携 ZIP。

## 构建要求

- Flutter SDK 3.44.1 或兼容 stable 版本；
- Visual Studio 2022，安装“使用 C++ 的桌面开发”工作负载；
- Inno Setup 6.5 或更高版本；
- Windows 10 1507（build 10240）或更高版本的 x64 Windows。

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

客户端只在节点连接成功后从 `Elegying/SSRVPN` 的正式 GitHub Release 检查并下载固定资产
`SSRVPN_Setup.exe`；OSS 仍由发布流水线同步为网站镜像，但不再是应用内更新源。安装包通过 SHA-256 校验后，以
`SSRVPN_Setup_v<版本号>.exe` 保存到当前 Windows 用户的真实桌面目录；客户端只提示用户
手动安装，不会自动运行安装包或退出 SSRVPN。仅由 v4.0.15 或更高版本客户端的内置更新流程
下载并标记的安装包会在安装事务成功后自动清理；旧版客户端下载的首个升级包没有此标记，
无法与手动下载安全区分，因此仍会保留。取消、失败、手动下载或身份校验不一致的安装包也
一律保留。若用户只删除安装包而留下隐藏标记，同版本重下会使用由正式文件名和可信 SHA-256
唯一派生的 32 位小写十六进制后缀，不会覆盖或认领旧标记；新安装包仍可在成功安装后自动
清理。按名称或时间匹配的历史 `.part`/`.previous` 文件不会被自动删除，中断恢复也会保留候选原文件。

## 安装数据边界

安装器要求 Windows 10 1507（build 10240）或更高版本，并固定写入
`%LOCALAPPDATA%\Programs\SSRVPN`。为验证并结束以管理员权限运行的旧实例，安装阶段会
请求 Windows 管理员授权；安装目录仍是每用户 LocalAppData，不会写入 Program Files。
清理只匹配当前安装目录中三个精确可执行路径：应用、启动器和随包 Mihomo，并在结束前再次
核对 PID、会话、路径与创建时间；不会按 Clash、OpenVPN、WireGuard、Tailscale 等通用
进程名关闭其他软件，也不会关闭其他目录中的同名程序。覆盖升级只替换已知程序文件，保留
安装目录 `bin\ssrvpn`、`%LOCALAPPDATA%\SSRVPN\ssrvpn` 与窗口状态。安装器不会搜索或
合并桌面、下载目录等位置遗留的旧独立副本；若其他目录、旧版或便携版 SSRVPN 仍持有全局
实例锁，安装器会保留该进程及代理恢复记录，并在修改系统代理或程序文件前失败。若已安装实例
或系统代理无法安全关闭，同样会在修改程序文件前失败。

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

Windows 原生恢复或打包变更还必须在 Windows 上执行
`scripts/test_windows_native_proxy_recovery.ps1`、实际构建安装器并运行
`scripts/test_windows_installer_package.ps1`。前者在进程级注册表沙箱中验证系统代理崩溃恢复，
不会修改测试账户的真实代理设置；若没有现成 CMake build tree，会先生成一次 Release build。
用户操作见 [Windows 指南](USER_GUIDE.md)。
