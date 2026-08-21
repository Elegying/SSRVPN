# ADR-012：自动准备可复现的正式版本

## 状态

已接受；取代 ADR-011 中“维护者必须手动刷新、合并并创建 tag”的发版编排，不改变其
取消日程刷新、内容寻址镜像、双哈希、只读最新性门禁和精确 Release 重试边界

## 日期

2026-08-03

## 背景

ADR-011 把 GeoIP 更新收敛到正式发版前，消除了每日 PR 噪声，但要求维护者依次运行
Maintenance、合并来源记录、等待 CI、创建 tag 和观察 Release。步骤本身可验证，却容易因
顺序遗漏而让 Release 在已创建 tag 后才报告 GeoIP 过期。

不能简单让 `release.yml` 在 tag 已存在后下载并打包上游 `latest`：同一 tag 在不同日期重跑
可能得到不同字节，提交中的 `GEOIP_SOURCE.txt` 也无法重建安装包。自动化必须发生在 tag
创建前，并让最终 tag 指向包含精确来源记录、已经完整验证的 `main` 提交。

仓库 `main` 启用了严格必需检查、PR、线性历史和禁止管理员绕过；`GITHUB_TOKEN` 的普通
push 不会递归启动新 workflow，但 GitHub 明确允许它创建 `workflow_dispatch`。因此发版准备
可以显式调度已有 CI，而不削弱分支保护或引入长期 PAT。

## 决策

1. 新增仅手动触发的 `Prepare Release` workflow。输入必须是与当前应用版本一致、远端尚不
   存在 tag 或 Release 的 `vX.Y.Z`；同一时间只允许一个准备流程。
2. 工作流从精确 `origin/main` 开始，先执行版本同步和版本转换校验，再运行现有 GeoIP
   同步、内容寻址镜像上传与公共回读验证。任何 API、摘要、重定向、镜像或工作树状态不明确
   都失败关闭。
3. GeoIP 有变化时，只提交 `docs/GEOIP_SOURCE.txt` 到本次运行专属临时分支。编排先通过
   `workflow_dispatch` 在该提交上运行现有九项必需 CI；全绿且 `main` 未前移后才创建 PR，
   并按受保护分支规则 rebase 合并。分支 CI 失败且 PR 尚未创建时，精确删除本次临时分支；
   已创建 PR 的失败状态保留供诊断。
4. 合并后必须确认远端 `main` 等于 GitHub 报告的合并提交，且 Git tree 与已验证分支完全
   一致。无论 GeoIP 是否变化，都在精确最终 `main` 上再次显式调度完整 CI；CI 结束后
   再次以只读方式确认 GeoIP 仍是上游 `latest`，并在 tag 创建前最后复核 `main`；GeoIP
   滚动或 `main` 前移都会中止流程。
5. 只有精确 `main` CI 成功且再次确认同名 tag/Release 不存在，才创建 annotated tag 并推送。
   因 `GITHUB_TOKEN` push 不递归触发工作流，编排使用 GitHub 当前 REST API 的
   `workflow_dispatch` 响应取得精确 run ID 和 URL，显式启动 tag 上的 `release.yml` 并等待
   结果。tag 推送是不可逆边界；若此后的调度、等待或 Release 失败，保留原 tag，并对该精确
   tag 手动重试 `Release`，不得删除或移动 tag。Release 环境原有人工批准、三端构建、OSS
   回滚和发布后验证保持不变。
6. `release.yml` 继续保留只读 GeoIP 最新性门禁。手工 tag、竞态期间的上游滚动或绕过
   `Prepare Release` 的旧流程仍会在平台构建前失败；精确已有 Release 重试继续使用
   ADR-011 定义的不可变身份校验。
7. `Maintenance > geoip-refresh` 保留为手动恢复入口，不再是正常发版的必需步骤，也不获得
   schedule 触发器。
8. `.github/main-branch-protection.json` 是 `main` 保护策略和九项必需检查的版本化真源。
   `Prepare Release` 在任何可变资产操作前以及创建 tag 前分别回读 GitHub API 并精确比较；
   保护不存在、检查集合漂移、检查应用身份变化或管理员可绕过时一律停止。

## 结果

- 正常发版只需在版本和 changelog 已合入 `main` 后运行一次 `Prepare Release`。
- GeoIP 更新仍有独立提交、PR、双哈希和不可变镜像，tag 不包含运行时生成的隐式输入。
- 分支 CI 与最终 `main` CI 都必须成功；任何创建 tag 前发现的竞态、已有 tag/Release 或外部
  状态歧义都会停在新 tag 创建前。tag 推送后的故障保留不可变 tag，转入精确 Release 重试。
- 自动准备会增加一次 CI；GeoIP 发生变化时会运行两次 CI。这是保护精确合并提交和分支规则
  的有意成本，不以减少验证换取速度。
- Release 启动后仍可能等待 `release` environment 批准；该批准保护正式发布凭据，不由准备
  workflow 绕过。

## 未采用的方案

### 在 Release 构建中直接下载 latest

同一 tag 会随时间改变构建输入，破坏来源记录和重跑可复现性。

### 由工作流直接推送 main

会绕过当前严格 PR、必需检查和线性历史规则；即使只修改来源记录也不接受。

### 使用长期 PAT 自动触发 PR CI

仓库已有 `workflow_dispatch`，可使用最小权限的短期 `GITHUB_TOKEN` 显式调度精确 ref；新增
长期秘密会扩大泄漏和轮换负担。

### 在 CI 前创建 tag，失败后删除

受保护的 `v*` tag 不允许改写或删除；先创建再回滚不符合不可变发布入口。

## 验证守卫

- `scripts/test_prepare_release_workflow.py` 以伪 GitHub API 和伪 Git 远端验证有变化、无变化、
  分支/最终 CI 失败和 tag 后调度失败，并检查 PR、双 CI、tag、Release 调度与不可逆边界。
- `scripts/test_geoip_workflow.py` 继续覆盖上游身份、确定性 gzip、镜像回读、重定向和竞态。
- `scripts/test_verify_release_transition.py` 继续禁止 `release.yml` 动态改写 GeoIP，并保护 tag、
  provenance、OSS 和精确 Release 重试边界。
- `actionlint`、ShellCheck 和 `scripts/test-release-tooling.sh` 是合并前最低门禁。

## 官方依据

- [GitHub：从工作流触发工作流](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [GitHub：Create a workflow dispatch event](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [GitHub：受保护分支](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)

## 相关文档

- [ADR-005：使用 SSRVPN 自控的内容寻址 GeoIP 镜像](005-content-addressed-geoip-mirror.md)
- [ADR-011：只在正式发版前刷新并强制验证 GeoIP](011-release-gated-geoip-refresh.md)
- [核心资产来源](../CORE_ASSETS.md)
- [发布检查清单](../RELEASE_CHECKLIST.zh-CN.md)
