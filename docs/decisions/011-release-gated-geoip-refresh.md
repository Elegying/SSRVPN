# ADR-011：只在正式发版前刷新并强制验证 GeoIP

## 状态

已由 [ADR-012](012-automatic-release-preparation.md) 取代其中的人工发版编排；取消每日刷新、内容寻址镜像、双哈希和 Release 只读门禁继续有效

## 日期

2026-08-02

## 背景

上游 MetaCubeX 会频繁替换 `latest` GeoIP 资产。每日自动检查会为每次上游变化创建新的
来源记录 PR，但已安装客户端只有随正式版本获得新数据库，非发版期间持续合并这些 PR
不会立即改善用户行为，反而增加审查通知、分支和 CI 噪声。

正式发布仍必须携带当时最新、可追溯且三端一致的 `geoip.metadb`。这个要求不能通过在
Release 构建阶段直接写入上游 `latest` 实现，因为应用 tag、提交、来源记录和构建输入必须
保持一致且可复现。

## 决策

1. `Maintenance` 不再包含 GeoIP `schedule` 触发器。`geoip-refresh` 只允许维护者通过
   `workflow_dispatch` 手动运行。
2. 创建应用版本 tag 前，维护者必须手动运行 `Maintenance > geoip-refresh`，审查并合并它
   创建的 `GEOIP_SOURCE.txt` PR，再等待合并后的 `main` CI 通过。
3. 新 Release 在三端构建前先从提交中固定的内容寻址镜像引导并验证 GeoIP，再运行
   `sync-geoip-metadb.py --check`。该命令只读比较上游 `latest`、来源记录和三端资产；任何
   不一致或上游不可确认状态都失败关闭。校验完成前会再次读取上游 Release 与资产身份；
   若期间 `latest` 滚动，即使第一次下载内容匹配也必须失败并重新验证稳定快照。
4. Release workflow 不运行 GeoIP 写入模式、不上传新镜像、不创建 PR，也不改写已经推送的
   tag。最新性门禁失败时，必须重新完成手动刷新和审核流程后再创建新的发布提交与 tag。
5. 只有已经存在完整 Release 资产、且 tag、commit、Release/asset ID、上传完成状态、
   provenance 和资产摘要全部通过校验的恢复重试，才可以继续使用原 tag 固定的 GeoIP，
   避免第二天的上游变化破坏不可变发布的故障恢复。授权脚本在 tag API 看不到 draft 时会
   只读分页查找精确 tag，并按资产 ID 下载 provenance；未找到返回专用状态，重复、网络
   故障、空或不完整 draft 均失败关闭，不能绕过最新性门禁。授权阶段还会把 Release ID
   与由 tag、全部资产 ID、状态、大小和摘要计算的规范化身份哈希传给发布 job；draft 到
   public 是唯一允许的状态迁移，不改变该不可变身份。发布 job 必须重新验证并复用同一身份。
   获授权的 Release 若在构建期间消失、变残或被替换，
   工作流立即失败，禁止删除旧 draft 或退化为新建 Release。最终公开使用 numeric Release
   ID 执行 PATCH，公开状态轮询与发布后终验也绑定同一 ID 和资产身份，不再按 tag 接受替代对象。
   OSS 推广后、PATCH 前会再次验证身份；公开轮询成功后、删除 OSS 恢复备份前还会验证一次。
   前者失败会恢复 OSS，后者失败会保留恢复备份并终止，避免资产变更被公开链静默接受。
6. Android、macOS 和 Windows 构建继续只消费同一个 `prepare-geoip` 产物，因此三端携带的
   GeoIP 字节与 `GEOIP_SOURCE.txt` 的双 SHA-256 保持一致。

## 结果

- 非发版期间不会再产生每日 GeoIP PR 或代码所有者审查通知。
- 正式发版多一个明确的人工准备步骤；遗漏时 Release 会在平台构建前失败，不会发布旧数据。
- 上游不可用时不能开始新的正式发布，但已验证发布的恢复路径不受后续上游滚动更新影响。
- 构建输入仍由应用 tag 内审核过的来源记录决定；对上游 `latest` 的访问只用于新发布的
  fail-closed 最新性证明，不会让可变输入直接进入安装包。

## 未采用的方案

### 每日自动创建 GeoIP PR

数据在非发版期间不会进入已安装客户端，持续 PR 的运维噪声高于收益，因此取消。

### Release 阶段直接下载并打包上游 latest

它会让同一 tag 在不同时间产生不同字节，并绕过来源记录审查，违反可复现发布要求。

### 只依赖人工清单，不设置发布门禁

人工步骤容易遗漏，无法满足“每个正式版本必须携带最新 GeoIP”的强制要求。

## 验证守卫

- `scripts/test_geoip_workflow.py` 检查 `Maintenance` 无 `schedule`、手动刷新仍使用完整镜像校验
  链，并验证新 Release 在上传共享核心资产前执行只读最新性门禁，同时拒绝校验期间滚动的
  上游 `latest`。
- `scripts/test_verify_release_transition.py` 禁止 Release 运行 GeoIP 写入模式。
- `scripts/authorize-existing-release-retry.py` 与
  `scripts/validate-existing-release-retry.py` 限制只有精确 tag、完整已上传资产且 provenance
  一致的 Release 才能进入恢复重试路径；测试覆盖公开 Release、隐藏 draft、重复 tag、网络
  故障与未完成资产。`scripts/reuse-github-release-assets.sh` 再次要求跨 job 的 Release ID 与
  规范化资产身份完全相同，并测试消失、替换和不完整状态均不得删除或新建。

## 相关文档

- [ADR-005：使用 SSRVPN 自控的内容寻址 GeoIP 镜像](005-content-addressed-geoip-mirror.md)
- [ADR-012：自动准备可复现的正式版本](012-automatic-release-preparation.md)
- [核心资产来源](../CORE_ASSETS.md)
- [发布检查清单](../RELEASE_CHECKLIST.zh-CN.md)
