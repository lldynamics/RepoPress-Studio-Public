# RepoPress Studio

面向 Git 驱动静态站点作者的原生 macOS 写作、资料与发布工作台。

RepoPress Studio 是 RepoPress 的桌面版本：用 Markdown 管理内容，以 Git 仓库作为发布边界，并把写作、图片、SEO、部署、RSS、知识库和可选 AI 集中到一个本地优先的工作区。主产品是原生 macOS 实现，不使用 Catalyst；仓库同时包含一个边界独立的 Tauri 2 跨平台桌面原型，用于验证 Windows / Linux 上的只读仓库浏览与轻量编辑能力。

> RepoPress 另有面向 iPhone 和 iPad 的 iOS 版，已经上架 App Store。两端围绕同一类静态站点工作流设计，但代码仓库、界面、数据模型、商业权益和发行节奏相互独立。

## 核心能力

- **原生写作工作台**：SwiftUI 三栏布局、基于 `NSTextView` 的 Markdown 编辑器、实时预览、光标位置插图、拖拽图片和本地草稿版本。
- **Git 仓库发布**：支持 Zola、Hugo、Astro、Jekyll 和 Hexo；可检查本地与远端变更，从 upstream 导入文章，并通过 GitHub / GitLab 直接提交或创建 PR / MR。
- **发布质量检查**：提供 front matter、路径与资源预检，SEO / Open Graph / Twitter 预览，发布包 diff、发布台账、回滚入口和部署状态检查。
- **图片与站点维护**：管理封面和素材，批量补充 alt / caption，检查源图状态并压缩 JPEG；站点维护区集中处理仓库、内容和部署问题。
- **本地知识与阅读**：内置资料库、网页与 PDF 导入、语义检索、RSS 订阅和阅读进度；工作区备份不会包含 Keychain 凭据。
- **可选 AI 工作流**：在 Inspector 中基于当前文章连续对话，执行元数据建议、审稿和发布文案等任务；API Key 由用户配置并存入 Keychain。
- **浏览器采集**：Chrome 和 Firefox 扩展通过带随机令牌的 `127.0.0.1` 回环接口连接本机应用，不把网页内容发送到开发者中转服务。

## 多平台关系

| 产品 | 定位 | 代码与发行边界 |
| --- | --- | --- |
| RepoPress Studio for macOS | 桌面写作、资料管理、本地 Git / SSG 与完整发布工作台 | 本仓库；原生 SwiftUI + AppKit，独立构建和发行 |
| RepoPress Desktop（实验性） | Windows / Linux 优先的仓库浏览与轻量 Markdown 编辑；当前不提供提交、推送、认证或发布 | `Apps/RepoPressDesktop/`；Tauri 2 + Rust + React，独立 CI，不承诺与 macOS 功能对等 |
| RepoPress for iOS | 面向 iPhone 和 iPad 的移动发布控制台 | 已上架 App Store；在独立仓库中维护 |

跨端演进以兼容现有产品为前提：优先共享端点、front matter、slug、路径、diff 等确定性规则；App 状态、持久化模型、Keychain、StoreKit、后台任务以及 AppKit / UIKit 界面继续由各端负责。

## 环境要求

- 运行：macOS 14 或更高版本。
- 开发：完整 Xcode 及兼容 Swift 6 的工具链；Command Line Tools 不足以覆盖完整 macOS 应用包流程。
- 质量脚本：Python 3 和系统开发工具。
- 本地发布、预览与 ChatGPT 登录：按需安装 Git、Hugo、Zola、Codex CLI、Node.js/npm 等工具；应用优先从系统路径、Homebrew 或 `PATH` 中动态解析，不会将这些第三方 CLI 捆绑进 `.app`。
- 浏览器扩展测试：Node.js 与 npm；日常 Swift 开发不依赖 Node。
- Tauri 原型：Node.js 24、Rust 1.90，以及目标系统对应的 Tauri 2 桌面依赖；它不参与原生 macOS 应用的打包。

