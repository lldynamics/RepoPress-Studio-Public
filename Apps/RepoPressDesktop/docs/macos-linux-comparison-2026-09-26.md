# macOS → Linux 差异复核 · 2026-09-26

已重新拉取并按固定源码核对：最新 macOS 主线是 `6857545bdca00884593193175cffb654cc092a22`（2026-09-24 18:26:57 +0800），比上次 `6abd42a8bbf4254961498c359cd7e9ef037f2fe7` 多 4 个提交。Linux 远端分支仍为 `97f1fd75e12b4b9606974890bfa317a7bac9b6e3`，本地 HEAD 与它相同；功能比较包含当前未提交工作区。

本轮结论：Linux 已有主要写作、资料、RSS 和受保护发布路径，但高级恢复、发布结果核实及跨端数据交换仍有差距。旧清单中“模型发现/连接测试未接通”已过时；建站向导、浏览器扩展、外部 MCP 客户端和应用内模型下载已从最新主线撤下，不再作为追平目标。

同日后续实施：P29 基础连接收尾、P30 主编辑器安全退出、P31 Git 推送执行记录和 P32 PR/MR 执行记录/跨重启只读核实已完成本地实现与测试，P33 随后增加只读下线引用审阅、来源复核与定位，见 [P33](p33-unpublish-impact.md)。此前各阶段分别见 [P29](p29-ai-connection.md)、[P30](p30-editor-safe-exit.md)、[P31](p31-publish-ledger.md)、[P32](p32-remote-review-verification.md)。下面的审计发现和末尾验证表保留首次对比时的历史结果；后续验证以对应阶段记录为准。

## 拉取范围和比较方法

执行了显式引用更新，避免单分支克隆遗漏 `main`：

```bash
git fetch origin refs/heads/main:refs/remotes/origin/main refs/heads/codex/linux-tauri-mvp:refs/remotes/origin/codex/linux-tauri-mvp
```

| 提交 | 日期 | 远端提交说明 |
| --- | --- | --- |
| `fb6fd83` | 2026-09-14 | fix: protect drafts, Git publishing, and AI operations |
| `5df197d` | 2026-09-15 | refactor: streamline AI and workspace features and strengthen quality checks |
| `838e9f9` | 2026-09-23 | Sync editor, knowledge, AI, and publishing improvements |
| `6857545` | 2026-09-24 | Sync RepoPress public source from fdb804fc |

旧、新 macOS 基线之间共 886 个文件变化，其中包含大量模块迁移、测试和文档；不以文件数或行数计算功能完成率。最新 `main` 不包含 `Apps/RepoPressDesktop`，本轮只下载对象并更新远端引用，没有把主线合并或覆盖到 Linux 分支。

主线程核对 AI、产品范围与验证结果，两路只读审阅分别核对内容/工作台和发布/恢复。macOS 使用固定 SHA 的 `git show`、`git grep`，Linux 追踪实际 UI → Gateway → Tauri 注册 → core。以下是功能与行为合同对照，不是两平台原生界面验收，也不穷举所有菜单项。

## 相对上次清单的重要变化

| 变化 | 最新主线与当前 Linux 的结论 |
| --- | --- |
| P29 连接基础已接通 | Linux `AiConnectionPanel` 同时挂入选区 AI 和连续对话；模型列表、选模型、小型文本探测都走一次性确认计划。剩余是集成细节、完整能力检测和真实服务验收，不能继续写“模型只能手填”。 |
| 新增笔记与 `.rpnotes` 交换 | macOS 有独立笔记编辑、归档、笔记包导入/导出和冲突副本流程；Linux 通用资料条目、Markdown 导出不能替代此能力。 |
| 新增 RSS 列表标题翻译 | macOS 有列表翻译开关、后端/语言选择和标题专用有界请求；Linux 正文、选区、结构化与批量预翻译已有，列表标题翻译缺失。 |
| 新增跨端工作区交换 | macOS 交换包只含站点配置摘要、文章草稿和附件，排除笔记、发布历史和凭据；Linux 没有等价交换包。它与 `.rpnotes`、完整备份是不同合同。 |
| 备份恢复范围扩大 | macOS 增加选择性备份/恢复及 iCloud 备份；Linux 仍只有 RSS 范围的备份恢复。应先补本地完整性与交换格式；iCloud 属平台差异，不能直接承诺 Linux 原样移植。 |
| 发布证据与下线审阅加强 | macOS 新增持久发布执行记录、冻结文件证据、网络结果不明后的只读核实，以及下线前文章引用影响审阅；Linux 后续 P31/P32 已覆盖 Git Push/PushRetry 与同项目 PR/MR 的持久记录和只读结果核实，P33 已补只读下线引用审阅，仍缺完整逐文件证据和下线执行流程。 |
| 工作台协作加强 | macOS 命令面板接入资料库/RSS 搜索，设置更明确区分共享 AI 连接与站点写作偏好；Linux 的文件/命令面板和简单设置仍需扩展。 |
| 主线删减与模块迁移 | `SiteStarter*`、`BrowserExtension/` 及其桥、`PublishingMCPClient/`、`LocalAIModelDownloadService` 已撤下；内建 Agent、外部引擎发现仍存在。大量 AI/资料/Git/Markdown 文件迁到独立 Core 模块，不能据旧路径消失判断功能删除。 |

