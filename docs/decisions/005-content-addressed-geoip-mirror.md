# ADR-005：使用 SSRVPN 自控的内容寻址 GeoIP 镜像

## 状态

已接受

## 日期

2026-07-19

## 背景

三端构建都需要同一份 `geoip.metadb`。上游 MetaCubeX 的 `latest` Release 会随每日发布
替换资产；GitHub API 为旧资产分配的唯一 ID 也会在替换后失效并返回 404。因此，把上游
Asset ID 记录为长期不可变下载地址并不成立：已有本地缓存时验证仍会通过，但全新 CI
runner、全新克隆和下一次发版会在 bootstrap 阶段失败。

构建需要一个由 SSRVPN 控制、可长期读取且仍能追溯到上游的信任边界，同时不能让每日
freshness 任务把未经校验的上游内容直接带入发布构建。

## 决策

1. 在 `Elegying/SSRVPN` 仓库保留专用支持 Release `core-assets-v1`，存放经过验证的
   deterministic gzip。它必须是已发布的 prerelease、不能是 draft，也不能抢占应用的
   `latest`；它不是应用版本 Release，也不进入面向用户的版本资产清单。支持 tag 与应用
   `v*` tag 由同一 active ruleset 禁止更新和删除，且没有人工绕过主体。
2. 每个 GeoIP 镜像使用 `geoip.metadb-<gzip-sha256>.gz` 命名。文件名由完整 gzip
   SHA-256 内容寻址；上传不得使用 `--clobber`。一旦某项被已合并的
   `docs/GEOIP_SOURCE.txt` 引用，就禁止替换或删除；误删时只能用完全相同的名称和字节恢复。
3. `GEOIP_SOURCE.txt` 同时记录两层证据：
   - 上游仓库、Release/Asset ID 与 URL、解压后原始文件 SHA-256；
   - SSRVPN 镜像仓库、固定支持 tag、内容寻址资产名、精确下载 URL 与 deterministic
     gzip SHA-256。
4. 普通 CI、正式 Release 和本地 `bootstrap-core-assets.sh` 不再读取上游 Asset URL。
   它们只接受精确的
   `https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/`
   路径，限制下载大小、协议和超时，并同时验证 gzip SHA-256 与有界解压后的原始 SHA-256。
   镜像回读只允许 `github.com`、`release-assets.githubusercontent.com` 和
   `objects.githubusercontent.com` 的 HTTPS 链路，拒绝降级到 HTTP 或跳转到其他主机。
5. `GeoIP Freshness` 是唯一主动读取上游 `latest` 的自动化边界。它按以下顺序执行：
   上游 checksum/API digest/实际内容校验 → deterministic gzip → 缺失时上传内容寻址镜像
   → 从公共镜像 URL 回读并验证双 SHA-256 → 创建只修改来源记录的 PR。旧来源记录中的
   upstream URL 即使已返回 404，也不得在这条自愈链路开始前被 bootstrap 访问。
   带 GitHub token 的 API 请求完全禁止重定向，避免 `Authorization` 被复制到另一个来源。
6. `core-assets-v1` 不存在、不可访问或不是已发布 prerelease 时，freshness 明确失败并
   提示修复支持 Release；已存在同名资产时只回读验证，不覆盖。回读失败或内容不符时不得
   创建更新 PR。若“列出资产”和“上传资产”之间发生同名竞态，上传不得 clobber；流程重新
   列出资产并以公共 URL 的 gzip/raw 双哈希回读为最终判断，匹配则复用，不匹配则失败。
7. 正式 Release workflow 与普通 CI 继续共享提交中已审核的镜像指针。定时检查失败不会
   破坏当前已锁定快照的构建；镜像本身缺失或损坏则安全失败，不能回退到上游 mutable
   `latest`。

## 信任边界

- MetaCubeX upstream 仅是 freshness 的候选数据源；checksum 文件、API digest（存在时）和
  实际下载内容必须一致。
- SSRVPN `core-assets-v1` 是构建可用性边界，不是完整性真源；完整性由仓库内审核过的两个
  SHA-256 固定。即使 Release 管理权限被误用，替换内容也会在 bootstrap 时被拒绝。
- freshness 的 GitHub token 可以创建分支、PR 和上传缺失镜像，但流程不授予覆盖既有资产
  的命令路径。代码审查和仓库权限仍需保护支持 Release 不被人工删除。
- `core-assets-v1` tag 已纳入仓库 release-tag ruleset；tag 更新和删除都会被拒绝。Release
  管理员仍可操作资产，因此内容寻址名称、双哈希和禁止 clobber 的流程约束仍不可省略。
- 普通 CI 和正式发版不需要信任当前上游状态，也不会因上游旧 Asset ID 被回收而改变输入。

## 结果

- 全新 runner 可以仅凭已提交来源记录重建三端 GeoIP 资产。
- 每日更新仍保留完整上游出处，且镜像存在并能从真实 bootstrap URL 回读后才进入代码审查。
- 支持 prerelease 成为必须长期保留的运维资源；仓库所有者需保护其 tag 和已引用资产，
  并确保它永远不成为应用 `latest`。
- GitHub Release 仍由仓库管理员控制，并非不可篡改账本；内容寻址名称和双哈希让错误替换
  可检测，但不能防止有权限的人删除资产。删除会造成明确的构建可用性故障，而不会静默使用
  其他内容。

## 未采用的方案

### 继续固定上游 API Asset ID

Asset ID 会随上游每日 Release 替换被删除，已经证明不能提供长期下载可用性，因此拒绝。

### 构建时跟随上游 `latest` 下载别名

输入会随时间变化，无法由提交和哈希记录复现，也会让上游临时变化直接进入正式发版，
因此拒绝。

### 把 gzip 或原始数据库提交到 Git/Git LFS

会重新扩大仓库或 LFS 下载契约，并让每次 GeoIP 更新进入 Git 历史。专用支持 Release 能在
保持来源记录可审查的同时避免提交大型生成资产。

### 使用另一家对象存储

可以提供不可变对象锁，但会增加凭据、费用、权限和故障域。当前 GitHub Release 加内容
寻址与双哈希已经满足个人项目的可用性和完整性要求；若未来需要对象锁，应由新 ADR 取代。

## 验证守卫

- `scripts/test_geoip_workflow.py` 模拟全新缓存且旧 upstream Asset URL 返回 404，确认
  bootstrap 只读取精确 SSRVPN 镜像；同时检查 workflow 顺序、URL allowlist、无 clobber
  上传和 gzip/raw 双哈希。
- `scripts/ensure-geoip-mirror.py` 在 PR 创建前检查支持 Release、已存在资产策略和公共 URL
  回读结果。
- `scripts/check-doc-consistency.sh` 把本 ADR 纳入当前文档一致性检查。

## 相关文档

- [核心资产来源](../CORE_ASSETS.md)
- [GeoIP 来源记录](../GEOIP_SOURCE.txt)
- [发布检查清单](../RELEASE_CHECKLIST.zh-CN.md)
