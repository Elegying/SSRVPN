# 三端真机验收矩阵

本矩阵是正式发布前人工验收的统一规范。自动化测试证明逻辑和失败边界，真机验收证明系统
VPN、代理、TUN、安装、无障碍及电量在目标系统上实际成立。没有对应设备证据的条目必须保持
“未执行”，不得标记通过。

## 证据头

每台设备先记录以下信息，日志、订阅和节点内容必须脱敏：

| 字段 | 内容 |
| --- | --- |
| 平台与系统版本 | 待填写 |
| 设备型号与 CPU | 待填写 |
| 应用版本、Git 提交 | 待填写 |
| 安装包文件名、SHA-256 | 待填写 |
| 网络类型、运营商或局域网 | 待填写 |
| 测试时间、执行人 | 待填写 |
| 结果 | 未执行 / 通过 / 失败 / 阻塞 |

每个失败必须附最小复现步骤、发生时间、应用诊断、系统日志和预期结果；禁止上传原始订阅、
节点密码、Token、API secret、用户名路径或未脱敏截图。

## 2026-09-03 v4.0.26 规整日志与规则文件持久化正式发布证据

- 实现 PR [#190](https://github.com/Elegying/SSRVPN/pull/190) 与发布稳定性 PR
  [#191](https://github.com/Elegying/SSRVPN/pull/191) 均经受保护检查后 squash 合并；最终 `main`、
  注释标签 `v4.0.26` 均精确指向提交 `35f099d40cc4917aea0381c1d0e78641a105dfc3`。精确
  [主分支 CI 33742979692](https://github.com/Elegying/SSRVPN/actions/runs/33742979692)、
  [Prepare Release 33744510425](https://github.com/Elegying/SSRVPN/actions/runs/33744510425) 和
  [Release 33744541261](https://github.com/Elegying/SSRVPN/actions/runs/33744541261) 均成功。
- [GitHub Release v4.0.26](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.26) 已公开，非
  draft、非 prerelease，共七项资产。独立完整下载后 APK SHA-256 为
  `43f895620738202c65b34d8d56154ad0a90efe6d4414d310f8ccf2393f721aa4`，DMG 为
  `cd2b1c14708e34173c5d6371006e051dd146a2461f14495ae25afb735daa498d`，Windows 安装器为
  `2db0dd5add0baf92c7c46db7c33cd9edc7cba8d3ffcb3b04574a0ba4c1873089`；实际文件、三份
  sidecar、Release API digest、provenance 与三个绑定最终提交的 GitHub Attestations 一致。
- OSS `latest.json` 已指向 `4.0.26`；三个版本化安装包再次独立完整下载，SHA-256 与 GitHub
  一致且逐字节相同。正式 Release 中 Shared 669 项（85.12%）、Android 279 项（68.15%）、
  macOS 286 项（66.75%）和 Windows 282 项（57.13%）均通过，三端原生、包结构、签名及
  Windows 安装/卸载 smoke 门禁成功。
- v4.0.25 首次发布因测试把随机 UDP 端口错误假设为同号 TCP 必然可用而在资产公开前停止；
  修复为确定性协议占用模型后重复测试和正式流水线均通过。产品端口选择逻辑未改，v4.0.25
  没有公开 Release，也没有切换 OSS 公共更新通道。

- 三端订阅页右上角统一显示带文字的“运行日志”按钮；节点选择页不再有重复入口。Android
  实际订阅页会打开原有诊断弹层，窄屏和大字号下仍保留可理解文字。
- 诊断默认展示一句话结论、中文检查项和按本地时间整理的运行记录；内部事件名、会话编号、
  路径、核心清单及重复配置输出默认隐藏，只在收起的脱敏技术明细中保留。复制报告采用相同
  规整结构，原有脱敏、大小上限及不自动上传边界不变。
- 已用 v4.0.24 实际 macOS 诊断定位远程规则持久化缺陷：Mihomo API 中六份 provider 已加载
  规则版本 1.1.0，但应用目录仍是旧 YAML 且无活动版本清单。候选流程改为先通过当前代理下载
  变化内容并完整校验，再热更新核心；全部成功后原子保存本地文件并最后提交清单。失败仍保留
  旧文件、旧版本与当前连接。
- `v4.0.26` 正式包已在 Xiaomi 2509FPN0BC / Android 17 和 Apple Silicon / macOS 26.6.2
  完成增量实机验收；完整范围与证据见
  [v4.0.26 Android/macOS 实机验收报告](uat/SSRVPN_Android_MacOS_v4.0.26_实机验收报告_20260903.md)。
  Android 真实完全断网时“节点与外部网络”诊断误报通过已记录为
  [#193](https://github.com/Elegying/SSRVPN/issues/193)，安排在下一客户端版本修复，不阻断
  `v4.0.26` 当前连接与数据通道。

| ID | 平台/模式 | 目标 | 通过标准 | 当前状态 |
| --- | --- | --- | --- | --- |
| V26-01 | Android、macOS、Windows UI | 订阅页、节点选择页、窄窗和大字号 | 订阅页显示“运行日志”文字且可打开诊断；节点页无重复入口 | Android/macOS 实机通过；Windows 自动化通过 / 人工未执行 |
| V26-02 | 三端诊断 | 正常、有提醒、错误及技术明细 | 默认内容简明规整且不泄露内部标识；原始脱敏信息仍可按需展开 | Android/macOS 实机完成；Android 断网误报见 #193；Windows 自动化通过 / 人工未执行 |
| V26-03 | 三端连接后规则升级 | v4.0.24 旧缓存、同版、失败和重连 | 新内容长期落盘；清单最后提交；失败不断连且下次可重试 | macOS 实机已验证升级与同版零下载；Android 当前规则可用但未单独证明两分钟零下载；失败注入仍为自动化；Windows 人工未执行 |

受保护合并、正式线上三端构建和公开资产已经完成。Android/macOS 本轮只将实际执行的场景
标记为通过：Android 抖音仅覆盖两个评论面板和一个私信会话、重连仅五轮；macOS 按维护者
要求未断网；Windows 未人工执行。未覆盖场景没有被自动化、其他平台或构建结果冒充为通过。

## 2026-09-03 v4.0.24 省流量规则更新与国内应用名单正式发布证据

- 受保护 PR [#188](https://github.com/Elegying/SSRVPN/pull/188) 已 squash 合并；`main`、标签
  `v4.0.24` 均精确指向提交 `ff801ba482a40333077fed92806f4d255d2b66d4`。精确
  [主分支 CI 33726967743](https://github.com/Elegying/SSRVPN/actions/runs/33726967743)、
  [Prepare Release 33728358633](https://github.com/Elegying/SSRVPN/actions/runs/33728358633) 和
  [Release 33728388311](https://github.com/Elegying/SSRVPN/actions/runs/33728388311) 均成功。
- [GitHub Release v4.0.24](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.24) 已公开，非
  draft、非 prerelease，共七项资产。独立完整下载后 APK SHA-256 为
  `6d8486b4291a5fe074a10f9950aa6c9d0dc2aa62a7a01429a90f4a4eba31d522`，DMG 为
  `077fe8b96c8b35434e5edf4991d04784f8022fb532be20707cffed22a1453d1d`，Windows 安装器为
  `6ccf7262f79e57891c9132929b4c73b1bbda4d89f54b698d6e7c55246cbfd887`；实际文件、三份
  sidecar、Release API digest、provenance 与三个 GitHub Attestations 逐项一致。
- OSS `latest.json` 已指向 `4.0.24`；三个版本化安装包再次独立完整下载，SHA-256 与 GitHub
  一致且逐字节相同。固定 Flutter 3.44.1 的完整本地门禁和正式 Release 中 Shared 665 项
  （85.01%）、Android Flutter 278 项、macOS 286 项（66.75%）、Windows 282 项（57.13%）
  均通过，三端原生、安装器 smoke 和包结构门禁成功。
- 连接成功后的规则检查从十分钟改为两分钟：先通过当前代理获取 122 字节的 `version.json`；
  本地版本相同或更高时不请求清单或 provider，只有线上版本更高才下载并校验清单。内容未变化
  的 provider 不刷新；六份活动文件全部通过 SHA-256、条目数、大小和语法复核后才持久化新
  清单。网络、解析、摘要、刷新或落盘失败均继续使用原有本地规则，且不改变当前节点连接。
- 公开规则版本 `1.1.0` 的版本描述、清单和六份 provider 已独立下载复核；版本描述声明的清单
  SHA-256 `e029db143fc1adfb3179a020a09eb8437fcbe58cfc56bbef76333441768d16db`
  与线上清单实算值一致。长期本地副本、同版本零下载、防降级、损坏恢复和部分刷新失败均有回归。
- Android“智能”模式国内应用精确旁路增至 182 个，新增汽车之家、懂车帝、飞猪和易车；
  常用浏览器、国外应用、VPN 和特权工具继续进入 TUN，“全局”模式仍不启用国内应用旁路。
  桌面订阅页右上角运行日志、节点页无重复入口及“关于”页检查更新继续由 Widget 回归保护。
- 发布时 `adb devices` 没有在线设备，因此 v4.0.24 正式 APK 的原地升级、抖音评论/私信图片、
  Telegram 及两分钟后台更新真实数据路径保持未执行；自动化不能替代该证据。

正式版仍需按下表记录真实数据通道；未取得设备证据时保持“未执行”：

| ID | 平台/模式 | 目标 | 通过标准 | 当前状态 |
| --- | --- | --- | --- | --- |
| V24-01 | Android 智能 | 抖音评论区、私信图片及新增四个国内应用 | 明确国内包名不进入 TUN；连续 20 轮图片、评论、消息和页面正常 | 自动化通过 / 真机未执行 |
| V24-02 | Android 智能/全局 | 浏览器、Telegram、国内与国外应用 | 浏览器和国外应用继续进入 TUN；全局模式不启用国内旁路 | 自动化通过 / 真机未执行 |
| V24-03 | 三端连接后更新 | 同版、升级、断网和损坏响应 | 约两分钟只先请求版本；同版零后续下载；失败不断连并沿用旧规则 | 自动化通过 / 真机未执行 |
| V24-04 | Android 升级/恢复 | v4.0.23 原地升级、旧规则缓存和原生快照 | 数据保留；有效缓存长期复用；损坏状态恢复内置基线且连接可用 | 自动化通过 / 真机未执行 |
| V24-05 | macOS TUN/系统代理 | 国内、海外、DNS、UDP/QUIC、规则更新 | 数据路径和系统设置正常；未知流量可访问；异常退出后恢复 | 线上构建/配置验证通过 / 人工未执行 |
| V24-06 | Windows TUN/系统代理 | 国内、海外、DNS、UDP/QUIC、规则更新 | 数据路径正常；更新失败不断连；异常退出后系统设置恢复 | 线上构建/安装 smoke 通过 / 人工未执行 |
| V24-07 | Windows/macOS UI | 订阅页日志、节点页、关于页检查更新 | 单一日志入口位置正确；窄窗口、键盘和读屏可用；手动更新可执行 | 自动化通过 / 人工未执行 |

## 2026-09-03 v4.0.23 国内应用旁路与桌面体验正式发布证据

- 受保护 PR [#186](https://github.com/Elegying/SSRVPN/pull/186) 已 squash 合并；`main`、标签
  `v4.0.23` 均精确指向提交 `2fe43b56b1e45f3462e4362aabcecd6140f3d9aa`。精确
  [主分支 CI 33713779646](https://github.com/Elegying/SSRVPN/actions/runs/33713779646)、
  [Prepare Release 33714753378](https://github.com/Elegying/SSRVPN/actions/runs/33714753378) 和
  [Release 33714772096](https://github.com/Elegying/SSRVPN/actions/runs/33714772096) 均成功。
- [GitHub Release v4.0.23](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.23) 已公开，非
  draft、非 prerelease，共七项资产。独立完整下载后 APK SHA-256 为
  `7b970325eeab297558c4134cfe3d94730896b546257cce4f20c8eac7490d356e`，DMG 为
  `a72faf077f0f22bed3a0c140b851854c56d0ee28318f2695094f27718b76e398`，Windows 安装器为
  `e0ede592c37f51cde820e26d7e12f69bff20565260359dbcb478475228dfc3a1`；实际文件、三份
  sidecar、Release API digest、provenance 与三个 GitHub Attestations 逐项一致。
- OSS `latest.json` 已指向 `4.0.23`；三个版本化安装包再次独立完整下载，SHA-256 与 GitHub
  一致且逐字节相同。发布事务证据不替代下表保持“未执行”的真实网络与人工桌面 UAT。
- 固定 Flutter 3.44.1 的完整本地门禁通过；正式 Release 中 Shared 659 项（84.98%）、Android
  Flutter 278 项、macOS 286 项（66.75%）和 Windows 282 项（57.13%）通过，Android Kotlin
  原生单测/Release 构建、macOS 原生测试、Windows 安装/卸载 smoke 和三端包结构门禁均成功。
- Android 仅在“智能”模式把 178 个经审查的国内应用排除在 TUN 外，包含抖音及轻量版；
  Chrome 各通道、Edge、Firefox、Brave、DuckDuckGo、Opera、三星、UC、QQ、夸克、华为、
  Vivo、百度、360、Via、Vivaldi 等浏览器，以及 Telegram、ChatGPT、Claude、Lark 国际版和
  不确定包名均有“不旁路”负例。“全局”模式禁用国内应用旁路；ADB 调试包保留既有旁路。
- 桌面订阅页右上角运行日志、节点页入口移除、关于页手动检查更新和紧凑宽度图标回退均有
  Widget 回归。macOS 系统代理减少三次重复 `networksetup` 启用调用，但快照、服务身份复核、
  guardian、回读和失败回滚仍有定向测试。Windows 连接事务未删除任何稳定性门禁。
- 发布时 `adb devices` 没有在线设备，因此 v4.0.23 正式 APK 的原地升级、抖音评论/私信图片
  和 Telegram 真实数据路径保持未执行；自动化不能替代该证据。

正式版仍需按下表记录真实数据通道；未取得设备证据时保持“未执行”：

| ID | 平台/模式 | 目标 | 通过标准 | 当前状态 |
| --- | --- | --- | --- | --- |
| V23-01 | Android 智能 | 抖音评论区、私信图片，微信、QQ、淘宝等国内应用 | 已维护国内包名不进入 TUN；连续 20 轮图片、评论和消息正常，无随机超时 | 自动化通过 / 真机未执行 |
| V23-02 | Android 智能 | Chrome/Edge/Firefox 等浏览器、Telegram、ChatGPT、Claude | 浏览器和国外应用继续进入 TUN，域名规则或强制代理规则生效 | 自动化通过 / 真机未执行 |
| V23-03 | Android 全局 | 国内与国外应用 | 国内应用旁路关闭，除既有 ADB 调试包外全部应用进入 TUN | 自动化通过 / 真机未执行 |
| V23-04 | Android 升级/恢复 | v4.0.22 原地升级、旧原生快照、模式切换 | 数据保留；旧 v1/v2 快照按“不旁路”解码；切换模式完整重连且无残留 VPN | 自动化通过 / 真机未执行 |
| V23-05 | macOS 系统代理 | 连接、断开、失败回滚和连接耗时 | 系统代理正确启用/恢复，失败不留脏状态；同机记录 10 次中位数和 P95 | 自动化通过 / 人工未执行 |
| V23-06 | Windows TUN/系统代理 | 国内、海外、DNS、UDP/QUIC、异常退出 | 数据路径正常，未知流量可访问，异常退出后系统网络设置恢复 | 线上构建/安装 smoke 通过 / 人工未执行 |
| V23-07 | Windows/macOS UI | 订阅页日志、关于页检查更新、未连接手动检查 | 键盘/读屏可达，窄窗口不溢出；手动检查可执行，自动检查仍只在连接后运行 | 自动化通过 / 人工未执行 |

## 2026-09-02 v4.0.22 智能分流正式发布与候选证据

- 受保护 PR [#183](https://github.com/Elegying/SSRVPN/pull/183) 已 squash 合并；`main`、标签
  `v4.0.22` 均精确指向提交 `eb3d161015f1abdb154c370b0c2de3bc2b0be57d`。精确
  [主分支 CI 33625677508](https://github.com/Elegying/SSRVPN/actions/runs/33625677508)、
  [Prepare Release 33627188347](https://github.com/Elegying/SSRVPN/actions/runs/33627188347) 和
  [Release 33627219065](https://github.com/Elegying/SSRVPN/actions/runs/33627219065) 均成功。
- [GitHub Release v4.0.22](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.22) 已公开，非
  draft、非 prerelease，共七项资产。完整下载后 APK SHA-256 为
  `81faed6d73c707baf8ae8c7ff1dd89119d581fccdb44624bcd0d06b1dcb1ac72`，DMG 为
  `c66039fb4d5c66ac44e6ecb2619e0d51be3c4edce9db93ef50d52819dd91c3ef`，Windows 安装器为
  `5a15890d38a97087be7edb2996030f542d68006aecec55a4822472742d580152`；实际文件、三份
  sidecar、Release API digest、provenance 与 GitHub Attestations 逐项一致。
- OSS `latest.json` 已指向 `4.0.22`；三个版本化资产独立完整下载后的 SHA-256 与 GitHub
  Release 一致，版本化和公共 `latest.json` 逐字节一致。发布事务证据不替代下表保持
  “未执行”的真实网络和人工桌面 UAT。

- 共享配置测试已覆盖“用户强制代理 → 用户强制直连 → 海外服务代理 → 国内企业域名/ASN
  直连 → GFW/CN/GeoIP → `MATCH,PROXY`”顺序、冲突目标代理优先及对应 DNS policy。
- 六份内置规则的 schema、语义版本、固定上游提交、条目数、SHA-256、必需服务域名和 CIDR
  已离线校验；有效远程缓存保留、损坏缓存恢复内置基线、刷新失败不改写缓存均有自动回归。
- macOS M1 / macOS 26.6.2 已使用项目内置 Mihomo v1.19.29 实际加载系统代理与 TUN 配置，
  配置校验成功；完整 macOS Flutter 定向生命周期测试通过。Windows 配置回归通过，真实
  Windows TUN、系统代理和安装器配置回归、构建及安装/卸载 smoke 已由正式 Windows runner
  执行；真实桌面流量矩阵仍需人工执行。
- Android Flutter 配置、原生桥守卫和 Kotlin 单测构建通过；本轮检查时 `adb devices` 没有
  在线设备，因此不能把旧版 Telegram 实机证据或本地编译冒充 v4.0.22 正式 APK 实机复验。

正式版仍需按下表记录真实数据通道；未取得设备证据时保持“未执行”：

| ID | 平台/模式 | 目标 | 通过标准 | 当前状态 |
| --- | --- | --- | --- | --- |
| R-01 | Android TUN | 淘宝、B站、微信、百度 | 普通应用进入 TUN，域名命中国内规则后直连且页面/消息可用 | 未执行 |
| R-02 | Android TUN | Google、YouTube、GitHub、OpenAI、Telegram | 域名、Telegram IP 或国外应用包名命中代理，真实功能可用 | 未执行 |
| R-03 | Android TUN | 百度智能云、阿里云、火山引擎、华为云 | 主域名、API 和已知 CDN 域名优先直连；用户强制代理可覆盖 | 未执行 |
| R-04 | macOS TUN | 国内/海外/国内 AI/海外 CDN | DNS 无旁路，TCP/UDP/QUIC 可用，嗅探失败不阻断 | 未执行 |
| R-05 | macOS 系统代理 | 同上 | 遵循系统代理的应用可用；不遵循系统代理的应用按产品说明改用 TUN | 未执行 |
| R-06 | Windows TUN | 同上 | IPv4、DNS、TCP/UDP/QUIC、断开恢复与系统路由正常 | 线上构建/安装器 smoke 通过 / 人工未执行 |
| R-07 | Windows 系统代理 | 同上 | 浏览器及遵循系统代理的应用可用，断开后系统代理完整恢复 | 线上构建/安装器 smoke 通过 / 人工未执行 |
| R-08 | 三端故障注入 | 规则更新失败、DNS 短时失败、节点断开恢复 | 保留旧规则与连接状态；未知目标走代理，不因刷新失败阻断建连 | 自动化通过 / 人工未执行 |

## 2026-09-02 v4.0.20 正式发布证据

- 正式版本 `4.0.20+4020` 的受保护 `main` 和标签 `v4.0.20` 精确指向提交
  `c7667ff0075ae9b5c4848cb72de842b9b7bcbe07`；精确主分支 CI
  [33553184498](https://github.com/Elegying/SSRVPN/actions/runs/33553184498)、
  [Prepare Release 33554832427](https://github.com/Elegying/SSRVPN/actions/runs/33554832427) 和
  [正式 Release 33554866473](https://github.com/Elegying/SSRVPN/actions/runs/33554866473) 均成功。
- [GitHub Release v4.0.20](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.20) 已公开，非
  draft、非 prerelease，共七项资产。完整下载后 APK SHA-256 为
  `f6cae87cd42825bdae68dc9879605a5749414d357cea6b932883bbfc5497f977`，DMG 为
  `2c988fb8b7563591763c2798e43a26d3f7587d2301390fa1e96a65dca59fa1f9`，Windows 安装器为
  `3f662fb2670b3d2247ba170d024458a4c6d43a6f65633125771c29a55bf3fba3`；三份 sidecar、
  Release API digest 和 provenance 逐项一致。
- provenance 精确记录标签、提交和三端摘要；APK、DMG、EXE 的 GitHub Attestations 均通过
  Sigstore/SLSA 验证，workflow ref、源码摘要和 run attempt 与正式发布一致。
- 正式 APK 为 `com.ssrvpn.android`、`versionName=4.0.20`、`versionCode=4020`、
  `minSdk=24`、`targetSdk=36`、arm64-v8a；APK v2 签名、单一 signer，证书 SHA-256 为
  `caf5bb670e4513c4e3d7815a7314f489281c37f02827db07d0a59e1242f2cc0c`，16 KiB zipalign
  检查通过。正式 DMG 可校验和挂载，应用版本为 `4.0.20+4020`、arm64，继续使用项目明确的
  ad-hoc、未公证免费分发边界。
- OSS `latest.json` 已指向 `4.0.20`，三个公开版本化资产独立完整下载后的 SHA-256 与 GitHub
  Release 完全一致。正式资产、构建和公共通道证据证明发布事务完整，不替代下方仍标记为
  `BLOCKED` 或“未执行”的硬件、OEM 与人工桌面 UAT。

## 2026-09-02 v4.0.20 Android 修复候选增量验收快照

- 修复候选提交 `ae83e529a60830e51054b710db764293dcf53732` 的 APK 在同一 Redmi Note 8 /
  Android 11 上完成 App 入口 20/20 轮连接与断开和 10/10 轮快速取消；全程保持同一 PID，
  断开后 VPN、`tun0`、7890/7891 均释放，超过旧版终止窗口后无资源回弹或 fail-closed 日志。
- 后台 60 秒与强制 deep Doze 60 秒保持同一 PID、`CONNECTED/VALIDATED` VPN、`tun0` 和
  真实 HTTPS 204；测试后已解除 Doze、唤醒并正常断开。
- 快捷磁贴单轮真实连接/断开通过。MIUI 在快捷面板展开时会为
  `cmd statusbar click-tile` 连续注入两次点击，面板收起时不投递；因此自动 20 轮保持
  `BLOCKED`，不把系统双击包装成人工单击验收。
- 候选来自版本提升前的精确修复提交，APK 身份仍为 `4.0.19+4019`；provenance 和 SHA-256
  将二进制绑定到该提交。正式 v4.0.20 已由受保护 `main` 重建并通过上方发布终验；候选与
  正式提交之间只有版本、变更日志和证据文件变化，没有改变本表实测的 Android 运行路径。
- 原生 16 KiB page-size 设备、蜂窝切换、第二 VPN、更多 OEM 继续保持未执行；本机 4 KiB
  设备和 ELF 16 KiB 对齐不替代硬件 UAT。
- 完整步骤、候选包身份、日志摘要和现场恢复见
  [v4.0.20 Android 修复候选实机验收报告](uat/SSRVPN_Android_v4.0.20_修复候选实机验收报告_20260902.md)。

## 2026-09-01 v4.0.19 Android / macOS 增量验收快照

- Android 正式 APK 已在 Redmi Note 8 / Android 11 上完成安装、首次启动、VPN 授权拒绝后重试、真实 `CONNECTED/VALIDATED` 数据路径、通知、快捷磁贴、同版本覆盖和恢复验证；真实 HTTPS 探针返回 204。
- Android C-03/C-04 失败：快速连接/断开第 2 轮、正常节奏第 5 轮均出现“自有 TUN lease 仍存在”，应用按 fail-closed 设计终止进程后恢复。旧 TUN 与数据端口最终清理，但进程稳定性不满足 20 轮标准；见 [#167](https://github.com/Elegying/SSRVPN/issues/167)。
- Android 锁屏强制 Doze 30 分钟后保持同一 PID、前台 Service、`tun0` 与 `CONNECTED/VALIDATED` VPN，真实 HTTPS 探针仍返回 204；Wi-Fi 中断后请求有界失败，恢复后同一会话重新返回 204。设备无 SIM，蜂窝切换仍为 BLOCKED。
- Android 实际启用 TalkBack 与 200% 字体，关键控件可取得无障碍焦点并由键盘顺序到达；诊断报告写入后读回一致，且对真实剪贴板的无正文扫描未命中 URL、非回环私网 IP、本机用户名路径或 fixture 敏感值。设备为 4 KiB page size，正式 core 的 16 KiB ELF 对齐不冒充原生 16 KiB 硬件 UAT。
- macOS 正式 DMG 已完成系统代理连接/断开、GUI 异常退出恢复、TUN 授权取消与同意、真实 TUN 数据路径、DNS 防泄漏与正常断开恢复；应用退出重开和单实例行为通过。持续离线取消未取得有效证据，保持“未执行”。
- macOS Developer ID/notarization 和 Windows Authenticode 已由维护者再次明确为“不需要”，继续按免费 ad-hoc / 未公证和 Windows 未签名分发，不列为缺口。
- 完整步骤、日志摘要和未执行边界见 [v4.0.19 Android/macOS 实机验收报告](uat/SSRVPN_Android_MacOS_v4.0.19_实机验收报告_20260901.md)。

## 2026-09-01 v4.0.19 Windows 增量验收快照

- 完整脱敏报告见 [v4.0.19 Windows 实机验收报告](uat/SSRVPN_Windows_v4.0.19_实机验收报告_20260901.md)。
- Windows 11 正式安装版完成 4.0.17 -> 4.0.19 覆盖升级、用户数据保留、系统代理、TUN 数据路径，以及系统代理/TUN 的 GUI 异常退出恢复；正式资产、SHA-256 和 provenance 一致。
- Windows 内置更新器下载并正确标记的 4.0.19 安装包，在安装成功并完整等待 130 秒后仍未自动清理；隔离复现结果相同。手动未标记安装器正确保留。该失败阻断本轮发布放行。
- 本机 UAC 管理员策略自动批准，因此弹窗同意/取消路径保持 `blocked`；托盘菜单正常退出无法由当前高完整性自动化会话可靠触发，同样保持 `blocked`。
- Windows 执行主机本轮没有 macOS 主机或 Android 真机，因此该报告不评价另外两端；项目当前 macOS/Android 结果见同日独立实机报告。自动化和包结构证据仍不替代真机。

## 2026-08-22 v4.0.16 正式发布证据边界

- `v4.0.16` 已正式发布，标签、`main` 和版本基线均为 `f85135ad5f50908982fa31a94cdb527f1b3d958c`；精确 `main` CI、Release workflow、三端正式资产、SHA-256、provenance、GitHub Attestations 和 OSS 公共通道均已通过。它们属于自动化与公开资产证据，不替代下列人工实机项目。
- 本版本在 v4.0.15 的三端连接健康/恢复、Android VPN 生命周期、Windows 内置更新与安装器，以及“关于/使用教程”界面基础上，统一了三端节点延迟的 TCP 端口建连口径。
- 本轮没有新增三端完整人工实机矩阵。Android 17、macOS Apple M 和 Windows 11 的最近实机证据继续按下方历史快照引用；没有执行的长时、耗电、弱网和读屏条目保持“未执行”。
- Windows 安装后自动删除只适用于 v4.0.15 或更高版本客户端内置更新器下载、SHA-256 校验并写入专属标记的版本化安装包。旧版客户端下载的首个升级包因没有标记必须保留；取消、失败、手动下载、文件名/摘要不匹配和非普通文件也必须保留。仅删除安装包、保留隐藏标记后，同版本重下必须使用由正式文件名和可信 SHA-256 唯一派生的 32 位小写十六进制后缀，新包成功安装后仍能清理，原标记逐字节保留。任何仅按保留文件名或修改时间匹配的 `.part`/`.previous` 文件都不得自动删除；中断恢复读取候选后也必须保留候选原文件。Windows 线上安装/覆盖 smoke 通过后只能记为自动化证据，不能冒充人工桌面验收。
- 本轮没有取得当前版本正式字体与 Retina 模糊的 macOS 实机截图；已用同一 1200×800 生产首页暗色主题 Widget fixture 并排对照“使用教程/关于”的几何与 18px 模糊，并以紧凑视口和大字号自动化覆盖可达性。测试字体截图只证明布局与材质一致，不标记为实机字体或像素验收。
- 桌面订阅卡片只通过长按/右键编辑的既定交互未修改。

## 2026-08-20 v4.0.13 增量验收快照

- `v4.0.13` 已通过业务 PR `#133` 和发布准备 PR `#134` 合入，标签精确指向 `aa157395`；标签前 `main` CI、Windows 安装器构建/安装/卸载 smoke、正式 Release 与公开资产校验全部通过。
- Windows 11 候选 `558ed85` 已完成覆盖安装、原数据保留、系统代理与 TUN 真实数据路径、三次主动取消、连接中刷新/模式切换、托盘和正式版回滚；诊断复制假成功、连接态节点切换无效和未连接文案三项失败已在后续提交修复并进入正式版，但尚待使用 v4.0.13 正式安装器完成人工实机复验。
- Android 17 USB 真机使用源码重建的 `cmfa`/16 KiB 对齐 core 完成两轮连接/断开，系统 VPN `VALIDATED`，经本地 core 的请求返回 HTTP 204；断开后 7890/7891 关闭、应用进程保持存活。设备自身 page size 为 4 KiB，未冒充 16 KiB 硬件验收。
- 指定订阅的兼容响应历史上可解析 24 个节点；本轮最新候选复测时公共 DNS 返回 `127.0.0.1`，安全检查按设计拒绝访问，因此该订阅的最新实机节点数仍未确认。
- 按用户边界未执行 Wi-Fi 断网故障注入。自动化、正式资产和 Android 增量真机证据不替代尚未执行的 Windows 修复后人工实机验收或原生 16 KiB page-size Android 硬件验收。

## 2026-08-18 v4.0.12 增量验收快照

本表记录候选提交 `47bfbea` 对本轮修复项的实机证据；这些客户端修复已随正式标签 `v4.0.12`（`891a991`）发布。候选后的变更仅涉及版本/文档准备和 Windows CI 测试外层超时，不改变本表实测的客户端行为；未重复的完整矩阵仍不标记为通过：

| 平台 | 环境 | 本轮结果 | 证据边界 |
| --- | --- | --- | --- |
| Android | Redmi Note 8 / Android 11 / MIUI 12.5.5 | 4/4 正常连接与断开保持 PID，VPN、Service、TUN 和端口释放 | MIUI 通知栏不显示应用已提交的“断开”动作，用户仍可进 App 正常断开，按 P2 记录 |
| Android | Xiaomi `2509FPN0BC` / Android 17 | 4/4 正常断开、2/2 快速取消通过，无进程终止、崩溃、ANR 或资源残留 | 不替代其他 OEM 的长时、Doze 与完整压力矩阵 |
| macOS | Apple M 系列 / macOS 26.5.2 | arm64 Release 启动、TUN 数据路径、短时中断恢复、正常断开、网络恢复和退出通过 | 持续断网后的取消专项按用户要求停止，不标记通过 |
| Windows | Windows 11 / GitHub Actions 候选安装器 | 覆盖安装、用户数据保留、连接、真实代理访问、断开和资源恢复通过 | 未重复不受本轮 Windows 代码影响的长循环与完整压力矩阵 |

## 所有平台共同流程

| ID | 场景 | 通过标准 | 最低证据 |
| --- | --- | --- | --- |
| C-01 | 全新安装和首次启动 | 无崩溃、无空白页，首次引导可完成 | 屏幕录像或截图、系统日志 |
| C-02 | 导入、刷新和选择节点 | 成功结果明确；失败不破坏旧数据 | 脱敏诊断、前后状态 |
| C-03 | 连续 20 次连接/断开 | 无崩溃、卡死、残留连接或端口占用 | 每轮耗时、末轮诊断 |
| C-04 | 连接中取消及快速重复点击 | 最终状态与最后一次用户操作一致 | 录像、阶段日志 |
| C-05 | 弱网、断网、切网和恢复 | 有界失败或恢复，不长期假连接 | 网络时间线、诊断 |
| C-06 | 后台 30 分钟及休眠/唤醒 | 状态不漂移；断开后系统设置恢复 | 前后系统状态、日志 |
| C-07 | 异常结束后重开 | 只清理本应用拥有的核心、代理或 TUN | 进程与系统网络状态 |
| C-08 | 更新提示和取消 | 只在版本号旁提示；用户点击后才打开更新页 | 录像、版本信息 |
| C-09 | 200% 字体和键盘/读屏 | 关键按钮可达、有名称，弹窗可关闭 | TalkBack/VoiceOver/Narrator 记录 |
| C-10 | 诊断复制 | 报告有界、可操作且不含敏感值和本机用户名 | 脱敏后的完整报告 |

## Android

| ID | 场景 | 通过标准 |
| --- | --- | --- |
| A-01 | 首次 VPN 授权、拒绝后重试 | 拒绝不假连接，重试可恢复 |
| A-02 | 通知断开、快捷磁贴连接/断开 | Flutter、Service、TUN 和磁贴状态一致 |
| A-03 | 系统回收应用进程后恢复 | 不复用过期配置代际，不出现点连接即断开 |
| A-04 | 锁屏、Doze、Wi-Fi/蜂窝切换 | 数据通道和通知状态一致，失败可诊断 |
| A-05 | 其他 VPN 切入、撤销 VPN 权限 | 有界断开且不持续重启 Service |
| A-06 | 安装覆盖升级 | 订阅和设置保留，旧原生会话不污染新版 |

## macOS

| ID | 场景 | 通过标准 |
| --- | --- | --- |
| M-01 | 首次打开未公证 DMG | 免费分发提示准确，应用能按指南打开 |
| M-02 | 系统代理连接、断开和异常退出 | 只恢复本应用拥有的代理事务 |
| M-03 | TUN 授权同意、取消和失败 | 取消不假连接，失败不留下 root 核心或路由 |
| M-04 | Cmd+Q、Dock 重开、重复启动 | 单实例和退出令牌正确，状态可恢复 |
| M-05 | 休眠/唤醒和网络位置变化 | 无陈旧 PID/代际，系统 DNS/代理可恢复 |
| M-06 | 覆盖安装新 DMG | 数据保留且旧核心资产不会被错误复用 |

## Windows

| ID | 场景 | 通过标准 |
| --- | --- | --- |
| W-01 | 普通桌面会话首次安装、启动和卸载 | 安装阶段正确请求 UAC；默认每用户路径工作，卸载不删除用户数据 |
| W-02 | 覆盖升级安装器 | 单一快捷方式，订阅和设置保留 |
| W-03 | 系统代理连接、断开和强制结束 | guardian 仅恢复本应用拥有的代理状态 |
| W-04 | TUN 管理员同意、取消和失败 | 取消不假连接，路由和适配器有界清理 |
| W-05 | 重启后 RunOnce 恢复 | 损坏日志失败关闭且不触碰无关代理设置 |
| W-06 | 托盘连接、退出和资源管理器重启 | 托盘状态与主窗口一致，可重新初始化 |

## 性能、内存与电量

使用相同设备、构建模式、节点、网络和电源状态比较；预热一次后至少采样 10 次启动、连接和
断开。记录中位数与 P95，任何结果超过产品现有超时预算都失败；同设备历史中位数连续三轮
退化超过 25% 时进入调查，单次异常不直接包装成回归。

连续执行 C-03 时记录进程内存。第 5 轮作为预热基线，第 20 轮结束并空闲两分钟后，内存不得
持续单调增长；仍高于预热基线 20% 时必须用平台 profiler 排查后再决定是否放行。

空闲电量分别测量断开和连接两组，每组至少 30 分钟、熄屏、关闭额外下载并保持同一网络。
Android 使用 Batterystats/系统耗电页，macOS 使用系统能源记录，Windows 使用 `powercfg`
报告。先建立同机基线再比较；不得把不同设备或不同网络的百分比直接相减。出现异常唤醒、
持续高 CPU、连接空闲耗电连续三次显著偏离同机基线时，必须附 profiler 或系统报告。

## 发布判定

触达某平台连接、系统网络、存储、安装或更新路径的版本，该平台对应共同流程和平台流程不得
有失败项。未触达的平台可以引用最近一次相同主版本和相同高风险边界的证据，但必须记录引用
的版本、提交和差异；新正式版本至少重新执行 C-01、C-03、C-08 及该平台安装/升级条目。