## 当前剩余工作清单

“部分”表示已有基础，待补列才是差距；“缺失”仅针对该行具体能力。“待验收”不等于源码缺失。

| 编号 | 模块 | Linux 当前状态 | 待补范围 |
| --- | --- | --- | --- |
| 1 | AI 连接与模型能力 | 部分，P29 基础本地收尾已完成 | 基础端点/错误提示和组件回归已补齐；仍需流式、工具、结构化输出、视觉等能力证据及过期状态、真实服务验证。 |
| 2 | 本地引擎 / Codex 准备 | 部分：已配置 Ollama 可用 | 本地引擎发现和启动/准备引导、Codex 组件与账户连接；不再包含主线已移除的应用内模型下载。 |
| 3 | 站点 AI 配置与写作风格 | 缺失站点作用域流程 | 共享连接与当前站点的绑定、范例文章选择、发送预览、风格/术语规则、确认应用与来源复验。现有 AI 服务档案不是完整站点 AI 配置。 |
| 4 | AI 元数据与批量维护 | 缺失高级队列 | 元数据/图片文案建议、逐字段接受、术语/内链审阅、暂停/重试、请求取消与来源复验；P25 确定性标签批改和选区 AI 不覆盖这些范围。 |
| 5 | 编辑器与设置 | 部分，P23/P24 已有 | 原始 Front Matter 折叠、恢复冲突策略、完整 SEO/社交预览、附件交互、全局新文章默认值；按 Linux 编辑器技术栈实现等价行为。 |
| 6 | 工作台与多窗口 | 部分 | 命令面板跨资料库/RSS 搜索、持续写作目标、按窗口文章状态与布局；保留已有正文/字段问题定位。 |
| 7 | 批量元数据 | 部分，P25 | 复杂 YAML/TOML、审阅式创建缺失 Front Matter、多对多重命名等；不能整篇无提示重写。 |
| 8 | 图片与资源维护 | 部分，P19/P22/P26 | 跨文章修复、封面/附件语义、复杂引用、压缩/WebP/裁剪/隐私清理、移动删除与撤销。当前扫描/预览/复用、引用诊断和单处修复保留。 |
| 9 | 保存恢复与安全退出 | 部分，P30 当前文章关闭保护已实施 | 当前文章冻结、主文件读回、一次性退出证明与可验证恢复包已实现；仍需全工作区后台持久化排空、附件和发布台账证据、真实桌面验收。[范围与验证](p30-editor-safe-exit.md)。 |
| 10 | 发布审阅、执行记录与台账 | 部分，P31/P32 已实施 | Git 推送与同项目 PR/MR 已先持久记录冻结目标，支持跨重启只读核实；仍需逐文件审阅完整性、部署错误源文件定位和真实服务验收。[P31](p31-publish-ledger.md) / [P32](p32-remote-review-verification.md)。 |
| 11 | 文章下线 | 部分，P33 只读审阅 | 已有有界源文件引用影响预览、显式来源复核和定位；仍缺真实路由/复杂语法覆盖、后端执行时来源复验、远端删除/下线 PR/MR、失败重试与本地清理。 |
| 12 | Git 同步与冲突 | 缺失高级流程 | rebase/merge 的计划、执行、冲突解决、取消及中断恢复；已有 fetch/push/index 操作保留。 |
| 13 | 多站点完整配置 | 部分，P21 | 模板/路径/默认作者分类/部署配置、复制、站点专属草稿归属与删除撤销；命名登记及受保护切换已存在。 |
| 14 | 知识库高级协作 | 部分 | 集合/批注/推荐/反向关联、跨 RSS/资料的写作目标与来源呈现、图片资料批量导出；保留现有资料分类、版本及显式 AI 授权。 |
| 15 | 独立笔记及笔记包 | 缺失 | 笔记编辑/归档、`.rpnotes` 清单与附件验证、导入预览、冲突副本和完整事务。通用资料导出不能代替交换协议。 |
| 16 | RSS 列表标题翻译 | 缺失此层 | 有界批次、取消/缓存、语言与后端选择、只发送标题的预览授权；已有正文/选区/批量翻译保留，Apple Translation 需平台替代方案。 |
| 17 | 内建 AI Agent | 缺失工具执行流程 | 内建工具目录、权限、调用确认、执行/取消及结果呈现。外部 MCP 客户端已从当前主线撤下，不混入本轮追平目标。 |
| 18 | 全工作区备份恢复 | 缺失 | 统一资料/RSS/草稿/配置/附件清单、排除凭据、选择性恢复、暂存与回滚；云端完成状态另行设计。 |
| 19 | 跨端工作区交换 | 缺失 | 站点摘要/草稿/附件交换、路径冲突预览、完整性核验及确认导入；与笔记包和完整备份分开。 |
| 20 | 内容维护与日志 | 部分 | 内容健康报告接可审阅修复队列；业务历史投影、AI/RSS 等事件、发布记录关联和保留策略。主线已撤下的建站向导不再列入。 |
| 21 | 隐私遮挡与界面语言 | 缺失对应 UI | 快速隐藏、私密内容遮挡/无障碍隐藏；跟随系统、中文/英文 UI。界面遮挡不等于加密，文章翻译不等于 UI 本地化。 |
| 22 | Linux 更新发布配置 | 待配置/验收 | 更新代码存在，但默认 endpoint 与公钥仍为空；需真实签名 AppImage 产物链路验证，`.deb` 走包管理升级。 |
| 23 | Linux 桌面发行矩阵 | 待目标环境验收 | 按现有合同覆盖 Ubuntu 22.04/24.04、GNOME/KDE、X11/Wayland、HiDPI、IBus/Fcitx5、AT-SPI，并绑定同一产物。 |

