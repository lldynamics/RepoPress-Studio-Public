# 工作台 UI 对齐：第十三批

日期：2026-10-07。承接[第十二批写作辅助](ui-writing-assistance-alignment-2026-10-05.md)，补齐站内链接选择器与 SSG 组件条的简中/English 呈现和长文本布局。参考当前检出的 Swift 面板与已保存的 `origin/main`（`2d2858fc5ebc3843d1a281026304c2551741691c`）；两个参考文件内容不同，本批分别复核了其功能边界，没有刷新远端或 Mac 实机视觉基线。

## 已实现

- `MarkdownInternalLinkPicker` 的标题、说明、搜索、按钮、ARIA、空状态和受控状态支持双语。异步读取期间切换语言，查询、焦点和待完成操作保持；读取结束后的成功提示使用完成时的当前语言。
- `MarkdownSSGComponentStrip` 的七种组件类型、区块说明、数量、行号、定位 ARIA 和定位反馈支持双语。仍最多显示前十二项，保留原来的顺序、类型符号、禁用规则和定位范围。
- 链接选择器的长名称、路径与站点路由允许换行，样式限定到 `markdown-internal-link-title`。SSG 标题栏和类型行允许换行；卡片标题截断、两行摘要、横向滚动及窄窗口规则保持现有行为，继续使用现有浅色/深色主题变量。

## 数据与交互边界

文章标题、建议标签、路径、URL、组件标题、预览、源码、ID、kind 和 UTF-16 定位范围保持原值。名称恰好是“插入链接”“提示框”等完整词典键时，也不翻译数据；包含 `{label}`、`{title}`、`{{raw}}` 的内容只作为单次插值参数，不发生递归替换。解析器提供的默认组件标题也保留原文，不按文字内容猜测来源。

链接成功提示只翻译外层句式。新增 translator ref 仅提供完成时的语言；原来的 value/selection 闭包、generation/openRef 失效检查、元数据读取失败回退、关闭/重开保护和回调次数保持不变。原有 effect 和 memo 依赖没有加入语言，切换语言不重新读取、清空查询、移动焦点或触发插入。SSG 回调仍收到原始 `sourceRange` 对象；行号没有新增 live region。

本批没有修改 `App.tsx`、全局 i18n、两个写作辅助函数、抽屉焦点、契约、Gateway、Rust 和 `App.css`。本批不扩展搜索、路由、解析器、真实资料读写或历史恢复能力。

## 包体处理

首个候选构建通过，但编辑器及静态依赖为 1301.4 KiB，超过既有 1300 KiB 预算。主线程在 `vite.config.ts` 中精确抽取 React、React DOM、Scheduler 和既有 i18n 入口及其静态依赖到共享 `ui-runtime` 块，没有宽泛归并整个 i18n 目录，也没有调整预算或弹窗挂载方式。