所有 SwiftPM target 都必须显式使用 Swift 6 语言模式；模块边界门禁会从清单动态盘点 target、产品与依赖，不依赖容易过期的固定数量。

## 快速开始

构建和测试 SwiftPM 产品：

```bash
swift build
swift test
```

只组装 `.app`，但不启动：

```bash
./script/build_and_run.sh --package-only
```

构建完整 macOS 应用包并启动：

```bash
./script/build_and_run.sh
```

## 项目结构

- `Sources/PublishingMarkdownCore/`、`Sources/PublishingGitCore/`、`Sources/PublishingAICore/`、`Sources/PublishingKnowledgeCore/`：Markdown、仓库发布、AI 与知识库的细粒度边界。
- `Sources/PublishingCoreSupport/`、`Sources/PublishingDomainContracts/`：共享基础设施与小型跨域值契约。
- `Sources/PublishingWorkbenchCore/`：跨域编排、Store、兼容适配和暂时保留的 umbrella 导出层。
- `Sources/PersonalSitePublisherMac/`：macOS App、SwiftUI 界面和 AppKit 适配层。
- `Sources/BrowserExtensionProtocolSupport/`：应用与浏览器扩展共享的协议常量。
- `Shared/RepoPressCoreContracts/`：跨 Swift / .NET 的版本化契约、固定样例和 Foundation-only 共享 Core。
- `BrowserExtension/`：Chrome 和 Firefox 扩展源码与渠道配置。
- `Apps/RepoPressDesktop/`：实验性的 Tauri 2 + Rust + React 跨平台桌面端，拥有独立依赖、测试和 CI 边界。
- `Tests/`、`UITests/`：单元、集成、运行态 UI 和无障碍测试。
- `Packaging/`：版本、entitlements、第三方声明与发行配置。
- `script/`：构建、质量门禁、扩展和发行脚本。
- `docs/`：隐私、版本及维护者文档。

## 质量门禁

日常修改先运行快速门禁；需要覆盖全部严格发行配置时使用 `all`：

```bash
./script/check_release_gate.sh --quick
./script/check_release_gate.sh --profile all
```

也可以列出或定向运行检查：

```bash
./script/check_release_gate.sh --list
./script/check_release_gate.sh \
  --check localization \
  --check swift-strict-build \
  --check swift-tests
```

模块编译耗时使用独立工具记录。先查看计划，再按需采集 Release 冷构建、暖构建和增量构建样本：

```bash
python3 script/benchmark_swift_module_builds.py --plan
python3 script/benchmark_swift_module_builds.py \
  --configuration release \
  --repetitions 3 \
  --scenario cold \
  --scenario warm \
  --scenario incremental
```

工具先在计时外解析依赖，并在整次运行中复用隔离的依赖下载缓存；每组冷构建使用独立编译器缓存，暖构建只复用对应冷样本。增量探针只修改临时源码副本，不触碰工作树。宿主机墙钟时间只用于趋势比较，不作为发行硬阈值。

代码、真实窗口和无障碍证据分层验证：

```bash
bash script/check_ui_runtime.sh --package-only
bash script/check_ui_runtime.sh --launch
bash script/check_accessibility_runtime.sh
```

`--package-only` 只证明 Release 应用包可生成；`--launch` 才检查真实启动和可见窗口。无障碍脚本提供运行态 XCUITest 证据，不能用普通单元测试替代。

启动性能基线由 `script/check_launch_performance.sh` 检查，默认要求从打开应用包到主窗口可见不超过 5 秒；本机基线可通过 `LAUNCH_BASELINE_MAX_SECONDS` 调整。

GitHub Actions 的证据层级按触发方式区分：`main` 分支 push 只运行快速静态门禁（Swift 6 严格测试清单编译、模块边界等）；Pull Request 运行快速门禁、覆盖率、分发构建和公共快照边界，但不运行真实窗口或无障碍 XCUITest。版本 tag push、固定夜间任务，以及 `workflow_dispatch` 选择 `release` 风险层，才运行发行构建后的真实启动、可见窗口与无障碍运行态检查，并附加 Release 性能证据；手动选择 `quick` 或 `pr` 时仅运行对应较低层级。Swift 6 证据由共享快速门禁提供，不存在独立的 Swift 6 migration lane。共享契约子树另有跨平台契约、Swift Core 与 .NET Core 门禁，使用说明见 [`Shared/RepoPressCoreContracts/README.md`](Shared/RepoPressCoreContracts/README.md)。

