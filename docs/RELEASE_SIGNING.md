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

## macOS：免费 ad-hoc 签名

`SSRVPN_MacOS/tool/package_macos.sh` 当前使用 ad-hoc 签名，适合本地构建和自用分发。陌生机器第一次打开时可能被 Gatekeeper 拦截，需要右键打开。

不配置 Apple Developer ID 和 notarization secrets。若未来决定付费公开分发，再新增 Developer ID 签名和 notarization 流程。

## Windows：免费安装包与绿色包

Windows 同时发布 Inno Setup 每用户安装包和绿色免安装 ZIP。没有代码签名证书时可以运行，但两种形式都可能触发 SmartScreen 未知发布者提示。

不配置 Windows code signing secrets。若未来决定购买证书，再给 exe 和 native DLL 增加 Authenticode 签名。

## 发布前检查

1. 确认 `main` CI 通过。
2. 确认 Android self-signed keystore secrets 已配置。
3. 从 `v*` tag 触发 Release workflow。
4. 下载 Release 产物，校验 SHA256。
5. 在干净机器上安装、启动、连接、断开并覆盖安装下一版测试。
