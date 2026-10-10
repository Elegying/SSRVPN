# 客户端账号用量接口 v1

SSRVPN 是通用客户端。此扩展默认关闭，不改变链接、密码、导入记录、VPN 配置或原本机流量采样。Android、Windows、macOS 共用 `packages/ssrvpn_shared` 的实现。

## HTTP 与统计口径

```http
GET /api/v1/user/usage
Authorization: Bearer <现有节点原始认证密钥>
Accept: application/json
Cache-Control: no-cache, no-store
X-SSRVPN-Node-Host: node.example.test
X-SSRVPN-Node-Port: 443
```

只访问运维明确配置的 HTTPS origin，固定拼接以上路径。严格校验证书；不使用节点的 `insecure`、订阅中的接口地址或管理员凭据。禁止重定向，凭据不进入 URL、日志、持久缓存或错误文本。查询使用普通 OS 路由，受现有 TUN 环境影响，但不创建 VPN、不修改系统代理。桌面系统代理模式下，仅在现有核心运行时复用该核心已确认的本机 HTTP 代理端口，通过 HTTPS CONNECT 查询；TUN 模式、Android 和未连接时使用普通路由。不会猜测其他程序代理端口或为查询启动核心。

节点头取自已确认的服务绑定，只用于查询所选端点的维护状态，不改变账号统计范围。支持该扩展的面板在认证通过后，仅对明确处于维护流程的所选端点返回 `NODE_MAINTENANCE`；未知端点、域名池或其他节点故障不推断为本节点维护。旧面板忽略这两个头，继续原有统计响应。

200 成功响应（全部为合成示例）：

```json
{
  "apiVersion": 1,
  "data": {
    "scope": "account",
    "usedBytes": 0,
    "trafficLimitBytes": 268435456000,
    "onlineDevices": 0,
    "deviceLimit": 3
  },
  "meta": {
    "serverTime": 1788652800,
    "trafficObservedAt": 1788652795,
    "onlineObservedAt": 1788652798,
    "expiresAt": 1788652820,
    "complete": true
  }
}
```

- `usedBytes`：现有凭据所属账号在全部受管节点、全部客户端上的服务端合计用量，包含已结算历史用量。不能与本机「本次累计」相加；超过额度仍显示实际用量。
- `onlineDevices`：账号当前在线客户端实例数，不是硬件去重后的物理设备数。卡片以「在线数/上限」显示，例如 `1/3`、`2/3`、`0/3`。
- 客户端「已用流量」展示 `用量/额度 百分比`，例如 `125GB/250GB 50%`。用量和额度分别读取 `usedBytes`、`trafficLimitBytes`，按现有 1024 进位独立选择 B 至 EB 单位；卡片首行数值显示用量/额度，下方同一行显示「已用50% 每月1日重置」。该提醒为产品文案，不参与客户端清零；用量始终由面板响应确定。比例由原始字节数计算、不截断超额，保留至一位小数并去除尾随 `.0`；非零不足 0.1% 四舍五入保留两位小数（例如 0.01%、0.05%，极小值为 0.00%），不使用小于号；达到 10000% 使用两位有效数字的科学计数法。零额度显示 `—%`，不假定为无限额度；无障碍语义保留两个原始字节数。
- 四个计数字段必须为非负整数，支持有符号 64 位最大值。`0 B`、`0` 个在线及零额度均有效。浮点数、字符串、布尔值、缺失字段均拒绝。
- `apiVersion` 必须为整数 1，`scope` 必须为 `account`，`complete` 必须为布尔值 true，成功响应不能混入 `error`。
- 时间均为正整数 Unix 秒；两个观察时间不得晚于 `serverTime`；`expiresAt` 必须晚于 `serverTime`，且距任一观察时间不得超过 30 秒。
- 面板必须以所有参与统计来源的最早有效采集/确认时间加 30 秒确定过期，不以收到客户端请求的时间给旧统计续期。任何来源缺失、未确认、过期都不能返回完整成功。
- 客户端有效期为 `expiresAt - serverTime - 本次请求耗时`，使用 Stopwatch 单调时钟和单独的到期计时器，不比较手机墙钟。不接受 `Age` 大于零或异常的缓存响应；同身份再次收到不递增的 `serverTime` 也按失败处理。
- 后台/离开首页暂停查询，保留同账号尚未过期的完整成功快照；恢复时检查原有效期并继续有界刷新。有效期仍由单调时间管理，暂停期间的墙钟耗时只用于保守扣除休眠时间，不得延长缓存有效期；墙钟倒退时丢弃快照。失败或过期后保留同一身份的上次成功数据，标明更新时间与暂未更新；历史数据不能作为当前设备限制等状态的证据。不同身份独立保存；同身份列表重建保留快照及原有效期、重试预算，凭据变化不复用旧快照。