Tauri 原型由 `.github/workflows/tauri-desktop.yml` 独立验证前端测试与构建、Rust 格式、单元测试和 clippy。macOS 上的本地通过只证明当前主机可构建；Linux 支持必须以 Ubuntu CI 或真实 Linux 设备上的同一套检查及窗口验证为准。

## 浏览器扩展

macOS 应用不内嵌浏览器扩展；Chrome 和 Firefox 扩展需要单独安装和更新。仓库提供 Chrome Web Store 与 Firefox 的源码、打包和身份校验流程。具体安装、权限与数据边界见 [`BrowserExtension/README.md`](BrowserExtension/README.md)。

真实浏览器 E2E 使用锁定的 npm 依赖，并会下载本地 Chromium 运行时；完整 Firefox 场景还需要本机安装 Firefox：

```bash
npm ci --ignore-scripts
npm run install:browser-extension:e2e
npm run test:browser-extension:e2e
```

失败截图和结构化结果写入 `output/playwright/browser-extension-e2e/`。

## 分发与版本

仓库分别维护公共门禁、Developer ID 直发和 Chrome 扩展发行配置。脚本存在只代表发行路径可验证，不代表某个线上渠道或构建当前已经发布。

```bash
./script/check_release_gate.sh --profile direct
./script/check_release_gate.sh --profile chrome
```

Developer ID 直发流水线分为检查、临时检查包、既有产物验证和正式发行四种模式：

```bash
./script/package_direct_release.sh --dry-run
./script/package_direct_release.sh --prepare
./script/package_direct_release.sh --validate
./script/package_direct_release.sh --release
```

- `--dry-run` 不构建、不签名、不联系 Apple，也不构成发布就绪证明。
- `--prepare` 只生成 ad-hoc 签名检查包，不能分发。
- `--validate` 验证现有完整签名、公证和更新产物。
- `--release` 需要干净且已提交的 checkout、Developer ID 身份、公证凭据、Sparkle 密钥与 HTTPS 更新地址。

完整配置和产物边界见 [`docs/direct-release.md`](docs/direct-release.md)。应用版本只在 [`Packaging/BuildVersion.xcconfig`](Packaging/BuildVersion.xcconfig) 中维护，递增规则见 [`docs/release-versioning.md`](docs/release-versioning.md)。

macOS 版当前代码不包含应用内购买或付费权益维护面；这不代表 iOS App Store 版的商业边界。

## 隐私与安全

RepoPress Studio 是本地优先应用，而不是完全离线应用。文件默认保留在用户设备；只有在用户明确执行仓库同步、发布、部署检查、AI 请求、网页采集或更新检查时，应用才会联系相应服务。凭据存入 Keychain，不进入工作区备份。

“快速隐藏”只提供界面遮挡，不是身份验证或磁盘加密。

不要把真实凭据、私人仓库内容、本机路径或未脱敏截图提交到仓库。安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告，不要创建公开 Issue。

## 贡献与许可

贡献流程见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。项目源码采用 Mozilla Public License 2.0，完整条款见 [`LICENSE`](LICENSE)；RepoPress 名称、标志和应用图标由 [`TRADEMARKS.md`](TRADEMARKS.md) 单独管理。

## README 与公开快照

- `README.md`：当前开发仓的中文产品、开发和发行入口。
- `README.public.md`：公开源码快照的 README 模板。
- `script/export_public_snapshot.sh`：将经过审核的公开文件复制到独立目录，并把 `README.public.md` 安装为公开快照的 `README.md`。

修改公共产品事实、构建命令或许可证说明时，应同步检查两份 README，避免公开快照退回旧信息。
