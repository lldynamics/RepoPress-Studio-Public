# 工作台 UI 对齐：第十四批

日期：2026-10-07。承接[第十三批站内链接与 SSG](ui-link-ssg-alignment-2026-10-07.md)，补齐版本历史与回收站、通用草稿中心、中文排版按钮的简中/English 呈现与长文本规则。参考当前检出的 `DraftVersionComparisonView.swift`、`DraftOwnershipTransferConfirmationView.swift` 和 `MacMarkdownComposerEditingActions.swift` 的行为边界；没有刷新远端或最新 Mac 实机视觉基线。

## 已实现

- 历史中心的标签页、列表、空状态、ARIA、受控状态、确认框及错误回退支持双语；时间按界面语言格式化。统一差异只翻译生成的两行标题和截断提示，保留正文行及增删符号。
- 通用草稿中心的编辑、目标路径、计划核对、移动确认、执行与一次性撤销提示支持双语。语言切换保持正文、选择、路径、焦点、待执行计划和撤销凭据，保留原有计划失效条件。
- 中文排版按钮及无改动/成功反馈支持双语。反馈记录执行时的选区或全文范围；随后改变选区、切换语言不会再次应用编辑，也不会把旧反馈改成新的选区范围。
- 三个组件的长文案、提示和相关容器允许换行；深色主题的强调按钮文字使用既有 surface 变量，计划内冲突文字使用既有深色错误色。历史列表标题仍截断，窄窗口断点、正文预览、按钮顺序及危险操作样式保留现有结构。CSS 结论来自源码审查，未测量原生窗口。

## 数据与交互边界

正文、标题、仓库名、路径、SHA、ID、计划项目的源/目标标签、后端警告、冲突、只读原因和操作摘要保持原值。原始数据恰好是完整词典键、含 `{name}` 或 `{{raw}}`、带 HTML 字符时，仍作为文本显示；插值不递归解释这些值。

历史错误按来源标记，通用草稿反馈区分受控词条和原始网关文本。空的 `Error.message` 继续不生成错误提示，原有空摘要回退语义保持。历史差异状态只存代码行，生成标题在呈现时翻译，不对合成 diff 做整体翻译。

历史中心的 9 组、通用草稿中心的 7 组原有 callback/effect/memo 依赖保持不变，没有加入语言。通用草稿的计划上下文 JSON、目标路径构造、IPC 参数和撤销回调字段保持；历史恢复的 baseline SHA、路径 trim、原始返回对象及来源参数保持。恢复的 dirty/只读限制、永久删除双确认、移动取消、busy 关闭限制及过期响应检查均沿用原有规则。

没有修改全局 i18n、`App.tsx`、`App.css`、Vite 配置、三个写作业务辅助函数、契约、Gateway 或 Rust。本批没有扩展真实文件转移、删除或恢复权限，也没有执行实际资料操作。

## 覆盖矩阵

| 范围 | 当前状态 |
| --- | --- |
| 前十三批界面 | 保留对应范围的双语支持 |
| 历史与回收站、通用草稿中心、中文排版按钮 | 本批补齐受控呈现及相关长文本规则 |
| 历史比较目标选择、Front Matter/正文分区 | [第十五批](ui-draft-comparison-alignment-2026-10-07.md)补齐；Mac 字段级元数据语义对比仍待实施 |
| Mac 草稿归属变更与 Linux 仓库文件转移 | 行为合同不同；本批保留 Linux 已有文件转移计划和明确移动确认 |
| Mac SSG 图形预览、链接反向引用/元数据搜索、外部链接模板 | 后续功能与结构差距 |
| 其他剩余界面和真实桌面交互 | 后续逐项验收 |
| 浏览器视觉、新截图及窄窗口测量 | 既有浏览器安全策略阻断仍在，本轮没有重试或绕过 |
| Tauri WebKitGTK、GNOME/KDE、Wayland/X11、HiDPI、中文 IME、AT-SPI、最新 Mac 实机 | 现场验收未完成 |

## 分工与保护

