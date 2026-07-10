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
3. 确认三端项目地址都指向：
   - `https://github.com/Elegying/SSRVPN`
4. 确认 Release workflow 需要的 Android 自签名 secrets 已配置。没有付费 Apple/Microsoft 证书时，不配置 macOS notarization 或 Windows code signing secrets。
5. 确认核心二进制和 geo 数据库哈希：

   ```bash
   scripts/verify-core-assets.sh
   ```
6. 确认没有明显密钥泄露、覆盖率没有低于当前保守门槛：

   ```bash
   scripts/check-secrets.sh
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

在干净目录完整解压 `SSRVPN.zip` 后执行，测试前先记录系统代理原值：

```bat
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
```

1. 运行 `SSRVPN_Diag.bat`；必需文件必须齐全，Mihomo 能输出版本，程序 10 秒后仍在运行；完成后从托盘退出诊断启动的实例。
2. 如果诊断报告旧版进程安全例外，以管理员身份运行一次 `remove_legacy_cet_exemption.bat`，然后重新诊断并确认警告消失。
3. 正常启动 `ssrvpn_windows.exe`；确认主页、订阅、节点和已选节点恢复正常，`%LOCALAPPDATA%\SSRVPN\logs\startup.log` 没有启动失败。
4. 先从托盘退出正常实例，再运行 `ssrvpn_safe_mode.bat`；确认安全模式提示可见，托盘、旧窗口位置和 Mihomo 自动初始化均被跳过。
5. 使用系统代理模式连接；确认浏览器可联网、代理指向 `127.0.0.1` 的实际监听端口。正常断开后，`ProxyEnable` 和 `ProxyServer` 必须精确恢复为测试前的值。
6. 再次连接后从任务管理器结束 `bin\mihomo.exe`；应用应退出连接状态并自动清理自己设置的系统代理，不得留下半连接状态。
7. 再次连接后从托盘选择“退出 SSRVPN”；应用和 Mihomo 都应退出，系统代理必须恢复，`%LOCALAPPDATA%\SSRVPN\crashes` 不应新增转储。
8. 分别用普通权限和管理员权限检查 TUN：普通权限必须明确失败且不残留代理；管理员权限下应能连接、断开并恢复网络。
9. 检查应用内更新能打开当前版本对应的 GitHub Release。日志可提交排查，但不要公开发送 `.dmp` 文件。

## 发布

1. 在 `main` 上创建版本 tag，例如：

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

2. 等待 GitHub Actions 的 `Release` workflow 完成。

## 发布后

1. 打开 GitHub Release，确认有这些文件：
   - `SSRVPN.apk`
   - `SSRVPN.apk.sha256`
   - `SSRVPN.dmg`
   - `SSRVPN.dmg.sha256`
   - `SSRVPN.zip`
   - `SSRVPN.zip.sha256`
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
   sha256sum -c SSRVPN.zip.sha256
   ```
6. 检查用户会看到的系统提示是否符合预期：
   - Android APK 使用同一个自签名 keystore，可覆盖安装升级。
   - macOS 未公证时可能需要右键打开。
   - Windows 未代码签名时可能出现 SmartScreen 未知发布者提示。
