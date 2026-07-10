# SSRVPN 包内教程、节点国旗与解锁检测审查

审查日期：2026-07-11

审查分支：`fix/package-guides-flags-unlock-audit`

基线：`v2.5.0` / `main` (`5752b6e`)

## 结论

本轮完成了 macOS DMG 与 Windows 便携 ZIP 中文教程、Windows 节点国旗、
三端共享解锁检测以及全项目质量门禁的复审。没有修改“私家车”延迟显示
策略或测试文件。

最大的正确性问题不在网络请求是否成功，而在旧版把“网页返回 200”直接
显示成“已解锁”。现在只有官方服务域名上的服务专用证据会显示“支持”；
普通官网和 API 只显示“可访问”，证据不足显示“无法判断”，网络或服务错误
显示“检测失败”。

## 已完成变更

- DMG 包含 `SSRVPN.app`、Applications 快捷方式和中文 `使用教程.txt`；
  Finder 布局直接展示三个入口。
- Windows ZIP 教程固定为用户指定的四步流程，文件名与实际入口统一为
  `ssrvpn_windows.exe`。
- CI 与发布工作流同时检查教程源文件和产物内容，避免脚本更新后文案回退。
- Windows 不再依赖系统字体渲染区域指示符 emoji，而是使用包内 SVG 国旗；
  无效或未知国家码统一显示全球占位图标。
- 解锁请求统一使用 GET，最多跟随 5 次 HTTPS 重定向，单响应最多读取
  768 KiB，一次最多并发 4 项。
- Android、macOS、Windows 共用同一个判定服务；Android 与桌面界面均展示
  状态、地区响应头和判定依据。
- Netflix 与 YouTube Premium 的最终响应必须仍在各自官方根域名下；跨域
  跳转即使伪造相同正文也只会显示“无法判断”。
- Android 初始化超时后的重试复用同一个在途初始化任务，避免并发启动两套
  核心服务；手动重试会重置计数。

## 解锁项目可靠性分级

| 项目 | 可可靠证明的范围 | 展示策略 |
|---|---|---|
| Netflix | HTTP 200、目标片 ID 与已知内容元数据同时存在 | `支持`；页面结构未知时为 `无法判断`，且不代表完整片库 |
| YouTube Premium | 页面明确的可用入口或国家/地区拒绝文案 | `支持` / `不支持` / `无法判断` |
| Claude、Gemini | API 端点是否可达；鉴权错误不能证明账号可用 | `可访问`；地区拒绝文案才是 `不支持` |
| Disney+、Prime Video、Max、Apple TV+、Spotify、Discovery+、TikTok | 官网是否可访问 | `可访问`，不宣称播放或账号权限 |
| Copilot、DeepSeek、GitHub | 官网是否可访问 | `可访问`，不宣称账号或地区权限 |

2026-07-10 的直连抽查确认了旧逻辑中的两个真实误判：YouTube Premium 页面
即使写明当前国家不可用，旧代码仍会因为正文包含 `premium` 而显示支持；
Prime Video 对 HEAD 返回 405，但 GET 正常，因此旧请求方式会产生假失败。
Apple TV+ 根页面当前返回 404，新逻辑会保守显示“无法判断”，不会显示
“不支持”。

服务的地区可用性本身会变化，判定边界参考各服务官方说明：

- [Netflix 地区片库说明](https://help.netflix.com/en/node/14164)
- [YouTube Premium 可用地区](https://support.google.com/youtube/answer/6307365)
- [Gemini API 可用地区](https://ai.google.dev/gemini-api/docs/available-regions)
- [Claude 支持国家和地区](https://www.anthropic.com/supported-countries)
- [Disney+ 地区可用性](https://help.disneyplus.com/article/disneyplus-location-availability)
- [Max 可用地区](https://help.max.com/sr-en/Answer/Detail/000002518)

## 验证证据

| 检查 | 结果 |
|---|---|
| Workspace analyze | 无问题 |
| 共享层 | 199 项通过，63.02% 行覆盖率 |
| Android Flutter | 86 项通过，45.83% 行覆盖率 |
| Android Kotlin/JUnit | 通过 |
| macOS Flutter | 34 项通过，32.33% 行覆盖率 |
| Windows Flutter | 33 项通过，1 项平台条件跳过，14.05% 行覆盖率 |
| Android Debug APK | 构建并安装成功；无线 ADB 随后离线，未完成截图验收 |
| macOS Release | `3.0.0+300` arm64 构建、临时签名和实机 UI 启动通过 |
| macOS DMG | 构建、校验、挂载和教程逐行烟测通过 |
| macOS 原生生命周期 | Dock 重开与隐藏窗口恢复 XCTest 通过 |
| Windows ZIP | 源文件、打包逻辑、组件测试和 CI 产物烟测已就绪；实机由 Windows 环境验收 |
| “私家车”延迟 | 相关文件与 `main` 无差异，现有 3 项策略测试通过 |

## 项目评分

| 维度 | 分数 | 说明 |
|---|---:|---|
| 正确性与恢复 | 8.8/10 | 启动、订阅、更新和解锁结果都采用保守失败语义 |
| 安全性 | 8.6/10 | 输入、下载、重定向、响应体、核心权限和代理所有权均有边界 |
| 可维护性 | 8.9/10 | 共享配置、桌面配置及核心生命周期/代理协调均已拆分并加入结构守卫；剩余大文件集中在 UI 组合层 |
| 测试与自动化 | 9.0/10 | 四层覆盖率门禁、原生测试、包内容和发布守卫齐全 |
| 发布准备度 | 8.4/10 | macOS 产物已实测；Windows 实机、桌面签名和 macOS TUN 仍是限制 |

整体评分：**8.7/10**。

## 如果这是我的项目，下一步

1. 在 Windows 11 干净虚拟机执行可重复的首次启动、国旗、连接、退出和代理
   恢复脚本，并把结果回传 CI。
2. 把 macOS Developer ID 公证与 Windows Authenticode 签名放到功能开发之前，
   先解决用户安装信任问题。
3. 将 Android 升级到 AGP 9 后迁移 Built-in Kotlin；当前 AGP 8.11 仍能构建，
   不把工具链大升级混入本轮修复。
4. 继续按屏幕区块拆分桌面 Home、桌面 app 和 Android `liquid_glass` 等 UI
   组合大文件，不再扩大已收口的 `ClashService` 主文件。
5. 为解锁检测维护少量、可解释的服务专用证据和回归样本；一旦官方页面变化，
   宁可回退到“无法判断”，也不制造“支持”的假结论。
