# SSRVPN Windows 安装与权限

导入订阅、连接、状态判断和订阅刷新请先阅读
[公共用户指南](../docs/USER_GUIDE.zh-CN.md)。本页只说明 Windows 差异。

## 安装与升级

Windows 只发布 `SSRVPN_Setup.exe`。安装器按当前用户安装到
`%LOCALAPPDATA%\Programs\SSRVPN`，创建桌面和开始菜单入口，不需要管理员权限。
请只从正式 Release 或官网固定地址下载安装器，并按发布页校验 SHA256。当前安装器没有
Authenticode 签名；只有在来源和哈希都确认无误时才继续处理 SmartScreen 提示。

覆盖运行新版安装器只替换已知程序文件，并保留：

- `%LOCALAPPDATA%\Programs\SSRVPN\bin\ssrvpn` 中的订阅、设置和 DPAPI 密钥；
- `%LOCALAPPDATA%\SSRVPN\ssrvpn` 回退数据；
- 当前用户的窗口状态。

旧恢复状态与已知 WebView 缓存会清理。安装器不会搜索、复制、修改或结束桌面、下载目录
等位置遗留的旧独立副本，因此多个旧数据源不会参与安装事务。若旧实例无法安全关闭，安装
会在替换文件前停止；请完全退出托盘实例后重试，仍失败时重启 Windows 再安装。

长期 API secret 保存在 `.api-secret.dpapi`：先用当前 Windows 登录用户的 DPAPI 加密，
再以同目录临时文件替换旧密文。不要复制、共享或公开整个数据目录。若启动页提示当前账户
无法解密本机密钥，请按[常见问题排查](../docs/TROUBLESHOOTING.zh-CN.md)处理。

## 系统代理与 TUN

- 系统代理模式无需管理员权限，适合浏览器和遵循 Windows 系统代理的应用。
- TUN 模式需要以管理员身份运行，用于游戏、桌面客户端及其他不读取系统代理的程序。
- SSRVPN 只结束自身进程，以及 PID 和可执行路径能确认属于当前安装目录的 Mihomo；不会
  按进程名称结束其他软件或旧独立副本中的 `mihomo.exe`。

## 托盘、诊断与安全模式

关闭主窗口时应用可能隐藏到系统托盘。可从托盘菜单重新显示、连接、断开或完全退出。

- `SSRVPN_Diag.bat`：检查安装目录必需文件和核心是否可以启动。
- `ssrvpn_safe_mode.bat`：窗口无法出现或启动后立即异常时，跳过托盘、旧窗口位置和核心
  自动初始化后启动。

SmartScreen、安装文件缺失、DPAPI、托盘、连接或更新问题见
[常见问题排查](../docs/TROUBLESHOOTING.zh-CN.md)。

## 技术依据

- [Microsoft：CryptProtectData](https://learn.microsoft.com/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
- [Microsoft：MoveFileExW](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw)
