# PersonalSitePublisherMac

原生 macOS 版个人网站发布控制台 MVP。

当前边界：

- 原生 SwiftUI + AppKit 小桥接，不把 Catalyst 当正式产品形态。
- 稳定三栏工作台：左侧统一任务导航与内容列表、中央编辑区、右侧 Inspector。
- 桌面 Markdown 编辑器：左侧 NSTextView 编辑，右侧实时预览，支持光标位置插图和拖拽图片引用。
- 本地和线上发布：选择 Zola/Hugo/Astro/Jekyll/Hexo 仓库、检查目录规则、读取本地与远端 Git 变更摘要、从 upstream 导入远端文章草稿、推断 GitHub/GitLab remote，并支持 API 直接提交或创建 PR/MR。
- AI 助手：在右侧 Inspector 内对话，中央始终保留正文编辑；支持文章上下文、快捷提示、工作流和追加回复到文章。
- SEO / 社交预览：缓存快照、手动刷新、Open Graph / Twitter / 搜索摘要和 AI 元数据建议入口。
- 部署和维护：发布台账、部署状态检查、站点维护工作台、素材库、快速隐藏、私密内容遮挡、免费版 / Pro 边界。
- 图片工作台：拖拽插图、批量补 alt/caption、检查封面路径和源图状态、批量压缩 JPEG。
- 启动性能基线：`script/check_launch_performance.sh` 默认要求从打开应用包到主窗口可见不超过 5 秒，可用 `LAUNCH_BASELINE_MAX_SECONDS` 调整。

运行：

```bash
./script/build_and_run.sh
```

日常修改后可先运行精简门禁；准备上架时仍运行完整门禁：

```bash
./script/check_release_gate.sh --quick
./script/check_release_gate.sh
./script/check_release_gate.sh --strict
```

应用版本只在 `Packaging/BuildVersion.xcconfig` 中维护。日常启动仍使用
Debug 构建；完整发布门禁会额外执行独立的 SwiftPM Release 配置构建。
版本递增和 App Store build number 边界见
[`docs/release-versioning.md`](docs/release-versioning.md)。

GitHub Actions 会在 push、pull request 和手动触发时运行同一套精简门禁，包括 Swift 6 严格并发零警告编译和完整 Swift 测试。

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
