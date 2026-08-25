# ADR-014：GeoIP 仅按明确指令手动更新

## 状态

已接受；取代 ADR-011 的发版前强制最新和 ADR-012 的自动 GeoIP 发版准备

## 日期

2026-08-26

## 决策

1. GeoIP 不设定时任务，也不由普通 CI、`Prepare Release` 或 `Release` 检查上游更新。
2. 发版不要求仓库固定的 GeoIP 是上游最新版，不因版本较旧而失败，也不自动修改
   `docs/GEOIP_SOURCE.txt`、上传镜像、创建或合并 GeoIP PR。
3. `Maintenance > geoip-refresh` 是唯一更新入口，只在维护者收到明确更新指令后手动运行；
   更新仍须经过上游来源校验、确定性 gzip、内容寻址镜像回读、独立 PR 和受保护 CI。
4. 普通 CI 和发版继续从提交内来源记录引导同一份三端 GeoIP，并严格验证镜像地址、压缩与
   解压 SHA-256、文件一致性和核心资产完整性。固定资源缺失或损坏仍须失败关闭。
5. 更新触发策略与资产完整性是两个边界：取消新旧检查不能削弱可复现构建、不可变 tag、
   Release 资产身份、provenance 或 OSS 发布事务。

## 结果

- 发版不再产生额外 GeoIP PR 和一轮平台 CI，也不受上游滚动或临时不可用影响。
- 已固定并审核的快照可以继续发布，直到维护者明确要求更新。
- 手动更新能力保留，但不会被发布入口、日程或其他自动任务隐式触发。

## 验证守卫

- `scripts/test_prepare_release_workflow.py` 禁止发布准备脚本调用 GeoIP 同步、镜像上传或 PR 命令。
- `scripts/test_geoip_workflow.py` 保证手动维护入口仍无 schedule，并验证 Release 只使用固定资产。
- `scripts/test_verify_release_transition.py` 禁止 `release.yml` 调用 GeoIP 同步脚本。
- `scripts/verify-core-assets.sh` 继续验证三端固定资源和来源摘要。

## 相关文档

- [内容寻址 GeoIP 镜像](005-content-addressed-geoip-mirror.md)
- [自动发布准备的其余边界](012-automatic-release-preparation.md)
- [核心资产来源](../CORE_ASSETS.md)
- [发布检查清单](../RELEASE_CHECKLIST.zh-CN.md)
