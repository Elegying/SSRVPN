# 发布签名说明

本项目可以在没有付费开发者账号的情况下构建安装包，但公开分发时仍应尽量使用稳定签名。签名材料、证书、keystore、密码和 token 都不能提交进 Git。

## Android：免费自签名 keystore

Android APK 不需要购买证书。个人开发者可以免费生成一个自签名 keystore，只要后续版本一直使用同一个 keystore，用户就可以覆盖安装升级。

生成命令示例：

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

Release workflow 会在构建前生成临时 `key.properties`。如果这些 secrets 缺失，发布会直接失败，避免产出 debug 签名 APK。

## macOS：免费可构建，正式分发需要付费证书

`SSRVPN_MacOS/tool/package_macos.sh` 当前使用 ad-hoc 签名，适合本地构建和自用分发。陌生机器第一次打开时可能被 Gatekeeper 拦截，需要右键打开。

正式公开分发需要 Apple Developer ID 证书和 notarization。推荐 secrets：

- `MACOS_DEVELOPER_ID_APPLICATION_P12_BASE64`
- `MACOS_DEVELOPER_ID_APPLICATION_PASSWORD`
- `MACOS_NOTARY_APPLE_ID`
- `MACOS_NOTARY_TEAM_ID`
- `MACOS_NOTARY_PASSWORD`

## Windows：免费可构建，正式分发需要代码签名证书

Windows ZIP 当前是绿色免安装包。没有代码签名证书时可以运行，但 SmartScreen 可能提示未知发布者。

正式公开分发建议签名 exe 和 native DLL。推荐 secrets：

- `WINDOWS_CODESIGN_PFX_BASE64`
- `WINDOWS_CODESIGN_PFX_PASSWORD`
- `WINDOWS_CODESIGN_TIMESTAMP_URL`

## 发布前检查

1. 确认 `main` CI 通过。
2. 确认 Android secrets 已配置。
3. 从 `v*` tag 触发 Release workflow。
4. 下载 Release 产物，校验 SHA256。
5. 在干净机器上安装、启动、连接、断开并覆盖安装下一版测试。