历史中心和通用草稿中心分别由 `gpt-6.1-sol` high 独占三个文件；涉及异步状态和确认流程，使用当前工具可用的模型代替不可用的 Terra。第三条 `gpt-6.1-sol` xhigh 只读复核组合源码、测试和证据。主线程负责中文排版、三份 CSS、词典门禁、工作树保护、整合及最终检查。没有子代理继续委派或写入重叠。

开工保存 2434 个文件哈希及 16 个关键文件副本。本批源码/测试共 13 个文件，6 个已有、7 个新增；另新增本篇记录并更新第十三批覆盖矩阵。没有提交、推送、合并、重置、清理或改写历史。同期 P53 恢复归档文件属于另一条活动任务，全部保留；本批前端检查不替代其 Rust、恢复事务或真实归档验收。

## 验收证据

- 开工限定基线：5 文件、27 项测试通过，包含 P52 恢复安装 Gateway 的 2 项测试；上一批未接线接口阻塞在本轮已解除。
- 新增 74 项测试：历史中心 33 项、通用草稿中心 34 项、中文排版 6 项、词典门禁 1 项。定向结果分别为历史 3 文件/43 项、通用草稿 2 文件/37 项、排版 2 文件/18 项、词典 1/1，全部通过。
- 36 个词典共 2501 个唯一键，新增三个本地词典各 54/70/6 项。共享译文、参数一致性和未全局注册门禁通过；静态审计未发现重复键、译文冲突、明确 `t()` 键缺失或三个组件 JSX 中文文本/静态属性残留。这不要求原始文章或后端数据变成英文。
- 生产构建与原包体门禁通过：启动 JavaScript 691.0 KiB，两个启动 JS 文件；九个必需懒加载 JS 块；编辑器及静态依赖 914.1 KiB。两个草稿弹层保持动态入口；没有调整预算。既有大块及 dialog 静态/动态混用提示仍存在。
- 全量前端检查在冻结的 472 个输入上完成：195 个测试文件中 194 个通过，1483 项中 1481 项通过、2 项失败。本批新增 74 项全部通过。两项失败均在同期 `knowledgeRestoreArchiveGateway.test.ts`，原因是 `gateway.inspectKnowledgeRestoreArchive is not a function`；该 P53 活动接口尚未接线，组合全量门禁未通过。

日志：`/tmp/repopress-ui-phase14-baseline-tests.log`、`/tmp/repopress-ui-phase14-history-tests.log`、`/tmp/repopress-ui-phase14-general-tests.log`、`/tmp/repopress-ui-phase14-typography-tests.log`、`/tmp/repopress-ui-phase14-catalog-tests.log`、`/tmp/repopress-ui-phase14-tests.log`、`/tmp/repopress-ui-phase14-build.log`、`/tmp/repopress-ui-phase14-bundle.log`。静态审计及构建图：`/tmp/repopress-ui-phase14-presentation-audit.json`、`/tmp/repopress-ui-phase14-bundle-graph.json`；冻结输入：`/tmp/repopress-ui-phase14-frontend-freeze.json`。组合源码 diff 为 1272 行；工作树和冻结哈希复核见 `/tmp/repopress-ui-phase14-final-audit.json`。

独立只读复核完成，无剩余代码或文档发现。13 个源码和 472 个前端输入哈希无漂移，开工文件无缺失；整仓 `git diff --check` 及本批文件空白检查通过。同期新增的 5 个恢复归档文件及变动的 2 个 Rust 文件全部保留。全量测试日志 SHA-256 为 `5303192cf491479c046785f1ec9aeca4b4a6a336f067600de045e550c11c7e10`；组合门禁仍受上述 P53 接线阻断。

```sh
npx vitest run --maxWorkers=4
npm run build
npm run check:bundle
git diff --check
```

React 测试使用隔离 DOM、受控异步 resolver、确认框/focus/帧调度模拟及少量 helper spy。它们验证界面状态和调用合同，不证明真实仓库复制、移动、删除、恢复、原生焦点或像素级对齐。
