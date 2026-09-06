# 账号统计与首页自适应验证记录

验证日期：2026-09-06。基线 `140a268812ab384770ef1f67c448212e868398b8`，独立工作分支 `codex/account-usage`；原工作树未提交的代理流量改造保持不动。初始实现阶段不合并、不发布客户端、不部署面板。维护者随后授权发布，v4.0.30 已完成受保护合并、三端正式构建与公开校验，详见 [发布记录](PROJECT_HEALTH.md)。

## 当前实现与审查重点

- 三端复用共享账号模型、可信提供方解析、HTTPS 客户端、单请求控制器和统计组件；本机上传/下载/累计采样保持隔离。
- 当前完整节点名含「私家车」且匹配明确服务器、端口、协议归属时才查询。首次加载、失败、过期、换账号或后台清除两个新增卡片，只有三块或五块。
- 原有链接和密码直接从既有解析结果读取。HTTPS 校验证书、禁止重定向和凭据日志，单调时间扣除请求耗时管理过期。
- 卡片整体居中，与导航栏左右边缘一致。设备数使用 `在线数/上限`；极大数字使用带近似说明的单位格式，语义仍包含精确实例数。
- 按维护者反馈，短视口连接按钮由 138 缩至 124 逻辑像素，其他视口也小幅缩小；标题、状态、按钮、节点分别留出间距。连接按钮保持圆形，状态标签与按钮共用中心线；正常竖向空间在页面中央，紧凑视口使用明确的分栏组合。不能把几何不溢出当作美观通过。
- 外层提示按实际文字高度占用空间；横向重排用稳定子树键保留采样和账号状态，避免手动拖窗重置统计。

## 命令与证据

所有 Flutter/Dart 命令使用 `mise exec flutter@3.44.1 --`。命令在独立工作树运行；未更改 Flutter 版本或依赖锁。

```bash
make verify
# 共享包内，完整状态/身份/真实 HTTPS 错误模拟
flutter test test/account_usage_test.dart test/account_usage_identity_test.dart test/account_usage_https_test.dart
flutter test test/account_usage_layout_test.dart test/home_traffic_panel_test.dart
# 三个平台分别已有平台测试，由 make verify 执行
# Android / macOS 目录内的完整客户端构建
flutter build apk --debug --dart-define-from-file=../config/ssrvpn-usage-defines.json
flutter build macos --debug --dart-define-from-file=../config/ssrvpn-usage-defines.json
# 独立原生宿主，按脚本输出步骤运行
python3 scripts/prepare-usage-native-smoke.py
```

`make verify` 已完成：发布工具 396 项、共享 970 项、Android 288 项、macOS 314 项、Windows 291 项通过；Windows 在 macOS 上跳过 7 项平台特定测试。四个包静态分析无问题，Android 原生单元测试、macOS XCTest 及进程/崩溃报告守卫通过。共享覆盖率 87.48%，Android 69.09%，macOS 68.72%，Windows 55.85%，均达到仓库门槛。

完整门禁后，完整 Android 应用首次导入弹窗的软键盘实测暴露了背景首页 4 像素挤压。已让三端首页背景保持完整尺寸，由弹窗自行处理键盘；订阅页面保留原键盘避让行为。新增 Android 实际 HomeScreen 的键盘回归通过，后续变更补跑四包静态检查（无问题）、Android 首页 24 项、macOS 首页 33 项、Windows 首页 17 项，均通过，并重新构建 Android/macOS 客户端。

## 布局检查

共享组件测试覆盖 28 个视口、字体缩放 1.0/1.5/2.0、错误提示开关、每种情况 3→5→3：504 次完整页面测量。另在同一页面保持 State 来回调整 84 个窗口尺寸，三种字体缩放，每个尺寸 5→3→5，共 756 次检查；连接、导航和更新按钮均实际点击。连续宽度 380→1200→380，每次 20 像素，并同时改变高度。

包括 320×568（带上下安全区）、320/360×640、390×844、用户截图近似视口 453×594 与 488×640、Windows 380×560 减 40 像素标题栏、macOS 同一最小窗口减 28 像素标题栏、640×320 与 844×390 横屏。保持既有 380×560 逻辑像素最小窗口，并在原生层补上启动前/安全模式下限，Windows 按当前显示器 DPI 换算。隔离宿主也从同一共享常量读取下限。

