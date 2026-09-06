# v4.0.31 首页间距验证

验证日期：2026-09-06。基线为 v4.0.30 后的主线 `44e0385`，独立分支
`codex/home-spacing-4031`；原目录暂停中的未提交改动未带入。

## 调整

三端共用 `SsrvpnHomeOverview`。竖向正常布局先按统计卡片的实际内容高度排版，再用
Flutter Column 的剩余空间分配，让标题、状态、连接按钮、节点与 IP 组合之间自然舒展。
统计区底边继续固定在首页内容底边，与底栏的间隔不变；没有移动底栏或改变卡片尺寸规则。
小窗口保留紧凑分栏，节点卡与其下方公网 IPv4 明确保留 12 逻辑像素间隔。
本机采样、凭据、路由、原生最小窗口与点击区域均沿用上一版本。

桌面首次启动/重置窗口以 440×720 逻辑像素为基准，在主显示器可用工作区居中。
小屏幕按比例缩小窗口，尽可能保留四周 16 像素边距，但不小于既有 380×560 限制；
已有有效窗口记录优先。共享 `DesktopWindowStateStore.initialBounds` 统一尺寸规则，
两端通过既有显示器插件读取逻辑像素工作区，查询失败/2 秒超时时回退到既有默认窗口。
不因高 DPI 重复缩放。物理工作区小于最低逻辑尺寸时，无法同时满足最小窗口和屏内完整显示，
仍保留既有最小限制，不宣称支持这一不可能的组合。

后台只暂停账号轮询，不因短暂失焦清空尚未过期的同账号成功结果；恢复前台检查原有效期，
正常轮询保留原节奏，失败退避与 Retry-After 不被前后台切换绕过。单调时间仍决定过期；
额外比较暂停期间的本机墙钟耗时以保守扣除深度休眠时间，只能缩短、不能延长原有效期。
墙钟倒退时丢弃缓存。凭据/归属/订阅修订变化仍清空，旧代次请求仍丢弃。

## 执行与证据

命令均使用 `mise exec flutter@3.44.1 --`，在相应包目录执行：

```bash
# packages/ssrvpn_shared
flutter analyze
flutter test --reporter expanded
flutter test test/account_usage_layout_test.dart test/home_overview_spacing_test.dart \
  --dart-define=SSRVPN_LAYOUT_OUTPUT=<截图目录> \
  --dart-define=SSRVPN_LAYOUT_FONT='/System/Library/Fonts/STHeiti Medium.ttc' \
  --dart-define=SSRVPN_LAYOUT_ICONS=<Flutter SDK>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
# SSRVPN_Android
flutter test test/real_home_node_widgets_test.dart
# SSRVPN_MacOS 与 SSRVPN_Windows 各自目录
flutter test test/desktop_home_screen_test.dart test/startup_default_window_test.dart
```

原 175 项布局测试覆盖 320/360/390 手机宽度、桌面 380×560 最小窗口扣除标题栏后的
380×520/532 内容区、横屏、连续拖窗、1/1.5/2 倍字体、长节点名与大数值、错误提示、
三卡→五卡→三卡。断言无实际滚动、卡片及文字完整、不重叠、控制区域可点击。
新增 21 项真实公网 IPv4 场景测试覆盖七种视口、三种字体与三卡/五卡切换，断言节点与
IP 间距至少 12、IP 文字不裁切、统计区仍贴底、富余空间均衡分配、切回三卡无残余间距。

真实中文字体的正常字号、五卡测量（单位：逻辑像素）：

| 内容视口 | 标题→状态 | 状态→按钮 | 按钮→节点 | 节点→IP | IP 组→统计 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 380×520 / 380×532 | 紧凑分栏 | 8 | 紧凑分栏 | 12 | 保留剩余空间 |
| 380×720 | 32 | 30 | 32 | 12 | 32 |
| 390×844 | 63 | 61 | 63 | 12 | 63 |
| 412×892 | 75 | 73 | 75 | 12 | 75 |

截图由真实共享组件渲染，使用模拟账号和文档地址，不是生产账号截图：

- [桌面最小内容视口 380×520](images/home-spacing-4031/balanced-380x520-5.png)
- [桌面常用内容视口 380×720](images/home-spacing-4031/balanced-380x720-5.png)
- [手机长屏 412×892](images/home-spacing-4031/balanced-412x892-5.png)

三端首页组件回归分别覆盖 Android 24 项、macOS 33 项、Windows 17 项；两桌面端各增加 2 项默认窗口平台接线/失败回退测试。共享测试新增短时后台保留、恢复刷新失败隐藏、冻结单调时钟的休眠过期、墙钟倒退、密码轮换后的迟到结果，以及默认工作区边界。
最终四包静态分析无问题，共享全量 996 项通过、覆盖率 87.55%；真实中文布局 196 项通过。
隔离 Android 模拟器 `emulator-5592` 另运行真实 HTTPS 模拟宿主，使用生产
`SsrvpnHomeStatistics` 生命周期接线：执行 Android Home 键、后台两秒、重新进入 Activity，
有效零值仍为五卡；后续刷新失败三卡、恢复五卡、普通节点三卡，九步全部通过。
临时宿主不加载 VPN 或正式账号；原生截图与九步记录保存在本地交付验证材料。
[Android 已连接状态后台恢复后的系统截图](images/home-spacing-4031/android-resumed-device-screen.png)
显示标题、五卡、操作与导航完整。模拟器测试宿主的离屏 `toImage` 截图曾触发静态图层缺失，
因此最终禁用宿主离屏截图、改用 Android 系统 `screencap` 核对真实前后画面，恢复正常；
生产首页没有此测试截图逻辑，未修改产品渲染器。504 次原矩阵测量无问题，63 次新增间距
测量通过；最小实际测试字号为 10 逻辑像素。

本地 Windows 组件测试运行在 macOS，不代表 Windows 原生运行；三端完整构建与原生平台
检查由受保护 CI/Release 执行，三端均已通过并正式发布，详见 [正式发布记录](PROJECT_HEALTH.md)。本轮没有覆盖用户正在使用的
客户端、操作其 VPN 会话或安装 USB 实机包，不将共享截图冒充三端实机验收。
