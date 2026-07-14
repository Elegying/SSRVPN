# SSRVPN 阿里云 OSS 发布运维

SSRVPN 的正式发布仍由 Git tag 触发。GitHub Actions 先构建并校验三端产物，
创建暂不公开的 GitHub Draft Release，再把同一批文件上传到阿里云 OSS 的
不可变版本目录。不可变文件验证完成后，工作流先备份并推广网站固定下载文件与
客户端 `latest.json`，再立即公开 GitHub Release。这样 GitHub 新版本不会先于
网站下载通道公开；客户端优先读取 OSS，只有 OSS 无有效更新时才回退 GitHub。

## 当前配置

GitHub 仓库的 Actions Variables：

- `ALIYUN_OSS_ENDPOINT=oss-cn-qingdao.aliyuncs.com`
- `ALIYUN_OSS_BUCKET=nikuaimobi`
- `ALIYUN_OSS_PREFIX=ssrvpn`

Actions Secrets 只保存 RAM 用户密钥，不能写入源码、文档、Issue 或日志：

- `ALIYUN_OSS_ACCESS_KEY_ID`
- `ALIYUN_OSS_ACCESS_KEY_SECRET`

OSS 对象结构：

```text
ssrvpn/
├── latest.json
├── ops/health.json
├── downloads/
│   ├── SSRVPN.apk(.sha256)
│   ├── SSRVPN.dmg(.sha256)
│   ├── SSRVPN_Setup.exe(.sha256)
│   └── SSRVPN.zip(.sha256)
└── releases/
    └── vX.Y.Z/
        ├── SSRVPN.apk(.sha256)
        ├── SSRVPN.dmg(.sha256)
        ├── SSRVPN_Setup.exe(.sha256)
        ├── SSRVPN.zip(.sha256)
        └── latest.json
```

`releases/vX.Y.Z/` 是不可变版本目录；`ssrvpn/latest.json` 是客户端读取的
唯一最新版本指针。工作流总是先上传并验证不可变产物，再以带备份的事务推广
固定下载文件和指针，最后把对应 GitHub Draft Release 转为正式版本。若 GitHub
明确仍是 draft 或 prerelease，工作流自动恢复 OSS；若 GitHub 状态无法确认，
不会盲目回滚，而是失败并保留 7 天恢复 Artifact 等待人工核实。同一 tag 重跑时
只接受字节完全相同的文件，禁止覆盖已存在但内容不同的版本对象。

`ssrvpn/downloads/` 是网站和人工分享使用的固定下载地址。每次正式发布都会
用已经校验过的同一批文件覆盖并重新下载比对，同时设置 `Cache-Control:
no-cache`。因此网站不需要随版本号修改链接。GitHub 备用地址使用
`https://github.com/Elegying/SSRVPN/releases/latest/download/<文件名>`。

## 正常发布

1. 修改并同步三端版本号和 `CHANGELOG.md`。
2. 运行 `make verify`，确认 `main` CI 全绿。
3. 创建并推送 `vX.Y.Z` tag。
4. 等待 GitHub Actions 的 `Release` workflow 全绿。
5. 运行 `scripts/check-release-assets.sh vX.Y.Z` 检查 GitHub 资产。
6. 检查 OSS 指针和所有下载 URL：

   ```bash
   curl -fsSL https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/latest.json
   ```

7. 抽查固定下载地址，例如：

   ```bash
   curl -fsSI https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/downloads/SSRVPN_Setup.exe
   ```

不需要手动进入 OSS 控制台上传版本文件。手工上传容易造成校验文件、清单和
实际产物不一致；正常版本只允许工作流写入。

## 发布前测试 OSS 权限

在 GitHub Actions 手动运行 `OSS Publish Smoke`。它只更新
`ssrvpn/ops/health.json`，不会修改版本和 `latest.json`。成功表示 RAM 密钥、
Bucket、Endpoint、公开读取和上传权限都可用。

## 密钥轮换

1. 在阿里云 RAM 为发布用户新建第二把 AccessKey。
2. 在 GitHub 仓库 Settings → Secrets and variables → Actions 中替换两项
   `ALIYUN_OSS_*` Secret。
3. 手动运行 `OSS Publish Smoke`，确认新密钥可用。
4. 再禁用并删除旧 AccessKey。

不要先删除旧密钥再测试新密钥。RAM 用户只需要写入
`nikuaimobi/ssrvpn/*` 的最小权限，不要使用阿里云主账号 AccessKey，也不要
授予其他 Bucket 权限。

## 故障和回滚

- Release workflow 在 OSS 步骤失败：不要手工改 `latest.json`；修复配置后
  重新运行失败任务。旧指针仍然有效，客户端会继续使用旧 OSS 版本或 GitHub
  备用源。若固定下载文件推广阶段恢复失败，工作流会失败并上传保留 7 天的
  `oss-public-channel-recovery-*` 备份 Artifact，按日志中对象清单恢复后再重跑。
- GitHub Release 最终状态无法读取：先在 GitHub 页面确认该 tag 是 draft、
  prerelease 还是正式版本，再决定是否使用恢复 Artifact；不得在状态不明时直接
  回滚，否则可能造成已公开 GitHub 版本再次指向旧 OSS 通道。
- 已发布版本确认有严重问题：先把 GitHub Release 标记为 prerelease，再在
  GitHub Actions 手动运行 `Roll back OSS public channel`，输入上一个稳定 tag。
  该工作流会先验证不可变版本目录，恢复网站使用的四个固定下载包及校验文件，
  全部下载比对成功后才恢复 `ssrvpn/latest.json`。随后尽快发布更高版本号的
  修复版；客户端不会自动降级已经安装的坏版本。
- 某个版本目录文件损坏：不要原地替换不可变文件。发布一个更高补丁版本，保留
  原目录用于审计。
- 怀疑 AccessKey 泄露：立即禁用该 Key，轮换 GitHub Secrets，检查 OSS 操作
  日志与 `latest.json`，再运行 smoke 和正式资产校验。

## 不要做的事

- 不要公开 AccessKey 或把它保存到本机项目文件。
- 不要删除仍被 `latest.json` 引用的版本目录。
- 不要只替换安装包而不同时更新 SHA256 和清单。
- 不要覆盖旧 tag 的文件来伪装成新版本。
- 不要在三端构建或校验失败时手工推进最新版本指针。