## P29 审计发现（同日后续已修复）

当前实际入口是 [AiConnectionPanel](../src/components/AiConnectionPanel.tsx)，由 [AIAssistant](../src/components/AIAssistant.tsx) 和 [AIChatPanel](../src/components/AIChatPanel.tsx) 挂载，经 [Gateway](../src/platform/repositoryGateway.ts)、[AI 命令](../src-tauri/src/commands/ai.rs)、[Tauri 注册](../src-tauri/src/lib.rs) 到 [AiConnectionStore](../src-tauri/src/core/ai_connection.rs)。计划五分钟有效、一次性消费，执行前重新核对配置与凭据；探测仅发送固定短文本，不发送文章/资料。

首次对比的源码检查及纯函数复核发现以下两处集成问题；随后 P29 实施已修复并补充组件回归：

1. 收尾前 `AiConnectionPanel` 的 `planMatchesRequest` 直接比较输入 endpoint 与计划 endpoint；Rust [ai_provider.rs:121](../src-tauri/src/core/ai_provider.rs#L121) 会规范化尾斜杠。输入 `http://127.0.0.1:11434/v1/`、计划返回 `/v1` 时比对为 `false`，`createPlan` 会丢弃响应而不展示确认。初次纯函数复核已得到 `false`；现已修复，未做原生窗口复现。
2. 面板 `connectionErrorLabel` 期待 `credential_missing`、`network_unavailable`、`invalid_endpoint` 等码，而后端实际会返回 `auth`、`network`、`ai_endpoint_invalid`、`ai_endpoint_policy_rejected`。鉴权/网络错误在纯函数复核中均退化为同一通用提示，分状态修复引导仍不完整。

模型发现不代表视觉/工具/流式能力。初次审计只有 Gateway 的 3 项连接专项前端测试；随后已补充 36 项 `AiConnectionPanel` 组件回归和 2 项 Rust 消费/过期回归，详见 P29 记录。

## 主要固定源码依据

以下 macOS 链接固定到本次 SHA；应使用这些路径，避免误读 Linux 分支里的旧 Swift 文件。

| 范围 | macOS 固定依据 | Linux 依据 |
| --- | --- | --- |
| AI 设置与能力 | [AISiteSettingsView](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Views/Settings/AISiteSettingsView.swift)、[能力种类](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingAICore/AIProviderCapabilityModels.swift)、[建议应用合同](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingWorkbenchCore/Stores/AIApplicationContract.swift) | 上述 P29 链路、[设置](../src/components/SettingsCenter.tsx)、[站点登记](../src-tauri/src/core/site_profiles.rs) |
| 笔记包 | [交换界面](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Views/Knowledge/KnowledgeNoteTransferSheet.swift)、[RPNotesPackageCodec](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingKnowledgeCore/Services/RPNotesPackageCodec.swift) | [KnowledgeLibrary](../src/components/KnowledgeLibrary.tsx)、[资料命令](../src-tauri/src/commands/knowledge.rs) |
| RSS 标题与统一搜索 | [标题控制器](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Support/RSSListTitleTranslationController.swift)、[命令面板搜索](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Views/Workspace/WorkspaceCommandPaletteContentSearch.swift) | [RssReader](../src/components/RssReader.tsx)、[翻译面板](../src/features/translation/RssTranslationPanel.tsx)、[App](../src/App.tsx) |
| 发布与下线 | [PublishExecutionRecord](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingWorkbenchCore/Models/PublishExecutionRecord.swift)、[执行结果核实](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublish/RemoteRepositoryPublishService%2BExecutionVerification.swift)、[下线审阅](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Views/Editor/DraftUnpublishReviewView.swift) | [Git 重试](../src-tauri/src/core/git_publish.rs)、[远程评审](../src-tauri/src/core/remote_publish.rs)、[发布中心](../src/components/PublishCenter.tsx) |
| 安全退出 | [SafeTermination](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingWorkbenchCore/Stores/WorkbenchStore%2BSafeTermination.swift)、[编辑器排空](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Views/Editor/MacMarkdownEditorTerminationFlushRegistry.swift) | [冲突审阅](../src/components/SaveConflictReview.tsx)、[workspace_state](../src-tauri/src/core/workspace_state.rs) |
| 备份与交换 | [存储设置入口](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Views/Settings/StorageManagementView.swift)、[WorkspaceExchangeCodec](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PublishingWorkbenchCore/Services/WorkspaceExchangeCodec.swift)、[iCloud 备份](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6857545bdca00884593193175cffb654cc092a22/Sources/PersonalSitePublisherMac/Support/iCloudWorkspaceBackupStore.swift) | [RSS core](../src-tauri/src/core/rss.rs)、[设置](../src/components/SettingsCenter.tsx) |
| 更新与发行 | 平台各自的发行合同 | [Tauri 配置](../src-tauri/tauri.conf.json)、[Linux 发行验收](linux-release-acceptance.md) |

## 建议实施顺序

1. **P29 基础收尾已实施**：端点比对、错误提示、组件回归和一次性消费已补齐；真实服务验证仍需独立验收，不重复开发模型列表和基础探测。
2. **补数据可靠性**：P30 主编辑器安全退出/文章恢复包与 P31/P32 Git 推送和 PR/MR 执行记录/只读核实已实施；P33 下线影响审阅已补只读部分；接着补受保护的下线执行、完整逐文件发布证据和全工作区退出事务。
3. **补跨端工作流**：独立笔记/`.rpnotes`、工作区交换、本地选择性备份恢复；各自定义格式与事务，不混为一个通用导入按钮。
4. **补使用体验**：RSS 列表标题翻译、统一搜索、站点写作风格、AI 批量维护，然后继续图片、多站点和同步高级能力。

首次比较只更新文档；用户随后要求“下一步”，已实施第 1 项本地收尾及第 2 项中的主编辑器安全退出/文章恢复包、Git 推送及 PR/MR 执行记录与只读核实。其余项目保持建议状态，没有真实发布。最新验证见 [P32](p32-remote-review-verification.md)，下表保留首次比较结果。

## 本轮验证与边界

| 检查 | 本轮实际结果 |
| --- | --- |
| `npm test -- --run` | 88 个文件、528 项通过。 |
| `npm run build` | TypeScript 与 Vite 生产构建通过；仍有大于 500 kB chunk 提示。 |
| `npm run check:bundle` | 通过：首屏 JavaScript 513.8 KiB、9 个懒加载块。 |
| `npm run check:version` | 通过：0.1.0 一致。 |
| `cargo test --offline --manifest-path src-tauri/Cargo.toml` | 共 329 项：受限环境中 324 通过，5 项因回环监听 `Operation not permitted` 失败。 |
| 回环测试复跑 | 允许本机回环后，`cargo test --offline --manifest-path src-tauri/Cargo.toml --lib -- core::ai_connection::tests core::browser_capture::tests` 的 21 项全部通过，包含原来失败的全部 5 项。没有把环境错误当作功能失败，也没有宣称一次全套无失败。 |
| P29 辅助复核 | 从现有源码提取纯函数运行，确认尾斜杠计划比对拒绝、鉴权/网络错误提示退化。没有调用真实 AI。 |
| 工作区保护与文档检查 | 对本轮开始时的 342 个已修改/未跟踪文件记录内容哈希；最终除本轮明确更新的 README/对照索引外保持一致；`git diff --check` 及新增报告空白、链接检查通过。 |

Rust 构建曾报告损坏的增量编译缓存警告，编译器说明会忽略该缓存；测试复跑已完成，本轮没有清理用户目录或改编译配置。没有重跑 Clippy/fmt、打包 AppImage/deb、原生窗口/输入法/无障碍矩阵或 macOS 运行时，也没有真实 AI、GitHub/GitLab 发布、iCloud 验收。未修改生产代码、合并、提交、推送或删除既有功能。
