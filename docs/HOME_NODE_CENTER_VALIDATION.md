# 首页节点居中验证（4.0.32）

本次只增加高窗口纵向布局规则：扣除系统/标题栏安全区后的整个主页（包括底部导航）
作为居中基准，节点卡自身中心固定在该区域中点。顶部启动提示占用也会扣除；
账号三卡/五卡切换和本机连接/断开不会移动节点卡中心。

高度受限时沿用 4.0.31 布局，尤其维护者确认的紧凑并排布局保持不变。
高窗口条件为首页 overview 在顶部 SafeArea 内、4px 内边距外高度至少 610 逻辑像素。
统计区仍贴底，节点到公网 IPv4 至少 12px；没有提高最小窗口、增加滚动或修改账户/代理行为。

## 已执行的布局验证

固定 Flutter 3.44.1，在 `packages/ssrvpn_shared` 执行：

```sh
mise exec flutter@3.44.1 -- flutter test \
  test/account_usage_layout_test.dart \
  test/home_overview_spacing_test.dart \
  test/home_node_center_test.dart --reporter expanded \
  --dart-define=SSRVPN_LAYOUT_OUTPUT=/private/tmp/ssrvpn-account-usage/dist/center-4032 \
  --dart-define='SSRVPN_LAYOUT_FONT=/System/Library/Fonts/STHeiti Medium.ttc' \
  --dart-define=SSRVPN_LAYOUT_ICONS=/Users/jared/.local/share/mise/installs/flutter/3.44.1/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
```

结果：206 项通过。包含手机 320/360/390 宽度、桌面最小窗口及连续缩放、横屏，
字体缩放 1.0/1.5/2.0，长节点名、大数值、错误提示、三卡/五卡往返。
测量断言覆盖控件/文字位于视口、不重叠、不裁切、无滚动范围/位移、连接和导航点击、
统计边缘与导航齐平、3→5→3 无残余间距。最小测试字号保持 10 逻辑像素。
额外 72 组安全区/连接状态检查覆盖 Android 上下 24px、macOS 28px、Windows 40px，
以及顶部提示；节点卡中心误差不超过 0.1 逻辑像素。

380×520、380×532、380×560 三种小窗口的三卡/五卡六张 PNG 与 4.0.31 基准
逐字节相同，直接证明已确认布局未改变。JSON 测量与比对结果归档于本地交付目录。

| 紧凑布局保持 | 高窗口三卡 | 高窗口五卡 |
| --- | --- | --- |
| ![紧凑五卡](images/home-center-4032/balanced-380x520-5.png) | ![居中三卡](images/home-center-4032/balanced-380x820-3.png) | ![居中五卡](images/home-center-4032/balanced-380x820-5.png) |

## 原生环境与门禁

隔离 Android 模拟器原生宿主在 360×840 逻辑屏幕使用共享生产组件和本地 HTTPS
模拟接口，九步成功：普通节点、首次等待、有效零值、真实 Home 切后台两秒恢复、
本机连接、断开、刷新失败、恢复大流量、回普通节点。系统截图确认恢复后五卡完整。
仅操作 `test.ssrvpn.usage_smoke`，未接触 USB 手机、正式 VPN 会话或真实凭据。

完整 `make verify`、macOS 隔离原生宿主与远端三端构建结果在交付时另行记录。
共享/宿主测试不等于三端正式客户端真机验收；本地没有 Windows 桌面运行环境。
