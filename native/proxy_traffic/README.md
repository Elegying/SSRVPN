# 仅代理流量统计扩展

三端保持 `sources.json` 锁定的上游提交、Go 版本、架构及协议构建标签。
2026-09-06 的扩展增加首页及 Android 常驻通知的代理统计，不改变分流规则，也不改变 Mihomo
原有 `/traffic`、`/connections` 的全局计数。此目录的核心扩展按 GPL-3.0 分发。

实际出口连接在创建时记录出口类型。DIRECT、拒绝、兼容直连、Pass 和 DNS
出口排除；选择器后续追加的名称不改变分类，因此不依赖用户可修改的节点名称。
只累计应用转发层的 tracker，排除内部拨号 tracker，避免代理链重复计数。
TCP、UDP、缓冲区及快速拷贝沿用核心原有字节计数路径；计数是核心转发的
应用数据量，不包含链路/加密开销，也不等同于服务商计费流量。

认证后的 `GET /ssrvpn/traffic` 返回 `sessionGeneration`、`sampledAtMillis`、
`upload`、`download` 四个整数，不返回连接历史。短连接关闭、界面隐藏均不丢失
累计。Android 同进程重新连接时开启新会话，旧连接和迟到拨号继续写入旧会话。
桌面核心随 VPN 会话重启。首页断开时清零，重连后重新累计。

## 重建与校验

- `GO_BIN=<固定 Go>/bin/go scripts/build-desktop-core.sh macos <输出路径>`
- `GO_BIN=<固定 Go>/bin/go scripts/build-desktop-core.sh windows <输出路径>`
- `GO_BIN=<固定 Go>/bin/go ANDROID_SDK_ROOT=<SDK> scripts/build-android-core.sh <输出路径>`

脚本核对上游 commit/tree 后应用平台补丁和共享源码，并运行出口分类、TCP/UDP、
短连接、旧会话、并发计数及 API 认证测试。macOS 可另运行
`python3 scripts/check-core-proxy-traffic.py <核心路径>` 验证实际本机代理转发。
此测试仅使用 loopback，不修改系统代理、TUN 或真实订阅。

`scripts/core-traffic-source.py digest` 对固定来源记录、三份补丁及运行时代码计算
摘要；三端资产来源记录必须匹配此摘要，二进制本身另以 SHA-256 固定。
测试文件不影响运行时摘要。新核心镜像采用内容寻址文件名，不覆盖旧核心资产。
完整对应源码由锁定上游源码、此目录以及 Android 的 `native/bridge` 共同组成。

## 不发版的源码同步

缺少扩展核心时，`scripts/bootstrap-core-assets.sh` 从固定源码本地重建，校验结果
仍须匹配来源清单中的二进制 SHA-256。规范构建主机固定为 macOS arm64（CI 使用 macos-15）；Android 的 C 工具链
跨宿主重建目前不保证字节相同，其他宿主应使用对应 CI 的校验制品。Go 下载归档的长度和摘要另由
`toolchains.json` 固定；不得将不匹配的产物替换进项目。

Android 使用固定临时源码路径以及 `-s -w -buildid=` 链接参数，避免 gomobile 本地
模块替换路径、NDK 调试路径及构建标识造成无关机器差异。源码、JNI 导出和 ELF 对齐
验证不受调试段移除影响。

普通 CI 只生成 `core-assets` 工作流制品，不上传 Release 资产。来源清单中的
内容寻址镜像字段保留目标身份，不代表该地址已发布。Windows 开发者可从待验收
提交对应的成功 CI 下载该制品到仓库根目录，然后执行 `make assets` 校验，避免
在 Windows 主机上安装 Android/macOS 交叉编译工具链。普通源码同步不创建标签、不触发 Prepare Release、不更新 GitHub/OSS 安装包。
显式授权发布时，Prepare Release 在精确 main CI 通过后，优先复用该次 CI 的 `core-assets`；
Release 同样查找精确 main 的可信制品。两处均复核仓库、工作流、提交、事件、24 小时时效、
全部九项必需门禁，以及制品 ID、归档 SHA-256、六个文件的固定摘要，再执行原核心验证。
缺失或过期才回退规范 macOS 主机源码重建；API、身份或摘要异常直接失败。
普通 CI 继续从源码重建，不使用此复用入口。发布制品复用不替代三端应用构建和签名。
