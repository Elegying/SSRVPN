# SSRVPN 发布检查清单

这份清单给个人维护者使用，目标是每次发布都按同一套步骤走，减少漏项。

## 发布前

1. 确认版本号一致：

   ```bash
   scripts/check-version-sync.sh
   ```
2. 确认本地或 GitHub CI 通过：
   - `packages/ssrvpn_shared`
   - `SSRVPN_Android`
   - `SSRVPN_MacOS`
   - `SSRVPN_Windows`
   - Windows 日志包含 PowerShell 5.1 全脚本兼容性和新生成安装包真实安装/卸载通过记录；不得只依据 job 绿色，日志中任何脚本或安装器错误都必须对应失败步骤。
3. 确认三端项目地址都指向：
   - `https://github.com/Elegying/SSRVPN`
4. 确认 Release workflow 需要的 Android 自签名 secrets 已配置。桌面端固定走免费分发：
   macOS ad-hoc、未公证，Windows 未签名；仓库和 GitHub 配置中不应出现 Apple/Microsoft
   付费证书 secrets 或启用变量。
5. 确认核心二进制和 geo 数据库哈希：

   ```bash
   scripts/verify-core-assets.sh
   ```
6. 确认没有明显密钥泄露、覆盖率没有低于当前保守门槛：

   ```bash
   scripts/check-secrets.sh
   gitleaks git --config .gitleaks.toml --redact --log-opts=--all
   make verify
   ```
7. 如本地已有安装包产物，做一次结构 smoke：

   ```bash
   scripts/smoke-release-artifacts.sh --allow-missing
   ```
8. 发布前后至少记录一次性能基准，用于对比低配设备体验是否退化：

   ```bash
   scripts/performance-baseline.sh
   ```

### Windows x64 实机冒烟

在干净 Windows 环境准备带有可识别旧订阅与设置的安装版目录，测试
`SSRVPN_Setup.exe` 全新安装与覆盖升级。测试前先记录系统代理原值：

```bat
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
```

1. 运行 `SSRVPN_Diag.bat`；必需文件必须齐全，Mihomo 能输出版本，程序 10 秒后仍在运行；完成后从托盘退出诊断启动的实例。
2. 如果诊断报告旧版进程安全例外，以管理员身份运行一次 `remove_legacy_cet_exemption.bat`，然后重新诊断并确认警告消失。
3. 正常启动 `ssrvpn_windows.exe`；确认主页、订阅、节点和已选节点工作正常，`%LOCALAPPDATA%\SSRVPN\logs\startup.log` 没有启动失败。
4. 先从托盘退出正常实例，再运行 `ssrvpn_safe_mode.bat`；确认安全模式提示可见，托盘、旧窗口位置和 Mihomo 自动初始化均被跳过。
5. 使用系统代理模式连接；确认浏览器可联网、代理指向 `127.0.0.1` 的实际监听端口。正常断开后，`ProxyEnable` 和 `ProxyServer` 必须精确恢复为测试前的值。
6. 再次连接后从任务管理器结束 `bin\mihomo.exe`；应用应立即提示核心异常退出，自动清理
   自己设置的系统代理并只恢复一次。首次恢复成功应显示成功提示；再次结束核心后必须停止
   重试、退出连接状态并提示最终失败，不得留下半连接或循环拉起。
7. 再次连接后从托盘选择“退出 SSRVPN”；应用和 Mihomo 都应退出，系统代理必须恢复，`%LOCALAPPDATA%\SSRVPN\crashes` 不应新增转储。
8. 再次连接后只从任务管理器结束 `bin\ssrvpn_windows_app.exe`，保留外层 `ssrvpn_windows.exe` 等待子进程退出；外层启动器必须自动恢复系统代理。随后重启 Windows，在未重新打开 SSRVPN 前确认浏览器可直接联网，系统代理不得仍指向 SSRVPN 的本地端口。
9. Windows 分别用普通权限和管理员权限检查 TUN：普通权限必须明确失败且不残留代理；管理员权限下应能连接、断开并恢复网络。macOS TUN 必须显示管理员授权框；取消授权、启动超时、正常断开和退出均不得遗留 root Mihomo、utun 默认路由、暂存目录或系统代理。
10. 在系统自带 Windows PowerShell 5.1 中确认 `$PSVersionTable.PSVersion` 后，创建两个带
   `settings.json` 的旧独立副本，并在 `%LOCALAPPDATA%\Programs\SSRVPN\bin\ssrvpn`、
   `%LOCALAPPDATA%\SSRVPN\ssrvpn` 和窗口状态文件中放置可识别旧配置，记录这些文件的
   SHA256，再启动 `SSRVPN_Setup.exe`。安装向导必须全程使用简体中文并在复制前准确说明
   替换和保留范围；它必须忽略两个旧独立副本，以普通用户权限安装到固定目录。自 3.4.2 起，
   覆盖升级、卸载以及保留数据后的重装都必须保留安装版订阅、设置、DPAPI 密钥、
   LocalAppData 回退数据和窗口状态，前后哈希一致；程序文件、旧恢复状态和两个已知
   WebView 缓存目录必须清理。交互安装只在完成页勾选后启动，静默安装不得启动 GUI。
   另保持已安装实例占用文件，确认安装器会在修改程序文件前阻断；退出实例后重试必须成功。
11. 检查应用内更新优先从 OSS 下载并校验 `SSRVPN_Setup.exe`，OSS 异常时能使用 GitHub
   备用下载；安装器确认接管后应用必须安全恢复代理并退出，交接失败不得修改程序文件。
   日志可提交排查，但不要公开发送 `.dmp` 文件。

## 发布

1. 在 `main` 上创建版本 tag，例如：

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

2. 等待 GitHub Actions 的 `Release` workflow 完成。
   工作流会先创建 Draft Release、上传并验证 OSS 不可变目录，然后备份并推广
   OSS 固定下载通道，最后公开 GitHub Release。GitHub 未能明确转为正式 Release
   时不得人工推进；按失败日志确认自动恢复结果或使用保留的恢复 Artifact。

## 发布后

1. 打开 GitHub Release，确认有这些文件：
   - `SSRVPN.apk`
   - `SSRVPN.apk.sha256`
   - `SSRVPN.dmg`
   - `SSRVPN.dmg.sha256`
   - `SSRVPN_Setup.exe`
   - `SSRVPN_Setup.exe.sha256`
   - `SSRVPN-release-provenance.json`（绑定 tag、commit 与三个安装包 SHA256）
   或直接运行：

   ```bash
   scripts/check-release-assets.sh vX.Y.Z
   ```
2. 下载每个平台产物，至少做一次启动检查。
3. 检查应用内更新是否能读到最新版本，并打开正确下载链接。
4. 按 `docs/PRODUCT_REQUIREMENTS.zh-CN.md` 检查安装包、首次导入、节点排序和记忆节点行为。
5. 检查 SHA256 校验文件可用：

   ```bash
   shasum -a 256 -c SSRVPN.dmg.sha256
   sha256sum -c SSRVPN.apk.sha256
   sha256sum -c SSRVPN_Setup.exe.sha256
   ```
6. 检查用户会看到的系统提示是否符合预期：
   - Android APK 使用同一个自签名 keystore，可覆盖安装升级。
   - macOS 未公证时可能需要右键打开。
   - Windows 未代码签名时可能出现 SmartScreen 未知发布者提示。
