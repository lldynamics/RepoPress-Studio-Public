# RepoPress

面向 Git 驱动静态站点作者的原生 macOS Markdown 与仓库工作台。

当前边界：

- 原生 SwiftUI + AppKit 小桥接，不把 Catalyst 当正式产品形态。
- 稳定三栏工作台：左侧统一任务导航与内容列表、中央编辑区、右侧 Inspector。
- 桌面 Markdown 编辑器：左侧 NSTextView 编辑，右侧实时预览，支持光标位置插图和拖拽图片引用。
- 本地和线上发布：选择 Zola/Hugo/Astro/Jekyll/Hexo 仓库、检查目录规则、读取本地与远端 Git 变更摘要、从 upstream 导入远端文章草稿、推断 GitHub/GitLab remote，并支持 API 直接提交或创建 PR/MR。
- AI 助手：在右侧 Inspector 内对话，中央始终保留正文编辑；支持文章上下文、快捷提示、工作流和追加回复到文章。
- SEO / 社交预览：缓存快照、手动刷新、Open Graph / Twitter / 搜索摘要和 AI 元数据建议入口。
- 部署和维护：发布台账、部署状态检查、站点维护工作台、素材库、快速隐藏（仅界面遮挡）和私密内容遮挡。
- 图片工作台：拖拽插图、批量补 alt/caption、检查封面路径和源图状态、批量压缩 JPEG。
- 启动性能基线：`script/check_launch_performance.sh` 默认要求从打开应用包到主窗口可见不超过 5 秒，可用 `LAUNCH_BASELINE_MAX_SECONDS` 调整。

运行：

```bash
./script/build_and_run.sh
```

当前主发行渠道是官网 Developer ID 版。用户可自行配置 AI 服务和 API Key；
Safari Web Extension 随应用内置，Chrome 扩展从 Chrome 网上应用店安装，Firefox 扩展可从
运行 `python3 script/build_browser_extension_source.py --browser firefox --output-dir
.build/browser-extension/firefox` 后，从 `.build/browser-extension/firefox/manifest.json` 以临时附加组件方式加载。
三种浏览器都通过带随机令牌的
本机回环接口连接同一个应用。

日常修改后可先运行精简门禁；准备发布时分别检查应用和浏览器商店：

```bash
./script/check_release_gate.sh --quick
./script/check_release_gate.sh
./script/check_release_gate.sh --profile direct
./script/check_release_gate.sh --profile chrome
```

每个 profile 只检查该渠道与公共发布基线，不会被其他渠道的凭据、
上架 ID 或素材阻断。当前产品不包含应用内购买、权益系统或付费功能维护面。

官网直发流水线有三个可独立验证的阶段：

```bash
./script/package_direct_release.sh --dry-run
./script/package_direct_release.sh --prepare
./script/package_direct_release.sh --release
```

`--dry-run` 不构建、不读取私钥、不联系 Apple；`--prepare` 只产出 ad-hoc
签名的检查包，不能分发。完整发布需要先在钥匙串中准备 Developer ID、
notarytool 凭据与 Sparkle EdDSA 私钥，然后配置：

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "RepoPress"
xcrun notarytool store-credentials "RepoPress-Notary"

export DIRECT_DISTRIBUTION_APPLICATION_IDENTITY="Developer ID Application: ..."
export DIRECT_DISTRIBUTION_NOTARY_PROFILE="RepoPress-Notary"
export REPOPRESS_UPDATE_FEED_URL="https://updates.example.com/stable-appcast.xml"
export REPOPRESS_UPDATE_PUBLIC_ED_KEY="<EdDSA public key>"
export REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="https://updates.example.com/downloads"
export REPOPRESS_SPARKLE_KEY_ACCOUNT="RepoPress"
export REPOPRESS_UPDATE_CHANNEL="stable" # 或 beta
./script/package_direct_release.sh --release
```

私钥只由 Sparkle 从 macOS 钥匙串读取，不写入仓库或发布目录。流水线会显式重签
Sparkle 嵌套组件，完成 hardened runtime、Apple 公证与 stapling，并产出 DMG、
ZIP、`stable-appcast.xml`/`beta-appcast.xml`、SHA-256 和 JSON manifest。Apple 安全时间戳、
公证票据和磁盘镜像元数据会变化，因此 manifest 记录源提交和产物哈希，
但不宣称字节级可复现。

应用版本只在 `Packaging/BuildVersion.xcconfig` 中维护。日常启动仍使用
Debug 构建；完整发布门禁会额外执行独立的 SwiftPM Release 配置构建。
版本递增和构建号边界见
[`docs/release-versioning.md`](docs/release-versioning.md)。

GitHub Actions 在 `main` push 运行精简门禁，在 pull request/手动触发时追加覆盖率、分发构建与 UI 证据。必需门禁使用 Swift 5 语言模式的 complete-concurrency 零警告编译；另有明确非阻塞、真正传入 `-swift-version 6` 的迁移诊断任务。

定位单项失败时，可重复传入检查 ID，例如：

```bash
./script/check_release_gate.sh --check localization --check swift-strict-build --check swift-tests
./script/check_release_gate.sh --list
```

浏览器扩展保留了快速的 VM/DOM 兼容回归，并额外使用真实 Chromium
和 Firefox 验证权限提示边界、MV3 Service Worker 唤醒、键盘焦点、320px
重排及浏览器 API 差异。首次运行需安装锁定依赖和 Chromium 内核：

```bash
npm ci
npm run install:browser-extension:e2e
npm run test:browser-extension:e2e
```

失败截图和结构化结果会写入 `output/playwright/browser-extension-e2e/`。