失败结构：

```json
{"apiVersion":1,"error":{"code":"STATS_INCOMPLETE"}}
```

稳定代码包括 `INVALID_CREDENTIALS`、`STATS_UNAVAILABLE`、`STATS_INCOMPLETE`、`STATS_STALE`。HTTP 非 200、解析异常、不完整、超时、断网、限流、认证失败均将当前结果标为不可用；已有同身份快照时保留并标记时间，没有快照时保留占位；悬停或长按可查看简明原因，诊断日志只记录脱敏的失败类型变化和恢复，不记录 URL、凭据或异常原文。401 也采用有界退避；凭据变化后重新校验，同身份的列表更新继续遵守原有退避。429 遵守 `Retry-After`（秒；也接受带响应 Date 的 HTTP 日期形式）。HTTP 200 的错误对象不会被当成功。客户端也可识别明确返回的 `DEVICE_LIMIT_REACHED`、`NODE_MAINTENANCE`，分别给出下一步操作；面板源码已接入所选端点的明确维护状态；设备上限也可由新鲜完整统计判定。账号到期提示取自订阅信息，缺少有效期时不推断。生产状态取决于服务端是否部署相应版本。不能仅凭 HTTP 状态、普通超时或旧设备数推断具体原因。

本契约已对照 Hysteria2-panel 开发源码的 `/api/v1/user/usage`、`Database.user_usage`、`_handle_user_usage` 和同名文档核对字段及 30 秒新鲜度规则。面板文档关于错误卡片的旧 UI 建议不适用于 SSRVPN：客户端保留同身份历史快照，并明确标注新鲜度。生产是否部署是另一项验证，不由源码存在推断。

## 可信提供方配置与旧链接兼容

构建配置 `SSRVPN_USAGE_PROVIDERS` 是 JSON **字符串**，没有配置或任何配置校验失败时整份关闭。一个节点端点不得归属两个提供方；使用精确服务器地址、端口、协议匹配，域名不通过 DNS 自动扩展为其他受信端点。界面标签不证明服务归属。

```json
{
  "SSRVPN_USAGE_PROVIDERS": "[{\"id\":\"example-panel\",\"origin\":\"https://usage.example.test:19998\",\"nodes\":[{\"id\":\"node-a\",\"server\":\"a.example.test\",\"port\":19999,\"protocol\":\"hysteria2\"}]}]"
}
```

提供方/节点 id 允许字母、数字、`_`、`.`、`-`，最长 64；最多 32 个提供方、每个最多 1024 个绑定。origin 不允许用户名、查询参数、fragment 或额外路径。当前适配 Hysteria2（解析结果 `hysteria2` 或 `hy2`）；其他协议安全隐藏。认证密钥直接来自现有解析结果 `extra.password`，不 trim、不轮换、不要求重新导入；无法作为合法 Bearer 头发送的值安全隐藏。

[公开构建默认配置](../config/ssrvpn-usage-defines.json) 不含运营接入地址。正式构建由受保护的仓库设置生成本机忽略文件 `config/ssrvpn-private-defines.json`，不得提交或记录其内容。

从各平台目录构建时注入同一文件：

```bash
# SSRVPN_Android
flutter build apk --debug --dart-define-from-file=../config/ssrvpn-private-defines.json
# SSRVPN_MacOS
flutter build macos --debug --dart-define-from-file=../config/ssrvpn-private-defines.json
# Windows 主机的 SSRVPN_Windows
flutter build windows --debug --dart-define-from-file=../config/ssrvpn-private-defines.json
```

官方 Release workflow 三端显式注入私有配置并验证编译绑定；桌面打包脚本接受可选配置文件参数。普通通用构建不加此参数，保留默认关闭。配置文件没有账号密码，也不会修改订阅、代理配置或触发发布。

## 展示、身份和生命周期

首页先用原有 `HomeNodeController` 求得实际展示节点：连接时已确认运行节点，未连接时当前选中/默认节点。只展示当前节点已经确认归属的账号数据。

无可用归属时保留基础统计；首次加载时显示占位。正常刷新保留同身份成功结果，失败或过期后明确标注为历史数据，不能继续当作当前状态。断开本机连接不把账号用量或其他设备在线数归零。

账号控制器与本机采样器独立。身份以提供方、归属 id、HTTPS endpoint、节点服务器/端口、原凭据的 SHA-256 隔离，仅存在内存。订阅列表修订废弃在途请求，但不清除身份未变的快照，不重置其有效期或重试预算。请求代次丢弃旧节点、旧密码、已删除节点及后台的迟到结果。

每个首页控制器至多一个在途请求，总超时 8 秒，响应体上限 32 KiB。正常 10 秒刷新；失败退避 15/30/60/120/240 秒，若 Retry-After 更长则遵守更长等待。节点变更无需等待请求即可隐藏；旧请求结算或超时后才发新请求，不产生重叠轮询。

