# SSRVPN Windows 安装、便携版与权限

导入订阅、连接、状态判断和订阅刷新请先阅读
[公共用户指南](../docs/USER_GUIDE.zh-CN.md)。本页只说明 Windows 差异。

## 选择安装版或便携版

普通用户优先使用 `SSRVPN_Setup.exe`。安装器按当前用户安装到
`%LOCALAPPDATA%\Programs\SSRVPN`，创建桌面和开始菜单入口，并支持后续覆盖升级。
该目录、快捷方式、日志和运行状态都位于当前用户可写位置，安装过程不需要管理员权限。

需要便携运行时使用 `SSRVPN.zip`：

1. 下载后完整解压整个 ZIP，不能只复制顶层 `ssrvpn_windows.exe`。
2. 从解压后的顶层目录运行 `ssrvpn_windows.exe`，不要直接在压缩包内运行。
3. 便携数据通常保存在 `bin\ssrvpn`；目录不可写时会回退到当前用户的 LocalAppData。
4. 便携目录包含订阅、缓存和运行时配置，应放在当前用户私有目录，不能直接公开分享。

两个产物都应从正式 Release 或官网固定地址获取，并按发布页校验 SHA256。当前 Windows
产物没有 Authenticode 签名；只有在来源和哈希都确认无误时才继续处理 SmartScreen 提示。

长期 API secret 保存在 `.api-secret.dpapi`：先用当前 Windows 登录用户的 DPAPI 加密，
再把同目录临时文件落盘并替换旧密文。复制便携目录不会把该用户的解密能力一并转移，
但目录中的订阅、缓存和运行时配置仍需保持私有。

跨电脑或跨 Windows 账户移动便携版时，先完全退出 SSRVPN，并从复制出的目录中排除
`.api-secret.dpapi`；目标账户首次启动会生成自己的密钥。如果启动页提示当前账户无法
解密本机密钥，应用会显示实际文件路径且保留原密文。退出应用后，将该文件重命名为
`.api-secret.dpapi.unreadable-YYYYMMDD-HHMMSS` 再启动；不要删除或分享旧文件。详细步骤见
[常见问题排查](../docs/TROUBLESHOOTING.zh-CN.md#windows-提示当前账户无法解密本机密钥)。

> **安装版数据清除提醒：** 从 3.3.3 起，每次运行 `SSRVPN_Setup.exe` 都会先清空固定
> 安装目录、LocalAppData 回退配置、窗口状态和旧安装恢复状态，再写入全新版本。安装器
> 不搜索、不备份、不恢复旧订阅、设置、缓存或 DPAPI 密钥；安装或升级完成后需要重新
> 导入订阅。桌面或下载目录中的便携副本不会被搜索或修改。

安装向导使用简体中文，并在复制前展示上述删除范围。若旧 SSRVPN 进程无法关闭，安装会
在删除任何旧数据前停止；请退出托盘实例后重试，仍失败时重启 Windows 再安装。

## 系统代理与 TUN

- 系统代理模式无需管理员权限，适合浏览器和遵循 Windows 系统代理的应用。
- TUN 模式需要以管理员身份运行，用于游戏、桌面客户端及其他不读取系统代理的程序。
- SSRVPN 只结束自身进程，以及 PID 和可执行路径能确认属于当前安装目录的 Mihomo；不会
  按进程名称结束其他软件的 `mihomo.exe`。

## 托盘、诊断与安全模式

关闭主窗口时应用可能隐藏到系统托盘。可从托盘菜单重新显示、连接、断开或完全退出。
托盘连接若自动调整端口，会打开主窗口显示实际调整结果；连接状态栏展示当前实际运行端口。
Mihomo 意外退出时会先恢复系统代理并自动重启一次；恢复成功或最终失败都会显示通知，
再次异常退出不会进入循环重启。

- `SSRVPN_Diag.bat`：检查便携包必需文件和核心是否可以启动。
- `ssrvpn_safe_mode.bat`：窗口无法出现或启动后立即异常时，跳过托盘、旧窗口位置和核心
  自动初始化后启动。

## 排查

SmartScreen、便携包缺文件、托盘、连接或更新问题见
[常见问题排查](../docs/TROUBLESHOOTING.zh-CN.md)。

## 技术依据

- [Microsoft：CryptProtectData](https://learn.microsoft.com/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
- [Microsoft：MoveFileExW](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw)
