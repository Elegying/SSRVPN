# SSRVPN Windows 安装与权限

导入订阅、连接、状态判断和订阅刷新请先阅读
[公共用户指南](../docs/USER_GUIDE.zh-CN.md)。本页只说明 Windows 差异。

## 安装与升级

Windows 只发布 `SSRVPN_Setup.exe`。安装目录仍固定为当前用户的
`%LOCALAPPDATA%\Programs\SSRVPN`，并创建桌面和开始菜单入口。为安全确认并停止已提权的
旧实例、校验安装内容，以及在回滚保护下替换程序文件，安装阶段会请求管理员授权。
安装器要求 Windows 10 1507（build 10240）或更高版本的 x64 Windows。
请只从正式 Release 或官网固定地址下载安装器，并按发布页校验 SHA-256。当前安装器没有
Authenticode 签名；只有在来源和哈希都确认无误时才继续处理 SmartScreen 提示。
安装完成后安装器不会自动运行 SSRVPN，也不会显示“运行 SSRVPN”复选框；请关闭安装器后
从桌面或开始菜单手动打开，并在 Windows UAC 中确认管理员授权。

覆盖运行新版安装器只替换已知程序文件，并保留：

- `%LOCALAPPDATA%\Programs\SSRVPN\bin\ssrvpn` 中的订阅、设置和 DPAPI 密钥；
- `%LOCALAPPDATA%\SSRVPN\ssrvpn` 回退数据；
- 当前用户的窗口状态。

旧恢复状态与已知 WebView 缓存会清理。安装器不会搜索、复制、修改或合并桌面、下载目录
等位置遗留的旧独立副本，因此多个旧数据源不会参与安装事务。为恢复自有系统代理并避免
安装文件锁，它只会关闭可执行路径精确属于当前安装目录的 SSRVPN 应用、启动器和随包
Mihomo，并在结束前复核 PID、当前登录会话、路径和创建时间。安装器不会按 Clash、
OpenVPN、WireGuard、Tailscale、ZeroTier 等通用进程名关闭其他软件，也不会关闭其他目录
中的同名程序。其他目录、旧版或便携版 SSRVPN 仍在运行时，安装器会在改动系统代理前停止
并提示退出所有实例；它不会替用户结束该副本。如其他代理/VPN 软件造成端口或网络设置冲突，
请先自行退出后重试。若已安装
实例无法安全关闭，安装会在替换文件前停止；请完全退出 SSRVPN 后重试，仍失败时重启
Windows 再安装。

由 v4.0.15 或更高版本客户端通过“立即更新”下载并通过 SHA-256 校验的版本化安装包，会在
安装成功后自动从原位置清理。旧版客户端下载的首个升级包没有专属标记，无法与手动下载安全
区分，因此仍会保留。取消安装、安装失败、手动从浏览器下载或校验身份不一致时，安装包也会
保留，方便重试或自行处理；清理流程不会扫描同目录中的其他文件。如果只删除安装包而隐藏
标记仍在，同版本重新下载会使用由正式文件名和可信 SHA-256 唯一派生的 32 位小写十六进制
后缀建立独立标记，旧标记保持不变。中断恢复只会有界读取当前目标专属候选，不会删除候选原文件。

长期 API secret 保存在 `.api-secret.dpapi`：先用当前 Windows 登录用户的 DPAPI 加密，
再以同目录临时文件替换旧密文。不要复制、共享或公开整个数据目录。若启动页提示当前账户
无法解密本机密钥，请按[常见问题排查](../docs/TROUBLESHOOTING.zh-CN.md)处理。

## 系统代理与 TUN

- 安装后的 SSRVPN 默认以管理员权限运行，每次启动都会显示 Windows UAC。取消授权时客户端
  不会启动；标准用户使用其他管理员账户授权时会进入该管理员账户的独立数据目录。
- 系统代理模式适合浏览器和遵循 Windows 系统代理的应用。
- TUN 模式用于游戏、桌面客户端及其他不读取系统代理的程序。客户端已经在管理员实例中
  运行，因此切换 TUN 后无需再次退出或重新授权。
- 客户端普通运行、断开、退出和安装器预清理都只结束自身进程，以及 PID 和可执行路径能
  确认属于当前安装目录的 Mihomo，不会按进程名称结束其他软件。

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
