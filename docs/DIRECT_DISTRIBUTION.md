# 已停用：Direct 发行签名与公证

> 产品决定：RepoPress for macOS 只维护一个 Mac App Store 全功能版本。本文件保留旧脚本的历史说明，不再是正式发布路径，不应生成或对外提供第二个应用版本。

本流程用于把 macOS 应用直接提供给用户下载，不用于 Mac App Store。正式产物必须同时满足：

- 使用有效的 `Developer ID Application` 证书签名；
- 应用与 Native Messaging 宿主使用相同开发团队，并启用 Hardened Runtime 和安全时间戳；
- 使用 `Packaging/DirectDistribution.entitlements`，不得启用 `get-task-allow`；
- 内置与当前扩展版本匹配、经过 Mozilla 签名并已验证的 Firefox XPI；
- Apple 公证状态为 `Accepted`，票据已装订到应用，并通过 Gatekeeper 检查。

当前 App Store 版本已经包含用户自备 AI 和浏览器商店扩展连接；完整边界见 `docs/app-store/FEATURE_BOUNDARY.md`。除非以后做出新的产品决策，否则不要执行下述旧 Direct 发行流程。

## 一次性准备

1. 在“钥匙串访问”中安装有效的 Developer ID Application 证书及其私钥。
2. 按 `BrowserExtension/README.md` 的步骤生成并验证当前版本的 Mozilla 签名 XPI。
3. 把 Apple 公证凭据存入登录钥匙串。命令会交互式请求 Apple ID、团队 ID 和 App 专用密码，密码不会写入仓库：

   ```bash
   xcrun notarytool store-credentials "PersonalSitePublisher-notary" \
     --apple-id "你的 Apple ID" \
     --team-id "你的 Team ID"
   ```

4. 在当前终端指定证书和钥匙串配置名称：

   ```bash
   export DIRECT_CODE_SIGN_IDENTITY='Developer ID Application: 你的名称 (TEAMID)'
   export NOTARYTOOL_KEYCHAIN_PROFILE='PersonalSitePublisher-notary'
   ```

也可以把证书 SHA-1 指纹赋给 `DIRECT_CODE_SIGN_IDENTITY`。不要把 Apple ID、App 专用密码或 API 私钥写入脚本、提交到 Git，或放进发行 ZIP。

## 发布操作

先做无构建、无提交的就绪检查：

```bash
python3 script/package_direct_release.py --check-readiness
```

只构建、签名并生成待公证 ZIP，不向 Apple 提交：

```bash
python3 script/package_direct_release.py --prepare-only
```

正式提交并等待结果；只有 Apple 返回 `Accepted` 后，脚本才会装订票据、执行 Gatekeeper 检查并生成最终 ZIP：

```bash
python3 script/package_direct_release.py --notarize
```

默认输出目录为 `dist/direct-release/`：

- `PersonalSitePublisherMac-<版本>-Direct-pre-notarization.zip`：提交给公证服务的签名产物；
- `notarytool-submission.json`：Apple 返回的提交回执；
- `notarytool-<提交 ID>.json`：公证未通过时尝试保存的诊断日志；
- `PersonalSitePublisherMac-<版本>-Direct-notarized.zip`：已装订并通过 Gatekeeper 的最终分发包。

`--prepare-only` 绝不会提交公证。`--notarize` 不会上传应用到下载服务器，也不会发布浏览器扩展；对外上传仍是单独、显式的发布步骤。

## 门禁与故障边界

行为测试可在没有发行证书的开发机上运行：

```bash
python3 script/test_direct_release_notarization.py
bash script/test_swift_release_build_gate.sh
```

严格直接分发门禁还会执行真实凭据检查，因此缺少 Developer ID 证书或钥匙串配置时会失败：

```bash
./script/check_release_gate.sh --profile direct
```

Edge 与 Firefox 的浏览器商店 profile 已从当前 Safari + Chrome 发布范围移除；本页仍记录旧版直装工作流需要的 Firefox XPI 校验，它不属于本次 App Store/浏览器渠道发布。

不得把本地 ad-hoc 签名、仅成功构建、待公证 ZIP，或尚未装订的应用描述为可正式分发产物。最终交付前应保留公证回执，并在目标 macOS 版本的干净账户或测试机上再次打开验证。