## 布局与复现验证

首页移除整体 `SingleChildScrollView`，外层启动提示也改为自然高度，不预留空余提示空间。连接按钮与状态标签共用中心线，常规竖向布局保持页面居中；不足以纵向容纳时采用成组的横向布局。统计区与底部导航栏同宽（最大 380 逻辑像素）并居中。根据可用宽高与实际字体测量重排连接区和统计卡；宽高允许时保留三列或三加二，矮而宽的空间可五列。卡片使用预留最大格式的文字度量防止数值变化跳动；调整真实字号与行高，卡片高度自然变化，不使用整体缩放或固定大文字槽。

本地流量延续原有二进制单位显示；账号流量沿用同一格式。超长设备计数以十进制 K/M/G/T/P/E 显示，并用「约值 · 实例」注明近似值，无障碍语义同时给出对应精确实例数及上限。

```bash
cd packages/ssrvpn_shared
flutter test test/account_usage_test.dart test/account_usage_https_test.dart
flutter test test/account_usage_layout_test.dart test/home_traffic_panel_test.dart
```

HTTPS 测试启动本地真实 TLS 模拟服务，临时生成证书并显式只在测试客户端信任它；验证默认客户端仍拒绝该自签证书、重定向不转发凭据、非 200、过期、缺字段、超时、重试及恢复。需要本机 `openssl`。

布局测试覆盖安全区、桌面最小窗口扣除原有标题栏、320/360/390 手机宽、横屏、连续宽度、字号 1/1.5/2、超大计数、长名称和错误提示，断言边界、卡片文字、点击区域、无 Scrollable、拖动无位移及三五切换后尺寸恢复。

可通过 `SSRVPN_LAYOUT_OUTPUT` 输出 PNG 和 `measurements.json`；`SSRVPN_LAYOUT_FONT` 指向本机合法使用的中文字体、`SSRVPN_LAYOUT_ICONS` 指向 Flutter 缓存的 MaterialIcons 字体，仅用于测试渲染，不打包系统字体。共享渲染测试不是三端实际运行验证，平台构建和运行状态见 [验证记录](ACCOUNT_USAGE_VALIDATION.md)。

## 当前线上验证与边界

2026-09-06 初次无凭据检查返回 404；维护者部署接口并授权测试账号后，重新执行真实 HTTPS 查询，返回 200。原有订阅解析器与可信提供方解析通过，认证密钥保持原样；生产 `AccountUsage.parse` 及 `AccountUsageClient.fetch` 共三轮校验成功，两轮刷新间隔 15 秒，服务时间和观察时间持续递增，扣除请求耗时后的有效期均为正。证书使用默认严格校验，没有沿用节点 `insecure` 参数，也没有跟随重定向。

凭据仅通过关闭回显的标准输入进入测试进程内存，未写入源码、产物或报告。账号数值仅保留在本地私有验收材料，不提交公共仓库。此次验证覆盖本机直连 HTTPS 与三端共用的生产解析/查询实现，不代表已完成三端原生应用、系统代理/TUN、连接/断开对在线数的影响或面板账本独立对账。本任务未部署面板、创建账号或发布客户端。

## 三端原生隔离复现

`mise x flutter@3.44.1 -- python3 scripts/prepare-usage-native-smoke.py` 创建临时、独立包名 `test.ssrvpn.usageSmoke` 的 Flutter 原生宿主，复制当前共享验证入口和依赖锁，生成一天有效的临时 TLS 测试证书。密钥只存在临时目录，不提交、不用于生产。需要 Flutter 3.44.1、openssl 和相应原生 SDK。

在脚本输出的目录分别执行 `flutter run -d macos`、`flutter run -d windows` 或 `flutter run -d <Android设备ID>`，均追加 `--dart-define-from-file=test-defines.json`，不要并发构建同一个宿主目录。宿主用真实本地 HTTPS 服务和生产查询客户端运行八个步骤，输出 `USAGE_NATIVE_PASS` 后退出，并在输出的临时目录保存关键显示状态截图及全部八步 JSON。它不加载生产客户端的设置、代理服务或账号。

这是共享组件在对应原生引擎中的实际运行证据，仍不等于三端完整 VPN、系统代理/TUN 或生产账号验收。完整平台应用另需构建及原有平台集成/原生测试；Windows 必须在 Windows 环境执行，不能以 macOS 结果代替。

跨仓库本地 TLS 契约回归可在共享包目录运行 `SSRVPN_PANEL_SOURCE=/path/to/Hysteria2-panel flutter test test/account_usage_panel_contract_test.dart`。测试创建临时证书与合成账号，不读取运营配置或启动 VPN；未指定面板源码时跳过该专项。
