# 免费分发与签名说明

本项目按个人开发者、免费发布维护。2026-07-15 起，产品决策固定为：

- Android 使用免费的自签名 release keystore。
- macOS 使用 ad-hoc 签名，不购买 Developer ID，不做 Apple 公证。
- Windows 不购买 Authenticode 证书，安装器保持未签名。
- 三端发布都生成 SHA256，并只从正式 GitHub Release 或官网固定地址分发。

仓库不保留 Apple/Microsoft 付费桌面签名自动化、启用变量或证书 secrets。除非维护者明确
取代本决策，否则不要重新加入这些入口。SHA256 可以验证下载内容与发布产物一致，但不能
证明操作系统信任的发布者身份；Gatekeeper 和 SmartScreen 提示属于已知产品边界。

## Android：免费自签名 keystore

Android APK 不需要购买证书。只要后续版本始终使用同一个 keystore，用户就可以覆盖安装升级。

正式发版全部走 GitHub Release workflow。本地可以没有 `.jks` 和
`android/key.properties`；GitHub Actions Secrets 配置完整时，workflow 会在 runner
上生成临时 `key.properties` 并签名 APK。

推荐用脚本生成一次 keystore。脚本只输出安全的上传命令，不会把 keystore 的 Base64 内容打印到终端；按提示配置 GitHub Actions Secrets：

```bash
scripts/create-android-release-keystore.sh
```

仓库需要以下 GitHub Actions secrets：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

证书摘要不是 secret。将同一 keystore 的 SHA-256 摘要配置为 GitHub Actions
Variable `ANDROID_RELEASE_CERT_SHA256`：

```bash
release_key_alias="${ANDROID_KEY_ALIAS:-ssrvpn}"
release_cert_sha256="$(
  keytool -exportcert \
    -keystore SSRVPN_Android/android/ssrvpn-release.jks \
    -alias "$release_key_alias" -rfc |
  openssl x509 -noout -fingerprint -sha256 |
  cut -d= -f2 | tr -d ':'
)"
test -n "$release_cert_sha256"
gh variable set ANDROID_RELEASE_CERT_SHA256 \
  --repo Elegying/SSRVPN --body "$release_cert_sha256"
unset release_cert_sha256
unset release_key_alias
```

Release workflow 会核对实际 APK 证书摘要。缺少 secrets、Variable 或摘要不一致会直接失败，避免
产出 debug 签名或错误签名谱系的 APK。keystore、密码和导出文件不得提交进 Git。

## macOS：固定 ad-hoc、未公证

`SSRVPN_MacOS/tool/package_macos.sh` 在打包时刷新并验证 ad-hoc 签名，然后生成 DMG 和
SHA256。Release workflow 不导入 P12、不调用 `notarytool`，也不保存 Apple 证书配置。
Release 明确禁用 Xcode 基础 entitlement 注入，并移除调试、JIT、未签名可执行内存和
禁用库校验权限；真实 Release `.app` 的最终 `codesign` 输出必须通过门禁。该边界记录在
[ADR-009](decisions/009-macos-release-entitlement-minimization.md)。

陌生机器首次运行可能被 Gatekeeper 阻止或提示无法验证开发者。用户应：

1. 只从正式下载地址获取 DMG。
2. 核对 `SSRVPN.dmg.sha256`。
3. 把应用拖到“应用程序”，右键 SSRVPN 并选择“打开”。
4. 不关闭 Gatekeeper，不执行来源不明的绕过命令。

ad-hoc 身份不能跨构建稳定复用，因此 macOS 长期 API secret 保持在权限为 `0600` 的
专用文件中，不迁移到依赖稳定代码身份的 Keychain ACL。该限制记录在 ADR-001。

## Windows：固定未签名

Windows 只发布 Inno Setup 每用户安装器并生成 SHA256。Release workflow
不导入 PFX、不调用 `signtool.exe`，打包脚本也不读取 Authenticode 环境变量。

SmartScreen 或浏览器可能显示“未知发布者”。用户只有在正式来源和 SHA256 都匹配时才应
选择保留并继续运行；任一条件不满足都不应绕过提示。

安装版固定写入 `%LOCALAPPDATA%\\Programs\\SSRVPN`，但安装阶段会请求管理员权限，
用于验证并结束残留的高权限 SSRVPN、Mihomo 和其他代理进程。TUN 连接本身同样需要以
管理员身份运行应用；这两个权限边界都与安装包是否签名无关。

## 自动化守卫

以下测试防止付费桌面签名入口或开发期 entitlement 重新进入活跃 Release 构建链，同时保留 macOS ad-hoc 验证：

```bash
python3 -m unittest scripts/test_free_desktop_distribution.py
```

发布前还必须执行：

```bash
make verify
scripts/check-release-assets.sh vX.Y.Z
```

最后从公开 Release 重新下载 APK、DMG 和 EXE，逐一校验随包 SHA256，并在目标平台
检查系统提示、首次启动、连接、断开和退出。桌面免费分发决策不会降低运行稳定性、代理
恢复、安装事务或来源校验的验收标准。
