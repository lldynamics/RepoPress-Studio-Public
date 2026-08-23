# Developer ID 直发流程

本文记录 RepoPress Studio 的 Developer ID 签名、公证和 Sparkle 更新产物流程。脚本和门禁可以证明本地产物满足既定约束，但不能证明官网已经部署、下载链接在线或某个版本正在对外发布。

## 前置条件

- 使用完整 Xcode 和兼容 Swift 6 的工具链。
- 从干净且已提交的 Git checkout 执行正式发行。
- 钥匙串中存在有效的 `Developer ID Application` 身份。
- 已保存 `notarytool` 凭据。
- 已准备 Sparkle EdDSA 密钥、HTTPS appcast 地址和下载地址前缀。
- `Packaging/BuildVersion.xcconfig` 中的版本与构建号已经更新并通过检查。

发布前先运行 Developer ID 渠道门禁：

```bash
./script/check_release_gate.sh --profile direct
```

## 一次性凭据配置

首次配置 Sparkle 签名密钥和 Apple 公证凭据：

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "RepoPress"
xcrun notarytool store-credentials "RepoPress-Notary"
```

私钥由 Sparkle 从 macOS 钥匙串读取，不应写入仓库、`.env`、构建日志或发行目录。

## 发行环境

在当前终端会话中配置正式发行参数：

```bash
export DIRECT_DISTRIBUTION_APPLICATION_IDENTITY="Developer ID Application: ..."
export DIRECT_DISTRIBUTION_NOTARY_PROFILE="RepoPress-Notary"
export REPOPRESS_UPDATE_FEED_URL="https://updates.example.com/stable-appcast.xml"
export REPOPRESS_UPDATE_PUBLIC_ED_KEY="<EdDSA public key>"
export REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="https://updates.example.com/downloads"
export REPOPRESS_SPARKLE_KEY_ACCOUNT="RepoPress"
export REPOPRESS_UPDATE_CHANNEL="stable" # 或 beta
```

示例域名必须替换为真实 HTTPS 发行地址；不要把私钥或公证密码放进这些变量。可运行以下命令查看脚本当前支持的全部参数：

```bash
./script/package_direct_release.sh --help
```

## 四种模式

```bash
./script/package_direct_release.sh --dry-run
./script/package_direct_release.sh --prepare
./script/package_direct_release.sh --validate
./script/package_direct_release.sh --release
```

| 模式 | 用途 | 证据边界 |
| --- | --- | --- |
| `--dry-run` | 检查工具、entitlements 和凭据名称 | 不构建、不签名、不联系 Apple，不证明发布就绪 |
| `--prepare` | 生成供本机检查的 ad-hoc 应用包 | 产物不能分发 |
| `--validate` | 验证现有完整发行产物 | 不需要本机签名身份或公证凭据，但需要完整产物集合 |
| `--release` | 执行正式签名、公证、stapling 和更新产物生成 | 需要全部凭据、网络与干净的提交态 checkout |

## 产物

完整发行流程会显式重签 Sparkle 嵌套组件，启用 hardened runtime，并生成：

- Developer ID 签名并公证、staple 的应用包和 DMG；
- ZIP 下载包；
- `stable-appcast.xml` 或 `beta-appcast.xml`；
- SHA-256 校验文件；
- 绑定源提交、版本、构建号和产物哈希的 JSON manifest。

Apple 安全时间戳、公证票据和磁盘镜像元数据会变化，因此 manifest 记录来源与哈希，但不宣称不同发行运行之间可以做到字节级复现。

## 版本边界

`Packaging/BuildVersion.xcconfig` 是 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 的唯一提交来源。SwiftPM-first 工程不会自动递增构建号；详细规则见 [`release-versioning.md`](release-versioning.md)。

本地检查不能证明某个构建号从未在更新渠道中发布，也不能替代对真实下载地址、appcast 和线上产物的发布后验证。
