# SSRVPN Windows

SSRVPN Windows 客户端支持系统代理、TUN、系统托盘与在线更新。安装后的客户端默认请求
Windows 管理员权限，因此每次启动都会显示 UAC；授权后系统代理与 TUN 均在同一管理员
实例中运行。安装完成后不会自动启动客户端，用户需从桌面或开始菜单自行打开并确认 UAC。
Windows 对外只发布 `SSRVPN_Setup.exe`，使用管理员安装模式，默认程序目录位于当前用户的 LocalAppData；不发布便携 ZIP。

[下载正式版](https://github.com/Elegying/SSRVPN/releases/latest) · [用户指南](USER_GUIDE.md) · [获取帮助](../SUPPORT.md) · [返回主项目](../README.md)

## 构建要求

- Flutter SDK **3.44.1**，其他 stable 版本不能替代；
- Visual Studio 2022，安装“使用 C++ 的桌面开发”工作负载；
- Inno Setup 6.5 或更高版本（5.0.20 的 CI 安装验收使用 6.7.1）；
- Windows 10 1507（build 10240）或更高版本的 x64 Windows。

## 构建安装器

先在仓库根目录通过 `make assets`（Git Bash / WSL）获取并校验固定资源，再进入
`SSRVPN_Windows`，在 Windows PowerShell 5.1 中运行：

```powershell
flutter pub get
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\package_windows.ps1 -DartDefineFromFile ..\config\ssrvpn-usage-defines.json
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

安装器默认目录为 `%LOCALAPPDATA%\Programs\SSRVPN`，始终提供目录选择页并预填上次的选择。
安装请求管理员授权，卸载信息写入 **HKLM 的 64 位视图**；默认路径位于用户目录不代表 HKCU 安装模式。

安装/卸载会结束映像名精确为 `ssrvpn_windows_app.exe`、`ssrvpn_windows.exe`、`mihomo.exe`
的进程，包括其他目录的副本；其他软件若使用同名 Mihomo 也可能受影响。逐 PID 的活进程身份校验保留，
不会扩展到 Clash、OpenVPN、WireGuard 等其他名称。完整边界见
[ADR-021](../docs/decisions/021-installer-name-based-process-stop.md)。

覆盖升级、失败恢复和卸载按可信程序清单及哈希处理文件，保留安装目录 `bin\ssrvpn`、
`%LOCALAPPDATA%\SSRVPN\ssrvpn`、窗口状态和无关文件，不搜索或合并其他目录的旧数据。
文件冲突、被修改的程序或无法确认的事务会停止处理并保留恢复材料，详见
[ADR-022](../docs/decisions/022-windows-program-ownership-and-recovery.md)。

CI 在 Windows runner 上验证 PowerShell 5.1 兼容、安装器结构、静默安装、覆盖升级、数据
保留、缓存清理与卸载。Windows 10/11 的交互向导、系统代理、管理员 TUN、重启与读屏仍需
真机验收。

## Mihomo 核心

安装器载荷包含带 SSRVPN 流量统计扩展的 `mihomo.exe`，基于 Mihomo `v1.19.27`，
使用 Go 1.20.14 / amd64 v1 构建。固定来源、补丁和 SHA-256 记录在
[`assets/mihomo-source.txt`](assets/mihomo-source.txt)。不能以缺少统计接口的上游原版替换；
更新流程见[核心资产说明](../docs/CORE_ASSETS.md)。

## 验证

在仓库根目录运行：

```bash
make verify
```

Windows 原生恢复测试 `scripts/test_windows_native_proxy_recovery.ps1` 使用进程级注册表沙箱，
若没有现成 CMake build tree，会先生成一次 Release build。涉及真实安装、卸载、同名进程或
注册表恢复的测试只在一次性 GitHub Windows runner 执行；
`scripts/test_windows_installer_package.ps1` 的 GitHub Actions 保护不得在个人电脑上伪造或绕过。
用户操作见 [Windows 指南](USER_GUIDE.md)。
