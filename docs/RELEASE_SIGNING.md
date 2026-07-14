# 发布签名说明

本项目按个人开发者、免费发布优先维护。Android 可以免费自签名；macOS 和 Windows 可以免费构建与分发，但没有付费证书时系统会显示安全提示。签名材料、证书、keystore、密码和 token 都不能提交进 Git。

## Android：免费自签名 keystore

Android APK 不需要购买证书。个人开发者可以免费生成一个自签名 keystore，只要后续版本一直使用同一个 keystore，用户就可以覆盖安装升级。

正式发版全部走 GitHub Release workflow。本地可以没有 `.jks` 和
`android/key.properties`；只要 GitHub Actions Secrets 已配置，workflow 会在
runner 上生成临时 `key.properties` 并签名 APK。

推荐使用脚本生成一次 keystore，并按输出提示添加 GitHub Actions Secrets：

```bash
scripts/create-android-release-keystore.sh
```

手动生成命令示例：

```bash
keytool -genkeypair \
  -v \
  -keystore ssrvpn-release.jks \
  -alias ssrvpn \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000
```

把 keystore 转成 GitHub Secret：

```bash
base64 -w 0 ssrvpn-release.jks
```

Windows PowerShell：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("ssrvpn-release.jks"))
```

仓库需要配置这些 GitHub Actions Secrets：

- `ANDROID_KEYSTORE_BASE64`：`ssrvpn-release.jks` 的 Base64 内容。
- `ANDROID_KEYSTORE_PASSWORD`：keystore 密码。
- `ANDROID_KEY_ALIAS`：key alias，例如 `ssrvpn`。
- `ANDROID_KEY_PASSWORD`：key 密码。

Release workflow 会在构建前生成临时 `key.properties`。如果这些 secrets
缺失，发布会直接失败，避免产出 debug 签名 APK。以后三端发版以 GitHub
线上构建产物为准，本地 release APK 只用于临时验证。

## macOS：默认 ad-hoc，可选 Developer ID 与公证

`SSRVPN_MacOS/tool/package_macos.sh` 默认继续使用 ad-hoc 签名，适合本地构建和自用分发。陌生机器第一次打开时可能被 Gatekeeper 拦截，需要右键打开。

Release workflow 已准备可选的 Developer ID 分发路径。启用后会：

1. 在 runner 临时 keychain 导入 P12，应用 hardened runtime 与可信时间戳。
2. 验证 `.app` 和 `.dmg` 代码签名。
3. 通过 `notarytool` 等待 Apple 公证，执行 stapling 与 `spctl` 验证。
4. 最后生成 DMG SHA256，并在结束时删除 runner 上的 P12 和临时 keychain。

先配置以下 GitHub Actions Secrets：

- `MACOS_CERTIFICATE_P12_BASE64`：Developer ID Application P12 的 Base64。
- `MACOS_CERTIFICATE_PASSWORD`：P12 导出密码。
- `MACOS_SIGNING_IDENTITY`：完整签名身份，例如 `Developer ID Application: ...`。
- `APPLE_NOTARY_APPLE_ID`：提交公证的 Apple ID。
- `APPLE_NOTARY_TEAM_ID`：Apple Developer Team ID。
- `APPLE_NOTARY_PASSWORD`：该 Apple ID 的 app-specific password。

全部配置后，把 repository variable `ENABLE_MACOS_SIGNING` 设为小写
`true`。变量未设置或为 `false` 时保持 ad-hoc；设为其他值、缺任一 secret、证书 Base64
无效、签名或公证失败时，Release job 会停止，不会降级发布未签名产物。

## Windows：默认未签名，可选 Authenticode

Windows 同时发布 Inno Setup 每用户安装包和绿色免安装 ZIP。默认没有代码签名证书，两种
形式都可能触发 SmartScreen 未知发布者提示。

Release workflow 已准备可选 Authenticode：先对便携包的用户启动器和 Flutter 主程序签名
并验证，再生成 `SHA256SUMS.txt` 和 ZIP；Inno Setup 完成后再签名并验证安装器，最后生成
安装器 SHA256。时间戳默认使用 DigiCert HTTPS RFC 3161 服务，可通过
`WINDOWS_SIGNING_TIMESTAMP_URL` 覆盖。

先配置以下 GitHub Actions Secrets：

- `WINDOWS_CERTIFICATE_PFX_BASE64`：代码签名 PFX 的 Base64。
- `WINDOWS_CERTIFICATE_PASSWORD`：PFX 密码。

全部配置后，把 repository variable `ENABLE_WINDOWS_SIGNING` 设为小写 `true`。变量未设置
或为 `false` 时保持当前未签名发布；显式启用但配置不完整、Base64 无效、找不到 Windows
SDK `signtool.exe`、签名或验证失败时，Release job 会停止。临时 PFX 在 job 结束时删除。

签名第三方上游二进制会造成错误发布者归属，因此当前只签 SSRVPN 用户入口和安装器，
不重新签名 Mihomo、Flutter runtime 或 VC runtime。

## 本地验证配置

验证器不会打印 secret 内容：

```bash
python3 scripts/validate_release_signing.py macos
python3 scripts/validate_release_signing.py windows
scripts/check-release-signing-automation.sh
```

默认输出 `disabled` 且返回成功；只有对应 enable 环境变量为小写 `true` 时才要求完整凭据。

## 发布前检查

1. 确认 `main` CI 通过。
2. 确认 Android self-signed keystore secrets 已配置。
3. 若启用桌面签名，先确认对应 enable variable 与全部 secrets；不得在发版当天临时猜测身份名称或证书密码。
4. 从 `v*` tag 触发 Release workflow，并检查签名、公证/stapling 或 Authenticode 验证步骤。
5. 下载 Release 产物，校验 SHA256，并独立检查实际签名身份、时间戳与公证票据。
6. 在干净机器上安装、启动、连接、断开并覆盖安装下一版测试；自动化签名成功不能替代系统信任提示的真机验收。