每次断言：卡片完整位于导航之上且不重叠，卡片文字无裁切，所有 Column 无实际子项溢出，原操作区域至少 48 像素，整页没有 Scrollable，拖动后位置不变；连接按钮宽高相等，状态与按钮中心线一致；卡片组左右边缘与导航表面相等；回到三块后无残余间距。长设备数检查从零到 int64 最大值的卡片矩形稳定。

真实中文字体和 MaterialIcons 的渲染截图及 `measurements.json` 输出到忽略的 `dist/usage-layout-cjk/`。测试使用本机字体，仅用于渲染证据，不打包进客户端。最小实际字号为 10 逻辑像素，仅发生于最紧凑/极端数值场景；系统文字缩放没有全局关闭。

这些检查限定于列出的受支持视口及连续区间，并非对无限小窗口的保证。更小视口若固定控件本身无法容纳，需要先明确产品布局取舍，不能用隐藏、裁切或恢复滚动冒充通过。

最新原生窗口修复提交 `c7b2cde` 的 [GitHub CI](https://github.com/Elegying/SSRVPN/actions/runs/34007314915) 已全部完成：Windows build/policy、Android、macOS、macOS native、Workspace checks 均成功。键盘修正后的最终代码提交 `cb18bbd` 的 [三端 CI](https://github.com/Elegying/SSRVPN/actions/runs/34007986449) 也已全部成功。

## 原生验证边界

| 平台 | 本地可执行项 | 不代表已验证的项目 |
| --- | --- | --- |
| Android | 完整 APK 构建、平台测试、Android 原生单元测试；完整客户端首页及导入弹窗/键盘实测；隔离 Android 36 模拟器 360×640 原生引擎和本地 HTTPS 八步状态验证 | 无 USB 实机验收；未使用生产账号；未完成生产 VPN/TUN 端到端联调 |
| macOS | 完整应用构建、平台测试、原生单元测试；独立包名原生宿主和本地 HTTPS 八步状态验证 | 不启动或中断用户现用 VPN；未完成生产系统代理/TUN 与账号联调 |
| Windows | 可在 macOS 执行的 Flutter 平台测试和静态守卫；原生构建应在 Windows CI/主机执行 | Windows CI 已在最终代码提交 cb18bbd 完成原生构建、安装包与策略门禁；本机没有 Windows 原生交互环境，实际手动拖窗/系统代理/TUN 验收仍未完成，不能以共享测试或 macOS 原生截图替代 |

隔离宿主显式控制查询资格，避免检查截图时失焦暂停模拟查询；实际前后台接线由共享组件生命周期测试覆盖，不冒充原生完整应用生命周期验收。隔离宿主使用合成认证和临时测试证书，入口不会加载任何平台 VPN 服务或生产设置。八步为普通节点三块且零请求、首次等待三块、有效零值五块、本机连接五块、本机断开仍五块、刷新错误三块、恢复大数字五块、普通节点再次三块。截图只保存关键状态，JSON 记录全部八步。宿主不是要分发的 SSRVPN 客户端。

较早 Android 模拟器出现系统 UI ANR，其截图不作为通过证据；改用独立临时 AVD 后重新验证。原生宿主早期采用固定延时，易受截图编码/JIT 影响，已改为等待有界的实际控制器状态；没有延长生产 8 秒请求超时。

## 真实面板接入

[配置文件](../config/ssrvpn-usage-defines.json) 与 [接口契约](CLIENT_USAGE_API_V1.md) 已就绪。真实地址为 `https://panel.ssrvpn.vip:19998/api/v1/user/usage`，可信节点为用户确认的域名/IP 与 19999/443 六个组合。

初次无凭据 HTTPS GET 得到 404。2026-09-06 维护者部署接口并提供授权测试账号后补验：真实接口返回 200；沿用原有订阅解析器、可信归属解析器与生产模型/查询客户端，三轮均接受响应。两轮刷新间隔 15 秒，服务时间与观察时间递增，扣除请求耗时后的有效期约 20–26 秒；普通节点和第三方改名节点仍被归属解析拒绝。

测试通过关闭回显的标准输入传入凭据，仅在进程内存使用，不记录完整链接、密码或身份哈希。账号实际用量和在线数仅留在本地验收材料，未提交公共仓库。本次未创建隔离账号、连接 VPN、修改生产配置或部署服务；已验证授权账号的真实查询，尚未独立核对面板账本、验证在线数随连接变化，或完成三端原生应用的生产系统代理/TUN 网络联调。

## 安装包与复现材料

交付的 `SSRVPN-account-usage-arm64-test.apk` 为 AOT/R8 优化测试构建，31,318,340 字节（约 29.9 MiB），包名 `com.ssrvpn.android.debug`、版本 `4.0.29-test`，使用 Android Debug 测试签名，不覆盖正式客户端包名。SHA-256：`59baca186ec12b7fd1995756fe1043dec4b224d3c3dbc63a4b75635a656d58a7`。

优化沿用仓库已有 release AOT、R8 和资源压缩设置，仅通过临时 Gradle init 配置将测试包名、显示名和签名隔离。没有修改仓库的正式签名/发布配置。已核对优化前后核心及数据库资产字节相同，且 HTTPS 提供方配置存在于 AOT 产物；优化包已在独立模拟器升级安装成功。未连接 USB 实机，未声称实机或真实 VPN 会话验收通过。

实际优化构建命令为 Android 目录的 `./gradlew --no-daemon --init-script <交付材料中的 optimized-test.init.gradle> assembleRelease -Ptarget-platform=android-arm64 -Ptarget=lib/main.dart -Pdart-defines=<配置键值逐项 Base64 后以逗号连接> -Pdart-obfuscation=false -Ptrack-widget-creation=false -Ptree-shake-icons=true`。使用的是明确给出的非敏感提供方配置，未包含账号认证密钥。完整可复现脚本、init 配置、构建日志随本地交付材料提供。

布局截图包含 `488x640-five-scale1.0-errorfalse.png`、`380x520-five-scale2.0-errortrue.png`、`320x568-five-scale2.0-errortrue.png`、`640x320-five-scale2.0-errortrue.png`，以及对应三卡模式。`measurements.json` 记录 504 次测量，全部无问题；最小实际字号 10。原生宿主的 `valid-zero.png`、`recovered-large.png`、`ordinary-again.png` 与八步 `report.json` 单独分平台保存。完整 Android 应用的优化包首页、导入弹窗键盘截图另存；不把旧系统 ANR 或已修复的溢出截图当作通过证据。

## 主要修改文件

| 范围 | 文件 |
| --- | --- |
| 模型、信任与查询 | `packages/ssrvpn_shared/lib/models/account_usage.dart`、`lib/services/account_usage_provider.dart`、`lib/services/account_usage_client.dart` |
| 生命周期与采样隔离 | `packages/ssrvpn_shared/lib/controllers/account_usage_controller.dart`、`lib/widgets/ssrvpn_home_statistics.dart` |
| 整页与卡片布局 | `packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview.dart`、`ssrvpn_home_overview_header.dart`、`ssrvpn_home_shell.dart`、`ssrvpn_home_traffic_panel.dart`、`ssrvpn_home_text.dart`、`ssrvpn_app_surface.dart`、`ssrvpn_version_update_footer.dart` |
| 三端接线 | `SSRVPN_Android/lib/app.dart`、`lib/screens/home_screen.dart`；共享 `lib/desktop_ui/desktop_app_shell_part.dart`、`screens/desktop_home_screen_part.dart`；两桌面平台 `lib/app.dart` |
| 原生窗口下限 | `SSRVPN_MacOS/macos/Runner/MainFlutterWindow.swift`、`RunnerTests/RunnerTests.swift`；`SSRVPN_Windows/windows/runner/win32_window.cpp`、`flutter_window.cpp` |
| 配置与验证 | `config/ssrvpn-usage-defines.json`；四个共享 `account_usage_*test.dart`；既有首页回归；`scripts/prepare-usage-native-smoke.py` 与共享包 `tool/account_usage_native_smoke.dart` |
