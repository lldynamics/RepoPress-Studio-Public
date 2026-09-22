# Developer ID 直发流程

> 文档类型：当前操作指南。来源与冲突处理见[文档来源与维护规则](README.md)。

本文记录 RepoPress Studio 的 Developer ID 签名、公证和 Sparkle 更新产物流程。权威执行语义来自 [`script/package_direct_release.sh`](../script/package_direct_release.sh)；签名权限来自 [`Packaging/DirectDistribution.entitlements`](../Packaging/DirectDistribution.entitlements)，版本来自 [`Packaging/BuildVersion.xcconfig`](../Packaging/BuildVersion.xcconfig)。正式参数以打包脚本的 `--help` 和环境变量读取项为准。

脚本和门禁可以证明本地产物满足既定约束，但不能证明官网已经部署、下载链接在线或某个版本正在对外发布。

## 前置条件

- 使用完整 Xcode 和兼容 Swift 6 的工具链。
- 从干净且已提交的 Git checkout 执行正式发行。
- 钥匙串中存在有效的 `Developer ID Application` 身份。
- 已保存 `notarytool` 凭据。
- 已准备 Sparkle EdDSA 密钥、HTTPS appcast 地址和下载地址前缀。
- [`Packaging/BuildVersion.xcconfig`](../Packaging/BuildVersion.xcconfig) 中的版本与构建号已经更新并通过 [`script/check_build_version.sh`](../script/check_build_version.sh) 检查。

RepoPress 不在应用包中携带 Git、Hugo、Zola、Codex 或 Node.js。相关功能运行时直接解析用户在系统、Homebrew 或 `PATH` 中安装的命令；正式发行包也不得复制或重签这些第三方 CLI。Sparkle 仍作为应用内更新框架随包分发，并按下述流程单独签名和验证。

门禁清单以 [`script/release_checks.json`](../script/release_checks.json) 为准。
`direct` profile 包含对既有完整签名、公证产物的 `--validate` 检查，不能作为首次生成产物前的纯预检。
完整 profile 适用于包含维护工作流和渠道台账的开发仓；公开源码快照按其安装的 CI 工作流验证源码，阅读本指南不代表快照包含全部发行材料。

## 一次性凭据配置

首次配置 Sparkle 签名密钥和 Apple 公证凭据：

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "RepoPress"
xcrun notarytool store-credentials "RepoPress-Notary"
```

私钥由 Sparkle 从 macOS 钥匙串读取，不应写入仓库、`.env`、构建日志或发行目录。

## 发行环境

在当前终端会话中配置正式发行参数。变量名和必填语义由 [`script/package_direct_release.sh`](../script/package_direct_release.sh) 定义：

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

| 模式 | 用途 | 证据边界 |
| --- | --- | --- |
| `--dry-run` | 检查工具、entitlements 和凭据名称 | 不构建、不签名、不联系 Apple，不证明发布就绪 |
| `--prepare` | 生成供本机检查的 ad-hoc 应用包 | 产物不能分发 |
| `--validate` | 验证现有完整发行产物 | 不需要本机签名身份或公证凭据，但需要完整产物集合 |
| `--release` | 执行正式签名、公证、stapling 和更新产物生成 | 需要全部凭据、网络与干净的提交态 checkout |

## 操作顺序

1. 更新版本和配置，运行 `./script/check_release_gate.sh --quick`；脚本有改动时运行 `--tooling` 自测。
2. 用 `./script/package_direct_release.sh --dry-run` 检查环境。它会报告缺失凭据名称，退出成功也不代表凭据或发行产物已经可用；需要本机检查包时另用 `--prepare`。
3. 在干净且已提交的 checkout 上运行 `./script/package_direct_release.sh --release`，生成正式签名、公证产物。该步骤会联系 Apple。
4. 产物存在后运行 `./script/check_release_gate.sh --profile direct` 做渠道验收；只需重验产物时使用 `./script/package_direct_release.sh --validate`。使用自定义输出位置时需按打包脚本参数指定实际产物，不应误验默认目录的旧文件。
5. 网站上传、appcast 部署和真实下载验证是后续发布操作；这些本地命令不完成网站部署。

## 产物

完整发行流程会显式重签 Sparkle 嵌套组件，启用 hardened runtime，并生成：

- Developer ID 签名并公证、staple 的应用包和 DMG；
- ZIP 下载包；
- `stable-appcast.xml` 或 `beta-appcast.xml`；
- SHA-256 校验文件；
- 绑定源提交、版本、构建号和产物哈希的 JSON manifest。

Apple 安全时间戳、公证票据和磁盘镜像元数据会变化，因此 manifest 记录来源与哈希，但不宣称不同发行运行之间可以做到字节级复现。

## 版本边界

[`Packaging/BuildVersion.xcconfig`](../Packaging/BuildVersion.xcconfig) 是 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 的唯一提交来源。SwiftPM-first 工程不会自动递增构建号；详细规则见 [`release-versioning.md`](release-versioning.md)。构建/启动入口由 [`script/build_and_run.sh`](../script/build_and_run.sh) 定义，本文不复制其参数清单。

本地检查不能证明某个构建号从未在更新渠道中发布，也不能替代对真实下载地址、appcast 和线上产物的发布后验证。
