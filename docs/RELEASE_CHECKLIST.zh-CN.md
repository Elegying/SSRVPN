# SSRVPN 发布检查清单

这份清单给个人维护者使用，目标是每次发布都按同一套步骤走，减少漏项。

## 发布前

1. 确认版本号一致：
   - `SSRVPN_Android/pubspec.yaml`
   - `SSRVPN_MacOS/pubspec.yaml`
   - `SSRVPN_Windows/pubspec.yaml`
   - 三端 `UpdateService.appVersion`
2. 确认本地或 GitHub CI 通过：
   - `packages/ssrvpn_shared`
   - `SSRVPN_Android`
   - `SSRVPN_MacOS`
   - `SSRVPN_Windows`
3. 确认三端项目地址都指向：
   - `https://github.com/Elegying/SSRVPN`
4. 确认 Release workflow 需要的 secrets 已配置，尤其是 Android 签名 secrets。

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
2. 下载每个平台产物，至少做一次启动检查。
3. 检查应用内更新是否能读到最新版本，并打开正确下载链接。
4. 如果公开分发，补做签名、公证和安全提示检查：
   - Android APK 签名
   - macOS notarization
   - Windows code signing