使用已安装的 Rollup 4.63.1；函数式 `manualChunks` 会归并指定模块的静态依赖，参照 [Rollup 官方配置说明](https://rollupjs.org/configuration-options/#output-manualchunks)。最终实际 manifest 中共享块没有静态或动态回边，编辑器闭包只包含编辑器和共享块；共享块也计入启动闭包。其他懒加载面板仍保留原有的主入口共享依赖。原来九个必需懒加载面板仍动态可达。这验证构建产物依赖图，不替代原生窗口运行验收。

## 覆盖矩阵

| 范围 | 当前状态 |
| --- | --- |
| 前十二批界面 | 保留相应范围的双语支持 |
| 站内链接选择器、SSG 组件条 | 本批补齐已有控件的受控呈现及相关长文本规则 |
| Mac 链接反向引用、标签/摘要等元数据搜索、外部链接模板入口 | 后续功能差距 |
| Mac SSG 图形缩略预览 | Linux 仍使用既有类型符号、标题与摘要，图形预览尚未对齐 |
| 中文排版按钮、历史与回收站、通用草稿中心 | [第十四批](ui-draft-lifecycle-alignment-2026-10-07.md)补齐双语呈现与相关长文本规则 |
| 其他剩余界面 | 后续逐项迁移与验收 |
| 原始模板正文、默认组件标题、按翻译显示名搜索 | 保留原始数据与原有查询语义 |
| 浏览器视觉、窄窗口测量及新截图 | 既有浏览器安全策略阻断仍在，本轮没有重试或绕过 |
| Tauri WebKitGTK、GNOME/KDE、Wayland/X11、HiDPI、中文 IME、AT-SPI、最新 Mac 实机 | 现场验收未完成 |

## 分工与保护

Luna medium 独占 SSG 三个文件；站内链接涉及异步完成和失效边界，由可用的 `gpt-6.1-sol` high 独占三个文件，代替当前工具未提供的 Terra。另一个 Sol xhigh 只读审查控件、测试、组合 diff、构建图与文档。主线程负责 CSS、词典门禁、打包配置、整合和最终全量验收。没有子代理继续委派或文件写入重叠。

开工保存 2419 个文件哈希及十个关键文件副本，后补保存未变的 Vite 配置副本。本批源码/测试共十个文件，五个已有、五个新增；另新增本篇记录并更新第十二批覆盖矩阵。没有提交、推送、合并、重置、清理或改写历史，也没有创建浏览器 fixture。同期 P52 恢复安装及合并投影变化属于另一条任务，本批全部保留；组合前端门禁不替代其 Rust、安装事务或真实恢复验收。

## 验收证据

- 开工限定基线：两个写作辅助测试文件共 11 项通过。
- 新增 19 项测试：链接选择器 12 项、SSG 条 6 项、词典门禁 1 项。链接定向结果为 2 文件/18 项；SSG 为 2 文件/11 项；词典门禁为 1/1，通过。
- 33 个词典共 2379 个唯一键，两个新增词典各 11 个本地词条。共享译文与参数一致性门禁通过；静态审计的重复键、译文冲突、明确 `t()` 键缺失、两个组件 JSX 中文文本/属性残留均为零。这不要求原始文章数据变成英文。
- 生产构建与原包体门禁通过：启动 JavaScript 689.1 KiB，两个启动 JS 文件；九个必需懒加载 JS 块；编辑器及静态依赖 914.1 KiB。既有大块及 dialog 静态/动态混用构建提示仍存在。
- 首轮全量测试：187 个文件、1323 项全部通过。同期 P52 新增前端文件后重新拍摄 441 个前端文件快照并复跑：189 个文件中 188 个通过，1356 项测试中 1355 项通过、1 项失败；唯一失败为 `knowledgeRestoreInstallGateway.test.ts` 的 `gateway.planKnowledgeRestoreInstall is not a function`，该并发接口尚未接线。本批新增 19 项均通过，10 个本批源码文件与冻结哈希一致。组合全量门禁未通过，不替代 P52 验收。

证据日志：`/tmp/repopress-ui-phase13-accepted-tests.log`、`/tmp/repopress-ui-phase13-accepted-build.log`、`/tmp/repopress-ui-phase13-accepted-bundle.log`。依赖图：`/tmp/repopress-ui-phase13-bundle-graph.json`；静态审计：`/tmp/repopress-ui-phase13-presentation-audit.json`；最终工作树审计：`/tmp/repopress-ui-phase13-final-audit.json`。本批组合 diff 为 498 行；开工文件无缺失，整仓 `git diff --check` 和本批逐文件空白检查通过。复验日志 SHA-256：`35250838792a63ba378784c9d75822b894922a271080bc3ff5e9c8db99294260`。独立只读复核完成，本批无剩余代码或文档发现；组合门禁仍受上述 P52 未接线接口阻断。

```sh
npx vitest run --maxWorkers=4
npm run build
npm run check:bundle
git diff --check
```

React 测试使用隔离 DOM、异步 resolver 与焦点方法模拟；无效插入位置使用隔离 helper spy 覆盖。CSS 结论来自源码审查；本批不宣称浏览器、原生桌面或像素级对齐已验收。
