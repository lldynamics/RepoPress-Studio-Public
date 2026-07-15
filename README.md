# PersonalSitePublisherMac

原生 macOS 版个人网站发布控制台 MVP。

当前边界：

- 原生 SwiftUI + AppKit 小桥接，不把 Catalyst 当正式产品形态。
- 三栏工作台：站点/工作区、内容列表、编辑与检查详情。
- 桌面 Markdown 编辑器：左侧 NSTextView 编辑，右侧实时预览，支持光标位置插图和拖拽图片引用。
- 本地和线上发布：选择 Zola/Hugo/Astro/Jekyll/Hexo 仓库、检查目录规则、读取本地与远端 Git 变更摘要、从 upstream 导入远端文章草稿、推断 GitHub/GitLab remote，并支持 API 直接提交或创建 PR/MR。
- AI 工作区：独立 AI 对话页、快捷提示、工作流模板、上下文文章、重新生成、引用追问和追加到文章；写作页仍保留按需出现的 AI 发布助手。
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
