# ADR-013：客户端连接后仅使用 GitHub Releases 更新

## 状态

已接受；自 v4.0.14 起生效，不改变 ADR-012 的构建、正式发布和 OSS 同步事务

## 日期

2026-08-20

## 背景

此前三端客户端在启动阶段优先读取阿里云 OSS `latest.json`，异常时回退 GitHub Releases。
这让应用内更新和网站镜像共享同一入口，也会在用户尚未连接节点时产生更新网络请求。
产品现在要求把正式版本发现、安装包和摘要统一到 GitHub Releases，并把检查推迟到用户
已经成功连接节点之后。

OSS 仍承担网站固定下载、人工分享、不可变版本归档和发布事务回滚。改变客户端来源不应
重写已经验证的三端构建、Draft Release、OSS 推广、GitHub 公开和发布后终验顺序。

## 决策

1. Android、Windows 与 macOS 的应用内更新只读取
   `https://api.github.com/repos/Elegying/SSRVPN/releases/latest`。
2. 客户端只接受正式 Release 中与平台精确对应的 `SSRVPN.apk`、`SSRVPN.dmg` 或
   `SSRVPN_Setup.exe`，下载 URL 必须属于 `Elegying/SSRVPN` 的同版本 tag 目录，并要求匹配的
   `.sha256` 资产。
3. GitHub 元数据、资产或摘要不可用时，本次检查失败关闭；不得请求 OSS `latest.json`、
   OSS 版本目录或固定下载别名作为备用更新源。
4. 更新检查只能在节点连接成功或启动恢复已确认核心仍处于连接态后调度。未确认连接的应用
   启动、首页初始化和后台状态恢复不得发起检查；检查结果返回前若已断开，不展示更新入口，
   下一次连接可重新检查。
5. 发现新版后仍只在底部版本号旁展示“发现新版本 立即更新”，用户点击后才打开更新页。
6. Release workflow 的三端构建、GitHub Release 和 OSS 同步链路保持不变。同一批已校验资产
   仍同步到 OSS 不可变目录、网站固定下载地址和 `latest.json`，但这些对象不再供客户端读取。

## 结果

- 应用内更新具有单一、可审计的正式版本来源，元数据、二进制和摘要来自同一 GitHub Release。
- 未连接启动不产生更新请求；连接成功后才使用当前节点网络检查。
- OSS 故障不会让客户端切换到旧镜像或混用来源，但正式发版仍会因 OSS 同步失败而失败关闭，
  保持网站镜像和 GitHub 正式资产一致。

## 未采用的方案

### 保留 OSS 作为静默备用源

这会继续让客户端拥有两个权威来源，并可能在 GitHub 故障时下载与正式 Release 状态不同的
镜像，因此不采用。

### 启动时检查，连接后只重试

这仍会在用户尚未选择或连接节点时产生网络请求，不符合新的产品时机边界。

### 删除 OSS 发布步骤

OSS 仍服务网站和人工分发，且现有发布事务已经覆盖不可变路径、摘要回读和失败回滚；本决策
只改变客户端，不改变构建与发布链路。

## 验证守卫

- 共享更新检查测试必须断言请求主机只有 GitHub API 和规范 GitHub Release 资产，不出现 OSS。
- Android 启动编排测试必须证明启动阶段没有更新步骤；三端连接逻辑必须在连接态校验后才调度。
- 正式 Release 继续通过现有发布工具测试、GitHub 资产检查和 OSS `latest.json`/固定下载摘要
  回读验证。

## 相关文档

- [产品需求](../PRODUCT_REQUIREMENTS.zh-CN.md)
- [发布检查清单](../RELEASE_CHECKLIST.zh-CN.md)
- [OSS 发布运维](../OSS_RELEASE_OPERATIONS.zh-CN.md)
- [ADR-012：自动准备可复现的正式版本](012-automatic-release-preparation.md)
