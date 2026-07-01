# 从历史平台仓库迁移到 Monorepo

SSRVPN 的主动开发已经迁移到 `Elegying/SSRVPN` Monorepo。历史平台仓库只保留代码记录，不再作为日常开发入口。

历史仓库包括：

- `Elegying/SSRVPN_Android`
- `Elegying/SSRVPN_MacOS`
- `Elegying/SSRVPN_Windows`

现在三端应用都通过 path 依赖使用 `packages/ssrvpn_shared`，因此推荐的开发布局就是本 Monorepo。

## 主要变化

- 共享模型、策略、订阅解析、配置生成和日志脱敏逻辑迁移到 `packages/ssrvpn_shared`。
- Android、macOS、Windows 仍保留各自独立的应用目录。
- CI 会先检查共享包，再分析和测试三端应用。
- 发布流程从一个带 `v*` 的 tag 触发，由同一个 GitHub Actions workflow 产出三端安装包。

## 为什么不继续维护独立平台仓库

如果继续把三个平台作为独立源码根维护，就必须额外处理共享包分发问题，例如：

- 把共享包复制到每个仓库，容易产生代码漂移。
- 使用 Git submodule，会增加日常同步和权限成本。
- 将 `ssrvpn_shared` 发布成独立包，需要维护版本、兼容性和私有发布流程。

Monorepo 可以让跨平台行为、测试和发布保持一致，减少重复修复。

## 推荐开发流程

```bash
git clone https://github.com/Elegying/SSRVPN.git
cd SSRVPN

cd packages/ssrvpn_shared
dart pub get
dart analyze
dart test

cd ../../SSRVPN_Android
flutter pub get
flutter analyze
flutter test
```

如果修改了共享行为，应分别在 `SSRVPN_Android`、`SSRVPN_MacOS` 和 `SSRVPN_Windows` 中执行 `flutter analyze` 和 `flutter test`，确认三端没有回归。

## 给旧仓库使用者的说明

- 新功能和修复请提交到 `Elegying/SSRVPN`。
- 旧平台仓库可以保留归档状态，作为历史记录和跳转入口。
- Release 下载应以 `Elegying/SSRVPN` 的 GitHub Releases 为准。
