# SSRVPN 阿里云 OSS 发布运维

SSRVPN 的正式发布仍由 Git tag 触发。GitHub Actions 先构建并校验三端产物，
随后发布 GitHub Release，再把同一批文件上传到阿里云 OSS。客户端优先读取
OSS，只有 OSS 无有效更新时才回退 GitHub。

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
└── releases/
    └── vX.Y.Z/
        ├── SSRVPN.apk(.sha256)
        ├── SSRVPN.dmg(.sha256)
        ├── SSRVPN_Setup.exe(.sha256)
        ├── SSRVPN.zip(.sha256)
        └── latest.json
```

`releases/vX.Y.Z/` 是不可变版本目录；`ssrvpn/latest.json` 是客户端读取的
唯一最新版本指针。工作流总是先上传并验证所有产物，最后才替换这个指针，
避免客户端看到半套发布文件。

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
  备用源。
- 已发布版本确认有严重问题：把 GitHub Release 标记为 prerelease，并将上一
  个稳定版本目录里的 `latest.json` 复制回 `ssrvpn/latest.json`。随后尽快发布
  更高版本号的修复版；客户端不会自动降级已经安装的坏版本。
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
