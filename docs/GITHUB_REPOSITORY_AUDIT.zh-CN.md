# GitHub 仓库整理审查报告

审查日期：2026-07-03

审查账号：`Elegying`

## 当前状态

当前保留仓库：

- `Elegying/SSRVPN`
- `Elegying/SSR_Panel`

已删除的历史/重复仓库：

- `Elegying/SSRVPN_Android`
- `Elegying/SSRVPN_MacOS`
- `Elegying/SSRVPN_Windows`
- `Elegying/SSRVPN-Windows`
- `Elegying/ssrvpn_shared`

## 结论

`Elegying/SSRVPN` 现在是客户端唯一主仓库。Android、macOS、Windows 三端源码、共享包、CI、Release workflow 和应用更新检查都应以这个 monorepo 为准。

`Elegying/SSR_Panel` 是独立的面板/服务端项目，继续保留。

## 删除后的维护规则

1. 新功能、修复、文档和 Release 都只放在 `Elegying/SSRVPN`。
2. 三端应用内展示的项目地址统一使用 `https://github.com/Elegying/SSRVPN`。
3. 三端 `UpdateService` 统一读取 `Elegying/SSRVPN` 的 GitHub Releases。
4. 不再恢复旧平台仓库，避免用户和未来维护者分不清真实入口。

## 后续检查

- 每次发布后确认 Release assets 包含 `SSRVPN.apk`、`SSRVPN.dmg`、`SSRVPN.zip` 和对应 `.sha256` 文件。
- 每次改版本号后确认三端 `pubspec.yaml` 与共享包 `AppConstants.appVersion` 同步。
- 当前按个人免费发布维护：Android 使用自签名 keystore，macOS/Windows 不配置付费签名或公证；发布说明中要提示 Gatekeeper/SmartScreen 可能出现的系统提示。
